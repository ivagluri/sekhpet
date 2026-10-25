"""Import a rigged character (glTF/GLB or FBX, with its animations) into a Blender file laid out
the pipeline's way.

  Blender --background --factory-startup --python sources/rigged/import_model.py -- <character folder>

Reads <folder>/character.json (see sources/rigged/README.md) and writes
work/<pal>/blender/<Pal>.blend: rig <Pal>_Rig (skeleton SK_<Pal>), one mesh <Pal>, facing -Y,
in metres, and every animation as SRC_<Pal>_<name> on a 30 fps timeline starting at frame 1,
for sources/rigged/compose.py to turn into the pet's clips. Also an inspection camera and a
"start here" text with select_action() for scrubbing through the animations in Blender.
"""
import bpy
import json
import math
import os
import re
import sys
from pathlib import Path
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
FOLDER = Path(sys.argv[sys.argv.index('--') + 1]).resolve()
SPEC = json.loads((FOLDER / 'character.json').read_text())
PAL = SPEC['pal']
DEST = ROOT / 'work' / PAL.lower() / 'blender'
DEST.mkdir(parents=True, exist_ok=True)
FPS = 30
FACING = {'-Y': 0, '+X': -90, '+Y': 180, '-X': 90}  # turn about Z that brings each to -Y

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps = FPS  # the importers key animations at the scene's rate
scene.unit_settings.system = 'METRIC'


def load(path):
    """Import a model or animation file; returns the objects it added."""
    before = set(bpy.data.objects)
    if path.suffix.lower() in ('.glb', '.gltf'):
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif path.suffix.lower() == '.fbx':
        bpy.ops.import_scene.fbx(filepath=str(path))
    else:
        sys.exit(f'{path.name}: glTF/GLB or FBX only (convert others first, e.g. assimp export model.dae model.glb)')
    return [o for o in bpy.data.objects if o not in before]


def channelbags(action):
    for layer in action.layers:
        for strip in layer.strips:
            yield from strip.channelbags


added = load(FOLDER / SPEC['model'])
rig = next(o for o in added if o.type == 'ARMATURE')
skinned = [o for o in added if o.type == 'MESH' and o.find_armature() == rig]
# Anything else (stray helper meshes, empties, cameras, lights) isn't part of the character.
for obj in added:
    if obj is not rig and obj not in skinned and obj.type != 'EMPTY':
        bpy.data.objects.remove(obj)
# Extra animation files for the same skeleton: keep their animations, drop the rest.
for pattern in SPEC.get('animations', []):
    for path in sorted(FOLDER.glob(pattern)):
        for obj in load(path):
            bpy.data.objects.remove(obj)

def bone_bag(action):
    """The channel bag that moves the bones (an animation can also hold its parent's)."""
    bags = list(channelbags(action))
    return max(bags, key=lambda b: sum(c.data_path.startswith('pose.bones') for c in b.fcurves)) if bags else None


def moves_object(bag):
    """Whether the animation moves the armature object itself (off its rest) rather than only its bones."""
    rest = {'location': 0.0, 'scale': 1.0, 'rotation_euler': 0.0}
    for curve in bag.fcurves:
        if curve.data_path.startswith('pose.bones'):
            continue
        base = 1.0 if curve.data_path == 'rotation_quaternion' and curve.array_index == 0 else rest.get(curve.data_path, 0.0)
        if any(abs(k.co.y - base) > 1e-4 for k in curve.keyframe_points):
            return True
    return False


