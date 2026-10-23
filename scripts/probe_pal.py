"""Measure a pal's imported clips for config generation (scripts/make_pal_config.py).

  Blender --background work/<pal>/blender/<Pal>.blend --python-exit-code 1 \
      --python scripts/probe_pal.py -- --pal <Pal> [--anims <Base>]

Writes work/<pal>/probe.json: per clip duration, root travel, pelvis lift
and additive type, plus the rig's standing pelvis height and idle extents.
"""
import bpy
import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
PAL = ARGS[ARGS.index('--pal') + 1]
ANIMS = ARGS[ARGS.index('--anims') + 1] if '--anims' in ARGS else PAL
BASE = ROOT / 'work' / PAL.lower()
PREFIX = f'AS_{ANIMS}_'

scene = bpy.context.scene
rig = bpy.data.objects[f'{PAL}_Rig']
mesh = bpy.data.objects[PAL]
bones = rig.pose.bones
root = bones.get('root')
pelvis = bones.get('pelvis')
standing = rig.data.bones['pelvis'].head_local.z if pelvis else None


def use(action):
    rig.animation_data.action = action
    rig.animation_data.action_slot = action.slots[0]
    for bone in bones:
        bone.matrix_basis.identity()


def vertical_extent(action, step=4):
    use(action)
    lo, hi = math.inf, -math.inf
    last = math.ceil(action.frame_range[1] - 1e-4)
    for frame in list(range(1, last + 1, step)) + [last]:
        scene.frame_set(frame)
        evaluated = mesh.evaluated_get(bpy.context.evaluated_depsgraph_get())
        zs = [(evaluated.matrix_world @ v.co).z for v in evaluated.data.vertices]
        lo, hi = min(lo, min(zs)), max(hi, max(zs))
    return lo, hi


clips = {}
for action in sorted(bpy.data.actions, key=lambda a: a.name):
    if not action.name.startswith(PREFIX):
        continue
    use(action)
    last = math.ceil(action.frame_range[1] - 1e-4)
    roots, lifts = [], []
    for frame in range(1, last + 1):
        scene.frame_set(frame)
        if root:
            roots.append(root.head.copy())
        if pelvis:
            lifts.append(pelvis.head.z - standing)
    end = (roots[-1] - roots[0]) if roots else None
    clips[action.name[len(PREFIX):]] = {
        'duration': round(float(action.get('source_duration_seconds', (last - 1) / 30)), 4),
        'additive': action.get('source_additive_type', 'AAT_None'),
        # Blender metres; the character faces -Y, so forward travel is negative y.
        'rootEnd': [round(end.x, 3), round(end.y, 3)] if end else [0, 0],
        'rootMax': round(max(((r - roots[0]).xy.length for r in roots), default=0), 3),
        'pelvisLift': round(max(lifts), 3) if lifts else 0,
    }

idle = bpy.data.actions.get(PREFIX + 'Idle')
low, high = vertical_extent(idle) if idle else (0, 0)
report = {
    'pal': PAL, 'anims': ANIMS,
    'bones': [b.name for b in rig.data.bones],
    'hasRoot': root is not None, 'hasPelvis': pelvis is not None,
    'standingPelvis': standing,
    'idleMinZ': round(low, 3), 'idleMaxZ': round(high, 3),
    'clips': clips,
}
(BASE / 'probe.json').write_text(json.dumps(report, indent=1))
print('PROBE_OK', PAL, len(clips), 'clips; idle height', round(high, 2))
