#!/bin/bash
# One-step build: ./Scripts/make-dmg.sh   ->   build/Orra.dmg
#
# Builds Orra.app (ad-hoc signed, no Apple Developer account needed), packs it into a
# drag-to-Applications installer with the background in Scripts/dmg/, and then CHECKS the
# result for your macOS username / home path so nothing personal ships.
# Needs macOS with Xcode. The first run may ask to let Terminal control Finder: click OK.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VOL="Orra"
OUT="$ROOT/build/Orra.dmg"

echo "==> Building Orra.app"
./Scripts/build.sh
APP="$ROOT/build/Orra.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }

# Fail early if the binary still carries local paths.
if strings -a "$APP/Contents/MacOS/Orra" | grep -qF "/Users/"; then
  echo "ERROR: the app binary still contains a /Users/... path. Not packaging it."
  strings -a "$APP/Contents/MacOS/Orra" | grep -F "/Users/" | head -3
  exit 1
fi

# Work in a neutral temp folder: Finder records the image's location in the installer's
# window settings, so it must not live under your home folder.
WORK="$(mktemp -d /private/tmp/orra-dmg.XXXXXX)"
trap 'hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "==> Staging installer"
mkdir -p "$WORK/stage/.background"
cp -R "$APP" "$WORK/stage/Orra.app"
ln -s /Applications "$WORK/stage/Applications"
# multi-resolution (Retina) background from the 1x and 2x images
tiffutil -cathidpicheck "$ROOT/Scripts/dmg/background.png" "$ROOT/Scripts/dmg/background@2x.png" \
  -out "$WORK/stage/.background/background.tiff"

hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
hdiutil create -srcfolder "$WORK/stage" -volname "$VOL" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -mountpoint "/Volumes/$VOL" >/dev/null

echo "==> Laying out the installer window"
chflags hidden "/Volumes/$VOL/.background"
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 588}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "Orra.app" of container window to {175, 243}
    set position of item "Applications" of container window to {485, 243}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
sync; sleep 2
hdiutil detach "/Volumes/$VOL" >/dev/null

echo "==> Compressing"
mkdir -p "$ROOT/build"
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

echo "==> Privacy check"
hdiutil attach "$OUT" -readonly -nobrowse -noverify -mountpoint "/Volumes/$VOL" >/dev/null
BAD=0
if strings -a "/Volumes/$VOL/Orra.app/Contents/MacOS/Orra" | grep -qE "/Users/|$USER"; then BAD=1; echo "  found your username/home path in the app binary"; fi
if [ -f "/Volumes/$VOL/.DS_Store" ] && strings -a "/Volumes/$VOL/.DS_Store" | grep -qE "/Users/|Users:|$USER"; then BAD=1; echo "  found your username/home path in the installer layout"; fi
hdiutil detach "/Volumes/$VOL" >/dev/null
[ "$BAD" -eq 0 ] || { echo "Privacy check FAILED - do not publish $OUT"; exit 1; }
echo "  clean."

echo
echo "Done: $OUT"
shasum -a 256 "$OUT"
