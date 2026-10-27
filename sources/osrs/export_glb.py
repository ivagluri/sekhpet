"""characters/<name>/ -> characters/<name>/model.glb: the character's models merged, one bone per vertex label
(or the model's own bones, for skeletal "animaya" NPCs), and every clip in character.json's "osrs" block.

  python3 sources/osrs/export_glb.py characters/<name>"""
import json, sys
from pathlib import Path
from cache import Cache
import anim, defs, glb, maya, model as mdl, player

SCALE = 1 / 128.0   # 128 model units = one tile, taken as a metre
TICK = 0.02         # sequence frame lengths are in 20 ms client ticks
MAX_HOLD = 2.0      # a pose held longer than this (a death's last frame, often minutes) is cut short


def to_gl(p):
    """OSRS model space (y down) -> glTF metres (y up); z flips too, keeping the frame right-handed."""
    return [p[0] * SCALE, -p[1] * SCALE, -p[2] * SCALE]


def mat_to_gl(m):
    c = [SCALE, -SCALE, -SCALE]
    out = anim.ident()
    for i in range(3):
        for j in range(3): out[i][j] = m[i][j] * c[i] / c[j]
        out[i][3] = m[i][3] * c[i]
    return out


def merged(cache, parts, recolours, scale=(1, 1, 1), hide=()):
    """parts: [(model id, recolours, y offset)] -> (models, vertices, labels, faces). Faces: (a, b, c, hsl).
    `hide`: face groups (the model's transparency groups) to leave out, such as water ripples."""
    models, verts, labels, faces = [], [], [], []
    for mid, rc, yoff in parts:
        m = mdl.load(cache, mid); models.append((m, len(verts)))
        colour = dict(rc); colour.update(recolours)
        off = len(verts)
        verts += [[m.vx[i] * scale[0], (m.vy[i] + yoff) * scale[1], m.vz[i] * scale[2]] for i in range(m.nv)]
        labels += m.vgroup if m.vgroup else [0] * m.nv
        for i in range(m.nf):
            if (m.rtypes[i] & 3) == 2 or m.alphas[i] == 255:
                continue  # hidden faces
            if hide and m.tgroups and m.tgroups[i] in hide:
                continue
            hsl = colour.get(m.colors[i], m.colors[i]) if m.tex[i] < 0 else None
            faces.append((m.f1[i] + off, m.f2[i] + off, m.f3[i] + off, hsl))
    return models, verts, labels, faces


def face_rgba(hsl):
    rgb = glb.hsl_to_rgb(hsl) if hsl is not None else (0.55, 0.55, 0.55)  # textured faces: plain grey
    return tuple(c ** 2.2 for c in rgb) + (1.0,)  # glTF vertex colours are linear


def mesh_arrays(verts, faces):
    """Flat-shaded triangles: each face gets its own corners so it keeps its one colour."""
    pos, col, tris, src = [], [], [], []
    for a, b, c, hsl in faces:
        rgba = face_rgba(hsl)
        start = len(pos)
        for v in (a, b, c):
            pos.append(to_gl(verts[v])); col.append(rgba); src.append(v)
        tris.append((start, start + 1, start + 2))
    return pos, col, tris, src


def clip_times(seq, loop):
    """Key times for a sequence's frames; a loop gets a last key back on the first pose."""
    times, t = [], 0.0
    lengths = [min(max(n, 1) * TICK, MAX_HOLD) for n in seq["lengths"]]
    for n in lengths:
        times.append(t); t += n
    times.append(t)
    order = list(range(len(lengths))) + [0 if loop else len(lengths) - 1]
    return times, order


