#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
VMD (Vocaloid Motion Data) 字节级解析库 —— T8 自建，不依赖任何第三方 VMD 库。

格式（已用字节级核对，见 vmd_pipeline.md）：
  header  : 30 bytes, "Vocaloid Motion Data 0002" + NUL 填充
  model   : 20 bytes (VMD 0002) / 10 bytes (VMD 0001)
  uint32  : 骨骼关键帧数
    每帧 111 bytes: 15B 骨骼名(cp932/shift-jis, NUL 填充) + uint32 帧号
                    + 3*f32 位置 + 4*f32 旋转(XYZW) + 64B 插值
  uint32  : 表情(摩夫)数   每帧 23 bytes: 15B 名 + uint32 帧号 + f32 权重
  uint32  : 相机数         每帧 61 bytes
  uint32  : 灯光数         每帧 28 bytes
  uint32  : 自阴影数       每帧 9 bytes
  uint32  : IK 数(仅 0002) 每帧 9 bytes 头 + ikCount*(20B 名 + 1B enable)
"""
import struct, os

BONE_FRAME_SIZE = 15 + 4 + 12 + 16 + 64   # 111
MORPH_FRAME_SIZE = 15 + 4 + 4             # 23
CAMERA_FRAME_SIZE = 4 + 4 + 12 + 12 + 24 + 4 + 1  # 61
LIGHT_FRAME_SIZE = 4 + 12 + 12            # 28
SHADOW_FRAME_SIZE = 4 + 1 + 4             # 9


class VmdError(Exception):
    pass


def dec_name(raw):
    """15/20 字节名字 -> str（NUL 截断，cp932 解码，失败退回 shift_jis / latin-1）"""
    raw = raw.split(b"\x00", 1)[0]
    for enc in ("cp932", "shift_jis", "utf-8"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def enc_name(s, n):
    b = s.encode("cp932")
    if len(b) > n:
        raise VmdError("name too long: %r" % s)
    return b + b"\x00" * (n - len(b))


class Vmd(object):
    def __init__(self, path):
        self.path = path
        self.size = os.path.getsize(path)
        self.header = None
        self.model = None
        self.interpolations = {}  # (bone_name, frame) -> 64 interpolation bytes
        self.bones = []      # [(name, frame, (px,py,pz), (rx,ry,rz,rw))]
        self.morphs = []     # [(name, frame, weight)]
        self.cameras = []
        self.lights = []
        self.shadows = []
        self.iks = []        # [(frame, show, [(bone_name, enable)])]
        self.trailing = 0    # 未消费字节数（用于验证解析完整性）
        self.sections = []   # [(名, 起始偏移, 字节数, 条数)]

    # ---------- 解析 ----------
    def parse(self):
        with open(self.path, "rb") as f:
            buf = f.read()
        off = 0
        n = len(buf)
        self.header = buf[0:30]
        off = 30
        # VMD 0001: 10B 模型名; 0002: 20B
        two = b"0002" in self.header[:30]
        mlen = 20 if two else 10
        self.model = dec_name(buf[off:off + mlen]); off += mlen
        self.version = "0002" if two else "0001"

        # --- 骨骼 ---
        sec_start = off
        cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
        if cnt > 20_000_000:
            raise VmdError("骨骼帧数异常: %d（解析已经跑偏）" % cnt)
        need = cnt * BONE_FRAME_SIZE
        if off + need > n:
            raise VmdError("骨骼段落越界: 需要 %d 字节，只剩 %d" % (need, n - off))
        for i in range(cnt):
            o = off + i * BONE_FRAME_SIZE
            name = dec_name(buf[o:o + 15])
            fr = struct.unpack_from("<I", buf, o + 15)[0]
            pos = struct.unpack_from("<3f", buf, o + 19)
            rot = struct.unpack_from("<4f", buf, o + 31)
            self.bones.append((name, fr, pos, rot))
            self.interpolations[(name, fr)] = tuple(buf[o + 47:o + 111])
        off += need
        self.sections.append(("bone", sec_start, off - sec_start, cnt))

        # --- 表情 ---
        sec_start = off
        cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
        if off + cnt * MORPH_FRAME_SIZE > n:
            raise VmdError("表情段落越界")
        for i in range(cnt):
            o = off + i * MORPH_FRAME_SIZE
            self.morphs.append((dec_name(buf[o:o + 15]),
                                struct.unpack_from("<I", buf, o + 15)[0],
                                struct.unpack_from("<f", buf, o + 19)[0]))
        off += cnt * MORPH_FRAME_SIZE
        self.sections.append(("morph", sec_start, off - sec_start, cnt))

        # --- 相机 ---
        sec_start = off
        cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
        if off + cnt * CAMERA_FRAME_SIZE > n:
            raise VmdError("相机段落越界")
        for i in range(cnt):
            o = off + i * CAMERA_FRAME_SIZE
            fr, distance, *values = struct.unpack_from('<If6f', buf, o)
            self.cameras.append(dict(frame=fr,distance=distance,
                position=list(values[:3]),rotation=list(values[3:]),
                interpolation=list(buf[o+32:o+56]),
                fov=struct.unpack_from('<I',buf,o+56)[0],
                perspective=buf[o+60]==0))
        off += cnt * CAMERA_FRAME_SIZE
        self.sections.append(("camera", sec_start, off - sec_start, cnt))

        # --- 灯光 ---
        sec_start = off
        cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
        if off + cnt * LIGHT_FRAME_SIZE > n:
            raise VmdError("灯光段落越界")
        off += cnt * LIGHT_FRAME_SIZE
        self.sections.append(("light", sec_start, off - sec_start, cnt))

        # --- 自阴影 ---
        sec_start = off
        cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
        if off + cnt * SHADOW_FRAME_SIZE > n:
            raise VmdError("自阴影段落越界")
        off += cnt * SHADOW_FRAME_SIZE
        self.sections.append(("shadow", sec_start, off - sec_start, cnt))

        # --- IK (0002) ---
        if two and off < n:
            sec_start = off
            cnt = struct.unpack_from("<I", buf, off)[0]; off += 4
            ok = True
            for i in range(cnt):
                if off + 9 > n:
                    ok = False; break
                fr = struct.unpack_from("<I", buf, off)[0]
                show = buf[off + 4]
                ikn = struct.unpack_from("<I", buf, off + 5)[0]
                off += 9
                if ikn > 4096 or off + ikn * 21 > n:
                    ok = False; break
                lst = []
                for j in range(ikn):
                    nm = dec_name(buf[off:off + 20])
                    en = buf[off + 20]
                    off += 21
                    lst.append((nm, en))
                self.iks.append((fr, show, lst))
            if not ok:
                raise VmdError("IK 段落越界")
            self.sections.append(("ik", sec_start, off - sec_start, cnt))

        self.trailing = n - off
        self._raw_len = n
        return self

    # ---------- 统计 ----------
    def bone_index(self):
        """name -> [(frame, pos, rot)]，按帧号升序"""
        d = {}
        for name, fr, pos, rot in self.bones:
            d.setdefault(name, []).append((fr, pos, rot))
        for k in d:
            d[k].sort(key=lambda t: t[0])
        return d

    def summary(self):
        idx = self.bone_index()
        out = []
        for name, keys in idx.items():
            frs = [k[0] for k in keys]
            out.append(dict(name=name, keys=len(keys), fmin=min(frs), fmax=max(frs)))
        out.sort(key=lambda r: -r["keys"])
        return out
