"""Drop the bones no clip moves, so the pack's clips load quickly.

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/prune_bones.py -- [bone...]

Game rigs often have hundreds of bones (face, cloth and helper bones) that the chosen clips
never move, and every clip file holds every joint: one with 547 bones took 6.6 s to load its
49 clips (a Palworld pal's take 0.4 s), a beachball each time the pet came out. A bone that
is never moved away from its rest pose rides its parent exactly, so its weights go to the
nearest bone that's kept, and it goes. Kept: bones moved (or held off rest) in any of the
pet's clips (AS_<Pal>_*), the named bones (feet, look bones), root, pelvis, and their ancestors.
Run last before pipeline/probe_pal.py.
"""
import bpy
import re
import sys

named = set(sys.argv[sys.argv.index('--') + 1:]) if '--' in sys.argv else set()
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.parent == rig]

PAL = rig.name.removesuffix('_Rig')
moving = set()
for action in [a for a in bpy.data.actions if a.name.startswith(f'AS_{PAL}_')]:
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    match = re.match(r'pose\.bones\["(.+)"\]\.(\w+)', curve.data_path)
                    if not match:
                        continue
                    channel = match.group(2)
                    rest = 1.0 if channel == 'scale' or (channel == 'rotation_quaternion' and curve.array_index == 0) else 0.0
                    if any(abs(key.co.y - rest) > 1e-4 for key in curve.keyframe_points):
                        moving.add(match.group(1))

keep = set()
for name in moving | named | {'root', 'pelvis'}:
    bone = rig.data.bones.get(name)
    while bone and bone.name not in keep:
        keep.add(bone.name)
        bone = bone.parent


def kept_ancestor(name):
    bone = rig.data.bones.get(name)
    while bone and bone.name not in keep:
        bone = bone.parent
    return bone.name if bone else 'root'


for mesh in meshes:
    groups = mesh.vertex_groups
    moved = {g.index: kept_ancestor(g.name) for g in groups if g.name not in keep and g.name in rig.data.bones}
    for target in set(moved.values()):
        if target not in groups:
            groups.new(name=target)
    for vertex in mesh.data.vertices:
        extra = {}
        for element in vertex.groups:
            if element.group in moved:
                extra[moved[element.group]] = extra.get(moved[element.group], 0) + element.weight
        for target, weight in extra.items():
            groups[target].add([vertex.index], weight, 'ADD')
    for index in sorted(moved, reverse=True):
        groups.remove(groups[index])

dropped = [b.name for b in rig.data.bones if b.name not in keep]
for action in bpy.data.actions:
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in [c for c in bag.fcurves if (m := re.match(r'pose\.bones\["(.+)"\]', c.data_path)) and m.group(1) not in keep]:
                    bag.fcurves.remove(curve)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
for name in dropped:
    rig.data.edit_bones.remove(rig.data.edit_bones[name])
bpy.ops.object.mode_set(mode='OBJECT')
bpy.ops.wm.save_mainfile()
print(f'PRUNE_OK kept {len(keep)} of {len(keep) + len(dropped)} bones')
