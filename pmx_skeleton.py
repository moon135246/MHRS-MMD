"""Read PMX 2.0/2.1 skeleton metadata without Blender or loading textures.

Binary field order cross-checked against the MMD Tools PMX reader:
https://github.com/MMD-Blender/blender_mmd_tools/blob/main/mmd_tools/core/pmx/__init__.py
Only metadata through the bone section is consumed; the PMX is never modified.
"""
from pathlib import Path
import struct


class Reader:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        self.at = 0

    def take(self, size):
        if size < 0 or self.at + size > len(self.data):
            raise ValueError(f'Truncated PMX at {self.at}, requested {size}')
        result = self.data[self.at:self.at+size]
        self.at += size
        return result

    def number(self, fmt):
        return struct.unpack('<'+fmt, self.take(struct.calcsize('<'+fmt)))[0]

    def count(self):
        n = self.number('i')
        if not 0 <= n <= 20_000_000:
            raise ValueError(f'Invalid PMX count {n}')
        return n

    def text(self):
        return self.take(self.count()).decode(self.encoding, errors='strict')

    def index(self, size):
        return self.number({1:'b', 2:'h', 4:'i'}[size])

    def vector(self):
        return list(struct.unpack('<3f', self.take(12)))


def read_skeleton(path):
    r = Reader(path)
    if r.take(4) != b'PMX ':
        raise ValueError('Not a PMX file')
    version = r.number('f')
    if not (abs(version-2) < 1e-4 or abs(version-2.1) < 1e-4):
        raise ValueError(f'Unsupported PMX version {version}')
    header = r.take(r.number('B'))
    if len(header) < 8:
        raise ValueError('Incomplete PMX header')
    encoding, uv, vi, ti, mi, bi, moi, ri = header[:8]
    r.encoding = {0:'utf-16-le', 1:'utf-8'}[encoding]
    if uv > 4 or any(s not in (1,2,4) for s in (vi,ti,mi,bi,moi,ri)):
        raise ValueError('Invalid PMX index sizes/UV count')
    model, english, comment, comment_en = [r.text() for _ in range(4)]
    vertex_count = r.count()
    for _ in range(vertex_count):
        r.take(32+16*uv)
        kind = r.number('B')
        sizes = {0:bi, 1:2*bi+4, 2:4*bi+16, 3:2*bi+40, 4:4*bi+16}
        if kind not in sizes:
            raise ValueError(f'Unsupported vertex weight {kind}')
        r.take(sizes[kind]+4)
    r.take(r.count()*vi)
    for _ in range(r.count()):
        r.text()
    for _ in range(r.count()):
        r.text(); r.text()
        r.take(65+2*ti+1)
        shared = r.number('B')
        if shared not in (0,1):
            raise ValueError('Invalid shared toon flag')
        r.take(1 if shared else ti)
        r.text(); r.count()
    bones = []
    for index in range(r.count()):
        bone = dict(index=index, name=r.text(), name_en=r.text(), pos=r.vector(),
                    parent=r.index(bi), layer=r.number('i'), flags=r.number('H'))
        flags = bone['flags']
        bone['tail'] = r.index(bi) if flags & 1 else r.vector()
        if flags & 0x300:
            bone['inherit'] = [r.index(bi), r.number('f')]
        if flags & 0x400:
            bone['fixed_axis'] = r.vector()
        if flags & 0x800:
            bone['local_axes'] = [r.vector(), r.vector()]
        if flags & 0x2000:
            bone['external_parent'] = r.number('i')
        if flags & 0x20:
            bone['ik'] = dict(target=r.index(bi), iterations=r.count(), limit=r.number('f'))
            links = []
            for _ in range(r.count()):
                link = dict(index=r.index(bi))
                limited = r.number('B')
                if limited:
                    link['min'], link['max'] = r.vector(), r.vector()
                links.append(link)
            bone['ik']['links'] = links
        bones.append(bone)
    for bone in bones:
        if not -1 <= bone['parent'] < len(bones):
            raise ValueError('Invalid parent index')
    return dict(path=str(Path(path).resolve()), model=model, model_en=english,
                version=version, vertices=vertex_count, bones=bones, bone_section_end=r.at)


if __name__ == '__main__':
    import json, sys
    sys.stdout.reconfigure(encoding='utf-8')
    print(json.dumps(read_skeleton(sys.argv[1]), ensure_ascii=False, indent=2))
