"""Export the realtime desktop-pet assets: one skinned base model plus one
armature-only animated USDZ per action, and a clips.json catalog.

  Blender --background work/<pal>/blender/<Pal>.blend --python-exit-code 1 \
      --python pipeline/export_realtime.py -- --pal <Pal> [--anims <Base>]

Reads work/<pal>/clip-config.json (sources/palworld/make_pal_config.py) and writes the pack to
work/<pal>/realtime/.
"""
import bpy
import json
import sys
import math
import re
import shutil
import tempfile
from pathlib import Path
from mathutils import Vector
from bpy_extras import anim_utils

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'pipeline'))
import pack_limits  # noqa: E402
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
PAL = ARGS[ARGS.index('--pal') + 1]
BASE = ROOT / 'work' / PAL.lower()
DEST = BASE / 'realtime'
CLIPS = DEST / 'clips'
CLIPS.mkdir(parents=True, exist_ok=True)
CONFIG = json.loads((BASE / 'clip-config.json').read_text())
# Variants use their base pal's animations (AS_<base>_...), e.g. `--anims CatMage`.
ANIMS = ARGS[ARGS.index('--anims') + 1] if '--anims' in ARGS else CONFIG.get('animSet', PAL)
PREFIX = f'AS_{ANIMS}_'
FPS = 30
BOUNDS_STEP = 3
# Pets are drawn a few hundred points tall, so 2048 px game textures are wasted
# memory; at 1024 they take a quarter of the graphics memory and look the same.
MAX_TEXTURE = 1024

scene = bpy.context.scene
scene.render.fps = FPS
RIG_NAME = f'{PAL}_Rig'
rig = bpy.data.objects[RIG_NAME]
mesh = bpy.data.objects[PAL]
rig.location = (0, 0, 0)
rig.rotation_euler = (0, 0, 0)

USD = dict(selected_objects_only=True, export_armatures=True, only_deform_bones=False,
           convert_orientation=True, export_global_forward_selection='NEGATIVE_Z',
           export_global_up_selection='Y', export_lights=False, export_cameras=False,
           export_custom_properties=False)


def to_scenekit(v):
    # Blender Z-up, character facing -Y  ->  SceneKit Y-up, character facing +Z.
    return Vector((v.x, v.z, -v.y))


def select(*names):
    for obj in bpy.data.objects:
        obj.select_set(obj.name in names)
    bpy.context.view_layer.objects.active = rig


def use_action(action):
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]


def last_frame(action):
    return math.ceil(action.frame_range[1] - 1e-4)


def strip_planar_root(action):
    """Return (copy without root X/Y travel, travel samples in SceneKit metres)."""
    use_action(action)
    root = rig.pose.bones['root']
    samples = []
    for frame in range(1, last_frame(action) + 1):
        scene.frame_set(frame)
        samples.append(to_scenekit(root.head.copy()))
    origin = samples[0]
    travel = [[round(s.x - origin.x, 4), round(s.z - origin.z, 4)] for s in samples]
    stripped = action.copy()
    stripped.name = action.name + '_InPlace'
    bag = anim_utils.action_get_channelbag_for_slot(stripped, stripped.slots[0])
    # The root bone's rest matrix is identity, so its location channels are armature X/Y.
    for fcurve in bag.fcurves:
        if fcurve.data_path == 'pose.bones["root"].location' and fcurve.array_index in (0, 1):
            first = fcurve.evaluate(1)
            for key in fcurve.keyframe_points:
                key.co.y = first
                key.handle_left.y = first
                key.handle_right.y = first
            fcurve.update()
    return stripped, travel


def limit_pelvis_lift(action, cap):
    """Scale the pelvis's rise above its standing height so the peak is at most `cap` metres.
    Bakes pelvis location on every frame of `action` (which must be a disposable copy)."""
    use_action(action)
    pelvis = rig.pose.bones['pelvis']
    standing = rig.data.bones['pelvis'].head_local.z
    frames = range(1, last_frame(action) + 1)
    heights = []
    for frame in frames:
        scene.frame_set(frame)
        heights.append(pelvis.head.z)
    peak = max(h - standing for h in heights)
    if peak <= cap:
        return 1.0
    factor = cap / peak

    def lowered(matrix, frame):
        height = heights[frame - 1]
        if height > standing:
            matrix.translation.z = standing + (height - standing) * factor
    bake_pelvis(action, frames, lowered)
    return factor


