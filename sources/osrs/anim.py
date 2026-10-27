"""Classic OSRS animation: a frame is a list of transforms (origin, translate, rotate, scale) on groups of
vertex labels, applied in order. Every transform is affine, so each label moves rigidly and one 4x4 matrix
per label per frame reproduces the client exactly."""
import math
from cache import Buf

SINE = [int(65536 * math.sin(i * 2 * math.pi / 2048)) for i in range(2048)]
COS = [int(65536 * math.cos(i * 2 * math.pi / 2048)) for i in range(2048)]


def ident():
    return [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def translate(x, y, z):
    m = ident(); m[0][3], m[1][3], m[2][3] = x, y, z; return m


def apply(m, p):
    return [m[i][0] * p[0] + m[i][1] * p[1] + m[i][2] * p[2] + m[i][3] for i in range(3)]


def _rotation(ax, ay, az):
    """The client's order: Z, then X, then Y; angles are steps of its 2048-entry table."""
    m = ident()
    if az:
        s, c = SINE[az] / 65536, COS[az] / 65536
        m = mul([[c, s, 0, 0], [-s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]], m)
    if ax:
        s, c = SINE[ax] / 65536, COS[ax] / 65536
        m = mul([[1, 0, 0, 0], [0, c, -s, 0], [0, s, c, 0], [0, 0, 0, 1]], m)
    if ay:
        s, c = SINE[ay] / 65536, COS[ay] / 65536
        m = mul([[c, 0, s, 0], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]], m)
    return m


class Frames:
    """Frames and framemaps (the label groups a frame's transforms act on), loaded on demand."""

    def __init__(self, cache):
        self.cache = cache; self._maps = {}; self._archives = {}

    def framemap(self, fid):
        if fid not in self._maps:
            b = Buf(self.cache.archive(1, fid)); n = b.u8()
            types = [b.u8() for _ in range(n)]
            sizes = [b.u8() for _ in range(n)]
            self._maps[fid] = (types, [[b.u8() for _ in range(s)] for s in sizes])
        return self._maps[fid]

    def raw(self, packed):
        a = packed >> 16
        if a not in self._archives:
            self._archives[a] = self.cache.files(0, a)
        return self._archives[a].get(packed & 0xFFFF)

    def framemap_id(self, packed):
        data = self.raw(packed)
        return None if data is None else data[0] << 8 | data[1]

    def frame(self, packed):
        """-> (framemap, [(transform index, dx, dy, dz)])"""
        data = self.raw(packed)
        hdr = Buf(data); fmid = hdr.u16(); n = hdr.u8()
        types, maps = self.framemap(fmid)
        d = Buf(data, 3 + n); ops = []; last = -1
        for i in range(n):
            flags = hdr.u8()
            if flags <= 0: continue
            if types[i] != 0:  # a transform uses the nearest origin before it, even one with no data
                for j in range(i - 1, last, -1):
                    if types[j] == 0:
                        ops.append((j, 0, 0, 0)); break
            dflt = 128 if types[i] == 3 else 0
            dx = d.short_smart() if flags & 1 else dflt
            dy = d.short_smart() if flags & 2 else dflt
            dz = d.short_smart() if flags & 4 else dflt
            ops.append((i, dx, dy, dz)); last = i
        return (types, maps), ops


def pose(base, label_verts, fm, ops):
    """Per-label 4x4 matrices (model units) for one frame, from the rest positions `base`."""
    types, maps = fm
    mats = {l: ident() for l in label_verts}
    origin = [0, 0, 0]
    for idx, dx, dy, dz in ops:
        t = types[idx]; labels = [l for l in maps[idx] if l in label_verts]
        if t == 0:
            n = 0; s = [0, 0, 0]
            for l in labels:
                for v in label_verts[l]:
                    p = apply(mats[l], base[v]); s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n += 1
            origin = [s[0] / n + dx, s[1] / n + dy, s[2] / n + dz] if n else [dx, dy, dz]
        elif t in (2, 3):
            if t == 2:
                m = _rotation((dx & 255) * 8, (dy & 255) * 8, (dz & 255) * 8)
            else:
                m = [[dx / 128, 0, 0, 0], [0, dy / 128, 0, 0], [0, 0, dz / 128, 0], [0, 0, 0, 1]]
            m = mul(translate(*origin), mul(m, translate(-origin[0], -origin[1], -origin[2])))
            for l in labels: mats[l] = mul(m, mats[l])
        elif t == 1:
            for l in labels: mats[l] = mul(translate(dx, dy, dz), mats[l])
        # t == 5 changes face transparency; not carried over
    return mats
