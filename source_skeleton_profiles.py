"""Optional source rest-direction profiles, independent of Rise outfit meshes.

VMD-only fallback is horizontal T-pose, marked for visual review. A known motion
can carry a verified/empirical profile selected by content hash. PMX is optional
and provides measured geometry, not a guarantee that it matches the VMD rig.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
from pmx_skeleton import read_skeleton

ARM_BONES = {f'{side}_{part}' for side in 'LR'
             for part in ('UpperArm', 'Forearm', 'Hand')}


def normalized(v):
    n = math.sqrt(sum(x*x for x in v))
    if n < 1e-10 or not math.isfinite(n):
        raise ValueError('Missing or zero-length source bone direction')
    return [x/n for x in v]


def between(a, b):
    a, b = normalized(a), normalized(b)
    dot = sum(x*y for x,y in zip(a,b))
    if dot < -0.999999:
        raise ValueError('Opposite source bone: needs explicit axis/roll calibration')
    return normalized([a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2],
                       a[0]*b[1]-a[1]*b[0], 1+dot])


def standard_profile():
    return dict(schema=1, id='standard_mmd_tpose', label='标准MMD水平手臂',
                scope='arm_rest_directions', confidence='assumed_requires_visual_review',
                note='VMD不含静止骨架；此为通用起点，不能保证任意模型/IK/附加变形完全正确。',
                corrections={bone:[0,0,0,1] for bone in sorted(ARM_BONES)})


def choose_profile(vmd_path, profile_dir=None):
    digest = hashlib.sha256(Path(vmd_path).read_bytes()).hexdigest()
    directory = Path(profile_dir or Path(__file__).with_name('source_profiles'))
    candidates = []
    for path in sorted(directory.glob('*.json')):
        profile = json.loads(path.read_text(encoding='utf-8-sig'))
        if profile.get('vmd_sha256') == digest:
            candidates.append(profile)
    if len(candidates) > 1:
        raise ValueError('More than one source profile matches this VMD; select explicitly')
    profile = candidates[0] if candidates else standard_profile()
    profile['selection'] = 'exact_vmd_sha256' if candidates else 'standard_fallback'
    return profile


def profile_from_pmx(path):
    model = read_skeleton(path)
    index = {bone['name']:bone for bone in model['bones']}
    measurements, corrections = {}, {}
    for side, prefix in [('L','左'),('R','右')]:
        for part, start, end in [('UpperArm','腕','ひじ'), ('Forearm','ひじ','手首'),
                                  ('Hand','手首','中指１')]:
            a = index.get(prefix+start)
            b = index.get(prefix+end)
            if part == 'Hand' and b is None:
                b = index.get(prefix+'中指1')
            if a is None or b is None:
                raise ValueError(f'PMX lacks required endpoint: {prefix+start}/{prefix+end}')
            direction = normalized([y-x for x,y in zip(a['pos'],b['pos'])])
            bone = side+'_'+part
            axis = [1 if side=='L' else -1, 0, 0]
            corrections[bone] = between(axis, direction)
            measurements[bone] = dict(start=a['name'], end=b['name'], direction=direction,
                down_degrees=math.degrees(math.atan2(-direction[1],abs(direction[0]))))
    return dict(schema=1, id='pmx_'+hashlib.sha256(Path(path).read_bytes()).hexdigest()[:12],
                label=Path(path).stem, scope='arm_rest_directions',
                confidence='measured_geometry_vmd_match_unverified',
                pmx_sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest(),
                source_file=Path(path).name, corrections=corrections, measurements=measurements,
                note='自动提取静止方向。尚未自动验证PMX与VMD匹配；不等价于完整PMX继承/IK求值，手掌roll需另验。')


def inspect_vmd_header(path):
    raw = Path(path).read_bytes()
    if not raw.startswith(b'Vocaloid Motion Data'):
        raise ValueError('Not VMD motion data')
    length = 20 if b'0002' in raw[:30] else 10
    model_bytes = raw[30:30+length].split(b'\0')[0]
    return dict(file=Path(path).name, sha256=hashlib.sha256(raw).hexdigest(),
                model_name_candidates={encoding:model_bytes.decode(encoding,errors='replace')
                                       for encoding in ('cp932','gbk','utf-8')})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--pmx', type=Path)
    group.add_argument('--vmd', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = profile_from_pmx(args.pmx) if args.pmx else dict(
        motion=inspect_vmd_header(args.vmd), selected_profile=choose_profile(args.vmd))
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(args.output)


if __name__ == '__main__':
    main()
