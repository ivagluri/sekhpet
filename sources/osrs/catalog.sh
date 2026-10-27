#!/bin/bash
# Render the character picker for player characters into work/osrs-catalog/ (picker.html): every style of
# every body part, numbered as outfit.txt uses them, and the colour palettes; also overview sheets.
#   bash sources/osrs/catalog.sh            styles and colours (a few seconds)
#   bash sources/osrs/catalog.sh --items    also an icon per wearable item, for the equipment lists (minutes,
#                                           the first time; icons already made are kept: delete items/ to redo)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
OUT="$ROOT/work/osrs-catalog"
(cd sources/osrs && python3 catalog.py)
"$BLENDER" --background --factory-startup --python-exit-code 1 --python sources/osrs/catalog_render.py -- "$OUT" 2>&1 \
  | grep -E "CATALOG_OK|Error|Traceback"
if [ "${1:-}" = "--items" ]; then
  "$BLENDER" --background --factory-startup --python-exit-code 1 --python sources/osrs/items_render.py -- "$OUT" 2>&1 \
    | grep -E "ITEMS_OK|Error|Traceback"
fi
(cd sources/osrs && python3 catalog.py --page)
echo "Open work/osrs-catalog/picker.html to design a player character."