def bake_pelvis(action, frames, adjust):
    """Re-key the pelvis location on every frame after `adjust(matrix, frame)` edits
    its armature-space matrix. `action` must be the active, disposable copy."""
    pelvis = rig.pose.bones['pelvis']
    baked = []
    for frame in frames:
        scene.frame_set(frame)
        matrix = pelvis.matrix.copy()
        adjust(matrix, frame)
        pelvis.matrix = matrix
        bpy.context.view_layer.update()
        baked.append(pelvis.location.copy())
    bag = anim_utils.action_get_channelbag_for_slot(action, action.slots[0])
    path = 'pose.bones["pelvis"].location'
    for fcurve in [f for f in bag.fcurves if f.data_path == path]:
        bag.fcurves.remove(fcurve)
    for axis in range(3):
        fcurve = bag.fcurves.new(path, index=axis)
        fcurve.group = bag.groups.get('pelvis') or bag.groups.new('pelvis')
        for frame, location in zip(frames, baked):
            fcurve.keyframe_points.insert(frame, location[axis], options={'FAST'})
        fcurve.update()


def pelvis_track(action):
    """World pelvis position on each frame, and the frames."""
    use_action(action)
    pelvis = rig.pose.bones['pelvis']
    frames = range(1, last_frame(action) + 1)
    track = []
    for frame in frames:
        scene.frame_set(frame)
        track.append(rig.matrix_world @ pelvis.head)
    return frames, track


def squash_motion(action, frames, track, reference, factors):
    """Scale the body's travel away from `reference` (the idle pelvis): rises by
    factors['up'], drops by factors['down'], sideways by factors['side']. The root's
    own travel is scaled the same way, so bones that hang off it follow. The pose
    and timing are unchanged. `action` must be a disposable copy."""
    def scaled(offset, axis):
        if axis < 2:
            return offset * factors['side']
        return offset * (factors['up'] if offset > 0 else factors['down'])

    bag = anim_utils.action_get_channelbag_for_slot(action, action.slots[0])
    # Each root location channel moves along its rest axis: armature X/Y/Z for Palworld
    # roots (identity rest), turned for rigs whose root rest is turned.
    rest = rig.data.bones['root'].matrix_local.to_3x3()
    for fcurve in bag.fcurves:
        if fcurve.data_path == 'pose.bones["root"].location':
            direction = rest.col[fcurve.array_index]
            for key in fcurve.keyframe_points:
                for point in (key.co, key.handle_left, key.handle_right):
                    if abs(direction.z) < 0.5:
                        point.y *= factors['side']
                    else:
                        point.y *= factors['up'] if point.y * direction.z > 0 else factors['down']
            fcurve.update()
    use_action(action)
    to_armature = rig.matrix_world.inverted()

    def moved(matrix, frame):
        offset = track[frame - 1] - reference
        target = reference + Vector([scaled(offset[axis], axis) for axis in range(3)])
        matrix.translation = to_armature @ target
    bake_pelvis(action, frames, moved)


