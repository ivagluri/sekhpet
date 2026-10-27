"""Config decoders (NPC, item, identikit, sequence, enum) for the current OSRS cache (rev 226+).
Ported from RuneLite's cache loaders (BSD-2)."""
from cache import Buf, Cache


def _params(b):
    out = {}
    for _ in range(b.u8()):
        kind = b.u8(); key = b.u24()
        if kind == 1: out[key] = b.string()
        elif kind == 2: out[key] = b.i32() << 32 | b.u32()
        else: out[key] = b.i32()
    return out


def _cond_op(b): b.u8(); b.u16(); b.u16(); b.i32(); b.i32(); b.string()
def _cond_subop(b): b.u8(); b.u16(); b.u16(); b.u16(); b.i32(); b.i32(); b.string()


def npc(data, nid=None):
    b = Buf(data); d = {"id": nid, "models": [], "name": None, "recolor": [], "retexture": [], "ops": [],
                        "widthScale": 128, "heightScale": 128, "size": 1}
    while True:
        o = b.u8()
        if o == 0: break
        if o == 1: d["models"] = [b.u16() for _ in range(b.u8())]
        elif o == 2: d["name"] = b.string()
        elif o == 12: d["size"] = b.u8()
        elif o == 13: d["stand"] = b.u16()
        elif o == 14: d["walk"] = b.u16()
        elif o in (15, 16): d[f"op{o}"] = b.u16()
        elif o == 17: d["walk"] = b.u16(); d["walkBack"] = b.u16(); d["walkLeft"] = b.u16(); d["walkRight"] = b.u16()
        elif o == 18: d["category"] = b.u16()
        elif 30 <= o < 35: d["ops"].append(b.string())
        elif o == 40: d["recolor"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif o == 41: d["retexture"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif o == 42: b.u16()
        elif o == 60: d["chathead"] = [b.u16() for _ in range(b.u8())]
        elif o == 61: d["models"] = [b.i32() for _ in range(b.u8())]
        elif o == 62: d["chathead"] = [b.i32() for _ in range(b.u8())]
        elif 74 <= o <= 79: b.u16()
        elif o in (93, 99, 107, 109, 111, 122, 123, 129, 130, 145, 147): pass
        elif o == 95: d["combat"] = b.u16()
        elif o == 97: d["widthScale"] = b.u16()
        elif o == 98: d["heightScale"] = b.u16()
        elif o in (100, 101): b.i8()
        elif o == 102:
            bits = b.u8()
            while bits:
                if bits & 1: b.big_smart2(); b.u_smart()
                bits >>= 1
        elif o == 103: b.u16()
        elif o == 106:
            b.u16(); b.u16(); d["morphs"] = [b.u16() for _ in range(b.u8() + 1)]
        elif o == 114: d["run"] = b.u16()
        elif o == 115: d["run"] = b.u16(); b.u16(); b.u16(); b.u16()
        elif o == 116: d["crawl"] = b.u16()
        elif o == 117: d["crawl"] = b.u16(); b.u16(); b.u16(); b.u16()
        elif o == 118:
            b.u16(); b.u16(); last = b.u16(); d["morphs"] = [b.u16() for _ in range(b.u8() + 1)] + [last]
        elif o in (124, 126, 146): b.u16()
        elif o == 249: d["params"] = _params(b)
        elif o == 251: b.u8(); b.u8(); b.string()
        elif o == 252: _cond_op(b)
        elif o == 253: _cond_subop(b)
        else: raise ValueError(f"npc {nid}: opcode {o}")
    return d


def item(data, iid=None):
    b = Buf(data); d = {"id": iid, "name": None, "recolor": [], "retexture": []}
    while True:
        o = b.u8()
        if o == 0: break
        if o == 1: d["inv"] = b.u16()
        elif o in (2, 3, 9): d[{2: "name", 3: "examine", 9: "o9"}[o]] = b.string()
        elif o in (4, 5, 6, 95, 97, 98, 99, 110, 111, 112, 139, 140, 148, 149): d[f"o{o}"] = b.u16()
        elif o in (7, 8): b.u16()
        elif o in (11, 15, 16, 65, 160, 251): pass
        elif o == 12: b.i32()
        elif o == 13: d["wearPos1"] = b.i8()
        elif o == 14: d["wearPos2"] = b.i8()
        elif o == 27: d["wearPos3"] = b.i8()
        elif o == 23: d["male0"] = b.u16(); d["maleOffset"] = b.u8()
        elif o == 24: d["male1"] = b.u16()
        elif o == 25: d["female0"] = b.u16(); d["femaleOffset"] = b.u8()
        elif o == 26: d["female1"] = b.u16()
        elif 30 <= o < 40: b.string()
        elif o == 40: d["recolor"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif o == 41: d["retexture"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif o == 42: b.i8()
        elif o == 43:
            b.u8()
            while b.u8() != 0: b.string()
        elif o == 44: d["inv"] = b.i32()
        elif o == 45: d["male0"] = b.i32(); d["maleOffset"] = b.u8()
        elif o == 46: d["male1"] = b.i32()
        elif o == 47: d["male2"] = b.i32()
        elif o == 48: d["female0"] = b.i32(); d["femaleOffset"] = b.u8()
        elif o == 49: d["female1"] = b.i32()
        elif o == 50: d["female2"] = b.i32()
        elif o in (51, 52, 53, 54): b.i32()
        elif o == 75: b.i16()
        elif o == 78: d["male2"] = b.u16()
        elif o == 79: d["female2"] = b.u16()
        elif o in (90, 91, 92, 93, 94): b.u16()
        elif 100 <= o < 110: b.u16(); b.u16()
        elif o in (113, 114): b.i8()
        elif o == 115: b.u8()
        elif o == 161: [b.u16() for _ in range(b.u16())]
        elif o == 200: b.u8(); b.u8(); b.string()
        elif o == 201: _cond_op(b)
        elif o == 202: _cond_subop(b)
        elif o == 249: d["params"] = _params(b)
        else: raise ValueError(f"item {iid}: opcode {o}")
    return d


def kit(data, kid=None):
    b = Buf(data); d = {"id": kid, "part": -1, "models": [], "recolor": [], "retexture": [], "selectable": True}
    while True:
        o = b.u8()
        if o == 0: break
        if o == 1: d["part"] = b.u8()
        elif o == 2: d["models"] = [b.u16() for _ in range(b.u8())]
        elif o == 3: d["selectable"] = False
        elif o == 5: d["models"] = [b.i32() for _ in range(b.u8())]
        elif o == 40: d["recolor"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif o == 41: d["retexture"] = [(b.u16(), b.u16()) for _ in range(b.u8())]
        elif 60 <= o < 70: b.u16()
        elif 70 <= o < 80: b.i32()
        else: raise ValueError(f"kit {kid}: opcode {o}")
    return d


def _sound(b): b.u16(); b.u8(); b.u8(); b.u8(); b.u8()


def sequence(data, sid=None):
    b = Buf(data); d = {"id": sid, "frames": [], "lengths": [], "maya": -1, "name": None}
    while True:
        o = b.u8()
        if o == 0: break
        if o == 1:
            n = b.u16(); d["lengths"] = [b.u16() for _ in range(n)]
            lo = [b.u16() for _ in range(n)]; hi = [b.u16() for _ in range(n)]
            d["frames"] = [h << 16 | l for l, h in zip(lo, hi)]
        elif o == 2: d["frameStep"] = b.u16()
        elif o == 3: d["interleave"] = [b.u8() for _ in range(b.u8())]
        elif o == 4: d["stretches"] = True
        elif o in (5, 8, 9, 10, 11): d[f"o{o}"] = b.u8()
        elif o == 6: d["leftHand"] = b.u16()
        elif o == 7: d["rightHand"] = b.u16()
        elif o == 12:
            n = b.u8(); [b.u16() for _ in range(2 * n)]
        elif o == 13: d["maya"] = b.i32()
        elif o == 14:
            for _ in range(b.u16()): b.u16(); _sound(b)
        elif o == 15: d["mayaStart"] = b.u16(); d["mayaEnd"] = b.u16()
        elif o == 16: d["vOffset"] = b.i8()
        elif o == 17: d["mayaMasks"] = [b.u8() for _ in range(b.u8())]
        elif o == 18: d["name"] = b.string()
        elif o == 19: pass
        else: raise ValueError(f"seq {sid}: opcode {o}")
    return d


def load_all(c, archive, fn):
    return {i: fn(blob, i) for i, blob in c.files(2, archive).items()}


def enum(data, eid=None):
    """-> {key: value} of a config enum (int or string values)."""
    b = Buf(data); out = {}
    while True:
        o = b.u8()
        if o == 0: break
        if o in (1, 2): b.u8()
        elif o == 3: b.string()
        elif o == 4: b.i32()
        elif o == 5:
            for _ in range(b.u16()): k = b.i32(); out[k] = b.string()
        elif o == 6:
            for _ in range(b.u16()): k = b.i32(); out[k] = b.i32()
        else: raise ValueError(f"enum {eid}: opcode {o}")
    return out

