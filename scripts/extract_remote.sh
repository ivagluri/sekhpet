#!/bin/bash
# Extract pals on the machine with the game over SSH, then build them here. For a
# setup where the game is on a Linux box you can reach with key-based SSH.
#   bash scripts/extract_remote.sh <host> <Pal> [more pals...]
#   PAK=/path/to/Pal-Windows.pak bash scripts/extract_remote.sh <host> <Pal>   (non-Steam install)
#   EXTRACT_ONLY=1 bash scripts/extract_remote.sh <host> <Pal>                 (zips only, no build)
# Zips land in work/zips/. extract_pal.py and its repak download stay in the remote
# ~/.cache/sekhpet-extract/ between runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ $# -ge 2 ] || { sed -n '2,8p' "$0"; exit 2; }
HOST="$1"
shift
REMOTE=.cache/sekhpet-extract
SSH=(ssh -n -o BatchMode=yes "$HOST")   # -n: ssh must not read this script's stdin
mkdir -p work/zips
"${SSH[@]}" "mkdir -p $REMOTE"
scp -q -o BatchMode=yes scripts/extract_pal.py "$HOST:$REMOTE/extract_pal.py"
ZIPS=()
for PAL in "$@"; do
  echo "== $PAL: extract on $HOST"
  "${SSH[@]}" "cd $REMOTE && python3 extract_pal.py '$PAL' ${PAK:+--pak '$PAK'}" | tail -1
  scp -q -o BatchMode=yes "$HOST:$REMOTE/$PAL-extract.zip" work/zips/
  "${SSH[@]}" "rm -f '$REMOTE/$PAL-extract.zip'"
  ZIPS+=("work/zips/$PAL-extract.zip")
done
[ -n "${EXTRACT_ONLY:-}" ] || bash scripts/make_pet.sh "${ZIPS[@]}"
