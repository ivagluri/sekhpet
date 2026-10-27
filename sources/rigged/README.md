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
| `cloth_follow.py` | Optional: lets a skirt, dress or cape partly follow the thighs, so the legs don't poke through it (`clothFollow`, below). Cheap; for short skirts. |
| `cloth_drape.py` | Optional: for cloth with bone chains of its own (game physics bones): bakes them hanging under gravity and pushed out of the legs on every frame (`clothDrape`, below). For long dresses and capes. |
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
  "recenter": false,                 // optional: centre lopsided side-on clips (export runs twice)
  "clothFollow": {                   // optional: cloth whose bones no clip moves (game physics)
    "groups": ["*Skirt*"],           //   its vertex groups, by name pattern
    "legs": [["thigh_l", "calf_l"], ["thigh_r", "calf_r"]],  // each side's leg bones from the top
                                     //   (one thigh bone each does for a short skirt)
    "waist": 0.1, "hem": 0.95,       //   share of its weight moved to them at the top and the hem
    "curve": 0.5                     //   below 1 climbs early, so it hangs with the legs when bending
  },
  "clothDrape": {                    // optional, instead of clothFollow: cloth with bone chains
    "chains": ["*Skirt*_Phy"],       //   the chain bones, by name pattern
    "body": "spine_01",              //   the bone whose tilt the cloth makes up for (the one it hangs from)
    "hang": [0.5, 1.0],              //   how much of that tilt it undoes at the chain's top and end
    "colliders": [["thigh_l", "calf_l", 0.085], ["calf_l", "foot_l", 0.06]],  // capsules: bone to bone, radius
    "margin": 0.01
  }
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

Every clip not used as the idle, a gait or a click becomes a random surprise. Two choices matter more
than they look:
- **The drag loop** (`input.dragGroup`'s loop) plays for as long as the pet is held, so it must be a real
  loop of a second or more that reads as being held or falling. A short airborne pose from a hop or jump
  (under half a second) twitches when looped; a held emote (covering the face, flailing) works better.
- **Idle variants:** a game idle is often very still. List every standing idle and talk idle the
  character has as `idleVariants`, or the pet looks frozen between surprises.

Optional extras:
- `groups`: start, loop and end clips that play as one, like a take-off, a glide and a landing.
- `idleVariants`: clips the idle drifts into now and then.
- `submenus`: surprises the app's menus and Pet Viewer list together under a name (`{"Emotes": [...]}`), so the
  other actions stay easy to pick.
- `feet` and `lookBones`: bone names for measuring stride and for watching the cursor.
- `staticScale`: clips SceneKit won't crossfade out of (PIPELINE.md problem 17).
- `input.dragGroup` and `input.dropGroup`: what plays while the pet is dragged and when it's dropped.

[PET_PACKS.md](../../PET_PACKS.md) describes what each one does in the app.

Review `work/<name>/check-sheet.png` afterwards, as for any pet.
