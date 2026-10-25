"""Make a rigged character's clips from its imported animations (after sources/rigged/import_model.py).

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/compose.py -- <character folder>

character.json's "clips" names each clip and what it's made of: an animation's name, or a
list of them played back to back, where a number between two is that many frames for
Blender to blend across a jump in the pose:

  "clips": {"Idle": "idle", "Hit": "hit_react", "Dash": ["dash_start", "dash_loop", 3, "dash_end"]}

Each becomes AS_<Pal>_<Clip>, the only animations the exporter sees; the imported ones stay as
SRC_<Pal>_<name> for scrubbing in Blender. "inPlace" (clip names or fnmatch patterns, "*" for
all) keeps those clips' body over one spot across the floor, up and down kept, as gaits must
be: the app moves the window instead. The rig is moved so the idle (the first clip, or
"Idle") stands on the origin.
"""
import bpy
import json
import sys
from fnmatch import fnmatch
from pathlib import Path
from mathutils import Vector

FOLDER = Path(sys.argv[sys.argv.index('--') + 1]).resolve()
SPEC = json.loads((FOLDER / 'character.json').read_text())
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
PAL = rig.name.removesuffix('_Rig')
FPS = 30
scene = bpy.context.scene


def channelbag(action):
    return action.layers[0].strips[0].channelbags[0]


composed = []
for name, recipe in SPEC['clips'].items():
    pieces = [recipe] if isinstance(recipe, str) else recipe
    target = bpy.data.actions.get(f'AS_{PAL}_{name}')
    if target:
        bpy.data.actions.remove(target)
    target = bpy.data.actions.new(f'AS_{PAL}_{name}')
    slot = target.slots.new('OBJECT', rig.name)
    bag = target.layers.new('Layer').strips.new(type='KEYFRAME').channelbag(slot, ensure=True)
    offset, gap = 0.0, 0
    for piece in pieces:
        if isinstance(piece, int):
            gap = piece
            continue
        source = bpy.data.actions.get(f'SRC_{PAL}_{piece}')
        if source is None:
            sys.exit(f'{name}: no animation {piece!r}; the imported ones are: '
                     + ', '.join(a.name.removeprefix(f'SRC_{PAL}_') for a in bpy.data.actions if a.name.startswith('SRC_')))
        start, end = source.frame_range
        shift = offset + (gap if offset else 0) - (start - 1)
        for curve in channelbag(source).fcurves:
            into = bag.fcurves.find(curve.data_path, index=curve.array_index) or \
                bag.fcurves.new(curve.data_path, index=curve.array_index, group_name=curve.group.name if curve.group else '')
            for key in curve.keyframe_points:
                into.keyframe_points.insert(key.co.x + shift, key.co.y, options={'FAST'}).interpolation = key.interpolation
        offset = end + shift + 1  # the next piece starts a frame after this one ends
        gap = 0
    for curve in bag.fcurves:
        curve.update()
    target.use_fake_user = True
    target['source_duration_seconds'] = round((target.frame_range[1] - 1) / FPS, 4)
    target['recipe'] = json.dumps(recipe)
    composed.append(target)

# Across the floor: the root's location channels whose rest axis lies flat. Other top-level
# bones animated beside the root (a PS1 rig's world-space weapon) lose the same travel.
rest = rig.data.bones['root'].matrix_local.to_3x3()
floor = [i for i in range(3) if abs(rest.col[i].z) < 0.5]
others = [b for b in rig.data.bones if b.parent is None and b.name != 'root']
patterns = SPEC.get('inPlace', [])
for action in composed:
    clip = action.name.removeprefix(f'AS_{PAL}_')
    flat = any(fnmatch(clip, p) for p in patterns)
    if flat:
        bag = channelbag(action)
        root_curves = {c.array_index: c for c in bag.fcurves
                       if c.data_path == 'pose.bones["root"].location' and c.array_index in floor}

        def travel(frame):
            return rest @ Vector([root_curves[i].evaluate(frame) if i in root_curves else 0.0 for i in range(3)])

        for bone in others:
            to_local = bone.matrix_local.to_3x3().inverted()
            for curve in bag.fcurves:
                if curve.data_path == f'pose.bones["{bone.name}"].location':
                    for key in curve.keyframe_points:
                        for point in (key.co, key.handle_left, key.handle_right):
                            point.y -= (to_local @ travel(point.x))[curve.array_index]
                    curve.update()
        for curve in root_curves.values():
            for key in curve.keyframe_points:
                for point in (key.co, key.handle_left, key.handle_right):
                    point.y = 0.0
            curve.update()
    print(f'CLIP {clip}: {action["recipe"]}, {action["source_duration_seconds"]:.2f} s' + (' (in place)' if flat else ''))

# Stand the idle's root over the origin (moving the objects and applying it keeps every clip
# relative to the rest pose as it was).
idle = bpy.data.actions.get(f'AS_{PAL}_Idle') or composed[0]
rig.animation_data.action = idle
rig.animation_data.action_slot = idle.slots[0]
scene.frame_set(1)
standing = rig.matrix_world @ rig.pose.bones['root'].head
if standing.xy.length > 0.01:
    meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.parent == rig]
    rig.location.x -= standing.x
    rig.location.y -= standing.y
    bpy.context.view_layer.update()
    bpy.ops.object.select_all(action='DESELECT')
    for obj in [rig] + meshes:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.transform_apply(location=True, rotation=False, scale=False)
    print(f'centred: moved {-standing.x:+.2f}, {-standing.y:+.2f} m')
scene.frame_start, scene.frame_end = 1, int(idle.frame_range[1])
scene.frame_set(1)
bpy.ops.wm.save_mainfile()
print('COMPOSE_OK')
