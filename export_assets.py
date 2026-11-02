"""Publish canonical game assets or readable, reinstallable export packages."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import tempfile
import zipfile
from asset_names import nickname as clean_name
from asset_names import asset_stem, source_asset
from audio_assets import install_music
from camera_assets import install_cameras
from library_lock import library_lock


def install_export(staged, target, nickname=None):
    target=Path(target);target.mkdir(parents=True,exist_ok=True)
    with library_lock(target):
        _install_export(staged,target,nickname)


def _install_export(staged, target, nickname=None):
    staged, target = Path(staged), Path(target)
    incoming = json.loads((staged / 'library.json').read_text(encoding='utf-8-sig'))['clips']
    planned, additions = [], []
    for entry in incoming:
        slug = entry['slug']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', slug):
            raise ValueError('曲目 ID 无效')
        item = dict(entry)
        for field, suffix, ext in [('file', '', 'motion'), ('fingers', '_fingers', 'fingers'), ('report', '_report', 'report')]:
            source = source_asset(staged, entry.get(field, f'dance_{slug}{suffix}.json'))
            if field == 'file' and not source.is_file():
                raise ValueError('导出包缺少动作文件')
            if not source.is_file():
                item.pop(field, None)
                continue
            name = f'{asset_stem(nickname, slug)}_{ext}.json' if nickname else f'dance_{slug}{suffix}.json'
            if nickname:
                item[field] = name
                item['nickname'] = nickname
            else:
                item.pop(field, None)
            planned.append((source, name))
        additions.append(item)
    target.mkdir(parents=True, exist_ok=True)
    manifest = target / 'library.json'
    library = json.loads(manifest.read_text(encoding='utf-8-sig')) if manifest.exists() else {'version': 1, 'clips': []}
    ids = {x['slug'] for x in additions}
    library['clips'] = [x for x in library.get('clips', []) if x.get('slug') not in ids] + additions
    library['version'] = 1
    backup = target / 'import_backups'
    for source, name in planned:
        dest = target / name
        if dest.exists() and dest.read_bytes() == source.read_bytes():
            continue
        if dest.exists():
            digest = hashlib.sha256(dest.read_bytes()).hexdigest()[:16]
            backup.mkdir(exist_ok=True)
            saved = backup / (dest.stem + '_' + digest + '.json')
            if not saved.exists():
                shutil.copy2(dest, saved)
        temporary = dest.with_suffix('.json.importing')
        shutil.copy2(source, temporary)
        temporary.replace(dest)
    # Media keeps separate manifests so reimporting motion alone preserves it.
    install_music(staged, target, nickname=nickname)
    install_cameras(staged, target, nickname=nickname)
    temporary = manifest.with_suffix('.json.importing')
    temporary.write_text(json.dumps(library, ensure_ascii=False, indent=2), encoding='utf-8')
    temporary.replace(manifest)
    # A direct GUI reimport must also refresh any standalone registration.
    for entry in additions:
        for descriptor in list(target.glob('package_*.json')):
            old=json.loads(descriptor.read_text(encoding='utf-8-sig'))
            if old.get('clip',{}).get('slug')==entry['slug']:
                _write_package(target,entry,descriptor=descriptor)


def _write_package(data, entry, descriptor=None):
    slug=entry['slug']
    filename=descriptor or data/f'package_{slug}.json'
    previous=json.loads(filename.read_text(encoding='utf-8-sig')) if filename.exists() else {}
    package={'schema':'mmdrise.package/1','clip':dict(entry),'files':{}}
    names=[entry.get(field,f'dance_{slug}{suffix}.json') for field,suffix in [('file',''),('fingers','_fingers'),('report','_report')]]
    for kind in ('audio','camera'):
        manifest=data/f'{kind}_library.json'
        track=json.loads(manifest.read_text(encoding='utf-8-sig')).get('tracks',{}).get(slug) if manifest.exists() else previous.get(kind)
        if track:
            package[kind]=track
            names.append(track['file'])
    for name in names:
        path=source_asset(data,name,music=name.startswith('music/'))
        if path.is_file():package['files'][name]=path.stat().st_size
    filename.write_text(json.dumps(package,ensure_ascii=False,indent=2),encoding='utf-8')
    return package


def export_mod(staged, output, label, nickname=None, make_zip=True):
    """Build one game-ready song folder and ZIP, without shared manifests.

    Existing output is kept as a sibling backup until the replacement succeeds;
    unrelated songs are never merged into the new distributable.
    """
    staged,output=Path(staged),Path(output)
    entries=json.loads((staged/'library.json').read_text(encoding='utf-8-sig'))['clips']
    if len(entries)!=1:raise ValueError('一次打包只能包含一首舞蹈。')
    entry=dict(entries[0]);slug=entry['slug']
    nickname=clean_name(label or entry.get('label') or slug)
    entry['label']=label or entry.get('label') or slug
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}',slug):raise ValueError('曲目 ID 无效')
    name=clean_name(label or nickname or entry.get('label') or slug)+'MMD_Dance'
    output.mkdir(parents=True,exist_ok=True)
    dest=output/name
    # Two distinct motions may have the same display name.
    def owned(folder):
        return any(json.loads(p.read_text(encoding='utf-8-sig')).get('clip',{}).get('slug')==slug for p in (folder/'reframework/data/MMDRise').glob('package_*.json'))
    if dest.exists() and not owned(dest):
        dest=output/(name+'_'+hashlib.sha256(slug.encode()).hexdigest()[:8])
    if dest.exists() and not owned(dest):
        raise ValueError('同名目录不是本曲目的 MOD 包，请另选输出位置或曲目名称。')
    if dest.is_symlink():raise ValueError('MOD 导出目录不能是链接。')
    with library_lock(output):
        with tempfile.TemporaryDirectory(prefix='.mmd_package_',dir=output) as temp:
            build=Path(temp)/dest.name;data=build/'reframework/data/MMDRise';data.mkdir(parents=True)
            old=dest/'reframework/data/MMDRise'
            old_manifest=next((p for p in old.glob('package_*.json') if json.loads(p.read_text(encoding='utf-8-sig')).get('clip',{}).get('slug')==slug),old/f'package_{slug}.json')
            # Re-converting motion alone retains the previous package's media.
            if old_manifest.exists():
                previous=json.loads(old_manifest.read_text(encoding='utf-8-sig'))
                if previous.get('clip',{}).get('slug')!=slug:raise ValueError('已有 MOD 包的曲目 ID 不匹配。')
                for kind in ('audio','camera'):
                    track=previous.get(kind)
                    if track and not (staged/f'{kind}_library.json').exists():
                        source=source_asset(old,track['file'],music=kind=='audio')
                        if not source.is_file():raise ValueError('旧 MOD 包的配套资源不完整。')
                        filename=asset_stem(nickname,slug)+('_music'+source.suffix if kind=='audio' else '_camera.json')
                        relative='music/'+filename if kind=='audio' else filename
                        target=source_asset(data,relative,music=kind=='audio');target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
                        (data/f'{kind}_library.json').write_text(json.dumps({'version':1,'tracks':{slug:dict(track,file=relative)}},ensure_ascii=False),encoding='utf-8')
            install_export(staged,data,nickname=nickname)
            final_entry=json.loads((data/'library.json').read_text(encoding='utf-8'))['clips'][0]
            final_entry['label']=entry['label']
            _write_package(data,final_entry,descriptor=data/f'package_{slug}_{nickname}.json')
            for filename in ('library.json','audio_library.json','camera_library.json','.library.lock'):
                (data/filename).unlink(missing_ok=True)
            # Media replacement during staging may create import backups; these
            # are not part of a distributable and are confined to our temp tree.
            backups=data/'import_backups'
            if backups.exists():
                assert backups.resolve().is_relative_to(Path(temp).resolve())
                shutil.rmtree(backups)
            readme=(f'{label or entry.get("label") or slug}\n\n'
                '需要：崛起 REFramework + MMD 播放器 1.0.0 或更高版本。\n'
                '含形态键表情时，还需 ShapeKeySystem 和支持形态键的角色 MOD。\n\n'
                '将本文件夹里的 reframework 合并到 MonsterHunterRise.exe 所在目录。\n'
                '游戏已运行：打开 MMD 播放器，启用总开关，点击“刷新曲库”。\n'
                '也可将同名 ZIP 直接作为 MOD 包安装；ZIP 根目录就是 reframework。\n'
                '每首舞有独立注册文件，不覆盖其他曲目的曲库配置。\n'
                '播放选项可修改播放/暂停快捷键，默认 End；不受 REF 面板开关影响。\n')
            readme_path=output/(dest.name+'_安装说明.txt')
            archive=Path(temp)/(dest.name+'.zip');zip_error=None
            if make_zip:
                try:
                    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
                        for path in sorted(build.rglob('*')):
                            if path.is_file():z.write(path,path.relative_to(build).as_posix())
                except (OSError,RuntimeError) as exc:
                    zip_error=str(exc);archive.unlink(missing_ok=True)
            backup=None
            if dest.exists():
                backups=output/'导出备份';backups.mkdir(exist_ok=True)
                backup=backups/dest.name
                n=1
                while backup.exists():backup=backups/f'{dest.name}_{n}';n+=1
                if dest.resolve().parent!=output.resolve() or not backup.resolve().is_relative_to(output.resolve()):
                    raise ValueError('导出备份路径超出输出目录。')
                dest.rename(backup)
            try:build.rename(dest)
            except Exception:
                if backup is not None:backup.rename(dest)
                raise
            zip_path=None
            if archive.exists():
                published_zip=output/(dest.name+'.zip')
                try:
                    archive.replace(published_zip)
                    zip_path=published_zip
                except OSError as exc:
                    # A ZIP open in another application must not invalidate
                    # the already complete folder or look like a fresh ZIP.
                    zip_error=str(exc)+'；同名旧 ZIP 未更新，请关闭占用程序后重新导出。'
            elif make_zip and (output/(dest.name+'.zip')).exists():
                # Never leave an older ZIP masquerading as this export.
                backups=output/'导出备份';backups.mkdir(exist_ok=True)
                previous_zip=output/(dest.name+'.zip')
                saved=backups/(dest.name+'_'+hashlib.sha256(previous_zip.read_bytes()).hexdigest()[:8]+'.zip')
                previous_zip.replace(saved)
            readme_temp=Path(temp)/'readme.txt'
            readme_temp.write_text(readme,encoding='utf-8-sig')
            readme_temp.replace(readme_path)
            return {'folder':dest,'zip':zip_path,'zip_error':zip_error,'readme':readme_path}
