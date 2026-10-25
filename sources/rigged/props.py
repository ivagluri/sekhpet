"""Attach rigid props (a sword, a hat) to a rigged character, each shown only in chosen clips
(after sources/rigged/compose.py).

  Blender --background work/<pal>/blender/<Pal>.blend --python sources/rigged/props.py -- <character folder>

character.json's "props" lists them:

  "props": [
    {"name": "SwordBack", "model": "sword.glb", "bone": "spine_03",
     "location": [0, 0.15, 0], "rotation": [0, 0, 180], "hideIn": ["Attack*"]},
    {"name": "SwordHand", "model": "sword.glb", "bone": "hand_r", "showIn": ["Attack*"]}
  ]

The prop's model (glTF/GLB or FBX; all its meshes, at their origin) goes onto a new mount bone
named after it, a child of `bone` at its rest: `location` (metres) and `rotation` (degrees)
place it in that bone's space, `scale` sizes it. `showIn` / `hideIn` are clip names or fnmatch
patterns; a prop with neither always shows. A hidden prop's mount bone is scaled to a still
invisible 0.001 for the whole clip, so the bone it rides is untouched.
"""
import bpy
import json
import math
import sys
from fnmatch import fnmatch
from pathlib import Path
from mathutils import Euler, Matrix, Vector

FOLDER = Path(sys.argv[sys.argv.index('--') + 1]).resolve()
SPEC = json.loads((FOLDER / 'character.json').read_text())
rig = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
PAL = rig.name.removesuffix('_Rig')
body = bpy.data.objects[PAL]
clips = [a for a in bpy.data.actions if a.name.startswith(f'AS_{PAL}_')]

for prop in SPEC.get('props', []):
    path = FOLDER / prop['model']
    before = set(bpy.data.objects)
    if path.suffix.lower() in ('.glb', '.gltf'):
        bpy.ops.import_scene.gltf(filepath=str(path))
    else:
        bpy.ops.import_scene.fbx(filepath=str(path))
    added = [o for o in bpy.data.objects if o not in before]
    meshes = [o for o in added if o.type == 'MESH']
    for mesh in meshes:
        mesh.data.transform(mesh.matrix_world)  # into the prop file's own space, about its origin
        mesh.parent = None
        mesh.matrix_world = Matrix()
        mesh.vertex_groups.clear()
        mesh.modifiers.clear()
    for obj in added:
        if obj not in meshes:
            bpy.data.objects.remove(obj)

    # The mount bone: the target bone's rest, so the prop rides it exactly.
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode='EDIT')
    parent = rig.data.edit_bones[prop['bone']]
    mount = rig.data.edit_bones.new(prop['name'])
    mount.head, mount.tail, mount.roll = parent.head, parent.tail, parent.roll
    mount.parent = parent
    bpy.ops.object.mode_set(mode='OBJECT')
    place = (rig.matrix_world @ rig.data.bones[prop['name']].matrix_local
             @ Matrix.Translation(Vector(prop.get('location', (0, 0, 0))))
             @ Euler([math.radians(a) for a in prop.get('rotation', (0, 0, 0))]).to_matrix().to_4x4()
             @ Matrix.Scale(prop.get('scale', 1.0), 4))
    for mesh in meshes:
        mesh.data.transform(place)
        mesh.vertex_groups.new(name=prop['name']).add(range(len(mesh.data.vertices)), 1.0, 'REPLACE')
        for material in mesh.data.materials:
            if material:
                material.surface_render_method = 'DITHERED'
                material.use_backface_culling = False
                for node in material.node_tree.nodes if material.node_tree else []:
                    if node.type == 'TEX_IMAGE' and node.image:
                        node.image.pack()
    bpy.ops.object.select_all(action='DESELECT')
    for mesh in meshes:
        mesh.select_set(True)
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.join()

    # Shown or hidden per clip, constant across each.
    show, hide = prop.get('showIn'), prop.get('hideIn')
    if show is None and hide is None:
        print(f'PROP {prop["name"]}: on {prop["bone"]}, always shown')
        continue
    shown_in = []
    for action in clips:
        clip = action.name.removeprefix(f'AS_{PAL}_')
        shown = (show is None or any(fnmatch(clip, p) for p in show)) and not any(fnmatch(clip, p) for p in hide or [])
        if shown:
            shown_in.append(clip)
        bag = action.layers[0].strips[0].channelbags[0]
        first, last = action.frame_range
        path = f'pose.bones["{prop["name"]}"].scale'
        for axis in range(3):
            curve = bag.fcurves.find(path, index=axis) or bag.fcurves.new(path, index=axis, group_name=prop['name'])
            curve.keyframe_points.clear()
            for frame in (first, last):
                curve.keyframe_points.insert(frame, 1.0 if shown else 0.001)
            curve.update()
    print(f'PROP {prop["name"]}: on {prop["bone"]}, shown in {len(shown_in)} of {len(clips)} clips')
bpy.ops.wm.save_mainfile()
print('PROPS_OK')