def fit_to_limits(name, source, limit, reference):
    """Squash a clip's body motion until its bounds fit `limit`, or there is no
    motion left to squash (whatever still exceeds comes from the pose and is kept).
    Returns (action, bounds, factors or None); a returned action other than
    `source` is a new copy the caller must remove."""
    bounds = measure_bounds(source)
    if not pack_limits.needs_fit(bounds, limit) or 'pelvis' not in rig.pose.bones:
        return source, bounds, None
    original = bounds
    frames, track = pelvis_track(source)
    reach = {'up': max(max(p.z - reference.z for p in track), 0.0),
             'down': max(max(reference.z - p.z for p in track), 0.0),
             'side': max(math.hypot(p.x - reference.x, p.y - reference.y) for p in track)}
    factors = {'up': 1.0, 'down': 1.0, 'side': 1.0}
    fitted = None
    for _ in range(4):
        excess = {'up': bounds['max'][1] - limit['top'],
                  'down': limit['bottom'] - bounds['min'][1],
                  'side': bounds['horizontalRadius'] - limit['radius']}
        changed = False
        for key in factors:
            # A rise or sweep within the fit margin was a pose from the start; leave it.
            within_margin = key != 'down' and (
                original['max'][1] <= limit['top'] * pack_limits.FIT_MARGIN if key == 'up'
                else original['horizontalRadius'] <= limit['radius'] * pack_limits.FIT_MARGIN)
            if excess[key] > 0 and reach[key] > 1e-3 and factors[key] > 0 and not within_margin:
                # Bounds follow a body translation one-for-one, so remove the excess from the reach.
                factors[key] = max(0.0, (reach[key] * factors[key] - excess[key]) / reach[key])
                changed = True
        if not changed:
            break
        if fitted:
            bpy.data.actions.remove(fitted)
        fitted = source.copy()
        fitted.name = source.name + '_Fit'
        squash_motion(fitted, frames, track, reference, factors)
        bounds = measure_bounds(fitted)
        if not pack_limits.violations(bounds, limit):
            break
    # If squashing a rise or sweep removed less than half of its excess, the pose is
    # what's big (rearing up, spread wings), not the travel: leave that motion alone.
    # Sinking keeps its squash; the floor lift below finishes the job.
    def excess(b, key):
        return b['max'][1] - limit['top'] if key == 'up' else b['horizontalRadius'] - limit['radius']
    unfixable = [key for key in ('up', 'side') if factors[key] < 1 and excess(bounds, key) > 0
                 and excess(bounds, key) > 0.5 * excess(original, key)]
    if unfixable:
        for key in unfixable:
            factors[key] = 1.0
        bpy.data.actions.remove(fitted)
        fitted = None
        if factors['down'] < 1:
            fitted = source.copy()
            fitted.name = source.name + '_Fit'
            squash_motion(fitted, frames, track, reference, factors)
            bounds = measure_bounds(fitted)
        else:
            bounds = measure_bounds(source)
    lifted = 0.0
    if bounds['min'][1] < limit['bottom']:
        # The pose itself dips below the floor (a long body pitching nose-down):
        # raise the body on just those frames, so the dive bobs at floor level.
        if not fitted:
            fitted = source.copy()
            fitted.name = source.name + '_Fit'
        # Aim just inside the limit so measuring every third frame can't read it as over.
        lifted = lift_above(fitted, limit['bottom'] * 0.98)
        bounds = measure_bounds(fitted)
    if not fitted:
        return source, bounds, None
    left = pack_limits.violations(bounds, limit)
    print(f"FIT {name}: up x{factors['up']:.2f}, down x{factors['down']:.2f}, sideways x{factors['side']:.2f}"
          + (f", lifted up to {lifted:.2f} m" if lifted else '')
          + (f" (pose still {', '.join(left)}; kept)" if left else ''))
    fit = {k: round(v, 4) for k, v in factors.items()}
    if lifted:
        fit['maxLift'] = round(lifted, 4)
    return fitted, bounds, fit


def lowest_points(action):
    """The mesh's lowest world height on every frame."""
    use_action(action)
    lows = []
    for frame in range(1, last_frame(action) + 1):
        scene.frame_set(frame)
        evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        world = evaluated.matrix_world
        lows.append(min((world @ v.co).z for v in evaluated.data.vertices))
    return lows


def lift_above(action, floor):
    """Raise the pelvis on each frame whose lowest point is below `floor` (world
    metres, negative), by exactly the shortfall. Returns the largest lift."""
    lows = lowest_points(action)
    lifts = [max(0.0, floor - low) for low in lows]
    if not any(lifts):
        return 0.0
    up = rig.matrix_world.inverted().to_3x3() @ Vector((0, 0, 1))
    use_action(action)

    def raised(matrix, frame):
        matrix.translation += up * lifts[frame - 1]
    bake_pelvis(action, range(1, last_frame(action) + 1), raised)
    return max(lifts)


