# Orra
Music player + clock on the macOS lock screen (Canopy/Alcove style).

## Build & run (macOS 14+, Xcode 26 recommended for Liquid Glass)
Open `Orra.xcodeproj` in Xcode and press Cmd+R (always open the `.xcodeproj`, not the folder),
or from Terminal:

    ./Scripts/build.sh
    open build/Orra.app

1. Menu bar icon -> "Preview (8 s)" to test without locking.
2. Play something in Music or Spotify, approve the Automation prompt.
3. Lock with Ctrl+Cmd+Q.

Modes: Compact card, or Full-screen artwork.

Defaults on first launch: opacity 30 %, dimming 0.1, blur 20 %.

## Icons
- **App icon**: `Resources/Assets.xcassets` -> `AppIcon`. Or run `./Scripts/make-icons.sh my-icon-1024.png`
  (one square PNG, makes all sizes).
- **Menu bar icon**: `Resources/Assets.xcassets` -> `StatusBarIcon` (black shape on transparent background;
  template image, adapts to light/dark).

## Notes
- Uses private SkyLight APIs (not App Store safe, may break on macOS updates).
- Now-playing via AppleScript (Music, Spotify). Not MediaRemote – blocked for third parties since macOS 15.4.

© nikolicfi
