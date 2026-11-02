"""Readable filenames shared by exports and installed game assets."""
import hashlib
from pathlib import Path
import re
import unicodedata


def nickname(text):
    value = unicodedata.normalize('NFC', text.strip())
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '_', value).strip(' .')[:40].rstrip(' .')
    if not value:
        raise ValueError('请填写曲目名称。')
    if re.fullmatch(r'CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]', value.split('.')[0], re.I):
        value = '_' + value
    return value


def asset_stem(text, slug):
    return nickname(text) + '_' + hashlib.sha256(slug.encode('utf8')).hexdigest()[:8]


def source_asset(root, name, music=False):
    """Accept only files directly in the package or its music directory."""
    if not isinstance(name, str) or '\\' in name or ':' in name or '\x00' in name:
        raise ValueError('资源路径无效')
    p = Path(name)
    if p.is_absolute() or '..' in p.parts or len(p.parts) != (2 if music else 1) or (music and p.parts[0] != 'music'):
        raise ValueError('资源路径无效')
    full = (Path(root) / p).resolve()
    if not full.is_relative_to(Path(root).resolve()):
        raise ValueError('资源路径超出导出目录')
    return full