def classic(cache, parts, recolours, clips, loops, scale, hide=()):
    _, verts, labels, faces = merged(cache, parts, recolours, scale, hide)
    label_verts = {}
    for i, l in enumerate(labels): label_verts.setdefault(l, []).append(i)
    used = sorted(label_verts)
    centre = {l: [sum(verts[v][k] for v in label_verts[l]) / len(label_verts[l]) for k in range(3)] for l in used}
    pos, col, tris, src = mesh_arrays(verts, faces)
    skin = [[(used.index(labels[v]) + 1, 1.0)] for v in src]
    joints = [("root", -1, anim.ident())] + [(f"label_{l:03d}", 0, anim.translate(*to_gl(centre[l]))) for l in used]
    frames = anim.Frames(cache); seqs = cache.files(2, 12); out = []
    for name, sid in clips.items():
        seq = defs.sequence(seqs[sid], sid)
        if not seq["frames"]:
            print(f"WARNING {name}: sequence {sid} has no frames, skipped"); continue
        times, order = clip_times(seq, name in loops)
        poses = []
        for fid in seq["frames"]:
            fm, ops = frames.frame(fid)
            poses.append(anim.pose(verts, label_verts, fm, ops))
        tracks = {}
        for n, l in enumerate(used):
            rest = anim.translate(*to_gl(centre[l]))
            tracks[n + 1] = [anim.mul(mat_to_gl(poses[k][l]), rest) for k in order]
        out.append((name, times, tracks))
    return pos, col, skin, tris, joints, out, verts, used, centre, label_verts


def parts_of(cache, folder, spec):
    """The character's models: (parts, recolours, NPC resize, name)."""
    o = spec["osrs"]
    if "npc" in o:
        n = defs.npc(cache.files(2, 9)[o["npc"]], o["npc"])
        parts = [(m, n["recolor"], 0) for m in n["models"]]; recolours = []
        scale = (n["widthScale"] / 128, n["heightScale"] / 128, n["widthScale"] / 128)
        name = n["name"]
    else:
        outfit = player.read_outfit(folder / o["player"])
        kits = defs.load_all(cache, 3, defs.kit); items = defs.load_all(cache, 10, defs.item)
        parts, recolours, _ = player.assemble(outfit, kits, items)
        scale = (1, 1, 1); name = spec["pal"]
    return parts, recolours, scale, name


def build(folder):
    folder = Path(folder)
    spec = json.loads((folder / "character.json").read_text())
    o = spec["osrs"]; cache = Cache()
    parts, recolours, scale, name = parts_of(cache, folder, spec)
    clips = o["clips"]; loops = set(o.get("loops", []))
    if set(spec["clips"]) != set(clips):  # osrs.clips is the list to edit; the import's map follows it
        spec["clips"] = {c: c for c in clips}
        (folder / "character.json").write_text(json.dumps(spec, indent=2) + "\n")
    seqs = {sid: defs.sequence(cache.files(2, 12)[sid], sid) for sid in clips.values()}
    hide = set(o.get("hideFaceGroups", []))
    if any(s["maya"] >= 0 for s in seqs.values()):
        pos, col, skin, tris, joints, anims = maya.build(cache, parts, recolours, clips, loops, (1, 1, 1), seqs, hide)
    else:
        pos, col, skin, tris, joints, anims, *_ = classic(cache, parts, recolours, clips, loops, (1, 1, 1), hide)
    if scale != (1, 1, 1):  # the game resizes an NPC after animating it
        # Scale the mesh and move the bones (S m S^-1) rather than scaling them: skinning stays exact
        # (S K S^-1 applied to S v), and no bone carries a rest scale, which Blender's import would lose.
        S = [[scale[0], 0, 0, 0], [0, scale[1], 0, 0], [0, 0, scale[2], 0], [0, 0, 0, 1]]
        Si = [[1 / scale[0], 0, 0, 0], [0, 1 / scale[1], 0, 0], [0, 0, 1 / scale[2], 0], [0, 0, 0, 1]]
        conj = lambda m: anim.mul(anim.mul(S, m), Si)
        pos = [[p[0] * scale[0], p[1] * scale[1], p[2] * scale[2]] for p in pos]
        joints = [(n, parent, conj(m)) for n, parent, m in joints]
        anims = [(n, t, {j: [conj(m) for m in ms] for j, ms in tr.items()}) for n, t, tr in anims]
    out = folder / spec["model"]
    glow = {face_rgba(hsl) for hsl in o.get("glow", [])}
    glb.write(str(out), name, pos, col, skin, tris, joints, anims, glow)
    height = max(p[1] for p in pos) - min(p[1] for p in pos)
    print(f"GLB_OK {out} {len(tris)} faces, {len(joints)} bones, {len(anims)} clips, {height:.2f} m tall")


if __name__ == "__main__":
    build(sys.argv[1])
