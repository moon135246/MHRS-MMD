"""Portable VMD -> MMD-Rise converter, no Blender required.

Supports sampled FK tracks, VMD Bezier position/Slerp rotation interpolation,
independent upper/lower body branches, root translation and 30 finger tracks.
Standard unbaked leg IK is solved offline and exported as ordinary FK frames.
"""
import argparse
from bisect import bisect_right
from functools import lru_cache
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
from vmd_lib import Vmd, VmdError
from source_skeleton_profiles import choose_profile, profile_from_pmx
from retarget_smile_arms import retarget, mul, inv, unit
from arm_inference import infer_profile
from motion_translation import PelvisMotion
from expression_assets import expression_data, expression_report
from leg_ik import LegIK, ik_may_be_enabled

I = [0.,0.,0.,1.]
IK_CONFIRMATION = ('此动作需要补算腿部 IK，才能得到可播放的腿部动作。\n\n'
    'IK 补算只能尽量还原原始 FK 效果，无法保证完全一致；缺少配套 PMX 时还会使用近似骨架。\n'
    '点击“确定”同意进行 IK 补算并继续转换；点击“取消”退出本次转换。')


class IKConsentRequired(ValueError):
    """No output is written until the caller explicitly allows IK baking."""
    def __init__(self, report):
        super().__init__(IK_CONFIRMATION)
        self.report=report

MAP = dict(Hip='Waist_00',spine_0='Spine_00',spine_1='Spine_01',
           Neck_0='Neck_00',Head='Head_00')
PARENT = dict(Hip=None,spine_0='Hip',spine_1='spine_0',Neck_0='spine_1',Head='Neck_0')
for side in 'LR':
    names = ['Shoulder','UpperArm','Forearm','Hand','Thigh','Shin','Foot','Toe']
    for part, joint in zip(names, ['Arm_00','Arm_01','Arm_02','Arm_03','Leg_00','Leg_01','Leg_02','Leg_03']):
        MAP[side+'_'+part] = side+'_'+joint
    previous = 'spine_1'
    for part in names[:4]:
        PARENT[side+'_'+part] = previous; previous = side+'_'+part
    previous = 'Hip'
    for part in names[4:]:
        PARENT[side+'_'+part] = previous; previous = side+'_'+part


def norm(q):
    n = math.sqrt(sum(x*x for x in q))
    if n < 1e-10:
        return I[:]
    return [x/n for x in q]


def rotate(q,v):
    x,y,z,w=q; a,b,c=v
    tx,ty,tz=2*(y*c-z*b),2*(z*a-x*c),2*(x*b-y*a)
    return [a+w*tx+y*tz-z*ty,b+w*ty+z*tx-x*tz,c+w*tz+x*ty-y*tx]


def slerp(a,b,t):
    a,b=norm(a),norm(b)
    d=sum(x*y for x,y in zip(a,b))
    if d<0: b=[-x for x in b]; d=-d
    if d>.9995: return norm([x+(y-x)*t for x,y in zip(a,b)])
    ang=math.acos(max(-1,min(1,d))); den=math.sin(ang)
    u,v=math.sin((1-t)*ang)/den,math.sin(t*ang)/den
    return [u*x+v*y for x,y in zip(a,b)]


@lru_cache(maxsize=65536)
def bezier(controls,t):
    x1,y1,x2,y2=[min(127,max(0,c))/127 for c in controls]
    if abs(x1-y1)+abs(x2-y2)<1e-10: return t
    lo,hi=0.,1.
    for _ in range(20):
        u=(lo+hi)/2; v=1-u
        x=3*v*v*u*x1+3*v*u*u*x2+u*u*u
        if x<t: lo=u
        else: hi=u
    u=(lo+hi)/2;v=1-u
    return 3*v*v*u*y1+3*v*u*u*y2+u*u*u


