"""Build a sprite character as a pal-style Blender file: flat cards on bones, one bone per pose frame.

  Blender --background --factory-startup --python sources/sprites/sprite_build.py -- \
      --pal <Pal> --spec characters/<name>/character.json --sprites work/<name>/sprites

Reads sources/sprites/sprite_atlas.py's atlas.png and layout.json. Each pose frame is two pairs of
one-sided cards standing on the floor, each pair on its own bone: the front sprite facing the
viewer with the back sprite behind it, and the side sprite on both flanks (mirrored on one).
Clips listed in `sideClips` (the walk, which the app turns side-on) show the flanks, so the
side view faces the way the pet goes; the rest show the front. A clip shows one bone's cards
at a time by scaling the others to almost nothing, so the pet is always a single paper
cut-out, at a slant while it turns (and in the Pet House, seen from above at any heading).
The pack's fades should be 0 so frames snap.
Writes work/<pal>/blender/<Pal>.blend for pipeline/probe_pal.py and pipeline/export_realtime.py.
"""
import bpy
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARGS = sys.argv[sys.argv.index('--') + 1:]
PAL = ARGS[ARGS.index('--pal') + 1]
SPEC = json.loads(Path(ARGS[ARGS.index('--spec') + 1]).read_text())
SPRITES = Path(ARGS[ARGS.index('--sprites') + 1])
LAYOUT = json.loads((SPRITES / 'layout.json').read_text())
# Metres per sprite pixel: given, or from "height", what the idle's first frame stands.
if 'height' in SPEC:
    idle_pose = SPEC['clips']['Idle'][0][0]
    PX = SPEC['height'] / LAYOUT['sprites'][LAYOUT['poses'][idle_pose][0]['front']]['h']
else:
    PX = SPEC['metresPerPixel']
FPS = 30
HIDDEN = 0.001  # exactly 0 breaks the USD export (PIPELINE.md problem 11)
GAP = 0.003  # between back-to-back cards

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS

# One bone per distinct pose frame, and one more for its flanks.
bone_of, frames_of = {}, {}
for pose, frames in LAYOUT['poses'].items():
    frames_of[pose] = []
    for index, frame in enumerate(frames):
        key = (frame['front'], frame['side'], frame['back'])
        bone_of.setdefault(key, f'{pose}_{index}')
        frames_of[pose].append((bone_of[key], frame['seconds']))

armature = bpy.data.armatures.new(f'SK_{PAL}')  # the USD skeleton's name, the pack's skeletonNode
rig = bpy.data.objects.new(f'{PAL}_Rig', armature)
scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode='EDIT')
root = armature.edit_bones.new('root')
root.head, root.tail = (0, 0, 0), (0, 0, 0.2)
for name in [n + side for n in bone_of.values() for side in ('', '_Side')]:
    bone = armature.edit_bones.new(name)
    bone.head, bone.tail, bone.parent = (0, 0, 0), (0, 0, 0.2), root
bpy.ops.object.mode_set(mode='OBJECT')


def cards(key):
    """(bone suffix, four corners, their UVs) for one pose frame's cards; the character faces -Y."""
    front, side, back = (LAYOUT['sprites'][i] for i in key)
    out = []
    for suffix, sprite, corner, uv in (
            # Front, seen from -Y: screen right is +X.
            ('', front, lambda w, h: [(-w, -GAP, 0), (w, -GAP, 0), (w, -GAP, h), (-w, -GAP, h)], 'plain'),
            # Back, seen from +Y: screen right is -X.
            ('', back, lambda w, h: [(w, GAP, 0), (-w, GAP, 0), (-w, GAP, h), (w, GAP, h)], 'plain'),
            # Flanks: the sprite faces left, its left edge goes forward (-Y). Seen from +X
            # (walking left) that's as drawn; seen from -X (walking right), mirrored.
            ('_Side', side, lambda w, h: [(GAP, -w, 0), (GAP, w, 0), (GAP, w, h), (GAP, -w, h)], 'plain'),
            ('_Side', side, lambda w, h: [(-GAP, w, 0), (-GAP, -w, 0), (-GAP, -w, h), (-GAP, w, h)], 'mirrored')):
        u0, u1 = (sprite['u0'], sprite['u1']) if uv == 'plain' else (sprite['u1'], sprite['u0'])
        out.append((suffix, corner(sprite['w'] * PX / 2, sprite['h'] * PX),
                    [(u0, sprite['v0']), (u1, sprite['v0']), (u1, sprite['v1']), (u0, sprite['v1'])]))
    return out


