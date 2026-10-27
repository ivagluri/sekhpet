"""OSRS model decoder: the two formats the current cache uses (type 2 and 3), ported from RuneLite's ModelLoader."""
from cache import Buf


class Model:
    pass


def _faces(m, nf, types, idx):
    a = b = c = last = 0
    f1, f2, f3 = [0] * nf, [0] * nf, [0] * nf
    for i in range(nf):
        t = types.u8()
        if t == 1:
            a = idx.short_smart() + last; b = idx.short_smart() + a; c = idx.short_smart() + b; last = c
        elif t == 2:
            b = c; c = idx.short_smart() + last; last = c
        elif t == 3:
            a = c; c = idx.short_smart() + last; last = c
        elif t == 4:
            a, b = b, a; c = idx.short_smart() + last; last = c
        f1[i], f2[i], f3[i] = a, b, c
    m.f1, m.f2, m.f3 = f1, f2, f3


def _verts(m, nv, flags, dx, dy, dz, groups, has_groups):
    x = y = z = 0
    m.vx, m.vy, m.vz = [0] * nv, [0] * nv, [0] * nv
    m.vgroup = [0] * nv if has_groups else None
    for i in range(nv):
        f = flags.u8()
        x += dx.short_smart() if f & 1 else 0
        y += dy.short_smart() if f & 2 else 0
        z += dz.short_smart() if f & 4 else 0
        m.vx[i], m.vy[i], m.vz[i] = x, y, z
        if has_groups:
            m.vgroup[i] = groups.u8()


def _maya(m, nv, s, on):
    m.maya = None
    if on:
        m.maya = []
        for _ in range(nv):
            n = s.u8(); m.maya.append([(s.u8(), s.u8()) for _ in range(n)])


def decode_type3(data):
    m = Model(); h = Buf(data, len(data) - 26)
    nv, nf = h.u16(), h.u16()
    ntex, rtype, prio, alpha, tgroup, ftex, vgroup, maya = (h.u8() for _ in range(8))
    xl, yl, zl, idxl, tgroupl, mayal = (h.u16() for _ in range(6))
    m.texRenderTypes = list(data[:ntex])
    simple = sum(1 for t in m.texRenderTypes if t == 0)
    complex_ = sum(1 for t in m.texRenderTypes if 1 <= t <= 3)
    cube = sum(1 for t in m.texRenderTypes if t == 2)
    p = ntex + nv; o_rtype = p
    if rtype == 1: p += nf
    o_ftype = p; p += nf
    o_prio = p
    if prio == 255: p += nf
    o_tgroup = p
    if tgroup == 1: p += nf
    o_vgroup = p; p += mayal
    o_alpha = p
    if alpha == 1: p += nf
    o_fidx = p; p += idxl
    o_ftex = p
    if ftex == 1: p += nf * 2
    o_tcoord = p; p += tgroupl
    o_color = p; p += nf * 2
    o_x = p; p += xl; o_y = p; p += yl; o_z = p; p += zl
    o_simple = p
    _verts(m, nv, Buf(data, ntex), Buf(data, o_x), Buf(data, o_y), Buf(data, o_z), g := Buf(data, o_vgroup), vgroup == 1)
    _maya(m, nv, g, maya == 1)
    col, rt, pr, al, tg, ft, tc = (Buf(data, o) for o in (o_color, o_rtype, o_prio, o_alpha, o_tgroup, o_ftex, o_tcoord))
    m.colors = []; m.rtypes = [0] * nf; m.alphas = [0] * nf; m.tex = [-1] * nf; m.tcoord = [-1] * nf
    m.tgroups = [0] * nf if tgroup == 1 else None
    m.prios = [0] * nf
    for i in range(nf):
        m.colors.append(col.u16())
        if rtype == 1: m.rtypes[i] = rt.i8()
        if prio == 255: m.prios[i] = pr.i8()
        if alpha == 1: m.alphas[i] = al.u8()
        if tgroup == 1: m.tgroups[i] = tg.u8()
        if ftex == 1: m.tex[i] = ft.u16() - 1
        if ftex == 1 and ntex > 0 and m.tex[i] != -1: m.tcoord[i] = tc.u8() - 1
    _faces(m, nf, Buf(data, o_ftype), Buf(data, o_fidx))
    s = Buf(data, o_simple); m.texTri = []
    for t in m.texRenderTypes:
        m.texTri.append((s.u16(), s.u16(), s.u16()) if t == 0 else None)
    m.nv, m.nf = nv, nf
    return m


def decode_type2(data):
    m = Model(); h = Buf(data, len(data) - 23)
    nv, nf, ntex = h.u16(), h.u16(), h.u8()
    rtype, prio, alpha, tgroup, vgroup, maya = (h.u8() for _ in range(6))
    xl, yl, zl, idxl, mayal = (h.u16() for _ in range(5))
    p = nv; o_ftype = p; p += nf
    o_prio = p
    if prio == 255: p += nf
    o_tgroup = p
    if tgroup == 1: p += nf
    o_rtype = p
    if rtype == 1: p += nf
    o_vgroup = p; p += mayal
    o_alpha = p
    if alpha == 1: p += nf
    o_fidx = p; p += idxl
    o_color = p; p += nf * 2
    o_tex = p; p += ntex * 6
    o_x = p; p += xl; o_y = p; p += yl; o_z = p; p += zl
    _verts(m, nv, Buf(data, 0), Buf(data, o_x), Buf(data, o_y), Buf(data, o_z), g := Buf(data, o_vgroup), vgroup == 1)
    _maya(m, nv, g, maya == 1)
    col, rt, pr, al, tg = (Buf(data, o) for o in (o_color, o_rtype, o_prio, o_alpha, o_tgroup))
    m.colors = []; m.rtypes = [0] * nf; m.alphas = [0] * nf; m.tex = [-1] * nf; m.tcoord = [-1] * nf
    m.tgroups = [0] * nf if tgroup == 1 else None
    m.prios = [0] * nf
    for i in range(nf):
        c = col.u16()
        if rtype == 1:
            f = rt.u8()
            m.rtypes[i] = f & 1
            if f & 2:
                m.tcoord[i] = f >> 2; m.tex[i] = c; c = 127
        m.colors.append(c)
        if prio == 255: m.prios[i] = pr.i8()
        if alpha == 1: m.alphas[i] = al.u8()
        if tgroup == 1: m.tgroups[i] = tg.u8()
    _faces(m, nf, Buf(data, o_ftype), Buf(data, o_fidx))
    s = Buf(data, o_tex)
    m.texRenderTypes = [0] * ntex
    m.texTri = [(s.u16(), s.u16(), s.u16()) for _ in range(ntex)]
    m.nv, m.nf = nv, nf
    return m


def decode(data):
    if data[-2] == 255 and data[-1] == 253: return decode_type3(data)
    if data[-2] == 255 and data[-1] == 254: return decode_type2(data)
    raise ValueError("unsupported model format")


def load(cache, mid):
    return decode(cache.archive(7, mid))
