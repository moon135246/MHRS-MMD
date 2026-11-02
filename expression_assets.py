"""Sparse VMD morph curves embedded in the dance asset (30 fps, linear weights)."""
import hashlib
import json
import math
from pathlib import Path
import struct
from vmd_lib import Vmd, VmdError
from library_lock import library_lock


def expression_data(source, *, parsed=None, required=True):
    source = Path(source)
    if parsed is None:
        if not source.read_bytes()[:30].startswith(b'Vocaloid Motion Data'):
            raise ValueError('表情文件不是有效 VMD')
        try:
            parsed = Vmd(source).parse()
        except (VmdError, struct.error, IndexError) as exc:
            raise ValueError('表情 VMD 数据不完整：' + str(exc)) from exc
    curves = {}
    clamped = 0
    for name, frame, weight in parsed.morphs:
        if not name or not math.isfinite(weight) or frame > 36000:
            raise ValueError(f'表情关键帧无效：{name!r} / {frame}')
        value = max(0., min(1., weight))
        clamped += value != weight
        # Last key wins at a duplicate frame, matching the body importer.
        curves.setdefault(name, {})[frame] = value
    if not curves:
        if required:
            raise ValueError('所选 VMD 没有表情关键帧')
        return None
    tracks = [{'name': name, 'keys': [[f, w] for f, w in sorted(keys.items())]}
              for name, keys in sorted(curves.items())]
    return dict(schema='mmdrise.morphs/1', fps=30, source=source.name,
                source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                tracks=tracks, clamped_keys=clamped,
                start=min(f for keys in curves.values() for f in keys),
                end=max(f for keys in curves.values() for f in keys))


def expression_report(data, body_count):
    if not data:
        return dict(tracks=0, active_tracks=0, keys=0)
    return dict(source=data['source'], tracks=len(data['tracks']),
                active_tracks=sum(any(w > 0 for _, w in t['keys']) for t in data['tracks']),
                keys=sum(len(t['keys']) for t in data['tracks']),
                end=data['end'], body_end=body_count-1,
                clamped_keys=data['clamped_keys'])


def attach_expression(source, library_dir, slug):
    """Update an existing clip's morphs without changing calibrated body/fingers."""
    import shutil
    from asset_names import source_asset
    data = expression_data(source)
    root = Path(library_dir)
    with library_lock(root):
        library = json.loads((root/'library.json').read_text(encoding='utf-8-sig')) if (root/'library.json').exists() else {'clips':[]}
        entry = next((c for c in library['clips'] if c['slug'] == slug), None)
        descriptor=next((p for p in root.glob('package_*.json') if json.loads(p.read_text(encoding='utf-8-sig')).get('clip',{}).get('slug')==slug),root/f'package_{slug}.json')
        if not entry and descriptor.is_file():
            entry=json.loads(descriptor.read_text(encoding='utf-8-sig')).get('clip')
        if not entry and slug == 'smile_rise' and (root/'dance_smile_rise.json').is_file():
            entry = {'slug': slug}  # original sample predates library.json
        if not entry:
            raise ValueError('曲库中没有此曲目 ID')
        path = source_asset(root, entry.get('file', f'dance_{slug}.json'))
        body = json.loads(path.read_text(encoding='utf-8-sig'))
        body['morphs'] = data
        result = expression_report(data, body['count'])
        changed = [(path, body)]
        report_path = source_asset(root, entry.get('report', f'dance_{slug}_report.json'))
        if report_path.is_file():
            report = json.loads(report_path.read_text(encoding='utf-8-sig'))
            report['expressions'] = result
            report['supported'] = 'FK body/arms/legs, root, fingers, VMD morphs via ShapeKeySystem; camera imported separately'
            changed.append((report_path, report))
        backup = root/'import_backups'
        backup.mkdir(exist_ok=True)
        for dest, obj in changed:
            digest = hashlib.sha256(dest.read_bytes()).hexdigest()[:16]
            saved = backup/(dest.stem+'_'+digest+'.json')
            if not saved.exists():
                shutil.copy2(dest, saved)
            temporary = dest.with_suffix('.json.importing')
            temporary.write_text(json.dumps(obj, ensure_ascii=False, separators=(',', ':'), allow_nan=False), encoding='utf-8')
            temporary.replace(dest)
        if descriptor.is_file():
            from export_assets import _write_package
            _write_package(root,entry,descriptor=descriptor)
        return result


if __name__ == '__main__':
    import argparse
    import sys
    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description='为已转换舞蹈添加/替换表情，保留已校准身体动作')
    parser.add_argument('vmd', type=Path)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--slug', required=True)
    args = parser.parse_args()
    print(json.dumps(attach_expression(args.vmd, args.library, args.slug), ensure_ascii=False))
