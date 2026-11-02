"""Validate and publish VMD camera tracks independently of body retargeting."""
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import struct
from vmd_lib import Vmd, VmdError
from asset_names import asset_stem, source_asset


def stage_camera(source, target, slug, label=None, offset=0):
    source, target = Path(source), Path(target)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', slug):
        raise ValueError('曲目 ID 无效')
    raw = source.read_bytes()
    if not raw.startswith(b'Vocaloid Motion Data'):
        raise ValueError('镜头文件不是 VMD。')
    try:
        motion = Vmd(source).parse()
    except (VmdError, struct.error, IndexError) as exc:
        raise ValueError('镜头 VMD 不完整：'+str(exc)) from exc
    keys = sorted({k['frame']:k for k in motion.cameras}.values(), key=lambda k:k['frame'])
    if not keys:
        raise ValueError('所选镜头 VMD 没有相机关键帧，请选择镜头文件。')
    for k in keys:
        if not all(math.isfinite(v) for v in [k['distance'],*k['position'],*k['rotation']]):
            raise ValueError('镜头含有非有限数值。')
        if not 1 <= k['fov'] <= 179 or any(v > 127 for v in k['interpolation']):
            raise ValueError('镜头视角或插值数据无效。')
        if not k['perspective']:
            raise ValueError('此版本支持透视镜头；所选 VMD 包含正交镜头，暂不能导入。')
    offset = float(offset)
    if not math.isfinite(offset):
        raise ValueError('镜头偏移必须为有限秒数。')
    digest = hashlib.sha256(raw).hexdigest()
    filename = 'camera_'+digest[:24]+'.json'
    data = dict(version=1, fps=30, source_sha256=digest,
                start=keys[0]['frame'], end=keys[-1]['frame'], keys=keys)
    target.mkdir(parents=True, exist_ok=True)
    asset_temp=(target/filename).with_suffix('.json.importing')
    asset_temp.write_text(json.dumps(data,ensure_ascii=False,separators=(',',':')),encoding='utf-8')
    asset_temp.replace(target/filename)
    manifest = target/'camera_library.json'
    library = json.loads(manifest.read_text(encoding='utf-8-sig')) if manifest.exists() else {'version':1,'tracks':{}}
    library['tracks'][slug] = dict(file=filename,label=label or source.stem,offset=offset,
                                   start=data['start'],end=data['end'],fps=30)
    temp = manifest.with_suffix('.json.importing')
    temp.write_text(json.dumps(library,ensure_ascii=False,indent=2),encoding='utf-8')
    temp.replace(manifest)
    return data


def install_cameras(staged, target, nickname=None):
    staged, target = Path(staged), Path(target)
    manifest = staged/'camera_library.json'
    if not manifest.exists():
        return
    additions = json.loads(manifest.read_text(encoding='utf-8-sig'))
    target.mkdir(parents=True,exist_ok=True)
    output = target/'camera_library.json'
    library = json.loads(output.read_text(encoding='utf-8-sig')) if output.exists() else {'version':1,'tracks':{}}
    for slug, track in additions['tracks'].items():
        source = source_asset(staged, track['file'])
        data = json.loads(source.read_text(encoding='utf-8-sig'))
        digest = data.get('source_sha256', '')
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('镜头资源缺少校验标识')
        filename = asset_stem(nickname, slug) + '_camera.json' if nickname else 'camera_' + digest[:24] + '.json'
        dest = target/filename
        if source.resolve() != dest.resolve():
            temp = dest.with_suffix('.json.importing')
            shutil.copy2(source,temp)
            temp.replace(dest)
        library['tracks'][slug] = dict(track, file=filename)
    if output.exists():
        backup = target/'import_backups';backup.mkdir(exist_ok=True)
        saved = backup/('camera_library_'+hashlib.sha256(output.read_bytes()).hexdigest()[:16]+'.json')
        if not saved.exists():shutil.copy2(output,saved)
    temp = output.with_suffix('.json.importing')
    temp.write_text(json.dumps(library,ensure_ascii=False,indent=2),encoding='utf-8')
    temp.replace(output)
