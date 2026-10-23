"""Import converted UEFormat assets into a self-contained Blender project."""
import bpy
import sys
import json
import math
from pathlib import Path
from mathutils import Vector
from bpy_extras import anim_utils

ROOT = Path(__file__).resolve().parents[1]
# Pal name from `-- --pal Name`; its files live in work/<pal>/.
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
PAL = ARGS[ARGS.index('--pal') + 1]
# Variants use their base pal's animations (AS_<base>_...), e.g. `--anims CatMage`.
ANIMS = ARGS[ARGS.index('--anims') + 1] if '--anims' in ARGS else PAL
BASE = ROOT / 'work' / PAL.lower()
CONVERTED = BASE / 'converted'
DEST = BASE / 'blender'
DEST.mkdir(parents=True, exist_ok=True)
sys.path.insert(0, str(ROOT / '.tools/UEFormat/plugins/blender'))
from io_scene_ueformat.importer.import_context import UEFormatImport
from io_scene_ueformat.options import UEModelOptions, UEAnimOptions

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = 'METRIC'
scene.render.fps = 30
model_path = next(CONVERTED.rglob(f'SK_{PAL}.uemodel'))
rig, model_dto = UEFormatImport(UEModelOptions(import_sockets=False)).import_file_with_dto(model_path)
rig.name = f'{PAL}_Rig'
meshes = [obj for obj in bpy.data.objects if obj.type == 'MESH']
assert rig.type == 'ARMATURE' and meshes
meshes[0].name = PAL
rig.show_in_front = False

# Original base textures, with alpha masking and DirectX normal conversion.
# The game's custom lighting, SSS, facial material curves and packed-mask shader
# are not assumed to be equivalent to Blender's Principled material.
texture_dir = model_path.parent
pngs = {path.stem: path for path in CONVERTED.rglob('*.png')}


def texture_path(name):
    return texture_dir / (name + '.png') if (texture_dir / (name + '.png')).exists() else pngs.get(name)


def referenced(definition, suffix):
    """The first texture the material references whose name ends with `suffix`."""
    textures = {k: v for k, v in (definition.get('Textures') or {}).items() if v}  # unset slots are null
    preferred = {'_B': ['Base Texture'], '_N': ['Normal', 'NormalTexture', 'Normal Texture']}.get(suffix, [])
    candidates = [textures[k] for k in preferred if k in textures] + list(textures.values())
    for texture in candidates:
        name = texture['ObjectName'].split("'")[1]
        if name.endswith(suffix) and texture_path(name):
            return name
    return None


material_report = []
for material in bpy.data.materials:
    definition_path = texture_dir / (material.name + '.json')
    if not definition_path.exists():
        definition_path = next(CONVERTED.rglob(material.name + '.json'), None)
    definition = json.loads(definition_path.read_text()) if definition_path else {}
    base_name = referenced(definition, '_B')
    if base_name is None:
        # Procedural materials (flames, glows) have no colour texture; their tint
        # lives in colour parameters. Approximate them as a flat, glowing colour.
        colours = [c for c in (definition.get('Colors') or {}).values() if c and c.get('Hex')]
        material.use_nodes = True
        shader = material.node_tree.nodes.get('Principled BSDF')
        if colours and shader:
            srgb = [tuple(int(c['Hex'][i:i + 2], 16) / 255 for i in (0, 2, 4)) for c in colours]
            mean = tuple(sum(c[i] for c in srgb) / len(srgb) for i in range(3))
            linear = tuple(((v + 0.055) / 1.055) ** 2.4 if v > 0.04045 else v / 12.92 for v in mean) + (1,)
            shader.inputs['Base Color'].default_value = linear
            shader.inputs['Emission Color'].default_value = linear
            shader.inputs['Emission Strength'].default_value = 1.0
            shader.inputs['Roughness'].default_value = 1.0
        material_report.append({'name': material.name, 'base_texture': None,
                                'flat_colour': '#' + ''.join(f'{round(v * 255):02X}' for v in mean) if colours and shader else None})
        continue
    material.use_nodes = True
    nodes = material.node_tree.nodes
    nodes.clear()
    output = nodes.new('ShaderNodeOutputMaterial')
    output.location = (640, 0)
    shader = nodes.new('ShaderNodeBsdfPrincipled')
    shader.location = (350, 0)
    shader.inputs['Roughness'].default_value = 0.65
    shader.inputs['Specular IOR Level'].default_value = 0.2
    texture = nodes.new('ShaderNodeTexImage')
    texture.name = 'Original base colour'
    texture.location = (-400, 180)
    texture.image = bpy.data.images.load(str(texture_path(base_name)), check_existing=True)
    links = material.node_tree.links
    links.new(texture.outputs['Color'], shader.inputs['Base Color'])
    mask = nodes.new('ShaderNodeMath')
    mask.operation = 'GREATER_THAN'
    mask.inputs[1].default_value = 0.3333
    mask.location = (100, -100)
    links.new(texture.outputs['Alpha'], mask.inputs[0])
    links.new(mask.outputs[0], shader.inputs['Alpha'])
    links.new(shader.outputs['BSDF'], output.inputs['Surface'])
    emissive_name = referenced(definition, '_EM')
    if emissive_name:
        # Glow maps (lava, crystals) drive emission; most pals have none.
        emissive = nodes.new('ShaderNodeTexImage')
        emissive.location = (-400, -620)
        emissive.image = bpy.data.images.load(str(texture_path(emissive_name)), check_existing=True)
        links.new(emissive.outputs['Color'], shader.inputs['Emission Color'])
        shader.inputs['Emission Strength'].default_value = 1.0
    normal_name = referenced(definition, '_N')
    if normal_name is None and ('Body' in material.name or 'Extra' in material.name) and texture_path(f'T_{PAL}_Body_N'):
        normal_name = f'T_{PAL}_Body_N'  # some pals' Extra material shares the body normal map
    if normal_name:
        normal = nodes.new('ShaderNodeTexImage')
        normal.location = (-700, -300)
        normal.image = bpy.data.images.load(str(texture_path(normal_name)), check_existing=True)
        normal.image.colorspace_settings.name = 'Non-Color'
        sep = nodes.new('ShaderNodeSeparateColor')
        sep.location = (-470, -300)
        invert_g = nodes.new('ShaderNodeMath')
        invert_g.operation = 'SUBTRACT'
        invert_g.inputs[0].default_value = 1
        invert_g.location = (-280, -420)
        combine = nodes.new('ShaderNodeCombineColor')
        combine.location = (-80, -300)
        normal_map = nodes.new('ShaderNodeNormalMap')
        normal_map.location = (140, -300)
        links.new(normal.outputs['Color'], sep.inputs['Color'])
        links.new(sep.outputs['Green'], invert_g.inputs[1])
        links.new(sep.outputs['Red'], combine.inputs['Red'])
        links.new(invert_g.outputs[0], combine.inputs['Green'])
        links.new(sep.outputs['Blue'], combine.inputs['Blue'])
        links.new(combine.outputs['Color'], normal_map.inputs['Color'])
        links.new(normal_map.outputs['Normal'], shader.inputs['Normal'])
    material.surface_render_method = 'DITHERED'
    material.use_backface_culling = False
    material['source_material_definition'] = material.name + '.json'
    material_report.append({'name': material.name, 'base_texture': base_name})

