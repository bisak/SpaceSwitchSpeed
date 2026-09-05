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
ICON="Resources/AppIcon.icns"

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(Scripts/toolchain.sh sdk)}"
echo "Building $CONFIG with SDK $(xcrun --show-sdk-version) from $DEVELOPER_DIR…"

swift build -c "$CONFIG" --product SpaceSwitchApp
swift build -c "$CONFIG" --product spaceswitch
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# The icon is generated rather than committed, so a fresh checkout builds one.
if [ ! -f "$ICON" ] || [ Scripts/make-icon.swift -nt "$ICON" ]; then
    echo "Rendering $ICON…"
    swift Scripts/make-icon.swift
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN/SpaceSwitchApp" "$APP/Contents/MacOS/SpaceSwitch"
# Contents/MacOS is case-insensitive on APFS, where "spaceswitch" and the
# bundle executable "SpaceSwitch" are the same path.
cp "$BIN/spaceswitch" "$APP/Contents/Helpers/spaceswitch"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
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
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Helpers/spaceswitch"
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$APP"

# Contents/MacOS lives on a case-insensitive filesystem, so a helper whose name
# differs from the bundle executable only by case would silently replace it.
for f in "$APP/Contents/MacOS/"*; do
    name="$(basename "$f")"
    if [ "$name" != "SpaceSwitch" ] && [ "$(echo "$name" | tr '[:upper:]' '[:lower:]')" = "spaceswitch" ]; then
        echo "error: $name collides with the bundle executable on a case-insensitive filesystem" >&2
        exit 1
    fi
done
test -x "$APP/Contents/Helpers/spaceswitch" || {
    echo "error: CLI missing from bundle" >&2
    exit 1
}

echo "Built $APP ($VERSION, signed with '$SIGN_ID')"