vertices, faces, uvs, groups = [], [], [], {}
for key, bone in bone_of.items():
    for suffix, corners, corner_uvs in cards(key):
        start = len(vertices)
        vertices += corners
        # Two triangles: SceneKit's hit test (clicks on the pet) ignores quads.
        faces += [(start, start + 1, start + 2), (start, start + 2, start + 3)]
        uvs += corner_uvs
        groups.setdefault(bone + suffix, []).extend(range(start, start + 4))
mesh_data = bpy.data.meshes.new(PAL)
mesh_data.from_pydata(vertices, [], faces)
layer = mesh_data.uv_layers.new(name='UVMap')
for loop in mesh_data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
mesh = bpy.data.objects.new(PAL, mesh_data)
scene.collection.objects.link(mesh)
for bone, indices in groups.items():
    mesh.vertex_groups.new(name=bone).add(indices, 1.0, 'REPLACE')
mesh.parent = rig
mesh.modifiers.new('Armature', 'ARMATURE').object = rig

# Unlit look: the sprite as emission over black, its alpha cutting the card out.
material = bpy.data.materials.new(f'{PAL}_Sprite')
material.use_nodes = True
nodes, links = material.node_tree.nodes, material.node_tree.links
shader = nodes['Principled BSDF']
shader.inputs['Base Color'].default_value = (0, 0, 0, 1)
shader.inputs['Roughness'].default_value = 1.0
shader.inputs['Specular IOR Level'].default_value = 0.0
shader.inputs['Emission Strength'].default_value = 1.0
texture = nodes.new('ShaderNodeTexImage')
texture.image = bpy.data.images.load(str(SPRITES / 'atlas.png'))
texture.image.name = f'{PAL}_Sprites_B'
texture.image.pack()
texture.interpolation = 'Closest'
links.new(texture.outputs['Color'], shader.inputs['Emission Color'])
links.new(texture.outputs['Alpha'], shader.inputs['Alpha'])
material.surface_render_method = 'DITHERED'
material.use_backface_culling = True  # one-sided: back-to-back cards each show their own side
mesh_data.materials.append(material)


def steps(clip):
    """[(bone, seconds)] for a clip's steps of [pose, seconds, repeats]."""
    out = []
    for step in clip:
        pose, seconds, repeats = (list(step) + [None, 1])[:3]
        frames = frames_of[pose]
        if seconds is not None:
            total = sum(s for _, s in frames) or len(frames)
            frames = [(bone, (s or 1) * seconds / total) for bone, s in frames]
        out += [(bone, s or 0.5) for bone, s in frames] * (repeats or 1)
    return out


rig.animation_data_create()
for clip, spec in SPEC['clips'].items():
    action = bpy.data.actions.new(f'AS_{PAL}_{clip}')
    slot = action.slots.new('OBJECT', rig.name)
    bag = action.layers.new('Layer').strips.new(type='KEYFRAME').channelbag(slot, ensure=True)
    curves = {(bone, axis): bag.fcurves.new(f'pose.bones["{bone}"].scale', index=axis, group_name=bone)
              for bone in groups for axis in range(3)}
    timeline, t = [], 0.0
    side = '_Side' if clip in SPEC.get('sideClips', []) else ''
    for bone, seconds in steps(spec):
        timeline.append((1 + round(t * FPS), bone + side))
        t += seconds
    end = 1 + round(t * FPS)
    for frame, shown in timeline + [(end, timeline[-1][1])]:
        for (bone, _), curve in curves.items():
            curve.keyframe_points.insert(frame, 1.0 if bone == shown else HIDDEN, options={'FAST'}).interpolation = 'CONSTANT'
    action.use_fake_user = True
    action['source_duration_seconds'] = round((end - 1) / FPS, 4)
    print(f'CLIP {clip}: {action["source_duration_seconds"]} s, {len(timeline)} frames')

rig.animation_data.action = bpy.data.actions[f'AS_{PAL}_Idle']
rig.animation_data.action_slot = rig.animation_data.action.slots[0]
out = ROOT / 'work' / PAL.lower() / 'blender'
out.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=str(out / f'{PAL}.blend'))
print(f'SPRITE_BUILD_OK {len(groups)} pose frames, {len(SPEC["clips"])} clips')
