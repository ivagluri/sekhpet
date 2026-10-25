#!/bin/bash
# Turn a rigged character (glTF/GLB or FBX, with its animations) into an installed pet, end to end.
#   bash sources/rigged/make_rigged_pet.sh <character folder>      (e.g. characters/hero)
# The folder holds character.json (the model, its animations and the clips made from them)
# and clip-config.json; see sources/rigged/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -eq 1 ] && [ -f "$1/character.json" ] || { sed -n '2,5p' "$0"; exit 2; }
SPEC="$(cd "$1" && pwd)"
cd "$ROOT"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
[ -x "$BLENDER" ] || { echo "Blender not found at $BLENDER; set BLENDER." >&2; exit 1; }
field() { python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); v=c.get(sys.argv[2]); print(" ".join(v) if isinstance(v, list) else ("" if v is None else v))' "$1" "$2"; }
PAL=$(field "$SPEC/character.json" pal)
BASE="work/$(echo "$PAL" | tr '[:upper:]' '[:lower:]')"
BLEND="$BASE/blender/$PAL.blend"
blender() { "$BLENDER" --background "$@" 2>&1; }
run() { blender "$BLEND" --python-exit-code 1 --python "$@"; }

echo "== $PAL: import"
rm -rf "$BASE/blender" "$BASE/probe.json" "$BASE/realtime"
blender --factory-startup --python-exit-code 1 --python sources/rigged/import_model.py -- "$SPEC" | grep -E "^ANIM|IMPORT_OK|WARNING|Error|Traceback|no bone|glTF/GLB"
run sources/rigged/compose.py -- "$SPEC" | grep -E "^CLIP|centred|COMPOSE_OK|Error|Traceback|no animation"
run sources/rigged/props.py -- "$SPEC" | grep -E "^PROP|PROPS_OK|Error|Traceback"
# Only the bones the clips move go into the pack, plus the feet and look bones the config names.
read -r -a NAMED <<< "$(field "$SPEC/clip-config.json" feet) $(field "$SPEC/clip-config.json" lookBones)"
run sources/rigged/prune_bones.py -- ${NAMED[@]+"${NAMED[@]}"} | grep -E "PRUNE_OK|Error|Traceback"
run pipeline/probe_pal.py -- --pal "$PAL" | grep -E "PROBE_OK|Error|Traceback"

if [ "$(field "$SPEC/character.json" recenter)" = "True" ]; then
  echo "== $PAL: recentre lopsided clips"
  cp "$SPEC/clip-config.json" "$BASE/clip-config.json"
  run pipeline/export_realtime.py -- --pal "$PAL" | grep -E "Error|Traceback" || true
  run sources/rigged/recenter.py -- "$BASE/realtime/clips.json" | grep -E "^recentred|RECENTER_OK|Error|Traceback"
fi
bash pipeline/finish.sh "$PAL" "$SPEC/clip-config.json"
