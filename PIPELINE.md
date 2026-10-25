# How a pal becomes a pet

Two machines: the one with the game (Windows or Linux) only extracts, and the Mac does the rest. See the [README](README.md) for setup.

```sh
python3 extract_pal.py <Pal>                  # game machine -> <Pal>-extract.zip
bash sources/palworld/make_pet.sh <Pal>-extract.zip    # Mac -> work/<pal>/, installed pet
```

To re-run a pal already in `work/`, after editing its overrides or updating the scripts, give its name instead of a zip: `bash sources/palworld/make_pet.sh <Pal>`.

`<Pal>` is the internal name, as in the model `SK_<Pal>` (`extract_pal.py --list` prints them all). Variants that share their base pal's animations (`CatMage_Fire` uses `CatMage`'s) are recognised from the name; `--anims <Base>` overrides that.

## extract_pal.py

Reads `Pal-Windows.pak` with repak and never modifies it. It takes every archive entry whose path contains the pal's name, plus the shared animation folder for variants. Then it follows the package references in each model, animation, material and texture package (found in their name maps) until nothing new turns up. A pal is typically 250–500 files and 20–80 MB, capped at 4000 files and 512 MB as a safety check.

The zip also carries the archive listing and two game tables: `DT_PalMonsterParameter` (sizes and speeds) and the English `DT_PalNameText_Common` (display names). Each file's SHA-256 goes into `manifest.json`, and `make_pet.sh` checks them all after unzipping.

## make_pet.sh

Each step is skipped when its output exists, so a failed run resumes. Delete a step's output to redo it, or `work/<pal>/` to start over.

| # | Step | Script | Output in `work/<pal>/` |
|---|---|---|---|
| 1 | Unzip and verify checksums; game tables go to `work/tables/` | (inline) | `raw/`, `manifest.json` |
| 2 | Decode the game tables (first pal, or when a newer zip brings them) | converter `--inspect`, `index_paldeck.py` | `work/tables/tables.json`, `paldeck.json` |
| 3 | Convert cooked packages to UEFormat meshes and animations, PNG textures and material JSON | `sources/palworld/converter` | `converted/` |
| 4 | Blender import: mesh, rig, materials, one action per clip, standard clip names | `build_blender.py` | `blender/<Pal>.blend` |
| 5 | Probe each clip: duration, root travel, pelvis lift, additive type; idle height | `probe_pal.py` | `probe.json` |
| 6 | Generate the behavior config (rules below), merged with `sources/palworld/overrides/<pal>.json` | `make_pal_config.py` | `clip-config.json` |
| 7 | Export the pack: model USDZ (textures at most 1024 px), one USDZ per clip, `clips.json` | `export_realtime.py` | `realtime/` |
| 8 | Bounds check: drop clips still far too big after fitting, then re-export (up to 3 rounds) | `check_pack.py --bounds-only` | `sources/palworld/overrides/<pal>.json` |
| 9 | Behavior test: a scripted offscreen run, and a contact sheet | `check_pack.py` | `check/`, `check-sheet.png` |
| 10 | Thumbnail, then install into the pets folder | the app's `--icon` mode | `realtime/thumbnail.png` |

Steps 6–10 always run, so re-running a pal after editing its overrides takes under a minute. A pet already on the desktop keeps its old pack loaded until you switch it off and on in the Pets window.

## Reviewing a pal

The behavior test fails if a scripted action didn't start or a frame came out empty. That only proves the mechanics. Look at `check-sheet.png`:

| Frame | Script | Look for |
|---|---|---|
| 0.4 s idle | — | Faces the viewer, full textures (no white or grey patches), sensible framing |
| 2.5 s click | Click at 1 s | Often back in idle by now; fine |
| 7.5 s double | Double-click at 6 s | Often back in idle; fine |
| 12.5 s drag | Drag at 11 s | Mid-air jump pose (idle if the pal has no Jump) |
| 15.5 s drop | Drop at 14 s | Landing |
| 20.5 / 23.5 s watch | Cursor up-left, then right | Head turned toward each side |
| 29 / 33 s group | First surprise group | Turned side-on, not facing the viewer |
| 41.5 s travel | First walking gait | A true side profile, facing the direction of travel |

