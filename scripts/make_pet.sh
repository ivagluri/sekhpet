#!/bin/bash
# Turn pals extracted with scripts/extract_pal.py into installed desktop pets.
#   bash scripts/make_pet.sh KingWhale-extract.zip [more zips...]
#   bash scripts/make_pet.sh KingWhale            re-run a pal already in work/ (e.g. after editing overrides)
# Each pal works in work/<pal>/ and is installed into the pets folder; the running app
# shows it in the Pets window. Steps whose output exists are skipped, so a failed run
# resumes; delete work/<pal>/ to start a pal over. Needs: scripts/setup_tools.sh run once,
# Blender (BLENDER=/path/to/Blender to override), and python3 with Pillow.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
APP_BIN=app/SekhPet/.build/release/SekhPet
LIBRARY="${SEKHPET_PETS:-$HOME/Library/Application Support/SekhPet/Pets}"
export DOTNET_CLI_HOME="$ROOT/.tools/dotnet-home" NUGET_PACKAGES="$ROOT/.tools/nuget" DOTNET_CLI_TELEMETRY_OPTOUT=1
CONVERTER=(.tools/dotnet/dotnet tools/converter/bin/Release/net10.0/Converter.dll)
MAPPINGS=.tools/Palworld-Mappings.usmap

[ $# -gt 0 ] || { sed -n '2,7p' "$0"; exit 2; }
[ -x .tools/dotnet/dotnet ] && [ -f "${CONVERTER[1]}" ] || { echo "Run scripts/setup_tools.sh first." >&2; exit 1; }
[ -x "$BLENDER" ] || { echo "Blender not found at $BLENDER; set BLENDER." >&2; exit 1; }
# The first Python with Pillow (the contact sheets need it).
PY=""
for candidate in python3 python3.13 python3.12 python3.11 python3.10; do
  command -v "$candidate" >/dev/null && "$candidate" -c 'import PIL' 2>/dev/null && { PY="$candidate"; break; }
done
[ -n "$PY" ] || { echo "No Python with Pillow found: python3 -m pip install Pillow" >&2; exit 1; }
[ -x "$APP_BIN" ] || swift build -c release --package-path app/SekhPet

make_one() {
  local ZIP="$1"
  local PAL ANIMS
  if [ "${ZIP%.zip}" = "$ZIP" ]; then
    # A pal name: re-run it from its work folder.
    local MANIFEST="work/$(echo "$ZIP" | tr '[:upper:]' '[:lower:]')/manifest.json"
    [ -f "$MANIFEST" ] || { echo "$ZIP: no $MANIFEST; give its extract zip instead" >&2; return 1; }
    read -r PAL ANIMS < <("$PY" -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["pal"], m["animSet"])' "$MANIFEST")
  else
    read -r PAL ANIMS < <("$PY" -c 'import json,sys,zipfile; m=json.loads(zipfile.ZipFile(sys.argv[1]).read("manifest.json")); print(m["pal"], m["animSet"])' "$ZIP") \
      || { echo "$ZIP isn't an extract_pal.py zip" >&2; return 1; }
  fi
  local LOWER BASE ARGS
  LOWER="$(echo "$PAL" | tr '[:upper:]' '[:lower:]')"
  BASE="work/$LOWER"
  ARGS=(--pal "$PAL")
  [ "$ANIMS" != "$PAL" ] && ARGS+=(--anims "$ANIMS")
  step() { echo "== $PAL: $*"; }
  blender() { "$BLENDER" --background "$@" 2>&1; }

  if [ ! -f "$BASE/manifest.json" ]; then
    step unpack and verify
    mkdir -p "$BASE" work/tables
    "$PY" - "$ZIP" "$BASE" <<'EOF' || return 1
import hashlib, json, sys, zipfile
from pathlib import Path
bundle, base = zipfile.ZipFile(sys.argv[1]), Path(sys.argv[2])
manifest = json.loads(bundle.read('manifest.json'))
for item in bundle.namelist():
    if item.startswith('raw/'):
        bundle.extract(item, base)
    elif item.startswith('tables/') or item == 'paklist.txt':
        bundle.extract(item, base.parent / 'tables')  # shared by all pals; newest wins
for path, digest in manifest['files'].items():
    assert hashlib.sha256((base / 'raw' / path).read_bytes()).hexdigest() == digest, f'{path} is damaged'
(base / 'manifest.json').write_text(json.dumps(manifest, indent=1))
print(f"verified {len(manifest['files'])} files")
EOF
    rm -f work/tables/tables.json
  fi

  if [ ! -f work/tables/tables.json ]; then
    step decode game tables
    "${CONVERTER[@]}" work/tables/tables work/tables/tables.json "$MAPPINGS" --inspect \
      Pal/Content/Pal/DataTable/Character/DT_PalMonsterParameter.uasset \
      Pal/Content/L10N/en/Pal/DataTable/Text/DT_PalNameText_Common.uasset | tail -1
    "$PY" scripts/index_paldeck.py || return 1
  fi

  if [ ! -f "$BASE/converted/conversion-report.json" ]; then
    step convert
    "${CONVERTER[@]}" "$BASE/raw" "$BASE/converted" "$MAPPINGS" "$PAL" "$ANIMS" | tail -1
  fi

  if [ ! -f "$BASE/blender/$PAL.blend" ]; then
    step blender import
    blender --factory-startup --python-exit-code 1 --python scripts/build_blender.py -- "${ARGS[@]}" \
      | grep -E "BLENDER_IMPORT_OK|Error|Traceback"
    [ -f "$BASE/blender/$PAL.blend" ] || { echo "Blender import failed" >&2; return 1; }
  fi

  if [ ! -f "$BASE/probe.json" ]; then
    step probe
    blender "$BASE/blender/$PAL.blend" --python-exit-code 1 --python scripts/probe_pal.py -- "${ARGS[@]}" \
      | grep -E "PROBE_OK|Error|Traceback"
  fi

  export_pack() {
    "$PY" scripts/make_pal_config.py "$PAL" "${ARGS[@]:2}" || return 1
    blender "$BASE/blender/$PAL.blend" --python-exit-code 1 --python scripts/export_realtime.py -- "${ARGS[@]}" \
      | grep -E "^wrote|^FIT|^texture|WARNING|rejected|Error|Traceback"
  }
  step configure and export
  export_pack || return 1
  # Clips still far too big after fitting are dropped and the pack re-exported until it settles.
  for _ in 1 2 3; do
    "$PY" scripts/check_pack.py "$PAL" --bounds-only && break
    step re-export after dropping oversized clips
    export_pack || return 1
  done

  step behavior check
  "$PY" scripts/check_pack.py "$PAL" || return 1

  step install
  local PACK="$BASE/realtime"
  if [ ! -f "$PACK/thumbnail.png" ] || [ "$PACK/clips.json" -nt "$PACK/thumbnail.png" ]; then
    SEKHPET_ASSETS="$PACK" "$APP_BIN" --icon "$PACK/thumbnail.png" --pet "$PAL" >/dev/null
    sips -Z 256 "$PACK/thumbnail.png" >/dev/null
  fi
  mkdir -p "$LIBRARY"
  rsync -a --delete "$PACK/" "$LIBRARY/$LOWER/"
  echo "== $PAL: installed. Review $BASE/check-sheet.png, then turn it on in the Pets window."
}

FAILED=0
for ZIP in "$@"; do
  make_one "$ZIP" || { echo "== FAILED: $ZIP" >&2; FAILED=$((FAILED + 1)); }
done
[ "$FAILED" = 0 ] || { echo "$FAILED of $# failed" >&2; exit 1; }
