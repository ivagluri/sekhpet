# Rigged characters

Turns a rigged 3D character with animations, as glTF/GLB or FBX, into a pet: one skinned
mesh, its clips, and optional rigid props such as a sword. For a model in another format,
convert it to glTF first: `assimp export model.dae model.glb` (`brew install assimp`) covers
COLLADA, OBJ, 3DS and more.

```sh
bash sources/rigged/make_rigged_pet.sh characters/<name>
```

Needs Blender 5 and Python 3 with Pillow. The script runs the steps below in order, each a
Blender script you can also run on its own, then `pipeline/finish.sh` (export, check, install):

| Step | Does |
|---|---|
| `import_model.py` | Imports the model and any extra animation files, joins the meshes, and applies scale and facing. Renames bones, retimes every animation onto 30 fps from frame 1, optionally bakes the colour into one texture, and saves `work/<name>/blender/<Name>.blend`. Prints how far each animation carries the body. |
| `compose.py` | Makes the pet's clips from the animations: renamed, joined, played in place. Stands the idle on the origin. |
| `props.py` | Attaches props on their own mount bones, shown only in the clips you choose. |
| `prune_bones.py` | Drops the bones no clip moves (face, cloth, helpers), so the clips load fast. |
| `recenter.py` | Optional: centres lopsided clips (lunges), which would otherwise widen the pet's window. |

## The character folder

```
characters/hero/
  character.json      what to import and how to make the clips
  clip-config.json    the pet's behaviour (see below)
  hero.glb            the model, with its animations
  anims/*.glb         optional: more animation files for the same skeleton
  sword.glb           optional: props
```

## character.json

```jsonc
{
  "pal": "Hero",                     // the pet's name (one word)
  "model": "hero.glb",               // glTF/GLB or FBX, relative to this folder
  "animations": ["anims/*.glb"],     // optional: more files whose animations are added
  "scale": 1.0,                      // optional: to metres (an FBX in centimetres: 0.01)
  "forward": "-Y",                   // optional: the way the character faces once imported
                                     //   (-Y, +Y, +X or -X in Blender); turned to face -Y
  "bones": {"Hips": "root"},         // optional renames. The pipeline needs a bone called root:
                                     //   the one that carries the body across the floor (often
                                     //   the hips). "pelvis" is optional.
  "textures": "textures",            // optional: where to look for textures the model doesn't
                                     //   carry (FBX usually doesn't); beside the model is searched too
  "bakeTexture": false,              // optional: bake vertex colours and several materials into one
                                     //   texture (models whose colour is in the vertices)
  "linearVertexColours": false,      // optional: vertex colours stored one sRGB step too bright
  "darkenGreys": [0.4, 0.12, 0.2],   // optional: darken neutral greys below 0.4 (saturation under
                                     //   0.12) by a factor of 0.2
  "clips": {                         // the pet's clips, from the animations' names (printed as ANIM
    "Idle": "idle",                  //   by the import): one animation,
    "Walk": "walk_cycle",
    "Dash": ["dash_start", "dash_loop", 3, "dash_end"]  // or several back to back; a number is
  },                                 //   frames to blend across a jump in the pose between two
  "inPlace": ["Walk", "Dash"],       // clips (or fnmatch patterns) that keep the body over one spot:
                                     //   gaits must, as the app moves the window for them
  "props": [                         // optional
    {"name": "SwordBack", "model": "sword.glb", "bone": "spine_03",
     "location": [0, 0.15, 0], "rotation": [0, 0, 180], "hideIn": ["Attack*"]},
    {"name": "SwordHand", "model": "sword.glb", "bone": "hand_r", "showIn": ["Attack*"]}
  ],
  "recenter": false                  // optional: centre lopsided side-on clips (export runs twice)
}
```

A prop's model goes on a new mount bone (named after it) that rides `bone`: `location` (metres)
and `rotation` (degrees) place it in that bone's space, and `scale` sizes it. `showIn` and
`hideIn` pick the clips it appears in; a prop with neither always shows. One sword can be on the
back in some clips and in the hand in others, as two props.

## clip-config.json

The pet's behaviour, in the format `pipeline/export_realtime.py` reads. The Palworld source
generates it; here you write it. A small one:

```json
{
  "displayName": "Hero",
  "animSet": "Hero",
  "meshScale": 1.0,
  "floats": false,
  "defaults": {"facing": "directional", "loop": false, "fadeIn": 0.3},
  "directionalYawDegrees": 40,
  "maxPelvisLift": {},
  "rootTravelScale": {},
  "stripRootMotion": [],
  "groups": {},
  "idleClip": "Idle",
  "clips": {"Idle": {"facing": "front", "loop": true}, "Walk": {"loop": true, "yawDegrees": 90}},
  "locomotion": {"Walk": {"weight": 1, "speed": 1.2, "maxSeconds": null}},
  "wander": {"chance": 0.35, "seconds": [2.5, 5], "minDistanceMetres": 1.5, "depthChance": 0.3},
  "surprise": {"intervalSeconds": [60, 180], "loopCount": [1, 2], "minSeconds": 3, "exclude": []},
  "input": {"singleClick": [{"clip": "Wave", "weight": 1}], "doubleClick": "Dash"}
}
```

Every clip not used as the idle, a gait or a click becomes a random surprise. Optional extras:
- `groups`: start, loop and end clips that play as one, like a take-off, a glide and a landing.
- `idleVariants`: clips the idle drifts into now and then.
- `feet` and `lookBones`: bone names for measuring stride and for watching the cursor.
- `staticScale`: clips SceneKit won't crossfade out of (PIPELINE.md problem 17).
- `input.dragGroup` and `input.dropGroup`: what plays while the pet is dragged and when it's dropped.

[PET_PACKS.md](../../PET_PACKS.md) describes what each one does in the app.

Review `work/<name>/check-sheet.png` afterwards, as for any pet.
