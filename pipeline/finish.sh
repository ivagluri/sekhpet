#!/bin/bash
# The last steps every source shares: export a pet's Blender file to a pack, check it, and
# install it into the pets folder.
#   bash pipeline/finish.sh <Pal> <clip-config.json> [--pad]
# Expects work/<pal>/blender/<Pal>.blend laid out the pipeline's way (rig <Pal>_Rig with a
# skeleton named SK_<Pal>, mesh <Pal>, clips AS_<Pal>_<Clip>) and probed with
# pipeline/probe_pal.py. --pad runs pipeline/pad_clips.py on the clips (needed when clips
# change only now and then, such as sprite frames).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ $# -ge 2 ] || { sed -n '2,8p' "$0"; exit 2; }
PAL=$1 CONFIG=$2
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
LIBRARY="${SEKHPET_PETS:-$HOME/Library/Application Support/SekhPet/Pets}"
APP_BIN=app/SekhPet/.build/release/SekhPet
LOWER=$(echo "$PAL" | tr '[:upper:]' '[:lower:]')
BASE="work/$LOWER"
PACK="$BASE/realtime"
blender() { "$BLENDER" --background "$@" 2>&1; }
# The first Python with Pillow (the check sheet needs it).
PY=""
for candidate in python3 python3.13 python3.12 python3.11 python3.10; do
  command -v "$candidate" >/dev/null && "$candidate" -c 'import PIL' 2>/dev/null && { PY="$candidate"; break; }
done
[ -n "$PY" ] || { echo "No Python with Pillow found: python3 -m pip install Pillow" >&2; exit 1; }
[ -x "$APP_BIN" ] || swift build -c release --package-path app/SekhPet

echo "== $PAL: export and check"
cp "$CONFIG" "$BASE/clip-config.json"
blender "$BASE/blender/$PAL.blend" --python-exit-code 1 --python pipeline/export_realtime.py -- --pal "$PAL" \
  | grep -E "^wrote|^FIT|WARNING|Error|Traceback"
if [ "${3:-}" = "--pad" ]; then
  blender --factory-startup --python-exit-code 1 --python pipeline/pad_clips.py -- "$PACK"/clips/*.usdz | grep -E "PAD_OK|Error|Traceback"
fi
$PY pipeline/check_pack.py "$PAL" | tail -2

echo "== $PAL: install"
SEKHPET_ASSETS="$PACK" "$APP_BIN" --icon "$PACK/thumbnail.png" --pet "$PAL" > /dev/null
sips -Z 256 "$PACK/thumbnail.png" > /dev/null
rsync -a --delete "$PACK/" "$LIBRARY/$LOWER/"
echo "== $PAL: installed. Review $BASE/check-sheet.png, then turn it on in the Pets window."
