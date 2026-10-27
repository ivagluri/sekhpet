# SekhPet

A macOS menu-bar app that puts 3D desktop pets on your screen, plus a pipeline that turns characters into pets: Palworld pals from your own copy of the game, any rigged 3D character you have as glTF or FBX, or a 2D character's sprite images.

<p align="center">
  <img src="docs/demo1.gif" alt="SekhPet demo: a pal on the desktop" width="420">
  <img src="docs/demo2.gif" alt="SekhPet demo: a pal over app windows" width="400">
</p>

Pets idle, wander along the bottom of the screen, play their game animations as random "surprises", watch your cursor, and react when you click, double-click or drag them. Up to eight can be out at once, each at its in-game relative size.

**No game assets are included.** This repository is only the engine and the conversion tools. To make pets you need your own source material (for pals, your own installed copy of Palworld), and packs built from someone else's art are theirs, so keep them to yourself. Not affiliated with or endorsed by Pocketpair.

## Requirements

- **Mac:** macOS 15 or later, Xcode command-line tools (Swift 6), [Blender](https://www.blender.org) 5.x, and Python 3 with [Pillow](https://pypi.org/project/pillow/) (`python3 -m pip install Pillow`).
- **The machine with the game (Windows or Linux):** Python 3.9 or later. The extractor downloads [repak](https://github.com/trumank/repak) to read the game's `.pak` file.

## Making pets

Each kind of source has its own folder in `sources/`, with a README and one script that takes it to an installed pet; they all finish with the shared steps in `pipeline/` (export, check, install).

| Source | You have | Run |
|---|---|---|
| [`sources/palworld/`](PIPELINE.md) | Palworld installed | `bash sources/palworld/make_pet.sh <Pal>-extract.zip` (below) |
| [`sources/rigged/`](sources/rigged/README.md) | a rigged character with animations, as glTF/GLB or FBX | `bash sources/rigged/make_rigged_pet.sh characters/<name>` |
| [`sources/sprites/`](sources/sprites/README.md) | a 2D character's sprite images (GIF, PNG or WebP) | `bash sources/sprites/make_sprite_pet.sh characters/<name>` |
| [`sources/osrs/`](sources/osrs/README.md) | RuneLite (Old School RuneScape) installed | `bash sources/osrs/make_osrs_pet.sh "<NPC name>"`, or `--player <name>` |

For the rigged and sprite sources, a character is a folder (in `characters/`, ignored by git, or anywhere) holding a `character.json` that says what to use and a `clip-config.json` for the pet's behaviour. Sprite pets are paper cut-outs: flat cards that turn and slant like the rest.

## Quick start (Palworld)

On the Mac, once:

```sh
bash sources/palworld/setup_tools.sh          # .NET, CUE4Parse, UEFormat and the Palworld type mappings, into .tools/
bash scripts/build_app.sh --install  # builds SekhPet.app into /Applications
```

Once you've made a pet, `bash scripts/build_app.sh --install --icon-pet <Pal>` rebuilds the app with an icon rendered from it.

On the machine with the game, copy `sources/palworld/extract_pal.py` there and run:

```sh
python3 extract_pal.py --list        # internal names, e.g. KingWhale is Panthalus
python3 extract_pal.py KingWhale     # writes KingWhale-extract.zip
```

It finds the usual Steam install; otherwise pass `--pak <path to Pal-Windows.pak>`. Copy the zip to the Mac, then:

```sh
bash sources/palworld/make_pet.sh KingWhale-extract.zip    # several zips at once is fine
```

This converts the pal, builds and checks the pack, and installs it. Open the app's paw menu, **Choose Pets…**, and switch the pal on. After the first pal, `python3 sources/palworld/index_paldeck.py --print` lists every pal's display name next to its internal name.

Building one pal takes about a minute, more for large ones. Review `work/<pal>/check-sheet.png`, which shows ten moments of a scripted test run; [PIPELINE.md](PIPELINE.md) says what to look for.

## Using the app

- **Paw menu:** each pet's own submenu (mode, Wander, Snap to Windows, Double-Click Action, Play Now (any animation, or Random), Watch Cursor (its own setting, or Now), Size, reset position, remove), Choose Pets…, Pet House, Pet Viewer…, then shared settings: Pause All, Wander, how often surprises happen, cursor watching, size, Low Power, launch at login, and Reset to Defaults (every setting and position, keeping the pets you have out).
- **On the pet:** click, double-click and drag it. Right-click for its Wander and Snap to Windows toggles, Double-Click Action (any of its animations, or a different random one each time, instead of the default), Watch Cursor (Occasionally, Always or Never for this pet, or the shared setting; Now for a spell right away), Size (Small, Medium or Large for this pet, or the shared size), and Remove from Desktop.
- **Snap to Windows** (per pet, on by default): drop a pet on a window's top edge, a title bar for instance, and it stands there, walks along it, rides along when the window moves, and falls to the next surface below when the window closes or minimizes. When a minimized or hidden window comes back, the pet jumps back up onto it, unless you've moved the pet since. It sits at its window's level, so other windows can cover it.
  - A pet that falls or steps off a window lands on the first window top below it, or on the screen bottom if there's none.
  - While you drag a pet, a faint shadow under its feet shows where it will stand. Near a surface it would snap to, the shadow moves onto that edge and glows.
- **Pet House** (paw menu, off by default): an alternate mode where every pet on the desktop moves into one small room, a frosted-glass toy box on the desktop. They stroll about, visit each other, kick a ball around and sometimes eat the fruit, which drops back in 30–60 seconds later. Click, double-click or right-click a pet as usual; drag a pet to pick it up, or drag the ball or fruit and let go to throw it.
  - Drag the box to move it, or the arrow on its front corner (shown when the mouse is over the box) to resize it. Like a pet, it stands on window tops, rides along when the window moves, falls when it closes, and jumps back on when it returns.
  - Switching it off sends the pets back to where they were on the desktop.
- **Pet Viewer** (Pet Viewer…): a loadout-screen style window for any installed pet, listed by paldeck number. Drag to turn and tilt, scroll or pinch to zoom, middle-drag to move up and down, and click or double-click the pet. Its card shows height, animation count and top speed; its animation list plays any animation once, or on a loop. A turntable slowly circles the pet until you grab the camera.
- **Working with Claude Code** (optional): a pet standing on a window of the app where [Claude Code](https://claude.com/claude-code) is working, a terminal say, plays its work animation (handiwork, or its first other work action) until Claude finishes or waits on you. Claude Code tells the app through hooks; add these to `~/.claude/settings.json`:

  ```json
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "timeout": 5, "command": "d=\"$HOME/Library/Application Support/SekhPet/Claude\"; mkdir -p \"$d\" && echo working > \"$d/.$PPID\" && mv -f \"$d/.$PPID\" \"$d/$PPID\"" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "timeout": 5, "command": "d=\"$HOME/Library/Application Support/SekhPet/Claude\"; mkdir -p \"$d\" && echo idle > \"$d/.$PPID\" && mv -f \"$d/.$PPID\" \"$d/$PPID\"" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "timeout": 5, "command": "d=\"$HOME/Library/Application Support/SekhPet/Claude\"; mkdir -p \"$d\" && echo idle > \"$d/.$PPID\" && mv -f \"$d/.$PPID\" \"$d/$PPID\"" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "timeout": 5, "command": "d=\"$HOME/Library/Application Support/SekhPet/Claude\"; rm -f \"$d/$PPID\"" }] }]
  }
  ```

  Each session writes one small file named for its `claude` process; the app watches that folder and reads nothing else. Every pet on any window of that app works, since windows and tabs of one app can't be told apart. Sessions inside tmux or screen don't count: they run under the tmux server, not the terminal app.
- **Pets window** (Choose Pets…): switch pets on and off, **Add Pet…** from a zip (or drop zips on the window), and **Export as Zip…** from a pet's ••• menu to move it to another Mac.
- **Low Power** draws at 20 fps without anti-aliasing. Automatic turns it on when running on battery or in macOS Low Power Mode.

The app is ad-hoc signed, so on another Mac macOS blocks the first launch. Open it once, then click **Open Anyway** in System Settings → Privacy & Security and confirm. Or clear the download flag first with `xattr -dr com.apple.quarantine SekhPet.app`, which also keeps macOS from running it from a temporary copy, where Launch at Login doesn't stick.

## Docs

- [PIPELINE.md](PIPELINE.md): how a pal becomes a pet, the rules the config generator follows, per-pal overrides, and known problems with their fixes.
- [sources/rigged/README.md](sources/rigged/README.md), [sources/sprites/README.md](sources/sprites/README.md) and [sources/osrs/README.md](sources/osrs/README.md): the other sources.
- [PET_PACKS.md](PET_PACKS.md): the pack format the app loads. Anything that produces this format works.

## Layout

| Path | What |
|---|---|
| `app/SekhPet/` | The app (Swift, SceneKit). `swift build` works on its own. |
| `scripts/` | Building the app: `build_app.sh`, and `make_icon.py` for its icon. |
| `pipeline/` | The steps every source finishes with: measure a Blender file's clips, export the pack, check it in the app's offscreen test, install it (`finish.sh`). |
| `sources/palworld/` | Palworld: `extract_pal.py` (game machine), `make_pet.sh` (Mac) and the steps it runs; `converter/`, a small CUE4Parse program for the game's packages; `overrides/`, optional hand fixes per pal. |
| `sources/rigged/` | Rigged glTF/GLB or FBX characters: import, clips, props, bone pruning. |
| `sources/sprites/` | Sprite images to paper cut-out pets. |
| `sources/osrs/` | Old School RuneScape NPCs and player characters, from RuneLite's game cache, through the rigged route. |
| `characters/` | Your characters for the rigged, sprite and OSRS sources (ignored by git). |
| `work/` | Everything generated per pet (ignored by git). |
| `.tools/` | Downloaded tools (ignored by git). |

## License

MIT No Attribution (MIT-0), for the code in this repository: use it however you like, no credit needed. See [LICENSE](LICENSE). The tools it downloads (CUE4Parse, UEFormat, repak, .NET, the mappings file) keep their own licenses.