# Animations that move the armature object (assimp conversions: a PS1 field model's flip and
# its body's sway): the motion goes onto the top-level bones instead, frame by frame, with the
# object held where it stands now, since the pipeline only plays bone animation. Recorded in
# world space while any parent empties (the glTF's Y-up turn) are still there.
worlds = {obj.name: obj.matrix_world.copy() for obj in [rig] + skinned}
moving = [a for a in bpy.data.actions if (bag := bone_bag(a)) and moves_object(bag)]
tops = [rig.pose.bones[b.name] for b in rig.data.bones if b.parent is None]
recorded = {}
if moving:
    rig.animation_data_create()
    for action in moving:
        rig.animation_data.action = action
        rig.animation_data.action_slot = bone_bag(action).slot
        first, last = (round(f) for f in action.frame_range)
        recorded[action.name] = {}
        for frame in range(first, last + 1):
            scene.frame_set(frame)
            recorded[action.name][frame] = {b.name: (rig.matrix_world @ b.matrix).copy() for b in tops}
    rig.animation_data.action = None

# Out of any parent empty, keeping the world placement, then scaled and turned to face -Y,
# all applied so the rig's own transform is identity (the exporter resets it).
for obj in [rig] + skinned:
    obj.parent = None if obj is rig else rig
for obj in list(bpy.data.objects):
    if obj.type == 'EMPTY':
        bpy.data.objects.remove(obj)
for obj in [rig] + skinned:
    obj.matrix_world = worlds[obj.name]
body = max(skinned, key=lambda o: len(o.data.vertices))
bpy.ops.object.select_all(action='DESELECT')
for obj in skinned:
    obj.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.join()
body.name = PAL
for modifier in body.modifiers:
    if modifier.type == 'ARMATURE':
        modifier.object = rig

if moving:
    for bone in tops:
        bone.rotation_mode = 'QUATERNION'
    for action in moving:
        bag = bone_bag(action)
        for curve in [c for c in bag.fcurves if not c.data_path.startswith('pose.bones')
                      or any(c.data_path.startswith(f'pose.bones["{b.name}"].{p}') for b in tops for p in ('location', 'rotation'))]:
            bag.fcurves.remove(curve)
    for action in moving:
        rig.animation_data.action = action
        rig.animation_data.action_slot = bone_bag(action).slot
        for frame, placed in recorded[action.name].items():
            scene.frame_set(frame)
            for bone in tops:
                bone.matrix = rig.matrix_world.inverted() @ placed[bone.name]
                bone.keyframe_insert('location', frame=frame)
                bone.keyframe_insert('rotation_quaternion', frame=frame)
    rig.animation_data.action = None
    for bone in rig.pose.bones:
        bone.matrix_basis.identity()
    print(f'{len(moving)} animations moved the armature object: baked onto its top bones')

rig.scale *= SPEC.get('scale', 1.0)
rig.rotation_mode = 'XYZ'  # glTF objects turn by quaternion; the facing turn below is an Euler one
rig.rotation_euler.z += math.radians(FACING[SPEC.get('forward', '-Y')])
bpy.ops.object.select_all(action='DESELECT')
rig.select_set(True)
body.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)

# Bone names: drop a prefix every bone shares, up to an underscore (assimp adds the rig's name),
# then the configured renames, notably to the pipeline's root (the bone that carries the body
# across the floor) and pelvis. In the rig, the vertex groups and every animation's channels.
renames = {}
names = [b.name for b in rig.data.bones]
prefix = os.path.commonprefix(names)
prefix = prefix[:prefix.rfind('_') + 1]
if prefix and len(names) > 1:
    renames = {name: name[len(prefix):] for name in names}
for old, new in SPEC.get('bones', {}).items():
    renames[next((k for k, v in renames.items() if v == old), old)] = new
for old, new in renames.items():
    if old in rig.data.bones:
        rig.data.bones[old].name = new
    if old in body.vertex_groups:
        body.vertex_groups[old].name = new
for action in bpy.data.actions:
    for bag in channelbags(action):
        for curve in bag.fcurves:
            match = re.match(r'pose\.bones\["(.+?)"\]', curve.data_path)
            if match and match.group(1) in renames:
                curve.data_path = curve.data_path.replace(f'["{match.group(1)}"]', f'["{renames[match.group(1)]}"]')
        for group in bag.groups:
            group.name = renames.get(group.name, group.name)
