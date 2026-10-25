#!/bin/bash
# One-time setup on the Mac: downloads .NET, the pinned CUE4Parse and UEFormat sources,
# and the Palworld type mappings into .tools/, then builds sources/palworld/converter.
#   bash sources/palworld/setup_tools.sh
# Versions and checksums are pinned in sources/palworld/tool-versions.json.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$TASK_ROOT"
mkdir -p .tools
if [ ! -x .tools/dotnet/dotnet ]; then
  curl -fL https://dot.net/v1/dotnet-install.sh -o .tools/dotnet-install.sh
  ARCH=$([ "$(uname -m)" = arm64 ] && echo arm64 || echo x64)
  bash .tools/dotnet-install.sh --version 10.0.402 --architecture "$ARCH" --install-dir .tools/dotnet --no-path
fi
fetch_repo() {
  local url="$1" target="$2" revision="$3"
  if [ ! -d "$target/.git" ]; then
    git clone --filter=blob:none "$url" "$target"
    git -C "$target" checkout --detach "$revision"
  fi
  if [ "$(git -C "$target" rev-parse HEAD)" != "$revision" ]; then
    echo "Unexpected source revision in $target; preserve local changes and review sources/palworld/tool-versions.json." >&2
    exit 1
  fi
}
fetch_repo https://github.com/FabianFG/CUE4Parse.git .tools/CUE4Parse 6f7b06eefa22f3cc259d03bb9901a384cb4fb538
git -C .tools/CUE4Parse submodule update --init --depth 1
git -C .tools/CUE4Parse/CUE4Parse-Natives/ACL/external/acl submodule update --init --depth 1 external/rtm
fetch_repo https://github.com/h4lfheart/UEFormat.git .tools/UEFormat d858fe38b2b5b8c63ac4b7481b4386ebfabbf935
if [ ! -f .tools/Palworld-Mappings.usmap ]; then
  curl -fL https://raw.githubusercontent.com/PalworldModding/UsefulFiles/acdf1a6a6076f84fae3275e7c1cdd08188994da8/Mappings.usmap -o .tools/Palworld-Mappings.usmap
fi
python3 - <<'PY'
import hashlib,json
from pathlib import Path
lock=json.loads(Path('sources/palworld/tool-versions.json').read_text())
assert hashlib.sha256(Path('.tools/Palworld-Mappings.usmap').read_bytes()).hexdigest()==lock['palworld_mappings_sha256'], 'Mapping checksum mismatch'
PY
python3 sources/palworld/prepare_converter.py
export DOTNET_CLI_HOME="$TASK_ROOT/.tools/dotnet-home" NUGET_PACKAGES="$TASK_ROOT/.tools/nuget"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_GENERATE_ASPNET_CERTIFICATE=false
.tools/dotnet/dotnet build sources/palworld/converter/Converter.csproj -c Release -clp:ErrorsOnly
echo "Tools ready."