catalog = {item['name']: item for item in json.loads((CONVERTED / 'package-catalog.json').read_text())}
action_report = []
for path in sorted(CONVERTED.rglob('*.ueanim')):
    action, dto = UEFormatImport(UEAnimOptions(override_skeleton=rig)).import_file_with_dto(path)
    source_count = dto.metadata.num_frames
    seconds = catalog[action.name]['seconds']
    # UEFormat reports NumFrames / SequenceLength. The first and final keys
    # span NumFrames-1 intervals; use the source duration to avoid shortening it.
    source_fps = (source_count - 1) / seconds
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    for key in curve.keyframe_points:
                        key.co.x = 1 + key.co.x * 30 / source_fps
                        key.handle_left.x = key.co.x
                        key.handle_right.x = key.co.x
                    curve.update()
    action.use_fake_user = True
    action.asset_mark()
    action.asset_data.description = f"Palworld source animation; {seconds:.3f} seconds, normalized to a 30 fps Blender timeline."
    action['source_fps'] = source_fps
    action['ueformat_reported_fps'] = dto.metadata.frames_per_second
    action['source_frames'] = source_count
    action['source_duration_seconds'] = catalog[action.name]['seconds']
    action['source_additive_type'] = catalog[action.name].get('additive_type') or 'AAT_None'
    if action['source_additive_type'] != 'AAT_None':
        action['conversion_note'] = 'Additive reaction preview baked onto skeleton reference pose; game runtime blends this over the current pose.'
        action.asset_data.description = action['conversion_note']
    action['timeline_fps'] = 30
    unmatched = [track.name for track in dto.tracks if track.name not in rig.pose.bones]
    action_report.append({'name': action.name, 'source_fps': source_fps,
        'source_frames': source_count, 'seconds': catalog[action.name]['seconds'],
        'frame_range': list(action.frame_range), 'tracks': len(dto.tracks),
        'unmatched_tracks': unmatched, 'curves': [c.name for c in dto.curves],
        'source_additive_type': action['source_additive_type']})

# A few pals spell standard clip names differently (AS_NegativeKoala_idle);
# normalise them so later steps can rely on the usual names.
CANONICAL = ['Idle', 'Walk', 'Run', 'Trot', 'Sprint', 'Transport', 'Petting', 'Damage', 'Encount', 'Hit',
             'Carrying', 'Carrying_Start', 'SleepStart', 'SleepLoop', 'SleepEnd', 'JumpLoop', 'JumpEnd',
             'Rest01', 'Rest02', 'Rest03', 'Rest04', 'Idle_Swim', 'Walk_Swim', 'Run_Swim']
for action in list(bpy.data.actions):
    prefix = f'AS_{ANIMS}_'
    if not action.name.lower().startswith(prefix.lower()):
        continue
    short = action.name[len(prefix):]
    canonical = next((c for c in CANONICAL if c.lower() == short.lower()), None)
    if canonical and canonical != short and prefix + canonical not in bpy.data.actions:
        for entry in action_report:
            if entry['name'] == action.name:
                entry['name'] = prefix + canonical
        action.name = prefix + canonical

