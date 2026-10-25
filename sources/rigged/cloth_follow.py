"""Let a skirt, dress or cape follow the legs, so they don't poke through it.

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/cloth_follow.py -- <character.json>

Game cloth is moved at runtime by physics or driver rigs that the pipeline doesn't run (FF7
Remake's Bonamik and kinematic drivers), so its bones never move in the clips: it rides the
hips stiffly while the legs kick, crouch and bend through it. This hands part of each cloth
vertex's weight to the leg bones, little at the waist and most at the hem, split between the
two legs by where the vertex sits side to side. No sway, but the hem goes where the legs go.

character.json's "clothFollow":

  "clothFollow": {"groups": ["*Skirt*"],
                  "legs": [["L_UpperLeg_a", "L_Foreleg_a"], ["R_UpperLeg_a", "R_Foreleg_a"]],
                  "waist": 0.1, "hem": 0.95, "curve": 0.5}

`groups` are vertex group (bone) name patterns. `legs` lists each side's leg bones from the top
(a single thigh bone per side is enough for a short skirt): a vertex follows the one at its height,
blended across the joint, so a long dress bends at the knee too. `waist` / `hem` are the share of
the weight moved to the legs at the hip joints (and above) and at the bottom edge; `curve` below 1 makes it climb
early (0.5: half way down already most of the way to `hem`), so the cloth hangs with the legs when
the body bends forward instead of swinging out with the hips. Run before
sources/rigged/prune_bones.py, which then merges the rest into the hips as before.
"""
import bpy
import json
import sys
from fnmatch import fnmatch
from pathlib import Path

SPEC = json.loads(Path(sys.argv[sys.argv.index('--') + 1]).read_text())
cloth = SPEC.get('clothFollow')
if not cloth:
    print('CLOTH_FOLLOW_OK (none)')
    sys.exit(0)
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
mesh = bpy.data.objects[rig.name.removesuffix('_Rig')]
groups = mesh.vertex_groups
patterns = [p.lower() for p in cloth['groups']]
cloth_groups = {g.index for g in groups if any(fnmatch(g.name.lower(), p) for p in patterns)}
# Each side: its leg bones from the top, and the height of each joint between them.
sides = [[side] if isinstance(side, str) else side for side in cloth['legs']]
for side in sides:
    for leg in side:
        if leg not in groups:
            groups.new(name=leg)
side_x = [(rig.matrix_world @ rig.data.bones[side[0]].head_local).x for side in sides]
joints = [[(rig.matrix_world @ rig.data.bones[leg].head_local).z for leg in side[1:]] for side in sides]
waist, hem, curve = cloth.get('waist', 0.1), cloth.get('hem', 0.95), cloth.get('curve', 0.5)
BLEND = 0.08  # metres either side of a joint over which a vertex passes from one bone to the next


def along(side, z):
    """[(bone, share)] of one side's leg bones for a vertex at height z."""
    shares, rest = [], 1.0
    for leg, joint in zip(sides[side], joints[side]):
        below = min(1.0, max(0.0, (joint + BLEND - z) / (2 * BLEND)))  # 0 above the joint, 1 below
        shares.append((leg, rest * (1 - below)))
        rest *= below
    shares.append((sides[side][-1], rest))
    return shares


world = mesh.matrix_world
weighted = [(v, sum(g.weight for g in v.groups if g.group in cloth_groups)) for v in mesh.data.vertices]
weighted = [(v, w) for v, w in weighted if w > 1e-4]
assert weighted, f'no vertices weighted to {cloth["groups"]}'
points = [world @ v.co for v, _ in weighted]
top, bottom = max(p.z for p in points), min(p.z for p in points)
# Measured from the hip joints, not the cloth's top edge: above them it rides the hips, below
# them it climbs towards the legs.
hips = min(top, sum((rig.matrix_world @ rig.data.bones[side[0]].head_local).z for side in sides) / len(sides))
for (vertex, _), point in zip(weighted, points):
    depth = min(1.0, max(0.0, (hips - point.z) / max(hips - bottom, 1e-6)))
    share = waist + (hem - waist) * depth ** curve
    if len(sides) == 2:
        # 0 at the second side's leg, 1 at the first's, linear across the middle.
        u = min(1.0, max(0.0, (point.x - side_x[1]) / (side_x[0] - side_x[1]))) if side_x[0] != side_x[1] else 0.5
        splits = [u, 1 - u]
    else:
        splits = [1.0]
    moved = 0.0
    for element in vertex.groups:
        if element.group in cloth_groups:
            moved += element.weight * share
            groups[element.group].add([vertex.index], element.weight * (1 - share), 'REPLACE')
    for side, split in enumerate(splits):
        for leg, part in along(side, point.z):
            if split * part > 0:
                groups[leg].add([vertex.index], moved * split * part, 'ADD')
bpy.ops.wm.save_mainfile()
print(f'CLOTH_FOLLOW_OK {len(weighted)} vertices of {len(cloth_groups)} groups follow '
      f'{", ".join("/".join(side) for side in sides)} ({hips - bottom:.2f} m from the hips to the hem)')
