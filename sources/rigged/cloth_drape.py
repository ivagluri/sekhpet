"""Bake a simple drape onto cloth bone chains (skirts, dresses, capes) in every clip.

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/cloth_drape.py -- <character.json>

Game cloth hangs from chains of bones that physics moves at runtime (FF7 Remake's Bonamik), so
in the clips they never move: the cloth rides the hips stiffly, juts out behind a body bent at
the waist and lets the legs through. On every frame of every clip this tilts each chain back
towards hanging the way it hangs at rest, by as much as the body has tipped (more towards the
hem), then pushes any joint that ends up inside a leg back out to its surface, and keys the
chain bones. No sway or momentum: the cloth is where gravity and the legs put it.

character.json's "clothDrape":

  "clothDrape": {
    "chains": ["*Skirt*_Phy"],          // bones in the chains, by name pattern; a chain is a run of
                                        //   them parent to child, starting below a bone that isn't one
    "body": "pelvis",                   // the bone whose tilt the cloth makes up for
    "hang": [0.5, 1.0],                 // how much of that tilt it undoes at the chain's top and end
    "colliders": [["L_UpperLeg_a", "L_Foreleg_a", 0.085], ["L_Foreleg_a", "L_Foot_a", 0.06], ...],
    "margin": 0.01                      // metres kept between the cloth and a collider
  }

Each collider is a capsule from one bone's head to another's, with a radius in metres. Run before
sources/rigged/prune_bones.py, which then keeps the chain bones because they move. Don't use
it together with sources/rigged/cloth_follow.py on the same cloth.
"""
import bpy
import json
import math
import sys
from fnmatch import fnmatch
from pathlib import Path
from mathutils import Matrix, Quaternion, Vector

SPEC = json.loads(Path(sys.argv[sys.argv.index('--') + 1]).read_text())
drape = SPEC.get('clothDrape')
if not drape:
    print('CLOTH_DRAPE_OK (none)')
    sys.exit(0)
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
PAL = rig.name.removesuffix('_Rig')
mesh = bpy.data.objects[PAL]
scene = bpy.context.scene
bones = rig.data.bones
patterns = [p.lower() for p in drape['chains']]
in_chain = {b.name for b in bones if any(fnmatch(b.name.lower(), p) for p in patterns)}
hang_top, hang_end = drape.get('hang', [0.5, 1.0])
margin = drape.get('margin', 0.01)
colliders = [(a, b, r) for a, b, r in drape.get('colliders', [])]

# Chains: from each bone in the set whose parent isn't, down through its first child in the set.
chains = []
for bone in bones:
    if bone.name in in_chain and (bone.parent is None or bone.parent.name not in in_chain):
        chain = [bone]
        while True:
            nxt = next((c for c in chain[-1].children if c.name in in_chain), None)
            if not nxt:
                break
            chain.append(nxt)
        chains.append(chain)
assert chains, f'no bones match {drape["chains"]}'


def rest_segment(chain, i):
    """A chain bone's rest direction and length, in armature space: towards the next bone's head
    (the last one keeps its own direction and the previous length)."""
    head = chain[i].head_local
    if i + 1 < len(chain):
        offset = chain[i + 1].head_local - head
    else:
        offset = (chain[i].tail_local - head).normalized() * (chain[i].head_local - chain[i - 1].head_local).length
    return offset.normalized(), offset.length


segments = [[rest_segment(chain, i) for i in range(len(chain))] for chain in chains]
rest_down = (bones[drape['body']].matrix_local.to_3x3().inverted() @ Vector((0, 0, -1))).normalized()

# Pose evaluation only: the 100k-vertex mesh needn't deform while baking.
armature_mods = [m for m in mesh.modifiers if m.type == 'ARMATURE']
for modifier in armature_mods:
    modifier.show_viewport = False


def push_out(point, posed):
    """Moves a point out of every collider capsule it's inside."""
    for a, b, radius in colliders:
        start, end = posed[a].head, posed[b].head
        axis = end - start
        t = max(0.0, min(1.0, (point - start).dot(axis) / max(axis.length_squared, 1e-9)))
        nearest = start + axis * t
        away = point - nearest
        if away.length < radius + margin:
            if away.length < 1e-6:
                away = Vector((0, -1, 0))  # dead centre: forwards
            point = nearest + away.normalized() * (radius + margin)
    return point


def bake(action):
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    for bone in rig.pose.bones:
        bone.matrix_basis.identity()
    bag = action.layers[0].strips[0].channelbags[0]
    last = math.ceil(action.frame_range[1] - 1e-4)
    keys = {}
    for frame in range(1, last + 1):
        scene.frame_set(frame)
        posed = rig.pose.bones
        body = posed[drape['body']].matrix.to_3x3()
        # The turn that brings the body's own "down" back to the world's.
        tilt = (body @ rest_down).normalized().rotation_difference(Vector((0, 0, -1)))
        for chain, segs in zip(chains, segments):
            parent = posed[chain[0].parent.name].matrix if chain[0].parent else Matrix()
            parent_rest = chain[0].parent.matrix_local if chain[0].parent else Matrix()
            above = parent  # posed matrix of the bone above, as baked
            above_rest = parent_rest
            rigid = (parent @ parent_rest.inverted()).to_3x3()  # the whole chain riding its root, unbent
            point = (parent @ (parent_rest.inverted() @ chain[0].matrix_local)).translation
            for i, (bone, (direction, length)) in enumerate(zip(chain, segs)):
                # Where this bone points riding the bone above (as baked), and where it should hang:
                # its rest direction riding the chain's root, turned back by part of the body's tilt
                # (once, from the root: turning each bone from the one above would compound).
                riding = (above @ above_rest.inverted()).to_3x3() @ direction
                share = hang_top + (hang_end - hang_top) * i / max(len(chain) - 1, 1)
                hanging = Quaternion().slerp(tilt, share) @ (rigid @ direction)
                aim = (push_out(point + hanging.normalized() * length, posed) - point).normalized()
                end = point + aim * length  # the bone keeps its length; the next one starts here
                # The bone's matrix as it would ride its parent, turned to aim along the new direction.
                riding_matrix = above @ (above_rest.inverted() @ bone.matrix_local)
                turn = riding.normalized().rotation_difference(aim).to_matrix().to_4x4()
                wanted = Matrix.Translation(point) @ turn @ Matrix.Translation(-point) @ riding_matrix
                basis = riding_matrix.inverted() @ wanted
                keys.setdefault(bone.name, []).append((frame, basis.to_quaternion()))
                above, above_rest, point = wanted, bone.matrix_local, end
    for name, samples in keys.items():
        path = f'pose.bones["{name}"].rotation_quaternion'
        rig.pose.bones[name].rotation_mode = 'QUATERNION'
        for axis in range(4):
            curve = bag.fcurves.find(path, index=axis) or bag.fcurves.new(path, index=axis, group_name=name)
            curve.keyframe_points.clear()
            curve.keyframe_points.add(len(samples))
            flat = []
            for frame, q in samples:
                flat += [frame, q[axis]]
            curve.keyframe_points.foreach_set('co', flat)
            curve.update()


clips = [a for a in bpy.data.actions if a.name.startswith(f'AS_{PAL}_')]
for action in clips:
    bake(action)
for modifier in armature_mods:
    modifier.show_viewport = True
rig.animation_data.action = None
for bone in rig.pose.bones:
    bone.matrix_basis.identity()
bpy.ops.wm.save_mainfile()
print(f'CLOTH_DRAPE_OK {len(chains)} chains ({sum(len(c) for c in chains)} bones) draped in {len(clips)} clips')
