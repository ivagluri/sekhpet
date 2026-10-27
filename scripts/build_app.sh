#!/bin/bash
# Build SekhPet.app: a menu-bar-only (LSUIElement) app. It ships without pets; they live
# in ~/Library/Application Support/SekhPet/Pets/<name>/ (sources/palworld/make_pet.sh installs them).
#   bash scripts/build_app.sh                    build app/build/SekhPet.app
#   bash scripts/build_app.sh --install          also replace /Applications/SekhPet.app
#   bash scripts/build_app.sh --icon AppIcon.icns  use your own app icon (optional; kept for later builds)
#   bash scripts/build_app.sh --icon-pet KingWhale  render the app icon from an installed pet
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app/SekhPet"
APP="$ROOT/app/build/SekhPet.app"
INSTALL=0
ICON=""
ICON_PET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --icon) ICON="$2"; shift ;;
    --icon-pet) ICON_PET="$2"; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

swift build -c release --package-path "$PKG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/.build/release/SekhPet" "$APP/Contents/MacOS/SekhPet"
if [ -n "$ICON_PET" ]; then
  # A head-and-shoulders render of the pet on a tile in its colours; kept in app/build/.
  TMP="$(mktemp -d)"
  "$PKG/.build/release/SekhPet" --icon "$TMP/render.png" --pet "$ICON_PET" >/dev/null
  python3 "$ROOT/scripts/make_icon.py" "$TMP/render.png" "$ROOT/app/build/AppIcon.icns" >/dev/null
  rm -rf "$TMP"
  ICON="$ROOT/app/build/AppIcon.icns"
fi
# The icon given last is kept in app/build/AppIcon.icns, so a plain rebuild doesn't drop it.
KEPT="$ROOT/app/build/AppIcon.icns"
[ -n "$ICON" ] && [ "$ICON" != "$KEPT" ] && cp "$ICON" "$KEPT"
[ -f "$KEPT" ] && cp "$KEPT" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.sekhpet</string>
  <key>CFBundleName</key><string>SekhPet</string>
  <key>CFBundleExecutable</key><string>SekhPet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  # Quit any running copy, then swap in the new bundle.
  pkill -x SekhPet && sleep 1 || true
  rm -rf /Applications/SekhPet.app
  ditto "$APP" /Applications/SekhPet.app
  echo "Installed /Applications/SekhPet.app"
fi
