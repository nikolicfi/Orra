#!/bin/bash
# Builds Orra.app with the Xcode project (so the app icon + menu bar icon asset catalog are compiled in).
set -e
pkill -x Orra 2>/dev/null || true   # make sure the old build is not still running
cd "$(dirname "$0")/.."
xcodebuild -project Orra.xcodeproj -scheme Orra -configuration Release \
  -derivedDataPath build/DerivedData CONFIGURATION_BUILD_DIR="$PWD/build" build | tail -n 5
echo "Built build/Orra.app"