def foot_bones():
    """The bones that touch the floor: config `feet`, else ball_l/ball_r, else the
    lowest bones at rest (which catches four-legged rigs)."""
    if CONFIG.get('feet'):
        return [rig.pose.bones[name] for name in CONFIG['feet']]
    if 'ball_l' in rig.pose.bones and 'ball_r' in rig.pose.bones:
        return [rig.pose.bones['ball_l'], rig.pose.bones['ball_r']]
    # Four-legged rigs: the lowest bone of each foot-like name (front hooves are
    # often `hand_*`), one per side and leg.
    named = [b for b in rig.data.bones
             if re.match(r'(ball|foot|hand|toe|hoof)(_\d+)?_[lr]$', b.name, re.IGNORECASE)]
    if named:
        lowest = {}
        for bone in named:
            key = (re.sub(r'(_\d+)?_[lr]$', '', bone.name.lower()), bone.name[-1].lower())
            if key not in lowest or bone.head_local.z < lowest[key].head_local.z:
                lowest[key] = bone
        return [rig.pose.bones[b.name] for b in lowest.values()]
    bones = sorted(rig.data.bones, key=lambda b: b.head_local.z)
    floor = bones[0].head_local.z
    low = [b for b in bones if b.head_local.z < floor + 0.08 and not b.children]
    return [rig.pose.bones[b.name] for b in (low or bones[:2])]


