"""Centre lopsided clips on the pet, after a first export (sources/rigged/make_rigged_pet.sh runs it).

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/recenter.py -- work/<pal>/realtime/clips.json

The window fits the widest reach around the pet's centre, so one forward lunge would size it for
every clip. Each side-on clip whose reach across the floor is off centre by more than 10 cm
(from the bounds the export measured) has its root shifted back over the middle. Idle,
front-facing clips and gaits are left alone. Export again afterwards.
"""
import bpy
import json
import math
import sys

RECENTER_MIN = 0.1  # metres off centre before a clip is shifted
pack = json.loads(open(sys.argv[sys.argv.index('--') + 1]).read())
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')

# The root's location channels lying along the floor, with the SceneKit axis each moves along
# (+1/-1 for x, +2/-2 for z): a turned root rest (UE skeletons) puts them on other channels.
rest = rig.data.bones['root'].matrix_local.to_3x3()
channels = {}
for i in range(3):
    axis = rest.col[i]
    if abs(axis.z) < 0.5:
        # Blender X is SceneKit x; Blender -Y (the way the pet faces) is SceneKit z.
        channels[i] = (1 if axis.x > 0 else -1) if abs(axis.x) > abs(axis.y) else (2 if axis.y < 0 else -2)

gaits = {entry['clip'] for entry in pack['locomotion']}
for name, clip in pack['clips'].items():
    if clip['facing'] != 'directional' or name in gaits or name == pack['idleClip']:
        continue
    low, high = clip['bounds']['min'], clip['bounds']['max']
    centre = {1: (low[0] + high[0]) / 2, 2: (low[2] + high[2]) / 2}
    if math.hypot(centre[1], centre[2]) < RECENTER_MIN:
        continue
    action = bpy.data.actions[f'AS_{pack["name"]}_{name}']
    for layer in action.layers:
        for strip in layer.strips:
            for bag in strip.channelbags:
                for curve in bag.fcurves:
                    if curve.data_path == 'pose.bones["root"].location' and curve.array_index in channels:
                        axis = channels[curve.array_index]
                        shift = -centre[abs(axis)] * (1 if axis > 0 else -1)
                        for key in curve.keyframe_points:
                            for point in (key.co, key.handle_left, key.handle_right):
                                point.y += shift
                        curve.update()
    print(f'recentred {name}: x {-centre[1]:+.2f} m, z {-centre[2]:+.2f} m')
bpy.ops.wm.save_mainfile()
print('RECENTER_OK')