rig.name = f'{PAL}_Rig'
rig.data.name = f'SK_{PAL}'  # the USD skeleton's name, which the pack's skeletonNode points to
rig.show_in_front = False
assert 'root' in rig.data.bones, ('no bone named root: name the one that carries the body across '
                                  'the floor (often the hips) in "bones", e.g. {"Hips": "root"}')

# Textures the model points to but didn't bring (FBX files usually reference theirs, and
# assimp drops COLLADA's): found by name in the "textures" folder or beside the model.
# Clear pixels cut out, and both faces drawn.
search = [FOLDER / SPEC['textures']] if 'textures' in SPEC else []
search.append((FOLDER / SPEC['model']).parent)


def find_texture(image):
    stem = Path(bpy.path.basename(image.filepath) or image.name).stem if image else ''
    for folder in search:
        for pattern in ([f'{stem}.*', f'{stem}*.png'] if stem else ['*.png']):
            found = next((p for p in folder.glob(pattern) if p.suffix.lower() in ('.png', '.jpg', '.jpeg', '.tga')), None)
            if found:
                return found
    return None


for material in bpy.data.materials:
    if not material.node_tree:
        continue
    shader = material.node_tree.nodes.get('Principled BSDF')
    for node in list(material.node_tree.nodes):
        if node.type != 'TEX_IMAGE':
            continue
        if not node.image or not node.image.has_data:
            found = find_texture(node.image)
            if found:
                node.image = bpy.data.images.load(str(found), check_existing=True)
            elif node.image:
                # Left out, so the part shows its plain colour rather than breaking the export.
                print(f'WARNING texture {node.image.name} not found (put it beside the model or in "textures")')
                material.node_tree.nodes.remove(node)
                continue
        if node.image:
            node.image.pack()
        if shader and not shader.inputs['Alpha'].links:
            material.node_tree.links.new(node.outputs['Alpha'], shader.inputs['Alpha'])
    material.surface_render_method = 'DITHERED'
    material.use_backface_culling = False


