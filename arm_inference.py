"""Conservative VMD-only arm-plane estimate; does not recover a complete rig."""
import math
from source_skeleton_profiles import standard_profile


def infer_profile(vmd):
    measurements = {}
    index = vmd.bone_index()
    for side, prefix in [('L', '左'), ('R', '右')]:
        vectors = []
        for _, _, q in index.get(prefix+'ひじ', []):
            length = math.sqrt(sum(x*x for x in q[:3]))
            # Discard near-zero rotations: their axis is numerically unstable.
            if length > math.sin(math.radians(7.5)):
                vectors.append([x/length for x in q[:3]])
        if len(vectors) < 20:
            return None
        matrix = [[sum(v[i]*v[j] for v in vectors) for j in range(3)] for i in range(3)]
        axis = vectors[len(vectors)//2]
        for _ in range(40):
            axis = [sum(row[j]*axis[j] for j in range(3)) for row in matrix]
            length = math.sqrt(sum(x*x for x in axis))
            if length < 1e-10:
                return None
            axis = [x/length for x in axis]
        concentration = sum(sum(a*b for a,b in zip(v,axis))**2 for v in vectors)/len(vectors)
        # Expected elbow axes for downward XY-plane arm rests. Sign is arbitrary.
        if axis[1] < 0:
            axis = [-x for x in axis]
        if concentration < .995 or abs(axis[2]) > .05:
            return None
        if (side == 'L' and axis[0] < 0) or (side == 'R' and axis[0] > 0):
            return None
        degrees = math.degrees(math.atan2(abs(axis[0]), abs(axis[1])))
        if not 10 <= degrees <= 70:
            return None
        measurements[side] = dict(down_degrees=degrees, axis=axis,
                                  concentration=concentration, active_keys=len(vectors))
    if abs(measurements['L']['down_degrees']-measurements['R']['down_degrees']) > 3:
        return None
    profile = standard_profile()
    profile.update(id='vmd_elbow_plane_estimate', label='VMD肘轴推断手臂初始方向',
        selection='bilateral_elbow_axis', confidence='inferred_requires_visual_review',
        measurements=measurements,
        note='双侧肘轴高度集中且近似镜像。假设初始手臂位于XY平面并下垂；不能恢复手掌roll、肩部继承或完整PMX骨架。')
    for side in 'LR':
        angle = math.radians(measurements[side]['down_degrees']) * (-1 if side=='L' else 1)
        for part in ('UpperArm','Forearm','Hand'):
            profile['corrections'][side+'_'+part] = [0,0,math.sin(angle/2),math.cos(angle/2)]
    return profile
