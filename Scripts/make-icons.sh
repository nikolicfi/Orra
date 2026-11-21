#!/bin/bash
# Usage: ./Scripts/make-icons.sh path/to/icon-1024.png
# Generates every size the app icon needs from ONE square PNG (1024x1024 recommended)
# and fills Resources/Assets.xcassets/AppIcon.appiconset. Needs macOS (uses sips).
set -e
SRC="$1"
[ -f "$SRC" ] || { echo "Usage: $0 icon-1024.png"; exit 1; }
cd "$(dirname "$0")/.."
SET=Resources/Assets.xcassets/AppIcon.appiconset
mkdir -p "$SET"
rm -f "$SET"/*.png
JSON='{
  "images" : ['
first=1
for base in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((base * scale))
    name="icon_${base}x${base}@${scale}x.png"
    sips -z $px $px "$SRC" --out "$SET/$name" >/dev/null
    [ $first -eq 1 ] || JSON+=','
    first=0
    JSON+="
    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${base}x${base}\" }"
  done
done
JSON+='
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}'
echo "$JSON" > "$SET/Contents.json"
echo "App icon updated. Rebuild in Xcode (Cmd+B)."