def bake_to_texture(mesh, size=1024):
    """Vertex colours (and several materials) the app's USD import doesn't see: bake the
    colour onto a fresh UV layout as one RGBA texture, alpha keeping cut-outs, and give the
    mesh a single matte material using it."""
    scene.render.engine = 'CYCLES'
    scene.cycles.samples = 1
    bpy.ops.object.select_all(action='DESELECT')
    mesh.select_set(True)
    bpy.context.view_layer.objects.active = mesh
    source_uv = mesh.data.uv_layers.active.name if mesh.data.uv_layers else None
    baked_uv = mesh.data.uv_layers.new(name='Baked')
    mesh.data.uv_layers.active = baked_uv
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.02)
    bpy.ops.object.mode_set(mode='OBJECT')
    images = {}
    for channel in ('Color', 'Alpha'):
        image = bpy.data.images.new(f'{PAL}_{channel}', size, size, alpha=False)
        image.colorspace_settings.name = 'sRGB' if channel == 'Color' else 'Non-Color'
        images[channel] = image
        for slot in mesh.material_slots:
            nt = slot.material.node_tree
            shader = nt.nodes['Principled BSDF']
            emit = nt.nodes.new('ShaderNodeEmission')
            out = next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL')
            source = shader.inputs['Base Color' if channel == 'Color' else 'Alpha']
            if source.links:
                nt.links.new(source.links[0].from_socket, emit.inputs['Color'])
            else:
                value = source.default_value
                emit.inputs['Color'].default_value = (value, value, value, 1) if channel == 'Alpha' else tuple(value)
            nt.links.new(emit.outputs['Emission'], out.inputs['Surface'])
            # The original UVs feed the textures; the bake writes into the new layout.
            for node in nt.nodes:
                if node.type == 'TEX_IMAGE' and node.image is not image and source_uv:
                    uv = nt.nodes.new('ShaderNodeUVMap')
                    uv.uv_map = source_uv
                    nt.links.new(uv.outputs['UV'], node.inputs['Vector'])
            target = nt.nodes.new('ShaderNodeTexImage')
            target.image = image
            nt.nodes.active = target
        bpy.ops.object.bake(type='EMIT', margin=24, use_clear=True)
        for slot in mesh.material_slots:
            nt = slot.material.node_tree
            for node in [n for n in nt.nodes if n.type in ('EMISSION', 'UV_MAP') or (n.type == 'TEX_IMAGE' and n.image in images.values())]:
                nt.nodes.remove(node)
            nt.links.new(nt.nodes['Principled BSDF'].outputs['BSDF'],
                         next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL').inputs['Surface'])
    rgba = bpy.data.images.new(f'{PAL}_Base_B', size, size, alpha=True)
    pixels = list(images['Color'].pixels)
    pixels[3::4] = list(images['Alpha'].pixels)[0::4]
    rgba.pixels = pixels
    rgba.filepath_raw = str(DEST / f'{PAL}_Base_B.png')
    rgba.file_format = 'PNG'
    rgba.save()
    rgba.pack()
    for image in images.values():
        bpy.data.images.remove(image)
    if source_uv:
        mesh.data.uv_layers.remove(mesh.data.uv_layers[source_uv])
    mesh.data.uv_layers.active = mesh.data.uv_layers['Baked']
    mesh.data.uv_layers['Baked'].active_render = True
    material = bpy.data.materials.new(f'{PAL}_Baked')
    material.use_nodes = True
    nt = material.node_tree
    shader = nt.nodes['Principled BSDF']
    # Matte: any reflection of the app's grey surroundings lifts dark colours to grey.
    shader.inputs['Roughness'].default_value = 1.0
    shader.inputs['Specular IOR Level'].default_value = 0.0
    shader.inputs['IOR'].default_value = 1.0
    texture = nt.nodes.new('ShaderNodeTexImage')
    texture.name = 'Original base colour'
    texture.image = rgba
    nt.links.new(texture.outputs['Color'], shader.inputs['Base Color'])
    mask = nt.nodes.new('ShaderNodeMath')
    mask.operation = 'GREATER_THAN'
    mask.inputs[1].default_value = 0.5
    nt.links.new(texture.outputs['Alpha'], mask.inputs[0])
    nt.links.new(mask.outputs[0], shader.inputs['Alpha'])
    material.surface_render_method = 'DITHERED'
    material.use_backface_culling = False
    mesh.data.materials.clear()
    mesh.data.materials.append(material)
    print(f'baked colours into {rgba.filepath_raw}')


# Vertex colour grading, for rips whose colour lives in the vertices (PS1 models):
# "linearVertexColours" takes colours stored one sRGB step too bright back down;
# "darkenGreys": [below, saturation, factor] darkens the neutral greys darker than `below`.
grade = SPEC.get('darkenGreys')
if SPEC.get('linearVertexColours') or grade:
    for attribute in body.data.color_attributes:
        for item in attribute.data:
            rgb = list(item.color_srgb[:3])
            if SPEC.get('linearVertexColours'):
                rgb = [(c / 12.92) if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
            if grade and max(rgb) < grade[0] and (max(rgb) - min(rgb)) <= grade[1] * max(max(rgb), 1e-6):
                rgb = [c * grade[2] for c in rgb]
            item.color_srgb = rgb + [item.color_srgb[3]]
if SPEC.get('bakeTexture'):
    bake_to_texture(body)

# Animations: "Armature|Walk" -> SRC_<Pal>_Walk, first key on frame 1. An animation can carry
# a slot per object it moved (the armature's parent empty too): only the one that moves bones
# is kept, without object-level channels, so every later step sees one slot.
for action in bpy.data.actions:
    bags = list(channelbags(action))
    if not bags:
        continue
    bones = max(bags, key=lambda b: sum(c.data_path.startswith('pose.bones') for c in b.fcurves))
    for curve in [c for c in bones.fcurves if not c.data_path.startswith('pose.bones')]:
        bones.fcurves.remove(curve)
    for slot in [s for s in action.slots if s != bones.slot]:
        action.slots.remove(slot)
sources = []
for action in sorted(bpy.data.actions, key=lambda a: a.name):
    name = re.sub(r'\W+', '_', action.name.rsplit('|', 1)[-1]).strip('_')
    first = action.frame_range[0]
    for bag in channelbags(action):
        for curve in bag.fcurves:
            for key in curve.keyframe_points:
                for point in (key.co, key.handle_left, key.handle_right):
                    point.x += 1 - first
            curve.update()
    action.name = f'SRC_{PAL}_{name}'
    action.use_fake_user = True
    action['source_duration_seconds'] = round((action.frame_range[1] - 1) / FPS, 4)
    sources.append(action)

rig.animation_data_create()


def activate(action):
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    for bone in rig.pose.bones:
        bone.matrix_basis.identity()
    scene.frame_start, scene.frame_end = 1, max(2, math.ceil(action.frame_range[1]))
    scene.frame_set(1)


# Where each animation carries the body, to help pick clips and which ones play in place.
hips = rig.pose.bones['root']
for action in sources:
    activate(action)
    start = rig.matrix_world @ hips.head
    travel = lift = 0.0
    for frame in range(1, scene.frame_end + 1):
        scene.frame_set(frame)
        here = rig.matrix_world @ hips.head
        travel, lift = max(travel, (here - start).xy.length), max(lift, here.z - start.z)
    print(f'ANIM {action.name.removeprefix(f"SRC_{PAL}_")}: {action["source_duration_seconds"]:.2f} s; '
          f'root travels up to {travel:.2f} m, rises up to {lift:.2f} m')

if sources:
    activate(sources[0])
bpy.context.view_layer.update()
coords = [body.matrix_world @ Vector(c) for c in body.bound_box]
low = Vector([min(c[i] for c in coords) for i in range(3)])
high = Vector([max(c[i] for c in coords) for i in range(3)])
center, height = (low + high) / 2, high.z - low.z


def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat('-Z', 'Y').to_euler()


camera = bpy.data.objects.new('Inspection Camera', bpy.data.cameras.new('Inspection Camera'))
scene.collection.objects.link(camera)
camera.location = center + Vector((height * 3.5, -height * 4.5, height * 0.35))
aim(camera, center)
camera.data.type = 'ORTHO'
camera.data.ortho_scale = height * 1.6
scene.camera = camera
for name, relative, power in [('Key', (2, -3, 4), 400), ('Fill', (2, 3, 2), 240), ('Rim', (-3, 0, 3), 360)]:
    light = bpy.data.objects.new(name, bpy.data.lights.new(name, 'AREA'))
    light.data.energy, light.data.shape, light.data.size = power, 'DISK', 3
    scene.collection.objects.link(light)
    light.location = center + Vector(relative) * max(height, 0.5)
    aim(light, center)
text = bpy.data.texts.new(f'{PAL} — start here.py')
text.write(f'''# Run once, then call bpy.app.driver_namespace["select_action"]("Walk") in the Python Console
# to scrub through an imported animation (SRC_{PAL}_...) or a composed clip (AS_{PAL}_...).
import bpy, math
def select_action(short_name):
    actions = bpy.data.actions
    action = actions.get(short_name) or actions.get("AS_{PAL}_" + short_name) or actions["SRC_{PAL}_" + short_name]
    rig = bpy.data.objects["{PAL}_Rig"]
    for bone in rig.pose.bones: bone.matrix_basis.identity()
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = max(2, math.ceil(action.frame_range[1]))
    bpy.context.scene.frame_set(1)
    return action.name
bpy.app.driver_namespace["select_action"] = select_action
''')
bpy.ops.wm.save_as_mainfile(filepath=str(DEST / f'{PAL}.blend'))
print('IMPORT_OK', DEST / f'{PAL}.blend', f'{len(rig.data.bones)} bones, {len(body.data.vertices)} vertices, '
      f'{len(sources)} animations, {height:.2f} m tall')
