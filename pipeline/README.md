# The shared pipeline

Every source (`sources/*`) finishes here. Its input is a Blender file laid out like this:
- `work/<name>/blender/<Name>.blend`, holding the rig `<Name>_Rig` and one skinned mesh `<Name>`.
- A skeleton named `SK_<Name>`, with a bone called `root` (and, optionally, `pelvis`).
- Facing -Y, in metres, standing on the origin.
- The pet's clips as actions `AS_<Name>_<Clip>`, on a 30 fps timeline from frame 1.

It also needs a `clip-config.json` for the pet's behaviour.

| Script | Does |
|---|---|
| `probe_pal.py` | Measures the clips (durations, travel, idle height) into `work/<name>/probe.json`. |
| `export_realtime.py` | Writes the pack (`work/<name>/realtime/`): the model and one file per clip as USDZ, plus `clips.json`. |
| `pad_clips.py` | Extends each clip's animation samples to its full length and makes frame changes instant, for clips that change only now and then (sprite frames). |
| `check_pack.py` | Checks the pack's size limits, then runs it through the app's offscreen test and draws the check sheet. |
| `pack_limits.py` | The size limits, shared by the export and the check. |
| `finish.sh` | All of the above after probing, then installs the pack: `bash pipeline/finish.sh <Name> <clip-config.json> [--pad]`. |
