# Old School RuneScape characters

Makes a pet from an OSRS NPC or a player character of your own design, straight from the game cache
RuneLite keeps (`~/.runelite/jagexcache/oldschool/LIVE`; set `OSRS_CACHE` for another). Nothing is
extracted up front: name a character when you want it.

```sh
bash sources/osrs/make_osrs_pet.sh "Wise Old Man"        # an NPC, by its in-game name
bash sources/osrs/make_osrs_pet.sh --player dragonknight  # a player: writes characters/dragonknight/outfit.txt
bash sources/osrs/make_osrs_pet.sh dragonknight           # ...fill the outfit in, then build it
bash sources/osrs/catalog.sh                              # the character picker and style sheets, for outfits
```

The first run of a character drafts its folder in `characters/<name>/`, writes the model as `model.glb`,
then builds and installs the pet with the generic rigged route (`sources/rigged/make_rigged_pet.sh`).
Edit the drafted files and run the same command again: a draft is kept unless you add `--redraft`.

Needs RuneLite (run once recently, so the cache is current), Blender 5, and Python 3 (with Pillow for the
check sheet, as for every source). The first run downloads two pinned files into `.tools/osrs/` (see
**Downloads**).

## The character folder

```
characters/wiseoldman/
  character.json     the rigged route's import spec, plus an "osrs" block (below)
  clip-config.json   the pet's behaviour (sources/rigged/README.md describes it)
  clips.txt          every animation made for this skeleton, by id and name, to add more from
  model.glb          written on every run from the cache
  outfit.txt         player characters only
  emotes.txt         optional: this character's own emote list
```

The `"osrs"` block in `character.json`:

```jsonc
"osrs": {
  "npc": 2108,                        // the NPC (or "player": "outfit.txt")
  "clips": {"Idle": 813, "Wave": 863},  // pet clip name -> the game's animation (sequence) id
  "loops": ["Idle", "Walk"],          // clips that loop: their last pose blends back into the first
  "hideFaceGroups": [4, 5, 6],        // optional: face groups to leave out (water ripples); kept on --redraft
  "glow": [4011]                      // optional: face colours that shine whatever the lighting; kept on --redraft
}
```

