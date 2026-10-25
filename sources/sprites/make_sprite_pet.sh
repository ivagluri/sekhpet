#!/bin/bash
# Turn a character's sprite images into an installed pet, end to end.
#   bash sources/sprites/make_sprite_pet.sh <character folder>      (e.g. characters/hero)
# The folder holds character.json (the images, the poses and the clips as pose sequences)
# and clip-config.json; see sources/sprites/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -eq 1 ] && [ -f "$1/character.json" ] || { sed -n '2,5p' "$0"; exit 2; }
SPEC="$(cd "$1" && pwd)"
cd "$ROOT"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
PY=""
for candidate in python3 python3.13 python3.12 python3.11 python3.10; do
  command -v "$candidate" >/dev/null && "$candidate" -c 'import PIL' 2>/dev/null && { PY="$candidate"; break; }
done
[ -n "$PY" ] || { echo "No Python with Pillow found: python3 -m pip install Pillow" >&2; exit 1; }
PAL=$($PY -c 'import json,sys; print(json.load(open(sys.argv[1]))["pal"])' "$SPEC/character.json")
BASE="work/$(echo "$PAL" | tr '[:upper:]' '[:lower:]')"
blender() { "$BLENDER" --background "$@" 2>&1; }

echo "== $PAL: sprites"
rm -rf "$BASE/sprites" "$BASE/blender" "$BASE/probe.json" "$BASE/realtime"
$PY -I sources/sprites/sprite_atlas.py "$SPEC/character.json" "$BASE/sprites"
blender --factory-startup --python-exit-code 1 --python sources/sprites/sprite_build.py -- \
  --pal "$PAL" --spec "$SPEC/character.json" --sprites "$BASE/sprites" | grep -E "SPRITE_BUILD_OK|Error|Traceback"
blender "$BASE/blender/$PAL.blend" --python-exit-code 1 --python pipeline/probe_pal.py -- --pal "$PAL" | grep -E "PROBE_OK|Error|Traceback"
bash pipeline/finish.sh "$PAL" "$SPEC/clip-config.json" --pad
