"""Pelvis displacement from bind position, including non-center translations."""
from pmx_skeleton import read_skeleton
from retarget_smile_arms import mul


def rotate(q,v):
    x,y,z,w=q;a,b,c=v
    tx,ty,tz=2*(y*c-z*b),2*(z*a-x*c),2*(x*b-y*a)
    return [a+w*tx+y*tz-z*ty,b+w*ty+z*tx-x*tz,c+w*tz+x*ty-y*tx]


class PelvisMotion:
    def __init__(self, tracks, pmx=None):
        self.tracks=tracks
        self.chain=None
        self.rest=[0.,0.,0.]
        self.details={'method':'root_chain_plus_lower_body_translation',
                      'vertical_reference':'rest_pose',
                      'channels':['全ての親','センター','グルーブ','腰','下半身']}
        if pmx:
            model=read_skeleton(pmx)
            bones=model['bones'];index={b['name']:b for b in bones}
            lower=index.get('下半身')
            if lower is None:raise ValueError('PMX缺少下半身骨骼，无法确定骨盆位移')
            chain=[];seen=set();b=lower
            while b is not None:
                if b['index'] in seen:raise ValueError('PMX骨盆父链存在循环')
                seen.add(b['index']);parent=bones[b['parent']] if b['parent']>=0 else None
                if b.get('inherit') and abs(b['inherit'][1])>1e-8:
                    raise ValueError('PMX骨盆父链含附加变换，当前无法可靠转换')
                offset=[x-y for x,y in zip(b['pos'],parent['pos'] if parent else [0,0,0])]
                chain.append((b['name'],offset));b=parent
            self.chain=list(reversed(chain));self.rest=lower['pos']
            self.details.update(method='pmx_pelvis_fk_minus_bind_position',
                channels=[n for n,_ in self.chain],pmx_model=model['model'])

    def at(self, frame):
        tr=self.tracks;pos=[0.,0.,0.];q=[0.,0.,0.,1.]
        if self.chain is not None:
            for name,offset in self.chain:
                step=rotate(q,[a+b for a,b in zip(offset,tr.p(name,frame))])
                pos=[a+b for a,b in zip(pos,step)]
                q=mul(q,tr.q(name,frame))
            return [x-y for x,y in zip(pos,self.rest)]
        for name in ['全ての親','センター','グルーブ','腰']:
            step=rotate(q,tr.p(name,frame));pos=[a+b for a,b in zip(pos,step)]
            q=mul(q,tr.q(name,frame))
        step=rotate(q,tr.p('下半身',frame))
        return [a+b for a,b in zip(pos,step)]