`glow` is for parts the game shows glowing, such as eyes: the desktop's key light comes from the upper left,
so a small face turned away from it goes dark (TzTok-Jad's right eye). Its values are the model's face
colours, the client's 16-bit HSL; `python3 sources/osrs/colours.py characters/<name>` lists them with where
each sits on the model.

To add a clip, put `"Name": id` in `osrs.clips` (ids and names are in `clips.txt`, and every animation's
name is in `.tools/osrs/AnimationID.java`); the import's `clips` map follows it. Give it settings in
`clip-config.json` if it needs any (a loop, a group, a click).

## NPCs

`make_osrs_pet.sh "<name>"` finds the NPC by name. Several NPCs often share a name; the first is used and the
others are listed with their `--id`.

- **Idle and gaits** come from the NPC's definition (its standing, walking and running animations).
- **Other clips** are the animations made for the same skeleton, named from RuneLite's animation list.
  Deaths, spawns, despawns, turns and chat-head animations are left out, as is anything over 20 s.
- **Behaviour:** other idles drift in as `idleVariants`; lie down + sleep + get up become a `Sleep` group;
  a defend or block is the click, an attack the double-click; everything else is a surprise.
- **Humans** (anything on the player skeleton) get the emote list instead (below).
- **Size:** the NPC's own resize is applied, and `meshScale` brings it within 1.2-2.4 m on screen.
- **Ground effects** (drawn shadows, water ripples, puddles: wide, flat face groups on the floor in colours
  the body doesn't use, plus small ones in the same colours) are hidden: the game draws them see-through,
  and solid they'd be blobs on the desktop. The draft lists them in `hideFaceGroups`.
- **Head:** `lookBones` is the head's bone (a human's highest; a creature's biggest at the front, top).

## Player characters

`--player <name>` writes an `outfit.txt` to fill in. One entry per line, `#` starts a comment:

```
include: dragon            # optional: lines from characters/_osrs/outfits/dragon.txt (a reusable loadout)
body: A                    # A or B, the game's two body types
hair: 6                    # also jaw, torso, arms, hands, legs, feet
hair colour: 4             # also torso colour, legs colour, feet colour, skin colour
Black d'hide chaps         # any other line is an item to wear, by its in-game name
Ancestral robe top
Abyssal whip #4151         # #<item id> picks one version when several share the name
stance: auto               # or an animation name or id
combat: auto               # or names/ids, comma separated; "none" for no attacks
emotes: default            # characters/_osrs/emotes.txt, or a file in this folder
```

- **Styles and colours** are numbered from 1 as the character designer lists them: a body type's
  selectable styles for that part, in the game's order. Unset parts and colours use the first.
- **The picker:** `catalog.sh` renders every style and writes `work/osrs-catalog/picker.html`: choose a
  body type, each part and the colours by picture, and the equipment from a searchable list per slot; it
  writes the `outfit.txt` for you (copy or download it into `characters/<name>/`). The equipment lists
  need `catalog.sh --items` once (about a minute): an icon per wearable item, as it looks dropped on the
  ground; only the picked item's icon is shown. The same folder has numbered overview sheets
  (`body-A-hair.png`, `colours.png` …). The template is `sources/osrs/picker.html`.
- **Worn items** cover the body parts the game says they do (a platebody hides the arms, a full helm the
  hair and beard). They animate with the body: OSRS items carry the body's own vertex labels.
- **Weapon stance and attacks** are decided by the game's server, so they're matched here by name: the idle
  from Fashionscape's weapon table, walk, run and attacks from animation names containing the weapon's
  name. The draft prints what it found (`STANCE`, `COMBAT`); set `stance:`/`combat:` when it's wrong.
  Attacks become `Attack`, `Attack2` …: the double-click, then surprises.
- After changing a weapon or the emote list, re-run with `--redraft` (the draft notices a newer outfit).

## Emotes

Every human pet, player or NPC, gets the emote tab's emotes as surprises (Wave on click, Jump for Joy on
double-click, Flap while held). The list comes from the game cache: the first run writes
`characters/_osrs/emotes.txt` with each emote's animation beside it:

```
Jump for Joy             # EMOTE_JUMP_WITH_JOY (2109)
Scared                   # DRAGON_SLAYER_QIP_JEN_SCARED (6649)  (a guess: check it)
# Crab dance             # no animation found (put an animation name or id here)
```

Comment out the ones you don't want. A line can also be an animation name or id. A character's own
`emotes.txt` replaces the shared list. Emote graphics (skill cape effects and such) aren't included.

## How the conversion works

- **Classic animation:** OSRS models have no skeleton. Each vertex carries a label, and each frame is a
  list of transforms (rotate, move, scale) on groups of labels. They're all affine, so every label moves
  rigidly: the model gets one bone per label (`label_NNN`, under `root`), exact to the game.
- **Skeletal ("animaya") NPCs:** newer content (about 3% of NPCs: Capybara, Callisto cub …) has real
  bones, keyframe curves and per-vertex weights. Their decoder is a port of Qodat's (GPL-3), so it's kept
  out of the repository: `maya_local.py` (in `.git/info/exclude`). Without it, these NPCs stop with a
  message saying so.
- **Motion** is smoothed: the game steps from pose to pose at its own frame times (20 ms ticks); the pet
  blends between them, as RuneLite's animation smoothing does. A pose held over 2 s (a death's last frame)
  is cut short.
- **Colours** are the faces' own (HSL in the game), recoloured as the NPC, item or outfit says, stored as
  vertex colours and baked into a texture by the rigged route (`bakeTexture`).
- **Size:** 128 model units (a tile) is taken as a metre.

## Downloads

Pinned in `tool-versions.json`, fetched into `.tools/osrs/` and checked by SHA-256:

- `AnimationID.java` from RuneLite (BSD-2): names for all of the game's animations.
- `weapon-idles.json`, Fashionscape's hand-kept table of weapon idle stances (`anims.json` in
  equirs/fashionscape-data), used as-is and not redistributed.

The player colour palettes aren't in the cache: they're read once from RuneLite's copy of the game client
(`~/.runelite/repository2/injected-client-*.jar`) into `.tools/osrs/palettes.json`, and again after a
RuneLite update.

## Known gaps

- **Textured faces** (rare: 28 of about 7,600 NPC models) come out plain grey.
- **Transparency** (glass, ghosts, effects that fade) isn't carried over: faces are opaque or left out.
- **Weapon matching** is by name, so unusual weapons need a `stance:`/`combat:` line.
- **Graphics** (spot animations: spell effects, emote effects) aren't included.
