#!/bin/bash
# Assembles SpaceSwitch.app from the SwiftPM products.
#
# The command line tool doubles as the background job, so the bundle carries one
# binary for the window and one for everything else.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.bisak.spaceswitch"
OUT="${OUT:-build}"
APP="$OUT/SpaceSwitch.app"

# macOS decides which control appearance an app gets from the SDK it was linked
# against, so building with an SDK older than the running system makes a native
# app look a release behind. The newest SDK is often in the Command Line Tools
# rather than in whatever `xcode-select` points at.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    best_dir=""; best_sdk=0
    for dir in "$(xcode-select -p 2>/dev/null)" /Library/Developer/CommandLineTools \
               /Applications/Xcode*.app/Contents/Developer; do
        [ -d "$dir" ] || continue
        sdk="$(DEVELOPER_DIR="$dir" xcrun --show-sdk-version 2>/dev/null | cut -d. -f1)"
        case "$sdk" in ''|*[!0-9]*) continue ;; esac
        if [ "$sdk" -gt "$best_sdk" ]; then best_sdk="$sdk"; best_dir="$dir"; fi
    done
    [ -n "$best_dir" ] && export DEVELOPER_DIR="$best_dir"

    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$best_sdk" -lt "$os_major" ]; then
        echo "warning: newest macOS SDK is $best_sdk but this system is $os_major;" >&2
        echo "         the app will be drawn with older system controls." >&2
    fi
fi
echo "Building $CONFIG with SDK $(xcrun --show-sdk-version) from ${DEVELOPER_DIR:-$(xcode-select -p)}…"

swift build -c "$CONFIG" --product SpaceSwitchApp
swift build -c "$CONFIG" --product spaceswitch
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/SpaceSwitchApp" "$APP/Contents/MacOS/SpaceSwitch"
# Contents/MacOS is case-insensitive on APFS, where "spaceswitch" and the
# bundle executable "SpaceSwitch" are the same path.
cp "$BIN/spaceswitch"    "$APP/Contents/Helpers/spaceswitch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>SpaceSwitch</string>
    <key>CFBundleDisplayName</key>       <string>SpaceSwitch</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>SpaceSwitch</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION#v}</string>
    <key>CFBundleVersion</key>           <string>${VERSION#v}</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>Copyright © 2026 Biser Atanasov. AGPL-3.0-or-later. No warranty.</string>
</dict>
</plist>
PLIST

SIGN_ID="${SIGN_ID:--}"
echo "Signing with identity: $SIGN_ID"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Helpers/spaceswitch"
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$APP"

# Contents/MacOS lives on a case-insensitive filesystem, so a helper whose name
# differs from the bundle executable only by case would silently replace it.
for f in "$APP/Contents/MacOS/"*; do
    name="$(basename "$f")"
    lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    if [ "$name" != "SpaceSwitch" ] && [ "$lower" = "spaceswitch" ]; then
        echo "error: $name collides with the bundle executable on a case-insensitive filesystem" >&2
        exit 1
    fi
done
test -x "$APP/Contents/Helpers/spaceswitch" || { echo "error: CLI missing from bundle" >&2; exit 1; }

echo "Built $APP ($VERSION)"
