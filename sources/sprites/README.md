# Sprite pets

Turns a 2D character's sprite images into a pet: each pose is a flat paper cut-out card, so it
works on the desktop and in the Pet House like any other pet.

```sh
bash sources/sprites/make_sprite_pet.sh characters/<name>
```

The character folder (in `characters/`, which git ignores, or anywhere) holds `character.json`
and `clip-config.json`. Steps: `sprite_atlas.py` packs the frames into one sharp texture,
`sprite_build.py` builds the cards and clips in Blender, then `pipeline/finish.sh --pad` exports,
checks and installs.

Needs Python 3 with Pillow, and Blender 5.

## The images

One folder of images, anywhere (its path in `character.json` is relative to the character folder). Each is a GIF, PNG or
WebP, still or animated; an animated one keeps its own frame timing. A pose usually has a
front view, and optionally a side view (facing **left**) and a back view:

```
Hero (Front).gif   Hero (Left).gif   Hero (Back).gif
Hero - Walk (Front).gif   Hero - Walk (Left).gif   Hero - Walk (Back).gif
Hero - Laugh.gif
```

A file is found as `<prefix><name>` or `<name>`, so with the prefix `Hero - ` a pose can say
`Walk (Left)` or `Hero (Left)`. Frames of different sizes are lined up by their bottom centre.

## character.json

```jsonc
{
  "pal": "Hero",                        // the pack's name
  "images": "art",                      // the image folder, relative to this folder
  "prefix": "Hero - ",                  // optional
  "height": 1.6,                        // metres the idle stands (its first frame, margins trimmed);
                                        //   or "metresPerPixel" instead, the same for every sprite
  "defaultSide": "Hero (Left)",         // optional: for poses without their own side or back;
  "defaultBack": "Hero (Back)",         //   without these the front view stands in
  "poses": {
    "Stand": {"front": "Hero (Front)"},
    "Walk": {"front": "Walk (Front)", "side": "Walk (Left)", "back": "Walk (Back)"},
    "Laugh": {"front": "Laugh"}
  },
  "sideClips": ["Walk"],                // clips the app turns side-on: they show the side view
  "clips": {                            // steps of [pose, seconds, repeats]
    "Idle": [["Stand"]],                //   a still pose with no time holds 0.5 s
    "Walk": [["Walk"]],                 //   an animated pose plays once at its own timing
    "Laugh": [["Laugh", null, 6]],      //   ... or repeated
    "Faint": [["Hit", 0.3], ["Down", 2.0]]  // seconds sets a still pose's hold time
  }
}
```

`clip-config.json` is the usual pet config: see the example in
[`sources/rigged/README.md`](../rigged/README.md) and [PET_PACKS.md](../../PET_PACKS.md). For a
sprite pet, set every `fadeIn` to 0 so frames snap, give side-on clips (those in `sideClips`)
`"facing": "directional"` with `directionalYawDegrees` 90, and set the walk's `speed` by hand
(about 1.2 m/s for a 1.6 m character).

For `height`, a person-sized character is about 1.6 m (Palworld pals are shown 1.2–2.4 m tall); a small one
like Sonic about 1.0 m. Rips come at different pixel scales (a 2× rip's 48 px is a 96 px one's), so set the height,
not the pixel size.