class Tracks:
    def __init__(self,vmd,count):
        self.vmd,self.count=vmd,count
        self.index=vmd.bone_index();self.cache={}

    def dense(self,name):
        if name in self.cache:return self.cache[name]
        keys=list({k[0]:k for k in self.index.get(name,[])}.values())
        keys.sort(key=lambda k:k[0])
        if not keys:
            out=[([0.,0.,0.],I)]*self.count
        else:
            frames=[k[0] for k in keys];out=[]
            for f in range(self.count):
                j=bisect_right(frames,f)
                if j==0: p,q=keys[0][1:]
                elif j==len(keys) or frames[j-1]==f:p,q=keys[j-1][1:]
                else:
                    a,b=keys[j-1],keys[j]; t=(f-a[0])/(b[0]-a[0])
                    c=self.vmd.interpolations.get((name,b[0]),tuple([20,20,20,20,20,20,20,20,107,107,107,107,107,107,107,107]+[0]*48))
                    p=[a[1][axis]+(b[1][axis]-a[1][axis])*bezier(tuple(c[axis:axis+16:4]),t) for axis in range(3)]
                    q=slerp(a[2],b[2],bezier(tuple(c[3:19:4]),t))
                if not all(math.isfinite(x) for x in (*p,*q)):
                    raise ValueError(f'非有限数值：{name} / {f}')
                out.append((p,norm(q)))
        self.cache[name]=out
        return out

    def q(self,name,f):return self.dense(name)[f][1]
    def p(self,name,f):return self.dense(name)[f][0]


def angle_max(keys):
    return max([2*math.degrees(math.acos(min(1,abs(norm(k[2])[3])))) for k in keys] or [0])


def diagnose(vmd):
    idx=vmd.bone_index(); warnings=[];need_ik=[]
    for side in ['左','右']:
        ik=idx.get(side+'足ＩＫ',idx.get(side+'足IK',[]))
        span=max([max(k[1][i] for k in ik)-min(k[1][i] for k in ik) for i in range(3)] or [0]) if ik else 0
        if span>.1 and angle_max(idx.get(side+'ひざ',[]))<1 and ik_may_be_enabled(vmd,side+'足ＩＫ'):
            need_ik.append(side+'足ＩＫ')
    if need_ik:warnings.append('腿部依赖尚未烘焙的IK：'+','.join(need_ik))
    handled={'全ての親','センター','グルーブ','腰','下半身','上半身','上半身2','首','頭'}
    for side in ['左','右']:
        handled.update(side+n for n in ['肩P','肩','肩C','腕','腕捩','ひじ','手捩','手首','足','ひざ','足首','つま先'])
        for name in ['親指','人指','中指','薬指','小指']:
            handled.update(side+name+str(i) for i in range(3))
            handled.update(side+name+chr(ord('０')+i) for i in range(3))
    handled.update(n for candidates in finger_mapping().values() for n in candidates)
    ignored=[n for n,k in idx.items() if n not in handled and angle_max(k)>1 and not any(x in n for x in ['ＩＫ','IK','目','髪','スカート','指先'])]
    if ignored:warnings.append('存在额外活动控制骨，需核对：'+', '.join(ignored[:20]))
    return dict(bone_tracks=len(idx),bone_keys=len(vmd.bones),morph_keys=len(vmd.morphs),
        ik_keys=len(vmd.iks),trailing_bytes=vmd.trailing,requires_ik_bake=need_ik,
        warnings=warnings)


def finger_mapping():
    result={}
    groups=[('親指',[0,1,2]),('人指',[1,2,3]),('中指',[1,2,3]),('薬指',[1,2,3]),('小指',[1,2,3])]
    for side,prefix in [('L','左'),('R','右')]:
        numbers=[i for i in range(16) if i!=9] if side=='L' else list(range(15))
        for target,(name,j) in zip(numbers,[(n,j) for n,ns in groups for j in ns]):
            result[f'{side}_Finger_{target:02}']=[prefix+name+chr(ord('０')+j),prefix+name+str(j)]
    return result


