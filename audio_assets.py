"""Publish local music independently of motion data and model profiles."""
import hashlib
import json
from pathlib import Path
import shutil
from asset_names import asset_stem, source_asset


def stage_music(source, target, slug, label, offset=0):
    source, target = Path(source), Path(target)
    suffix = source.suffix.lower()
    if suffix not in {'.wav', '.mp3', '.flac'} or not source.is_file():
        raise ValueError('请选择 WAV、MP3 或 FLAC 音乐文件。')
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    relative = 'music/' + digest[:24] + suffix
    dest = target / relative
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists():
        temp = dest.with_suffix(suffix + '.importing')
        shutil.copy2(source, temp)
        temp.replace(dest)
    manifest = target / 'audio_library.json'
    data = json.loads(manifest.read_text(encoding='utf-8-sig')) if manifest.exists() else {'version': 1, 'tracks': {}}
    data['tracks'][slug] = {'file': relative, 'label': label, 'offset': float(offset)}
    temp = manifest.with_suffix('.json.importing')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    temp.replace(manifest)
    return relative


def install_music(staged, target, nickname=None):
    staged, target = Path(staged), Path(target)
    manifest = staged / 'audio_library.json'
    if not manifest.exists():
        return
    additions = json.loads(manifest.read_text(encoding='utf-8-sig'))
    target.mkdir(parents=True, exist_ok=True)
    output = target / 'audio_library.json'
    data = json.loads(output.read_text(encoding='utf-8-sig')) if output.exists() else {'version': 1, 'tracks': {}}
    for slug, track in additions['tracks'].items():
        source = source_asset(staged, track['file'], music=True)
        suffix = source.suffix.lower()
        if suffix not in {'.wav', '.mp3', '.flac'}:
            raise ValueError('音乐格式无效')
        digest = hashlib.sha256(source.read_bytes()).hexdigest()[:24]
        name = asset_stem(nickname, slug) + '_music' if nickname else digest
        relative = Path('music') / (name + suffix)
        dest = target / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        if not dest.exists() or hashlib.sha256(dest.read_bytes()).hexdigest()[:24] != digest:
            temp_asset=dest.with_suffix(suffix+'.importing')
            shutil.copy2(source,temp_asset)
            temp_asset.replace(dest)
        data['tracks'][slug] = dict(track, file=relative.as_posix())
    temp = output.with_suffix('.json.importing')
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    temp.replace(output)
