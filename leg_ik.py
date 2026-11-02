"""Offline standard MMD leg/toe IK baking. No game runtime dependency.

The built-in skeleton is an explicit approximation, not recovered VMD geometry.
PMX input uses its measured rest offsets and standard two-link knee constraints.
Unsupported append transforms/chains fail rather than silently approximating PMX.
"""
import bisect
import math
from pmx_skeleton import read_skeleton
from retarget_smile_arms import mul, inv

I = [0., 0., 0., 1.]


def add(a,b): return [x+y for x,y in zip(a,b)]
def sub(a,b): return [x-y for x,y in zip(a,b)]
def dot(a,b): return sum(x*y for x,y in zip(a,b))
def length(a): return math.sqrt(dot(a,a))
def cross(a,b): return [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]]
def unit(q):
    n=length(q)
    return [v/n for v in q] if n>1e-12 else I[:]


def rotate(q,v):
    t=[2*x for x in cross(q[:3],v)]
    return add(v,add([q[3]*x for x in t],cross(q[:3],t)))


def axis_angle(axis,angle):
    h=angle/2
    return [v*math.sin(h) for v in axis]+[math.cos(h)]


def direction(v):
    n=length(v)
    return [x/n for x in v] if n>1e-10 else None


def perpendicular(v,axis):
    return direction(sub(v,[dot(v,axis)*x for x in axis]))


def between(a,b,max_angle):
    na,nb=length(a),length(b)
    if min(na,nb)<1e-10:return I[:]
    a,b=[x/na for x in a],[x/nb for x in b]
    angle=math.acos(max(-1,min(1,dot(a,b))))
    axis=cross(a,b);n=length(axis)
    if n<1e-10:
        if angle<1e-8:return I[:]
        axis=cross(a,[1,0,0] if abs(a[0])<.9 else [0,1,0]);n=length(axis)
    return axis_angle([v/n for v in axis],min(angle,max_angle))


def ik_may_be_enabled(vmd,name):
    name=name.replace('IK','ＩＫ')
    keys=[]
    end=max((k[1] for k in vmd.bones),default=0)
    for frame,show,items in sorted(vmd.iks,key=lambda k:k[0]):
        for n,on in items:
            if n.replace('IK','ＩＫ')==name and frame<=end:keys.append((frame,bool(on)))
    return not keys or keys[0][0]>0 or any(on for _,on in keys)


def standard_skeleton():
    bones=[]
    def bone(name,pos,parent=None,ik=None):
        b=dict(index=len(bones),name=name,pos=pos,parent=parent,flags=0)
        if ik:b['ik']=ik
        bones.append(b)
        return b['index']
    root=bone('全ての親',[0,0,0]);center=bone('センター',[0,9,0],root)
    groove=bone('グルーブ',[0,9,0],center);waist=bone('腰',[0,12.8,0],groove)
    lower=bone('下半身',[0,12.8,0],waist)
    for side,x in [('左',.9),('右',-.9)]:
        hip=bone(side+'足',[x,11.1,0],lower)
        knee=bone(side+'ひざ',[x,6.2,-.1],hip)
        ankle=bone(side+'足首',[x,1.3,.3],knee)
        toe=bone(side+'つま先',[x,.1,-1.4],ankle)
        parent=bone(side+'足IK親',[0,0,0],root)
        ik=bone(side+'足ＩＫ',[x,1.3,.3],parent,
                dict(target=ankle,iterations=64,limit=1.,links=[
                    dict(index=knee,min=[-math.pi,0,0],max=[0,0,0]),dict(index=hip)]))
        bone(side+'つま先ＩＫ',[x,.1,-1.4],ik,
             dict(target=toe,iterations=8,limit=1.,links=[dict(index=ankle)]))
    return bones


