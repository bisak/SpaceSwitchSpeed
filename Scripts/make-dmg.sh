#!/bin/bash
# Packages a built SpaceSwitchSpeed.app as the disk image people download.
# Run with: Scripts/make-dmg.sh <app> <version> <output.dmg>
#
# A disk image's window is a Finder icon view, and the only place its
# appearance can be recorded is the .DS_Store of the volume itself, which only
# Finder writes. So this mounts a writable image, has Finder lay the window out
# on it, and then converts that volume to the compressed, read-only image that
# ships. Everything Finder is told here is paired with the artwork behind it:
# the icon positions are the ones docs/images/dmg-background.pdf draws its
# arrow between.

set -euo pipefail

app=$1
version=$2
output=$3
volume="SpaceSwitchSpeed $version"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
stage=$(dirname "$output")/dmg-stage
writable=$(dirname "$output")/dmg-rw.dmg

[ -d "$app" ] || { echo "no app at $app — run make app first" >&2; exit 1; }

# Whatever goes wrong below, do not leave a volume mounted or a staging tree
# behind for the next run to trip over.
mounted=""
cleanup() {
	[ -n "$mounted" ] && hdiutil detach "$mounted" -force -quiet 2>/dev/null
	rm -rf "$stage" "$writable"
}
trap cleanup EXIT

# An earlier run left mounted would take the volume name and Finder would then
# be laying out the wrong window.
hdiutil detach "/Volumes/$volume" -force -quiet 2>/dev/null || true
rm -rf "$stage" "$writable" "$output"
mkdir -p "$stage/.background"

ditto "$app" "$stage/$(basename "$app")"
ln -s /Applications "$stage/Applications"
cp "$root/docs/images/dmg-background.pdf" "$stage/.background/background.pdf"
cp "$app/Contents/Resources/AppIcon.icns" "$stage/.VolumeIcon.icns"

size=$(($(du -sm "$stage" | cut -f1) + 32))
hdiutil create -quiet -srcfolder "$stage" -volname "$volume" -fs HFS+ \
	-format UDRW -size "${size}m" "$writable"
mounted=$(hdiutil attach "$writable" -readwrite -noverify -noautoopen -nobrowse \
	| sed -n 's|.*\(/Volumes/.*\)$|\1|p' | head -1)
# If something else still holds the name, macOS mounts this one beside it as
# "<volume> 1" and the layout below would be applied to the other volume.
[ "$mounted" = "/Volumes/$volume" ] || {
	echo "mounted at $mounted rather than /Volumes/$volume: another volume is" >&2
	echo "holding that name. Eject it and build again." >&2
	exit 1
}

tucked=$(osascript - "$volume" <<'APPLESCRIPT'
on run argv
	set volumeName to item 1 of argv
	tell application "Finder"
		tell disk volumeName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			-- Finder's bounds are the whole window: the content the picture is
			-- drawn into is this less the title bar, so the height asked for is
			-- the artwork's plus a title bar's worth.
			set the bounds of container window to {320, 160, 960, 588}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set label position of viewOptions to bottom
			set shows item info of viewOptions to false
			set shows icon preview of viewOptions to false
			set background picture of viewOptions to file ".background:background.pdf"
			-- The picture only appears on a window opened after it was set, and
			-- reopening re-runs Finder's layout, which snaps the icons to its
			-- grid. So the positions are set last, on the window that is left.
			close
			open
			set position of item "SpaceSwitchSpeed.app" of container window to {168, 224}
			set position of item "Applications" of container window to {472, 224}
			-- Anyone browsing with hidden items shown sees the picture and the
			-- volume icon sitting on top of the artwork, which is what has
			-- happened to every disk image that never gave them a position. Put
			-- them below the window. Finder will only take a position for an
			-- item it is displaying, so this needs hidden items shown here too.
			set tuckedAway to "no"
			try
				set position of item ".background" of container window to {120, 700}
				set position of item ".VolumeIcon.icns" of container window to {400, 700}
				set tuckedAway to "yes"
			end try
			-- Positioning an item selects it, and the selection is kept along
			-- with everything else, so the window would open with the app
			-- already highlighted.
			tell application "Finder" to set selection to {}
			delay 1
			close
			return tuckedAway
		end tell
	end tell
end run
APPLESCRIPT
)

# The volume shows the app's icon rather than a blank disk, and neither the
# picture nor that icon is something to browse.
SetFile -a C "/Volumes/$volume"
SetFile -a V "/Volumes/$volume/.background" "/Volumes/$volume/.VolumeIcon.icns"

sync
hdiutil detach "$mounted" -quiet
mounted=""
hdiutil convert "$writable" -quiet -format UDZO -imagekey zlib-level=9 -o "$output"

if [ "$tucked" != "yes" ]; then
	echo "note: Finder would not place the hidden items, so they will land on" >&2
	echo "      the artwork for anyone browsing with hidden items shown." >&2
	echo "      Turn those on here (shift-command-.) and build again to fix it." >&2
fi