def planted_foot_speed(action):
    """Ground speed (m/s) an in-place locomotion clip implies: the median backward
    speed of whichever foot is lowest while it is near the floor."""
    use_action(action)
    feet = foot_bones()
    samples = []
    for frame in range(1, last_frame(action) + 1):
        scene.frame_set(frame)
        samples.append([foot.head.copy() for foot in feet])
    floor = min(min(p.z for p in pair) for pair in samples)
    speeds = []
    for now, after in zip(samples, samples[1:]):
        planted = min(range(len(feet)), key=lambda i: now[i].z)
        if now[planted].z < floor + 0.03:
            # The character faces -Y, so a planted foot slides toward +Y.
            speeds.append((after[planted].y - now[planted].y) * FPS)
    return round(sorted(speeds)[len(speeds) // 2], 3) if speeds else 0.0


def unzero_scales(action):
    """Props are hidden by scaling their bone to exactly zero (Dupin's hat), which the
    USD exporter can't decompose. Nudge those keys to a still-invisible 0.001. Safe
    because this script never saves the .blend."""
    bag = anim_utils.action_get_channelbag_for_slot(action, action.slots[0])
    for fcurve in bag.fcurves:
        if fcurve.data_path.endswith('.scale'):
            for key in fcurve.keyframe_points:
                if abs(key.co.y) < 1e-3:
                    key.co.y = key.handle_left.y = key.handle_right.y = math.copysign(1e-3, key.co.y or 1)
            fcurve.update()


def hold_scales(action):
    """Drops a clip's scale animation, leaving every bone at its first frame's scale. For clips
    listed in `staticScale`: SceneKit doesn't crossfade out of some clips with time-sampled
    scale (Sekhmet's Sprint): the pet snaps to the next clip instead."""
    bag = anim_utils.action_get_channelbag_for_slot(action, action.slots[0])
    for fcurve in bag.fcurves:
        if fcurve.data_path.endswith('.scale') and len(fcurve.keyframe_points) > 1:
            first = fcurve.keyframe_points[0].co.y
            for key in fcurve.keyframe_points:
                key.co.y = key.handle_left.y = key.handle_right.y = first
            fcurve.update()


def measure_bounds(action):
    use_action(action)
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    radius = 0.0
    frames = list(range(1, last_frame(action) + 1, BOUNDS_STEP)) + [last_frame(action)]
    for frame in frames:
        scene.frame_set(frame)
        evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        world = evaluated.matrix_world
        for vertex in evaluated.data.vertices:
            p = to_scenekit(world @ vertex.co)
            lo = Vector(map(min, lo, p))
            hi = Vector(map(max, hi, p))
            radius = max(radius, math.hypot(p.x, p.z))
    return {'min': [round(c, 4) for c in lo], 'max': [round(c, 4) for c in hi],
            'horizontalRadius': round(radius, 4)}


# Base model: skinned mesh, skeleton, materials and packed textures; no animation.
# The USD exporter copies each texture's file, so a scaled image is saved under its own
# name in a scratch folder and pointed at there (in memory; the .blend is never saved).
SCALED = Path(tempfile.mkdtemp(prefix='sekhpet-textures-'))
for image in bpy.data.images:
    width, height = image.size
    if image.source != 'FILE' or max(width, height) <= MAX_TEXTURE:
        continue
    factor = MAX_TEXTURE / max(width, height)
    image.scale(round(width * factor), round(height * factor))
    if image.packed_file:
        image.unpack(method='REMOVE')
    image.filepath_raw = str(SCALED / (Path(bpy.path.abspath(image.filepath)).stem + '.png'))
    image.file_format = 'PNG'
    image.save()
    print(f'texture {image.name}: {width}x{height} -> {image.size[0]}x{image.size[1]}')
rig.animation_data.action = None
for bone in rig.pose.bones:
    bone.matrix_basis.identity()
# SceneKit draws nothing of a skinned mesh exported with blend shapes (LeafMomonga's wing
# morphs, which the game drives from curve-only assets our clips don't carry anyway).
for obj in bpy.data.objects:
    if obj.type == 'MESH' and obj.data.shape_keys:
        print(f'WARNING: dropped shape keys from {obj.name}: '
              + ', '.join(k.name for k in obj.data.shape_keys.key_blocks[1:]))
        obj.shape_key_clear()
select(PAL, RIG_NAME)
bpy.ops.wm.usd_export(filepath=str(DEST / f'{PAL}.usdz'), export_animation=False,
                      export_materials=True, generate_preview_surface=True,
                      export_textures_mode='NEW', **USD)

# Limits for oversized clips, from the idle pose; the idle pelvis anchors the squash.
idle_action = bpy.data.actions[PREFIX + CONFIG['idleClip']]
LIMIT = pack_limits.limits(measure_bounds(idle_action))
REFERENCE = None
if 'pelvis' in rig.pose.bones:
    _, idle_track = pelvis_track(idle_action)
    REFERENCE = sum(idle_track, Vector()) / len(idle_track)

defaults = CONFIG['defaults']
grouped = {name for g in CONFIG['groups'].values() for name in g['start'] + [g['loop']] + g['end']}
clips = {}
for action in sorted(bpy.data.actions, key=lambda a: a.name):
    if not action.name.startswith(PREFIX) or action.name.endswith('_InPlace'):
        continue
    name = action.name[len(PREFIX):]
    settings = {**defaults, **CONFIG['clips'].get(name, {})}
    travel = None
    exported = action
    if name in CONFIG['stripRootMotion']:
        exported, travel = strip_planar_root(action)
    lift_factor = None
    if name in CONFIG['maxPelvisLift']:
        if exported is action:
            exported = action.copy()
            exported.name = action.name + '_InPlace'
        lift_factor = limit_pelvis_lift(exported, CONFIG['maxPelvisLift'][name])
    if re.search(r'(Start|Loop|End)$', name) and name not in grouped:
        print(f'WARNING: {name} looks like part of a start/loop/end group but is not in one')
    bounds = fit = None
    # Excluded clips never play (additive Hit, the Carrying flop), so they aren't fitted.
    if name != CONFIG['idleClip'] and name not in CONFIG['surprise']['exclude'] and REFERENCE is not None:
        fitted, bounds, fit = fit_to_limits(name, exported, LIMIT, REFERENCE)
        if fitted is not exported:
            if exported is not action:
                bpy.data.actions.remove(exported)
            exported = fitted

    unzero_scales(exported)
    if name in CONFIG.get('staticScale', []):
        if exported is action:
            exported = action.copy()
            exported.name = action.name + '_InPlace'
        hold_scales(exported)
    use_action(exported)
    scene.frame_start = 1
    scene.frame_end = last_frame(exported)
    select(RIG_NAME)
    bpy.ops.wm.usd_export(filepath=str(CLIPS / f'{name}.usdz'), export_animation=True,
                          export_meshes=False, export_materials=False, **USD)

    entry = {
        'file': f'clips/{name}.usdz',
        'duration': round(float(action['source_duration_seconds']), 4),
        'loop': settings['loop'],
        'facing': settings['facing'],
        'yawDegrees': settings.get('yawDegrees', CONFIG['directionalYawDegrees']),
        'fadeIn': settings['fadeIn'],
        'bounds': bounds or measure_bounds(exported),
    }
    if name in CONFIG['locomotion']:
        settings = CONFIG['locomotion'][name]
        speed = settings.get('speed')
        if speed is None:
            speed = planted_foot_speed(action)
            # Trust the stride (no foot sliding) unless it is implausible next to the
            # game's own speed for this gait, e.g. floaters and swimmers with no planted foot.
            game = settings.get('gameSpeed')
            if game and not 0.3 * game <= speed <= 2 * game:
                print(f'{name}: measured stride speed {speed} m/s rejected; using game speed {game}')
                speed = game
            elif not game and speed <= 0.05:
                # No game speed to fall back on: a gentle walk, about Sekhmet's pace for her size.
                fallback = round(0.75 * LIMIT['top'] / pack_limits.RISE, 3)
                print(f'WARNING {name}: measured stride speed {speed} m/s rejected and no game speed; using {fallback}')
                speed = fallback
        entry['groundSpeed'] = speed
    if lift_factor is not None:
        entry['pelvisLiftScale'] = round(lift_factor, 4)
    if fit:
        entry['motionFit'] = fit
    if travel:
        entry['rootTravel'] = {'end': travel[-1], 'samples': travel, 'fps': FPS,
                               'scale': CONFIG['rootTravelScale'].get(name, 0.0)}
    clips[name] = entry
    if exported is not action:
        bpy.data.actions.remove(exported)
    print(f'exported {name}: {entry["duration"]}s')

# Surprise pool: every clip except the idle clip (and its variants), input clips and excluded ones.
# Start/loop/end members are represented once, by their group.
inputs = CONFIG['input']
reserved = {CONFIG['idleClip'], inputs['doubleClick'], *CONFIG['surprise']['exclude'], *CONFIG.get('idleVariants', [])}
reserved |= {entry['clip'] for entry in inputs['singleClick']}
reserved |= set(CONFIG['locomotion'])  # reached through the wander behavior instead
for name in (inputs.get('dragGroup'), inputs.get('dropGroup')):
    if not name:
        continue
    group = CONFIG['groups'][name]
    reserved |= set(group['start'] + [group['loop']] + group['end'])
pool = [{'group': name} for name, group in CONFIG['groups'].items()
        if not reserved & set(group['start'] + [group['loop']] + group['end'])]
pool += [{'clip': name} for name in sorted(clips) if name not in reserved and name not in grouped]

catalog = {
    'name': PAL,
    'displayName': CONFIG.get('displayName', PAL),
    'paldeckNo': CONFIG.get('paldeckNo'),
    'meshScale': CONFIG.get('meshScale', 1.0),
    'lookBones': CONFIG.get('lookBones'),  # neck/head bones for cursor watching; None auto-detects
    'model': f'{PAL}.usdz',
    'skeletonNode': f'SK_{PAL}',
    'coordinateSystem': 'SceneKit metres, Y up, character faces +Z at yaw 0',
    'clips': clips,
    'groups': CONFIG['groups'],
    'idleClip': CONFIG['idleClip'],
    'idleVariants': CONFIG.get('idleVariants', []),  # played within the idle, not as surprises
    'surprise': {k: v for k, v in CONFIG['surprise'].items() if not k.startswith('_')},
    'surprisePool': pool,
    'locomotion': [{'clip': name, 'weight': v['weight'], 'maxSeconds': v.get('maxSeconds')}
                   for name, v in CONFIG['locomotion'].items()],
    'wander': {k: v for k, v in CONFIG['wander'].items() if not k.startswith('_')},
    'input': CONFIG['input'],
}
for group in CONFIG['groups'].values():
    for name in group['start'] + [group['loop']] + group['end']:
        assert name in clips, f'group member {name} missing'
(DEST / 'clips.json').write_text(json.dumps(catalog, indent=1))
shutil.rmtree(SCALED, ignore_errors=True)
print(f'wrote {len(clips)} clips to {DEST}')
