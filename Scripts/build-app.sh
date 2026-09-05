#!/bin/bash
# Assembles SpaceSwitch.app from the SwiftPM products.
#
# The helper is embedded rather than installed separately so SMAppService can
# register it: a daemon must ship inside the bundle that vouches for it.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.1.0)}"
CONFIG="${CONFIG:-release}"
BUNDLE_ID="com.bisak.spaceswitch"
HELPER_ID="$BUNDLE_ID.helper"
OUT="${OUT:-build}"
APP="$OUT/SpaceSwitch.app"

echo "Building $CONFIG…"
swift build -c "$CONFIG" --product SpaceSwitchApp
swift build -c "$CONFIG" --product spaceswitchd
swift build -c "$CONFIG" --product spaceswitch
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"

cp "$BIN/SpaceSwitchApp" "$APP/Contents/MacOS/SpaceSwitch"
cp "$BIN/spaceswitchd"   "$APP/Contents/MacOS/spaceswitchd"
# Contents/MacOS is case-insensitive on APFS, where "spaceswitch" and the
# bundle executable "SpaceSwitch" are the same path.
cp "$BIN/spaceswitch"    "$APP/Contents/Helpers/spaceswitch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>SpaceSwitch</string>
    <key>CFBundleDisplayName</key>       <string>SpaceSwitch</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>SpaceSwitch</string>
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

cat > "$APP/Contents/Library/LaunchDaemons/$HELPER_ID.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>          <string>$HELPER_ID</string>
    <key>BundleProgram</key>  <string>Contents/MacOS/spaceswitchd</string>
    <key>RunAtLoad</key>      <true/>
    <key>KeepAlive</key>      <true/>
    <key>ProcessType</key>    <string>Background</string>
    <key>AssociatedBundleIdentifiers</key>
    <array><string>$BUNDLE_ID</string></array>
</dict>
</plist>
PLIST

SIGN_ID="${SIGN_ID:--}"
echo "Signing with identity: $SIGN_ID"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/spaceswitchd"
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
