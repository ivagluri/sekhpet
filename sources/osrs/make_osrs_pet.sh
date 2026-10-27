#!/bin/bash
# Turn an OSRS character into an installed pet, from the game cache RuneLite keeps
# (~/.runelite/jagexcache/oldschool/LIVE; OSRS_CACHE overrides it).
#   bash sources/osrs/make_osrs_pet.sh <npc name> [--id N] [--redraft]    e.g. "Wise Old Man"
#   bash sources/osrs/make_osrs_pet.sh --player <name>                    start a player character
# The first run drafts characters/<name>/ (see sources/osrs/README.md); edit it and run again.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
[ $# -ge 1 ] || { sed -n '2,6p' "$0"; exit 2; }
TOOLS=.tools/osrs
VERSIONS=sources/osrs/tool-versions.json
pin() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$VERSIONS" "$1"; }
fetch() {  # url file sha256
  [ -f "$2" ] && [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ] && return 0
  echo "== fetching $(basename "$2")"
  curl -sfL "$1" -o "$2.part" || { echo "Download failed: $1" >&2; exit 1; }
  [ "$(shasum -a 256 "$2.part" | cut -d' ' -f1)" = "$3" ] || { echo "Checksum mismatch: $1" >&2; rm -f "$2.part"; exit 1; }
  mv "$2.part" "$2"
}
mkdir -p "$TOOLS"
fetch "https://raw.githubusercontent.com/runelite/runelite/$(pin runelite_commit)/runelite-api/src/main/java/net/runelite/api/gameval/AnimationID.java" \
  "$TOOLS/AnimationID.java" "$(pin animation_ids_sha256)"
fetch "https://raw.githubusercontent.com/equirs/fashionscape-data/$(pin fashionscape_data_commit)/anims.json" \
  "$TOOLS/weapon-idles.json" "$(pin weapon_idles_sha256)"

set +e
OUT=$(cd sources/osrs && python3 draft.py "$@")
RC=$?
set -e
echo "$OUT" | grep -v '^FOLDER '
[ $RC -eq 3 ] && exit 0      # a new player's outfit.txt was written: fill it in first
[ $RC -eq 0 ] || exit $RC
SPEC=$(echo "$OUT" | sed -n 's/^FOLDER //p')

echo "== $(basename "$SPEC"): model and clips from the cache"
(cd sources/osrs && python3 export_glb.py "$SPEC")
bash sources/rigged/make_rigged_pet.sh "$SPEC"