Also skim the output for the size line (`game … -> shown …`), `rejected` stride measurements (the game's speed is used instead), `FIT` lines and `BOUNDS: excluded`.

## Rules the config generator follows

- **Facing:** Idle and `RestNN` face the viewer. Everything else turns 40°: gaits 90°, clips that cover ground 30–60°.
- **Size:** game height = the blueprint's `CharacterMesh0` `RelativeScale3D` (`BP_<Pal>`, default 1) × the model's idle height, clamped to **1.2–2.4 m on screen**. The pack's `meshScale` carries the result.
- **Groups:** clips are grouped by stem from the suffixes `Start/StartLoop/Action/UpLoop/ActionLoop/Loop/DownLoop/End`. A suffix counts after an underscore (any case) or attached and capitalized (`LargeDownStart`, `JumpStart`), so a word that merely ends in "end" doesn't match.
  - If a name reads two ways (`LargeDownLoop` is `Large`+`DownLoop` or `LargeDown`+`Loop`), the stem its siblings share wins.
  - Numbered sub-stems merge into their parent: `TrickShow_Start` → `TrickShow_01` → `TrickShow_01_Loop` → `TrickShow_01_End` is one group.
  - Numbered actions chain in number order: `MoonBlade_Start` → `_Action1` → `_Action2` → `_End` is one move, as are `NightmareFlame_Action_01` and bare numbered clips beside a group (`BrutalMachete_01`, `Breaching_01`).
  - With no loop suffix, a clip named just the stem is the held part (`SleepStart` → `Sleep` → `SleepEnd`); with none at all (a Start, actions, an End), the group plays through once.
  - Falls and holds (`UpLoop`, `DownLoop`) loop 1–2 times and `Skill_*` loops 3–6 times. Other loops repeat until the surprise lasts at least 6 s.
  - The exporter warns about a clip ending in Start/Loop/End that isn't in a group.
- **Travel:** Walk, Trot, Transport, Run, Sprint, Walk_Swim and Run_Swim become wandering gaits.
- **Work:** the clips the blueprint's `ActionMontageMap` plays for work (CommonWork, Architecture, Mining, Deforest, Watering, Feeding, Cooking, Cool) loop, as their montages do in the game, so repeats wrap without a crossfade hitch. A clip the map also uses for something else (one pal's CommonWork is its Eat) stays a one-shot. Variants inherit the map from a base blueprint that isn't extracted, so for them the usual names (CommonWork, Architecture, Mining, Deforest, Watering, Planting, Cooking, Cooling) stand in.
- **Root travel:** clips whose root bone travels more than 0.3 m are stripped in place and replayed by moving the window, scaled to at most 1.5 m.
- **Pelvis launches:** a lift above max(1 m, half the pal's height) is capped at 0.4 × height. `Getup*` clips with a big lift are excluded instead (capping them sinks the body into the floor).
- **Reactions:** click plays Petting (87%) or Damage (13%). Double-click plays the first standalone `Skill_*` clip of 0.8–4 s, otherwise Encount. Dragging holds the Jump group's loop and letting go plays its landing.
- **Oversized clips** (limits in `pipeline/pack_limits.py`): a clip that rises above 1.6× the idle height, sinks below 0.35× it, or reaches sideways beyond the larger of 1.25× the height and 1.2× the idle reach is fitted, not dropped.
  - The exporter squashes the root and pelvis travel (up, down and sideways separately) until the clip fits. Then it lifts the body on any frame whose pose still dips below the sink limit, so a nose-first dive bobs at floor level. Pose and timing are untouched.
  - Sinks are always fitted. Rises and sweeps are fitted only when more than 10% over, and a squash is undone if it removed less than half the excess: that size comes from the pose (rearing up, spread wings), not travel, and the window grows instead.
  - The output shows `FIT <clip>: up x…, down x…, sideways x…, lifted up to … m`; `clips.json` records `motionFit`.
- **Exclusions:** additive clips (Hit), the Carrying clip (a flop onto the side), and the rare clip whose pose alone is still 1.6× past a limit after fitting.
- **Speed:** see problem 8 below.

**Overrides:** hand fixes go in `sources/palworld/overrides/<pal>.json`, merged over the generated config: dicts merge, lists replace, `exclude` accumulates, and `null` removes a key (`"locomotion": {"Sprint": null}` drops a gait). `allowLarge` keeps clips the bounds check would drop. A fully hand-made `work/<pal>/clip-config.json` also works: the generator keeps any config it didn't write.

## Problems met, and their fixes

"Automatic" means the pipeline handles it; "Manual" means you act.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | Extraction: `FileNotFoundError` for a file whose name differs in case (`AKE_Lizardman_Stealth.bnk`) | repak's filters are case-sensitive; name matching isn't | Automatic: exact-path filters for those files |
| 2 | Blender: `key "AS_<Pal>_Idle" not found` | Some pals spell standard clips differently (`_idle`) | Automatic: standard clip names are normalized on import |
| 3 | Blender: `'NoneType' object is not subscriptable` | Material JSON with empty texture slots | Automatic: skipped |
| 4 | A part renders plain white (a flame, a cloud) | Procedural material with no colour texture | Automatic: a flat glowing colour from the material's colour parameters; `_EM` maps drive glow. Translucent effects stay solid |
| 5 | Missing or wrong normal map | Texture names were guessed | Automatic: textures are read from each material's JSON |
| 6 | Feet slide, or a pal crawls or teleports | Stride measurement fails on floaters, swimmers and belly-sliders | Automatic: a measured stride is kept only within 0.3–2× of the game's speed for that gait; otherwise the game's speed is used |
| 7 | A quadruped's stride measures 0 | No `ball_l/r` bones; feet are `hand_*` and `ball_02_*` | Automatic: feet chosen by name (`ball/foot/hand/toe/hoof`), then the lowest leaf bones. `feet` in overrides forces a list |
| 8 | Dragged pal flops onto its side | A pal's Carrying clip is a flop, not a carried pose | Automatic: dragging uses the Jump group; Carrying is excluded |
| 9 | Dragging a pal with no jump does nothing | No JumpLoop/JumpEnd clips | Accepted: dragging just moves it |
| 10 | Start/loop/end clips play as separate surprises | Unusual naming | Automatic for the cases above; the exporter's `WARNING … looks like part of a … group` flags any left. Fix by hand with `groups` in overrides |
| 11 | Blender `Could not decompose skeleton transforms`; a hidden prop flashes | Props hidden by scaling a bone to exactly 0 | Automatic: zero scales nudged to 0.001 before export |
| 12 | A giant pal (Panthalus, 27 m) ran the test out of memory, or its nose and tail were clipped | Sizes in model metres without `meshScale`; a fixed camera depth | Automatic: test frames use `meshScale` and are capped at 2048 px; the camera's depth range comes from the pal's reach |
| 13 | High memory with several pets out | 2048 px game textures | Automatic: textures above 1024 px are scaled down at export |
| 14 | A paldeck pal has no model folder | Its blueprint uses a differently named mesh | Manual: see below |
| 15 | Build fails in the probe: `index 0 out of range` | A curve-only animation (`AS_LeafMomonga_Walk_Curves`) has no bone channels | Automatic: dropped on import |
| 16 | The pal is invisible: every test frame is empty | The mesh has shape keys; SceneKit draws nothing of a skinned mesh exported with blend shapes | Automatic: shape keys dropped before export (printed as a `WARNING`) |
| 17 | No crossfade out of some clip: the pal snaps to the next one (Sekhmet after Sprint). In the check sheet it shows as the pal staying in that clip's pose (LeafMomonga flat after a drop) | SceneKit mishandles crossfading out of some clips with time-sampled bone scale; the offline renderer behind the check frames freezes instead of snapping. Not every such clip: 510 of 1308 have sampled scale, and most blend fine | Manual: list the clips in `staticScale` in overrides, which holds their scale at the first frame's |

### No model folder

`index_paldeck.py --print` marks these. Some variants' blueprints point at a mesh with another name (Bellanoir Libero's is `SK_NightLady_Pink`).

