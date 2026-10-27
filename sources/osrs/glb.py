"""A small skinned glTF (GLB) writer: one mesh coloured from a palette texture, a joint hierarchy, and animations
given as each joint's model-space matrix per key time (LINEAR keys)."""
import json, math, struct, zlib
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


CELL = 8  # palette cell, in pixels: every corner of a face samples its cell's middle, so filtering can't mix colours


def png(width, height, rows):
    """rows: [[(r, g, b) bytes per pixel]] -> PNG file bytes."""
    raw = b"".join(b"\0" + bytes(v for px in row for v in px) for row in rows)
    chunk = lambda tag, data: struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def palette(colours, glow):
    """Distinct linear colours -> (cell per colour, colour PNG, glow PNG or None, side in cells). The glow
    image is black but for the glowing colours' cells."""
    cells = {c: i for i, c in enumerate(sorted(set(colours)))}
    side = 1
    while side * side < len(cells): side *= 2
    def image(lit):
        texel = lambda c: tuple(round(255 * min(1.0, max(0.0, v)) ** (1 / 2.2)) for v in c[:3])  # back to sRGB
        grid = [[(0, 0, 0)] * side for _ in range(side)]
        for c, i in cells.items():
            if lit(c): grid[i // side][i % side] = texel(c)
        return png(side * CELL, side * CELL, [[px for px in row for _ in range(CELL)] for row in grid for _ in range(CELL)])
    shine = image(lambda c: c in glow) if any(c in glow for c in cells) else None
    return cells, image(lambda c: True), shine, side


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

    def add_bytes(self, data):
        start = len(self.bin)
        self.bin += data
        while len(self.bin) % 4: self.bin += b"\0"
        self.views.append({"buffer": 0, "byteOffset": start, "byteLength": len(data)})
        return len(self.views) - 1


def write(path, name, positions, colours, skin, triangles, joints, animations, glow=()):
    """positions: [xyz] per vertex (glTF space, metres); colours: [rgba] per vertex; skin: [[(joint, weight), ...]]
    per vertex; triangles: [(a, b, c)] vertex indices; joints: [(name, parent index or -1, rest matrix)] with
    model-space rest matrices, parents before children; animations: [(name, times, {joint: [matrix per time]})]
    with model-space matrices (joints left out stay at rest). glow: colours (rgba, as in `colours`) that shine
    with their own colour (glowing eyes), through the material's emissive texture.

    Each triangle is one colour, so the colours become a palette texture rather than vertex colours: the
    pipeline would otherwise bake them onto a texture, where a face smaller than a pixel goes missing."""
    buf = _Buffer()
    cells, image, shine, side = palette([colours[tri[0]] for tri in triangles], set(glow))
    flat_pos, flat_uv, flat_j, flat_w = [], [], [], []
    for tri in triangles:
        i = cells[colours[tri[0]]]
        uv = ((i % side + 0.5) / side, (i // side + 0.5) / side)
        for v in tri:
            flat_pos.append(positions[v]); flat_uv.append(uv)
            ws = sorted(skin[v], key=lambda jw: -jw[1])[:4]
            tot = sum(w for _, w in ws) or 1.0
            ws = ws + [(0, 0.0)] * (4 - len(ws))
            flat_j.append(tuple(j for j, _ in ws)); flat_w.append(tuple(w / tot for _, w in ws))
    attrs = {"POSITION": buf.add("3f", flat_pos, "VEC3", 5126, True, 34962),
             "TEXCOORD_0": buf.add("2f", flat_uv, "VEC2", 5126, False, 34962),
             "JOINTS_0": buf.add("4H", flat_j, "VEC4", 5123, False, 34962),
             "WEIGHTS_0": buf.add("4f", flat_w, "VEC4", 5126, False, 34962)}
    images = [{"name": f"{name}_Palette", "mimeType": "image/png", "bufferView": buf.add_bytes(image)}]
    material = {"name": name, "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0,
                                                        "roughnessFactor": 1},
                # Matte: any reflection of the app's grey surroundings lifts dark colours to grey.
                "extensions": {"KHR_materials_specular": {"specularFactor": 0}, "KHR_materials_ior": {"ior": 1}}}
    if shine:
        images.append({"name": f"{name}_Glow", "mimeType": "image/png", "bufferView": buf.add_bytes(shine)})
        material.update(emissiveTexture={"index": 1}, emissiveFactor=[1, 1, 1])
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
         "extensionsUsed": ["KHR_materials_specular", "KHR_materials_ior"],
         "scene": 0, "scenes": [{"nodes": [0] + roots}], "nodes": nodes,
         "materials": [material], "meshes": [{"name": name, "primitives": [{"attributes": attrs, "material": 0}]}],
         "images": images, "textures": [{"source": i, "sampler": 0} for i in range(len(images))],
         "samplers": [{"magFilter": 9728, "minFilter": 9728}],
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