def activate(name):
    action = bpy.data.actions[name]
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    # Clear transforms of bones not keyed in a subsequent action.
    for bone in rig.pose.bones:
        bone.matrix_basis.identity()
    scene.frame_start = 1
    scene.frame_end = math.ceil(action.frame_range[1])
    scene.frame_set(1)

activate(f'AS_{ANIMS}_Idle')
bpy.context.view_layer.update()
mesh = meshes[0]
coords = [mesh.matrix_world @ Vector(c) for c in mesh.bound_box]
low = Vector([min(c[i] for c in coords) for i in range(3)])
high = Vector([max(c[i] for c in coords) for i in range(3)])
center = (low + high) / 2
height = high.z - low.z

def aim(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat('-Z', 'Y').to_euler()

camera_data = bpy.data.cameras.new('Inspection Camera')
camera = bpy.data.objects.new('Inspection Camera', camera_data)
scene.collection.objects.link(camera)
camera.location = center + Vector((height * 3.5, -height * 4.5, height * 0.35))
aim(camera, center)
camera_data.type = 'ORTHO'
camera_data.ortho_scale = height * 1.22
scene.camera = camera
for name, relative, power, size in [
    ('Key', (2, -3, 4), 800, 4), ('Fill', (2, 3, 2), 500, 3), ('Rim', (-3, 0, 3), 700, 3)
]:
    light_data = bpy.data.lights.new(name, 'AREA')
    light_data.energy = power
    light_data.shape = 'DISK'
    light_data.size = size
    light = bpy.data.objects.new(name, light_data)
    scene.collection.objects.link(light)
    light.location = center + Vector(relative)
    aim(light, center)
world = bpy.data.worlds.new('Inspection World')
world.use_nodes = True
world.node_tree.nodes['Background'].inputs[0].default_value = (0.12, 0.12, 0.12, 1)
world.node_tree.nodes['Background'].inputs[1].default_value = 0.6
scene.world = world
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 24
scene.render.resolution_x = 640
scene.render.resolution_y = 640
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.view_settings.view_transform = 'Standard'

# Keep a ready-to-use action selector inside the blend file.
text = bpy.data.texts.new(f'{PAL} — start here.py')
text.write('''# Run once, then call bpy.app.driver_namespace["select_action"]("Rest02") in the Python Console.
import bpy, math
def select_action(short_name):
    name = short_name if short_name.startswith("AS_PAL_") else "AS_PAL_" + short_name
    rig = bpy.data.objects["PAL_Rig"]
    action = bpy.data.actions[name]
    for bone in rig.pose.bones: bone.matrix_basis.identity()
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = math.ceil(action.frame_range[1])
    bpy.context.scene.frame_set(1)
    return action.name
bpy.app.driver_namespace["select_action"] = select_action
'''.replace('AS_PAL_', f'AS_{ANIMS}_').replace('PAL', PAL))

for obj in bpy.context.selected_objects:
    obj.select_set(False)
rig.select_set(True)
bpy.context.view_layer.objects.active = rig
for screen in bpy.data.screens:
    for area in screen.areas:
        if area.type == 'VIEW_3D':
            area.spaces.active.region_3d.view_perspective = 'CAMERA'
            area.spaces.active.shading.type = 'MATERIAL'
        elif area.type == 'DOPESHEET_EDITOR':
            area.spaces.active.mode = 'ACTION'
for path in texture_dir.glob('*.png'):
    image = bpy.data.images.load(str(path), check_existing=True)
    image.use_fake_user = True
for image in bpy.data.images:
    if image.source == 'FILE': image.pack()
report = {
    'bones': len(rig.data.bones), 'vertices': sum(len(m.data.vertices) for m in meshes),
    'triangles': sum(len(m.data.polygons) for m in meshes), 'materials': material_report,
    'bounds_metres': {'min': list(low), 'max': list(high)}, 'actions': action_report,
    'notes': 'Base colours, alpha masks and normal maps reconstructed; Unreal packed-mask lighting and facial material curves are not automatically reproduced.'
}
(DEST / 'blender-import-report.json').write_text(json.dumps(report, indent=2))
bpy.ops.wm.save_as_mainfile(filepath=str(DEST / f'{PAL}.blend'))
print('BLENDER_IMPORT_OK', json.dumps({k: report[k] for k in ['bones', 'vertices', 'triangles']}))

if '--preview' in sys.argv:
    for name in ['Idle', 'Rest01', 'Rest02', 'Rest03', 'Rest04']:
        if f'AS_{ANIMS}_{name}' not in bpy.data.actions:
            continue
        activate(f'AS_{ANIMS}_' + name)
        for fraction in [0.0, 0.25, 0.5, 0.75]:
            scene.frame_set(1 + round((scene.frame_end - 1) * fraction))
            scene.render.filepath = str(DEST / 'inspection' / f'{name}-{int(fraction*100):02d}.png')
            bpy.ops.render.render(write_still=True)