1. Extract and build the base pal first (here `NightLady`); the variant's blueprint comes with it. Find the mesh it uses:

   ```sh
   export DOTNET_CLI_HOME=$PWD/.tools/dotnet-home NUGET_PACKAGES=$PWD/.tools/nuget
   .tools/dotnet/dotnet sources/palworld/converter/bin/Release/net10.0/Converter.dll work/nightlady/raw /tmp/bp.json \
     .tools/Palworld-Mappings.usmap --inspect Pal/Content/Pal/Blueprint/Character/Monster/PalActorBP/NightLady/BP_NightLady_Dark.uasset
   ```

   In `/tmp/bp.json`, the `CharacterMesh0` export's `SkeletalMesh` names the mesh, and `RelativeScale3D` its scale (1 if absent).
2. Write `sources/palworld/overrides/<mesh lowercased>.json` with `{"displayName": "<paldeck name>"}`.
3. Extract and build under the mesh's name: `python3 extract_pal.py NightLady_Pink --anims NightLady`, then `make_pet.sh` as usual.

The mesh can also sit in the base pal's own folder (Lyleen Noct's `SK_LilyQueen_Ice` is in `LilyQueen/`, beside `SK_LilyQueen`); look there and for its textures when the blueprint isn't in the base pal's extraction. The same three steps work: the extractor and converter find the mesh wherever its folder is.

If the blueprint keeps the base mesh and only swaps materials (`OverrideMaterials`), the pipeline can't express that yet.

## Known limitations

- **Effects** (flames, clouds, sparkles) are flat solid colours, not translucent or gradient.
- **Size clamp:** pals outside 1.2–2.4 m lose their true relative size.
- **Odd surprises** such as swim idles on dry land stay in the pool; exclude them in the overrides.
- **Game updates** can change the archive, the type mappings or the tables. Re-extract, and update the mappings pin in `sources/palworld/tool-versions.json` if conversion starts failing.

## Bounds measurement performance

The exporter currently measures bounds with a Python loop over each evaluated vertex. A bulk-access/NumPy replacement was validated during the Aerith conversion. [The performance note](pipeline/BOUNDS_PERFORMANCE.md) contains the candidate implementation, cross-source comparisons and measured timings. It preserves the existing frame sampling and bounds rules; the shared exporter has not yet adopted it.
