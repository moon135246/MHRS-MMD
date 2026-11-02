"""Convert source rest-direction profiles to Rise arm rotation channels.

Historical filename retained for compatibility. Default is standard T-pose,
not a hardcoded 45 degrees. Profiles are independent of game outfit meshes.
"""
import argparse
import copy
import json
import math
from pathlib import Path
from source_skeleton_profiles import standard_profile, profile_from_pmx

ARM_BONES = {f'{side}_{part}' for side in 'LR'
             for part in ('UpperArm', 'Forearm', 'Hand')}
IDENT = [0.0, 0.0, 0.0, 1.0]


def mul(a, b):
    x, y, z, w = a
    u, v, t, s = b
    return [w*u+x*s+y*t-z*v, w*v-x*t+y*s+z*u,
            w*t+x*v-y*u+z*s, w*s-x*u-y*v-z*t]


def inv(q):
    return [-q[0], -q[1], -q[2], q[3]]


def unit(q):
    length = math.sqrt(sum(x*x for x in q))
    if length < 1e-12:
        raise ValueError('Zero quaternion')
    return [round(x/length, 8) for x in q]


def retarget(data, angle=None, profile=None):
    if data.get('arm_retarget'):
        raise ValueError('Already retargeted: rebake from original VMD or use a raw backup')
    if data.get('w_anchor') not in ('rise_pure_identity', 'identity_rise'):
        raise ValueError('Requires raw Rise identity animation, not Wilds-derived animation')
    if profile is not None and angle is not None:
        raise ValueError('Choose a source profile or an explicit legacy angle, not both')
    if angle is not None and not 0 <= angle <= 85:
        raise ValueError('Source arm rest angle must be between 0 and 85 degrees')
    for table in ('bind', 'restw'):
        if any(q != IDENT for q in data[table].values()):
            raise ValueError(f'{table} must remain Rise identity')
    if profile is None:
        profile = standard_profile()
        if angle is not None:
            profile.update(id='manual_angle',confidence='manual_calibration',
                           source_rest_down_degrees=angle)
            for bone in ARM_BONES:
                half = math.radians(-angle if bone.startswith('L_') else angle)/2
                profile['corrections'][bone] = [0,0,math.sin(half),math.cos(half)]
    if profile.get('schema') != 1 or profile.get('scope') != 'arm_rest_directions':
        raise ValueError('Unsupported source profile')
    if set(profile.get('corrections', {})) != ARM_BONES:
        raise ValueError('Source profile must contain exactly six arm corrections')
    for q in profile['corrections'].values():
        if len(q) != 4 or not all(isinstance(x,(int,float)) and math.isfinite(x) for x in q):
            raise ValueError('Invalid source profile quaternion')
        if abs(sum(x*x for x in q)-1) > 1e-5:
            raise ValueError('Source profile quaternion must be unit length')
    result = copy.deepcopy(data)
    correction = {}
    for bone in data['order']:
        if bone in ARM_BONES:
            correction[bone] = profile['corrections'][bone]
        else:
            correction[bone] = IDENT
    for original, output in zip(data['frames'], result['frames']):
        for bone in ARM_BONES:
            d = correction[bone]
            parent_d = correction.get(data['parent'].get(bone), IDENT)
            # Wtarget = Wsource D; Ltarget = Dparent^-1 Lsource Dchild.
            output[bone]['w'] = unit(mul(original[bone]['w'], d))
            output[bone]['r'] = unit(mul(inv(parent_d), mul(original[bone]['r'], d)))
    result['arm_retarget'] = {
        'version': 2, 'source_profile': copy.deepcopy(profile),
        'bones': sorted(ARM_BONES), 'formula': 'Wtarget=Wsource*D; Ltarget=inv(Dparent)*Lsource*Dchild',
        'target_bind_unchanged': True,
    }
    result['w_note'] = 'Rise identity target; source arm rest direction retargeted (see arm_retarget)'
    result['r_note'] = 'Rise T-pose local rotation; source arm rest direction converted'
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--angle', type=float, help='Explicit manual calibration; never a global default')
    group.add_argument('--profile', type=Path)
    group.add_argument('--pmx', type=Path)
    args = parser.parse_args()
    data = json.loads(args.source.read_text(encoding='utf-8-sig'))
    profile = profile_from_pmx(args.pmx) if args.pmx else (
        json.loads(args.profile.read_text(encoding='utf-8-sig')) if args.profile else None)
    result = retarget(data, angle=args.angle, profile=profile)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(f'Retargeted {len(result["frames"])} frames; profile: {result["arm_retarget"]["source_profile"]["id"]}')


if __name__ == '__main__':
    main()