class LegIK:
    def __init__(self,tracks,vmd,pmx=None):
        self.tracks=tracks
        self.bones=read_skeleton(pmx)['bones'] if pmx else standard_skeleton()
        self.byname={b['name']:b['index'] for b in self.bones}
        # VMD spelling variants refer to the same standard controls.
        for b in self.bones:
            if b['name'] not in tracks.index:
                alias=b['name'].replace('ＩＫ','IK')
                if alias in tracks.index:b['name']=alias
        self.chains=[]
        for side in ['左','右']:
            foot=self.byname.get(side+'足ＩＫ',self.byname.get(side+'足IK'))
            toe=self.byname.get(side+'つま先ＩＫ',self.byname.get(side+'つま先IK'))
            if foot is None:raise ValueError('标准腿 IK 缺少控制骨：'+side+'足ＩＫ')
            for control,expected in [(foot,[side+'ひざ',side+'足']),(toe,[side+'足首'])]:
                if control is None:continue
                b=self.bones[control];ik=b.get('ik')
                if not ik or [self.bones[l['index']]['name'] for l in ik['links']]!=expected:
                    raise ValueError('暂不支持此 PMX 的非标准腿 IK 链：'+b['name'])
                if self.bones[ik['target']]['name']!=(side+'足首' if control==foot else side+'つま先'):
                    raise ValueError('PMX 腿 IK 末端不符合标准：'+b['name'])
                if control==foot:
                    knee=ik['links'][0]
                    if any(abs(x)>1e-6 for x in knee.get('min',[0,1,1])[1:]+knee.get('max',[0,1,1])[1:]):
                        raise ValueError('暂不支持此 PMX 的非标准膝盖旋转限制')
                extra_limits=ik['links'][1:] if control==foot else ik['links']
                if any('min' in link or 'max' in link for link in extra_limits):
                    raise ValueError('验证版暂不支持髋部或脚踝额外 IK 限制：'+b['name'])
                self.chains.append(control)
        needed=set()
        def ancestors(i,seen=None):
            seen=set() if seen is None else seen
            if i is None or i<0:return
            if i in seen:raise ValueError('PMX 腿骨父链存在循环')
            seen.add(i);needed.add(i);ancestors(self.bones[i]['parent'],seen)
        for c in self.chains:
            ancestors(c);ancestors(self.bones[c]['ik']['target'])
            for link in self.bones[c]['ik']['links']:ancestors(link['index'])
        for i in needed:
            b=self.bones[i]
            if b.get('inherit') and abs(b['inherit'][1])>1e-8:
                raise ValueError('腿 IK 骨链含附加变换，验证版暂不支持：'+b['name'])
        self.needed=needed
        self.offset={i:sub(self.bones[i]['pos'],self.bones[self.bones[i]['parent']]['pos']
                         if self.bones[i]['parent'] is not None and self.bones[i]['parent']>=0 else [0,0,0]) for i in needed}
        self.switches={}
        for frame,show,items in sorted(vmd.iks,key=lambda k:k[0]):
            for name,enabled in items:self.switches.setdefault(name.replace('IK','ＩＫ'),{})[frame]=bool(enabled)
        self.switches={n:sorted(items.items()) for n,items in self.switches.items()}
        self.stats=dict(method='standard_two_bone_hinge_plus_toe_offline',geometry='pmx_measured' if pmx else 'builtin_standard_approximation',
                        frames=0,chains=[self.bones[i]['name'] for i in self.chains],
                        max_ankle_error=0.,max_toe_error=0.,ankle_error_sum=0.,ankle_samples=0,
                        ankle_over_0_1=0,knee_min_degrees=0.,knee_max_degrees=0.,max_reachable_solver_error=0.,unreachable_samples=0)
        self._plane_twists={}
        self._prepared=False

    def prepare(self):
        """Plan a small, centered correction in the source thigh's coordinates.

        Source rotation remains the reference. Only the IK correction near full
        extension is filtered; bent poses and IK-off boundaries are untouched.
        Planning the entire clip also makes seeking independent of call order.
        """
        if self._prepared:return
        self._prepared=True
        count=getattr(self.tracks,'count',0)
        samples={c:[None]*count for c in self.chains if len(self.bones[c]['ik']['links'])==2}
        for frame in range(count):self._solve(frame,measure=False,collect=samples)
        changed=near=0;maximum=0.
        for control,rows in samples.items():
            for f,row in enumerate(rows):
                if row is None or row['bend']>=12.:continue
                near+=1
                axis,pole=row['axis'],row['pole']
                sine=0.;cosine=0.
                for j in range(max(0,f-3),min(count,f+4)):
                    # Do not average across an IK switch, invalid direction, or
                    # a large target-direction cut in this short neighborhood.
                    segment=rows[min(f,j):max(f,j)+1]
                    if any(s is None for s in segment):continue
                    if any(dot(a['axis'],b['axis'])<.9 for a,b in zip(segment,segment[1:])):continue
                    other=rows[j]
                    transported=rotate(between(other['axis'],axis,math.pi),other['pole'])
                    transported=perpendicular(transported,axis)
                    if transported is None:continue
                    angle=math.atan2(dot(axis,cross(pole,transported)),dot(pole,transported))
                    weight=math.exp(-.5*((j-f)/1.5)**2)*(.25+.75*min(1.,other['bend']/12.))
                    sine+=weight*math.sin(angle);cosine+=weight*math.cos(angle)
                if sine*sine+cosine*cosine<1e-12:continue
                strength=max(0.,min(1.,(12.-row['bend'])/9.))
                strength=strength*strength*(3.-2.*strength)
                twist=max(-math.radians(8),min(math.radians(8),math.atan2(sine,cosine)))*strength
                if abs(twist)>1e-7:
                    self._plane_twists[control,f]=twist;changed+=1;maximum=max(maximum,abs(math.degrees(twist)))
        self.stats['knee_stability']=dict(method='source_relative_centered_plane',prepared_frames=count,
            window_radius_frames=3,extension_threshold_degrees=12.,max_allowed_twist_degrees=8.,
            near_extension_samples=near,adjusted_samples=changed,max_applied_twist_degrees=maximum,
            preserves_ankle_position=True,preserves_foot_world_rotation=True,seek_order_independent=True)

    def enabled(self,name,frame):
        items=self.switches.get(name.replace('IK','ＩＫ'),[])
        j=bisect.bisect_right([k[0] for k in items],frame)
        return items[j-1][1] if j else True

    def solve(self,frame):
        self.prepare()
        return self._solve(frame)

    def _solve(self,frame,measure=True,collect=None):
        tr=self.tracks;bones=self.bones
        local={i:list(tr.q(bones[i]['name'],frame)) for i in self.needed}
        positions={i:add(self.offset[i],tr.p(bones[i]['name'],frame)) for i in self.needed}
        cache={}
        def world(i):
            if i in cache:return cache[i]
            parent=bones[i]['parent']
            if parent is None or parent<0:p,q=positions[i],local[i]
            else:
                pp,pq=world(parent);p=add(pp,rotate(pq,positions[i]));q=unit(mul(pq,local[i]))
            cache[i]=(p,q)
            return p,q
        for control in self.chains:
            b=bones[control]
            if not self.enabled(b['name'],frame):continue
            ik=b['ik'];target=ik['target'];goal=world(control)[0][:]
            links=ik['links']
            if len(links)==2:
                # Solve the standard X hinge analytically. Unlike iterative CCD,
                # this reaches nearby straight-leg targets without slow convergence.
                knee,hip=links[0]['index'],links[1]['index']
                hp,hq=world(hip);delta=sub(goal,hp);distance=length(delta)
                u,v=positions[knee],positions[target]
                a=u[1]*v[1]+u[2]*v[2];bb=-u[1]*v[2]+u[2]*v[1]
                radius=math.hypot(a,bb)
                if radius<1e-8:raise ValueError('退化的腿骨无法进行标准 IK 求解')
                cosine=(distance*distance-dot(u,u)-dot(v,v)-2*u[0]*v[0])/(2*radius)
                phase=math.atan2(bb,a);angle=math.acos(max(-1,min(1,cosine)))
                low,high=links[0]['min'][0],links[0]['max'][0]
                candidates=[max(low,min(high,phase+sign*angle+turn*2*math.pi)) for sign in [-1,1] for turn in [-1,0,1]]
                def reach(theta):return length(add(u,rotate(axis_angle([1,0,0],theta),v)))
                old=2*math.atan2(local[knee][0],local[knee][3])
                theta=min(candidates,key=lambda x:(round(abs(reach(x)-distance),9),abs(x-old)))
                local[knee]=axis_angle([1,0,0],theta)
                effective=add(u,rotate(local[knee],v))
                correction=between(effective,rotate(inv(hq),delta),math.pi)
                local[hip]=unit(mul(local[hip],correction));cache.clear()
                parent=bones[hip]['parent']
                parent_q=world(parent)[1] if parent is not None and parent>=0 else I
                axis=direction(rotate(inv(parent_q),delta))
                if collect is not None and axis is not None:
                    # Remove the authored thigh orientation before comparing
                    # neighboring IK corrections. A deliberate source turn is
                    # therefore not treated as direction noise.
                    source=tr.q(bones[hip]['name'],frame)
                    source_axis=rotate(inv(source),axis)
                    pole=perpendicular(rotate(mul(inv(source),local[hip]),[1,0,0]),source_axis)
                    lower=rotate(local[knee],v)
                    bend=math.degrees(math.acos(max(-1.,min(1.,dot(u,lower)/max(1e-12,length(u)*length(lower))))))
                    if pole is not None:collect[control][frame]=dict(axis=source_axis,pole=pole,bend=bend)
                twist=self._plane_twists.get((control,frame),0.)
                if twist and axis is not None:
                    # Rotate the bend plane about the hip/goal ray: the solved
                    # ankle position stays fixed. Counter-rotate its local
                    # orientation so subsequent toe IK sees the original foot.
                    foot_q=world(target)[1]
                    local[hip]=unit(mul(axis_angle(axis,twist),local[hip]));cache.clear()
                    local[target]=unit(mul(inv(world(bones[target]['parent'])[1]),foot_q));cache.clear()
                residual=abs(reach(theta)-distance)
                if measure:
                    if residual>1e-4:self.stats['unreachable_samples']+=1
                    else:self.stats['max_reachable_solver_error']=max(self.stats['max_reachable_solver_error'],length(sub(world(target)[0],goal)))
            for iteration in range(0 if len(links)==2 else min(96,max(8,ik['iterations']))):
                if length(sub(world(target)[0],goal))<1e-5:break
                for link in links:
                    i=link['index'];p,q=world(i)
                    e=rotate(inv(q),sub(world(target)[0],p));t=rotate(inv(q),sub(goal,p))
                    if 'min' in link:
                        # Standard MMD knee: hinge around local X, negative bend.
                        angle=math.atan2(e[1]*t[2]-e[2]*t[1],e[1]*t[1]+e[2]*t[2])
                        angle=max(-ik['limit'],min(ik['limit'],angle))
                        old=2*math.atan2(local[i][0],local[i][3])
                        old=(old+math.pi)%(2*math.pi)-math.pi
                        new=max(link['min'][0],min(link['max'][0],old+angle))
                        local[i]=axis_angle([1,0,0],new)
                    else:local[i]=unit(mul(local[i],between(e,t,ik['limit'])))
                    cache.clear()
            error=length(sub(world(target)[0],goal))
            if not measure:continue
            if len(links)==2:
                self.stats['max_ankle_error']=max(self.stats['max_ankle_error'],error)
                self.stats['ankle_error_sum']+=error;self.stats['ankle_samples']+=1
                self.stats['ankle_over_0_1']+=error>.1
                knee=local[links[0]['index']];angle=math.degrees(2*math.atan2(knee[0],knee[3]))
                self.stats['knee_min_degrees']=min(self.stats['knee_min_degrees'],angle)
                self.stats['knee_max_degrees']=max(self.stats['knee_max_degrees'],angle)
            else:self.stats['max_toe_error']=max(self.stats['max_toe_error'],error)
        if measure:self.stats['frames']+=1
        return {side+'_'+part:world(self.byname[side_jp+jp])[1]
                for side,side_jp in [('L','左'),('R','右')]
                for part,jp in [('Thigh','足'),('Shin','ひざ'),('Foot','足首'),('Toe','つま先')]}
