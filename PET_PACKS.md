# Pet packs

A pet is one folder, its **pack**. The app loads every pack in `~/Library/Application Support/SekhPet/Pets/` (also reachable from the Pets window). `scripts/make_pet.sh` writes packs from Palworld, but any source that produces this format works.

```
kingwhale/
  KingWhale.usdz        the skinned model: mesh, skeleton, materials and textures; no animation
  clips/Idle.usdz       one file per animation: the skeleton only, animated
  clips/Walk.usdz
  ...
  clips.json            the catalog: every clip, plus the pet's behavior
  thumbnail.png         optional; shown in the Pets window (256 px works well)
```

To share one, zip the folder (or use **Export as Zip…** in the Pets window). **Add Pet…** accepts a zip with one pack in it, either the pack folder itself or its files at the top level.

## Conventions

- **Units and axes:** SceneKit metres, Y up, the character facing +Z at rest, feet at Y = 0. Every length in `clips.json` (bounds, speeds, distances) is in these model metres, before `meshScale`.
- **Model:** a skinned mesh with its skeleton under a node named by `skeletonNode`. Textures go inside the USDZ; 1024 px is plenty at desktop size.
- **Clips:** each clip USDZ holds the same skeleton (same node name), animated. The app takes the first animation it finds on that node and plays it on the model's skeleton, crossfading between clips.
- **In place:** clips shouldn't travel. The app moves the window for walking (`groundSpeed`) and for clips that cover ground (`rootTravel`), so strip that travel out of the animation itself.
- **Size:** keep every clip within the pet's normal footprint where you can. The window is sized to fit the biggest clip the pet can play, so one huge clip makes a huge (invisible, click-through) window.

## clips.json

```jsonc
{
  "name": "KingWhale",              // unique id; the pets folder uses it lowercased
  "displayName": "Panthalus",
  "paldeckNo": "203",               // the game's paldeck number, with a letter for variants (005B); the Pet Viewer sorts by it
  "meshScale": 0.0869,              // on-screen scale; standing height × meshScale = metres shown
  "model": "KingWhale.usdz",
  "skeletonNode": "SK_KingWhale",
  "lookBones": null,                // neck/head bones for cursor watching; null auto-detects neck_01/neck + head
  "idleClip": "Idle",
  "clips": {
    "Idle": {
      "file": "clips/Idle.usdz",
      "duration": 3.33,             // seconds
      "loop": true,                 // a seamless loop, or a one-shot
      "facing": "front",            // "front" faces the viewer; "directional" turns side-on
      "yawDegrees": 40,             // how far a directional clip turns (90 = full profile)
      "fadeIn": 0.35,               // crossfade into this clip, seconds
      "bounds": {"min": [-17.4, -0.07, -30.6], "max": [17.4, 27.6, 17.4], "horizontalRadius": 31.7},
      "groundSpeed": 30.0,          // locomotion only: model metres per second the stride covers
      "rootTravel": {               // optional: the authored path of a clip that covers ground
        "samples": [[0, 0], [0.1, 0.02]], "end": [1.4, 0.3], "fps": 30, "scale": 0.5
      }
    }
  },
  "groups": {                       // start/loop/end clips that always play as one unit
    "Sleep": {"start": ["SleepStart"], "loop": "SleepLoop", "end": ["SleepEnd"], "loopCount": [1, 2]}
  },
  "surprisePool": [{"clip": "Encount2"}, {"group": "Sleep"}],
  "surprise": {"intervalSeconds": [60, 180], "loopCount": [2, 4], "minSeconds": 6},
  "locomotion": [{"clip": "Walk", "weight": 5, "maxSeconds": null}, {"clip": "Run", "weight": 2, "maxSeconds": 4}],
  "wander": {"chance": 0.35, "seconds": [2.5, 6], "minDistanceMetres": 1.5, "depthChance": 0.5},
  "input": {
    "singleClick": [{"clip": "Petting", "weight": 87}, {"clip": "Damage", "weight": 13}],
    "doubleClick": "Encount",       // optional
    "dragGroup": "Jump",            // optional: the group's loop holds while dragged
    "dropGroup": "Jump"             // optional: letting go plays the group's end
  }
}
```

What the app does with it:

- **Idle** loops. Every `surprise.intervalSeconds` (a random time in the range; the menu can change it) one entry from `surprisePool` plays, then the pet returns to idle. Looping clips and group loops repeat `loopCount` times, and short surprises repeat until they last `minSeconds`.
- **Wandering** is a share (`wander.chance`) of surprises: a `locomotion` clip picked by `weight`, walked for `wander.seconds` at the clip's `groundSpeed`. `depthChance` is how often a trip also steps into or out of the screen.
- **Bounds** are the extent of the mesh over the whole clip, in model metres. The app sizes the window from them, and keeps a walking pet's body from crossing a screen edge using them.
- **Groups** never cut off mid-way: interrupting one plays its end clips first.
- Clip names are free-form. Only the names listed in this file matter.

Optional fields can be left out: `displayName` (defaults to `name`), `paldeckNo`, `meshScale` (1), `lookBones`, `rootTravel`, `groundSpeed`, `loopCount`, `maxSeconds`, and the `input` reactions. The pipeline also writes a few informational fields (`motionFit`, `pelvisLiftScale`, `coordinateSystem`) that the app ignores.
