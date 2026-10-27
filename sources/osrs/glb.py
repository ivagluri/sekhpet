"""A small skinned glTF (GLB) writer: one mesh with vertex colours, a joint hierarchy, and animations given
as each joint's model-space matrix per key time (LINEAR keys)."""
import json, math, struct
from anim import mul


def hsl_to_rgb(hsl, brightness=0.6):
    """The client's 16-bit HSL colour (6 bits hue, 3 saturation, 7 lightness) to linear-ish RGB 0-1."""
    h = ((hsl >> 10) & 63) / 64 + 0.5 / 64
    s = ((hsl >> 7) & 7) / 8 + 0.5 / 8
    l = (hsl & 127) / 128
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs((h * 6) % 2 - 1))
    m = l - c / 2
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][min(int(h * 6), 5)]
    return tuple(min(1.0, max(0.0, v + m)) ** brightness for v in (r, g, b))


def inverse(m):
    """Inverse of an affine 4x4."""
    a = [row[:3] for row in m[:3]]
    det = (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
           + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    inv = [[(a[(j + 1) % 3][(i + 1) % 3] * a[(j + 2) % 3][(i + 2) % 3] - a[(j + 1) % 3][(i + 2) % 3] * a[(j + 2) % 3][(i + 1) % 3]) / det
            for j in range(3)] for i in range(3)]
    t = [-sum(inv[i][k] * m[k][3] for k in range(3)) for i in range(3)]
    return [inv[0] + [t[0]], inv[1] + [t[1]], inv[2] + [t[2]], [0, 0, 0, 1]]


def decompose(m):
    """Affine 4x4 -> translation, quaternion (x, y, z, w), scale. Shear, which bone transforms can't hold,
    is dropped (OSRS scales are almost always uniform)."""
    cols = [[m[0][j], m[1][j], m[2][j]] for j in range(3)]
    sc = [math.sqrt(sum(v * v for v in c)) or 1e-9 for c in cols]
    x = [v / sc[0] for v in cols[0]]
    y = [v / sc[1] for v in cols[1]]
    d = sum(a * b for a, b in zip(x, y)); y = [b - d * a for a, b in zip(x, y)]
    ny = math.sqrt(sum(v * v for v in y)) or 1; y = [v / ny for v in y]
    z = [x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0]]
    if sum(a * b for a, b in zip(z, cols[2])) < 0:
        z = [-v for v in z]; sc[2] = -sc[2]
    R = [[x[0], y[0], z[0]], [x[1], y[1], z[1]], [x[2], y[2], z[2]]]
    tr = R[0][0] + R[1][1] + R[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1) * 2; q = [(R[2][1] - R[1][2]) / s, (R[0][2] - R[2][0]) / s, (R[1][0] - R[0][1]) / s, s / 4]
    elif R[0][0] > R[1][1] and R[0][0] > R[2][2]:
        s = math.sqrt(1 + R[0][0] - R[1][1] - R[2][2]) * 2; q = [s / 4, (R[0][1] + R[1][0]) / s, (R[0][2] + R[2][0]) / s, (R[2][1] - R[1][2]) / s]
    elif R[1][1] > R[2][2]:
        s = math.sqrt(1 + R[1][1] - R[0][0] - R[2][2]) * 2; q = [(R[0][1] + R[1][0]) / s, s / 4, (R[1][2] + R[2][1]) / s, (R[0][2] - R[2][0]) / s]
    else:
        s = math.sqrt(1 + R[2][2] - R[0][0] - R[1][1]) * 2; q = [(R[0][2] + R[2][0]) / s, (R[1][2] + R[2][1]) / s, s / 4, (R[1][0] - R[0][1]) / s]
    return [m[0][3], m[1][3], m[2][3]], q, sc


class _Buffer:
    def __init__(self):
        self.bin = bytearray(); self.views = []; self.accessors = []

    def add(self, fmt, rows, typ, comp, minmax=False, target=None):
        start = len(self.bin)
        for r in rows: self.bin += struct.pack("<" + fmt, *r)
        while len(self.bin) % 4: self.bin += b"\0"
        view = {"buffer": 0, "byteOffset": start, "byteLength": len(self.bin) - start}
        if target: view["target"] = target
        self.views.append(view)
        acc = {"bufferView": len(self.views) - 1, "componentType": comp, "count": len(rows), "type": typ}
        if minmax:
            acc["min"] = [min(r[i] for r in rows) for i in range(len(rows[0]))]
            acc["max"] = [max(r[i] for r in rows) for i in range(len(rows[0]))]
        self.accessors.append(acc)
        return len(self.accessors) - 1