def convert(vmd_path,slug,output_dir,label=None,pmx=None,profile_path=None,scale=.08023,register=True,vertical_reference='rest',expression_path=None,allow_ik=False):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}',slug):
        raise ValueError('曲目ID只能使用英文字母、数字、下划线和短横线')
    vmd_path,output_dir=Path(vmd_path),Path(output_dir)
    if not math.isfinite(scale) or scale <= 0:
        raise ValueError('位移缩放必须是大于零的有限数值')
    if vertical_reference not in ('rest','first_frame'):
        raise ValueError('高度基准必须为rest或first_frame')
    with vmd_path.open('rb') as source:
        if not source.read(30).startswith(b'Vocaloid Motion Data'):
            raise ValueError('文件不是有效的 VMD 动作文件')
    try:
        vmd=Vmd(vmd_path).parse()
    except (VmdError,struct.error,IndexError) as exc:
        raise ValueError('VMD 数据不完整或格式不受支持：'+str(exc)) from exc
    if not vmd.bones:raise ValueError('这不是模型动作VMD，可能是表情或镜头文件')
    count=max(k[1] for k in vmd.bones)+1
    if count>36000:raise ValueError('动作超过20分钟，请先裁剪后转换')
    facial=expression_data(expression_path) if expression_path else expression_data(vmd_path,parsed=vmd,required=False)
    report=diagnose(vmd);report['source_file']=vmd_path.name;report['count']=count
    if report['requires_ik_bake'] and not allow_ik:raise IKConsentRequired(report)
    output_dir.mkdir(parents=True,exist_ok=True)
    tr=Tracks(vmd,count);frames=[];pelvis_motion=PelvisMotion(tr,pmx)
    leg_solver=None
    if report['requires_ik_bake']:
        try:leg_solver=LegIK(tr,vmd,pmx)
        except ValueError as exc:
            report['ik_error']=str(exc)
            (output_dir/f'dance_{slug}_report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            raise
        report['warnings']=[w for w in report['warnings'] if not w.startswith('腿部依赖尚未烘焙的IK')]
        if not pmx:report['warnings'].append('腿 IK 使用内置标准骨架近似（验证版）；VMD 不含腿长，请对照原视频复核膝盖和落脚，配套 PMX 可提供实测骨架。')
    for f in range(count):
        g=I
        for name in ['全ての親','センター','グルーブ','腰']:
            g=mul(g,tr.q(name,f))
        w={'Hip':mul(g,tr.q('下半身',f)), 'spine_0':mul(g,tr.q('上半身',f))}
        w['spine_1']=mul(w['spine_0'],tr.q('上半身2',f))
        w['Neck_0']=mul(w['spine_1'],tr.q('首',f));w['Head']=mul(w['Neck_0'],tr.q('頭',f))
        for side,prefix in [('L','左'),('R','右')]:
            shoulder=mul(mul(w['spine_1'],tr.q(prefix+'肩P',f)),tr.q(prefix+'肩',f))
            w[side+'_Shoulder']=shoulder
            upper=mul(mul(shoulder,tr.q(prefix+'肩C',f)),tr.q(prefix+'腕',f))
            fore=mul(mul(upper,tr.q(prefix+'腕捩',f)),tr.q(prefix+'ひじ',f))
            hand=mul(mul(fore,tr.q(prefix+'手捩',f)),tr.q(prefix+'手首',f))
            w[side+'_UpperArm'],w[side+'_Forearm'],w[side+'_Hand']=upper,fore,hand
            prev=w['Hip']
            for part,jp in [('Thigh','足'),('Shin','ひざ'),('Foot','足首'),('Toe','つま先')]:
                prev=mul(prev,tr.q(prefix+jp,f));w[side+'_'+part]=prev
        if leg_solver:w.update(leg_solver.solve(f))
        frame={'pos':[round(x,7) for x in pelvis_motion.at(f)]}
        for bone in MAP:
            parent=PARENT[bone]
            frame[bone]=dict(w=unit(w[bone]),r=unit(mul(inv(w[parent]),w[bone]) if parent else w[bone]))
        frames.append(frame)
    if leg_solver:
        report['ik_baked']=True
        report['leg_ik']=leg_solver.stats
        report['leg_ik']['mean_ankle_error']=leg_solver.stats['ankle_error_sum']/max(1,leg_solver.stats['ankle_samples'])
        if leg_solver.stats['max_ankle_error']>.1:
            report['warnings'].append('部分帧脚 IK 目标未完全到达；可能超出腿长或受关节限制，请核对配套模型及落脚。')
    # A measured PMX bind pose does not supersede an exact-motion calibration:
    # the supplied model may differ from the rig on which the VMD was authored.
    known_profile=choose_profile(vmd_path)
    if profile_path:
        profile=json.loads(Path(profile_path).read_text(encoding='utf-8-sig'))
        profile['selection']='explicit_profile'
    elif known_profile.get('selection') == 'exact_vmd_sha256':
        profile=known_profile
        if pmx:
            profile=dict(profile,pmx_usage='pelvis_translation_only; verified_arm_profile_preserved')
    elif pmx:
        profile=profile_from_pmx(pmx)
        profile['selection']='pmx_geometry'
    else:
        profile=known_profile
    if profile.get('selection') == 'standard_fallback':
        profile = infer_profile(vmd) or profile
    ident={b:I[:] for b in MAP}
    data=dict(name=label or vmd_path.stem,slug=slug,fps=30,start=0,count=count,ref=0,
        order=list(MAP),map=MAP,parent=PARENT,bind=ident,restw=ident,
        wref={b:frames[0][b]['w'] for b in MAP},frames=frames,w_anchor='rise_pure_identity',
        pos_bone='Hip',pos_unit='mmd',pos_scale=scale,pos_z_flip=True,pos_mirror=False,
        pos_y_reference=vertical_reference,pos_y_rest=0.,position_schema=2,
        g_x180=False,root_zero=False,yaw180=False,reflect_z=True,reflect_x=False,
        arm_pure_local=False,fix_foot=False,fix_arm=False,foot_pitch=0.,shoulder_pitch=0.,
        arm_width=0.,elbow_pitch=0.,converter='mhrs_vmd_1',
        source_sha256=hashlib.sha256(vmd_path.read_bytes()).hexdigest())
    data=retarget(data,profile=profile)
    if leg_solver:data['leg_ik_bake']=report['leg_ik']
    if facial:data['morphs']=facial
    data['wref']={b:data['frames'][0][b]['w'] for b in MAP}
    fingers=[];fm=finger_mapping()
    for f in range(count):
        frame={}
        for target,candidates in fm.items():
            name=next((n for n in candidates if n in tr.index),None)
            q=tr.q(name,f) if name else I
            d=profile['corrections'][target[0]+'_Hand']
            q=unit(mul(inv(d),mul(q,d)))
            frame[target]=[-q[0],-q[1],q[2],q[3]]  # same Mz coordinate conversion as body
        fingers.append(frame)
    report['source_profile']=profile;report['duration_seconds']=count/30
    report['translation']=dict(pelvis_motion.details,
        vertical_reference=vertical_reference,initial=frames[0]['pos'],
        ranges=[[min(f['pos'][i] for f in frames),max(f['pos'][i] for f in frames)] for i in range(3)])
    report['expressions']=expression_report(facial,count)
    if facial and facial['clamped_keys']:
        report['warnings'].append(f"{facial['clamped_keys']} 个表情权重超出 0～1，已限制到模型的标准范围。")
    if facial and facial['end']>=count:
        report['warnings'].append('表情尾部超过身体动作；只播放身体动作时间范围内的表情。')
    report['supported']='FK body/arms/legs, root, fingers, sparse VMD morphs via ShapeKeySystem; camera imported separately'
    if leg_solver:report['supported']+='; standard offline leg/toe IK (preview)'
    for name,obj in [(f'dance_{slug}.json',data),(f'dance_{slug}_fingers.json',fingers),(f'dance_{slug}_report.json',report)]:
        (output_dir/name).write_text(json.dumps(obj,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    if register:
        p=output_dir/'library.json'
        library=json.loads(p.read_text(encoding='utf-8-sig')) if p.exists() else dict(version=1,clips=[])
        clips=[c for c in library.get('clips',[]) if c.get('slug')!=slug]
        clips.append(dict(slug=slug,label=label or vmd_path.stem,count=count,fps=30))
        library.update(version=1,clips=clips)
        p.write_text(json.dumps(library,ensure_ascii=False,indent=2),encoding='utf-8')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('vmd',type=Path);parser.add_argument('--slug',required=True)
    parser.add_argument('--output',type=Path,required=True);parser.add_argument('--name')
    group=parser.add_mutually_exclusive_group();group.add_argument('--pmx',type=Path);group.add_argument('--profile',type=Path)
    parser.add_argument('--scale',type=float,default=.08023)
    parser.add_argument('--height-reference',choices=['rest','first_frame'],default='rest')
    parser.add_argument('--expression',type=Path,help='可选：独立表情VMD，替代动作文件内的表情')
    parser.add_argument('--allow-ik',action='store_true',help='明确同意对需要补算的动作进行腿部 IK 补算；结果不能保证与原始 FK 完全一致')
    args=parser.parse_args()
    report=convert(args.vmd,args.slug,args.output,args.name,args.pmx,args.profile,args.scale,vertical_reference=args.height_reference,expression_path=args.expression,allow_ik=args.allow_ik)
    print(json.dumps({k:report[k] for k in ['count','duration_seconds','warnings']},ensure_ascii=False))


if __name__=='__main__':
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    try:main()
    except (ValueError,OSError) as e:
        print('转换未完成：'+str(e),file=sys.stderr);sys.exit(1)
