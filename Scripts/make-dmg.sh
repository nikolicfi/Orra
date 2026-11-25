#!/bin/bash
# One-step build: ./Scripts/make-dmg.sh   ->   build/Orra.dmg
#
# Builds Orra.app (ad-hoc signed, no Apple Developer account needed), packs it into a
# drag-to-Applications installer with the background in Scripts/dmg/, and then CHECKS every
# file in the result for your macOS username / home path so nothing personal ships.
# Needs macOS with Xcode. The first run may ask to let Terminal control Finder: click OK.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
VOL="Orra"
OUT="$ROOT/build/Orra.dmg"

# Everything is built and packed in neutral folders under /private/tmp, so no path under
# your home folder can end up in the app or in the installer's window settings.
BUILD_SRC="$(mktemp -d /private/tmp/orra-build.XXXXXX)"
WORK="$(mktemp -d /private/tmp/orra-dmg.XXXXXX)"
trap 'hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true; rm -rf "$BUILD_SRC" "$WORK"' EXIT

echo "==> Building Orra.app (in a neutral folder)"
rsync -a --exclude .git --exclude build ./ "$BUILD_SRC/"
( cd "$BUILD_SRC" && ./Scripts/build.sh )
APP="$BUILD_SRC/build/Orra.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found"; exit 1; }

# Remove debug symbols (they record the Swift module path), then re-sign: macOS refuses to
# run a modified binary whose signature is no longer valid.
strip -S "$APP/Contents/MacOS/Orra"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

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

echo "==> Privacy check (every file in the finished installer)"
hdiutil attach "$OUT" -readonly -nobrowse -noverify -mountpoint "/Volumes/$VOL" >/dev/null
HITS="$(grep -rlaF -e "/Users/" -e "Users:" -e "$USER" "/Volumes/$VOL" 2>/dev/null || true)"
hdiutil detach "/Volumes/$VOL" >/dev/null
if [ -n "$HITS" ]; then
  echo "Privacy check FAILED - these files contain your username or home path:"
  echo "$HITS"
  echo "Do NOT publish $OUT"
  exit 1
fi
echo "  clean."

echo
echo "Done: $OUT"
shasum -a 256 "$OUT"