def write(path, name, positions, colours, skin, triangles, joints, animations):
    """positions: [xyz] per vertex (glTF space, metres); colours: [rgba] per vertex; skin: [[(joint, weight), ...]]
    per vertex; triangles: [(a, b, c)] vertex indices; joints: [(name, parent index or -1, rest matrix)] with
    model-space rest matrices, parents before children; animations: [(name, times, {joint: [matrix per time]})]
    with model-space matrices (joints left out stay at rest)."""
    buf = _Buffer()
    flat_pos, flat_col, flat_j, flat_w = [], [], [], []
    for tri in triangles:
        for v in tri:
            flat_pos.append(positions[v]); flat_col.append(colours[v])
            ws = sorted(skin[v], key=lambda jw: -jw[1])[:4]
            tot = sum(w for _, w in ws) or 1.0
            ws = ws + [(0, 0.0)] * (4 - len(ws))
            flat_j.append(tuple(j for j, _ in ws)); flat_w.append(tuple(w / tot for _, w in ws))
    attrs = {"POSITION": buf.add("3f", flat_pos, "VEC3", 5126, True, 34962),
             "COLOR_0": buf.add("4f", flat_col, "VEC4", 5126, False, 34962),
             "JOINTS_0": buf.add("4H", flat_j, "VEC4", 5123, False, 34962),
             "WEIGHTS_0": buf.add("4f", flat_w, "VEC4", 5126, False, 34962)}
    rest = [m for _, _, m in joints]
    nodes = [{"name": name, "mesh": 0, "skin": 0}]
    for i, (jname, parent, m) in enumerate(joints):
        local = m if parent < 0 else mul(inverse(rest[parent]), m)
        t, q, s = decompose(local)
        node = {"name": jname, "translation": t, "rotation": q, "scale": s}
        kids = [k + 1 for k, (_, p, _) in enumerate(joints) if p == i]
        if kids: node["children"] = kids
        nodes.append(node)
    roots = [i + 1 for i, (_, p, _) in enumerate(joints) if p < 0]
    ibm = [tuple(inverse(m)[r][c] for c in range(4) for r in range(4)) for m in rest]
    j = {"asset": {"version": "2.0", "generator": "sekhpet sources/osrs"},
         "scene": 0, "scenes": [{"nodes": [0] + roots}], "nodes": nodes,
         "materials": [{"name": name, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1}}],
         "meshes": [{"name": name, "primitives": [{"attributes": attrs, "material": 0}]}],
         "skins": [{"joints": [i + 1 for i in range(len(joints))], "skeleton": roots[0],
                    "inverseBindMatrices": buf.add("16f", ibm, "MAT4", 5126)}]}
    anims = []
    for aname, times, tracks in animations:
        tacc = buf.add("f", [(t,) for t in times], "SCALAR", 5126, True)
        samplers, channels = [], []
        for ji in sorted(tracks):
            parent = joints[ji][1]
            trs = [[], [], []]
            for k, m in enumerate(tracks[ji]):
                if parent >= 0:
                    pm = tracks[parent][k] if parent in tracks else rest[parent]
                    m = mul(inverse(pm), m)
                t, q, s = decompose(m)
                if trs[1]:  # keep quaternions on one hemisphere so LINEAR keys take the short way
                    p = trs[1][-1]
                    if sum(a * b for a, b in zip(p, q)) < 0: q = [-v for v in q]
                trs[0].append(t); trs[1].append(q); trs[2].append(s)
            for target, rows, typ, fmt in (("translation", trs[0], "VEC3", "3f"), ("rotation", trs[1], "VEC4", "4f"),
                                           ("scale", trs[2], "VEC3", "3f")):
                samplers.append({"input": tacc, "output": buf.add(fmt, rows, typ, 5126), "interpolation": "LINEAR"})
                channels.append({"sampler": len(samplers) - 1, "target": {"node": ji + 1, "path": target}})
        anims.append({"name": aname, "samplers": samplers, "channels": channels})
    if anims: j["animations"] = anims
    j["buffers"] = [{"byteLength": len(buf.bin)}]; j["bufferViews"] = buf.views; j["accessors"] = buf.accessors
    js = json.dumps(j).encode()
    while len(js) % 4: js += b" "
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(buf.bin)))
        f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
        f.write(struct.pack("<II", len(buf.bin), 0x004E4942)); f.write(buf.bin)
