#!/bin/bash
# Space Switch Speed — speed control for the macOS Space-switch animation.
# Copyright (C) 2026 Biser Atanasov. Licensed under AGPL-3.0-or-later.
# See LICENSE. This program comes with ABSOLUTELY NO WARRANTY.
#
# Extracts one macOS release's Dock binary from Apple's public restore image, so
# `dock-check` can be pointed at a release this Mac is not running.
#
#     Scripts/fetch-dock.sh 15.0
#     Scripts/fetch-dock.sh https://updates.cdn-apple.com/.../UniversalMac_..._Restore.ipsw
#
# Only the system image is downloaded, not the whole restore file, and it is
# mounted read-only and detached again. Nothing is installed and the host system
# is never written to.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $(basename "$0") <macOS version | ipsw url>" >&2; exit 2; }
command -v aea >/dev/null || { echo "this needs macOS 15 or later for /usr/bin/aea" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/build/docks"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dock-fetch.XXXXXX")
MNT="$WORK/mnt"
mkdir -p "$OUT" "$MNT"

cleanup() {
  for volume in "$MNT"/*; do
    [ -d "$volume" ] && hdiutil detach -quiet -force "$volume" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

URL="$1"
if [[ "$URL" != http* ]]; then
  echo "looking up macOS $1..."
  URL=$(curl -sSL --max-time 60 "https://api.ipsw.me/v4/device/Macmini9,1?type=ipsw" \
    | python3 -c "
import json, sys
want = sys.argv[1]
for f in json.load(sys.stdin)['firmwares']:
    if f['version'] == want:
        print(f['url']); break
else:
    sys.exit('no restore image published for macOS ' + want)
" "$1")
fi

NAME=$(basename "$URL" .ipsw)
echo "$NAME"

# The restore file is a zip; read its directory and take only the system image.
read -r MEMBER OFFSET SIZE < <(python3 - "$URL" <<'PY'
import re, struct, subprocess, sys

url = sys.argv[1]

def fetch(first, last):
    return subprocess.run(["curl", "-sS", "--max-time", "180", "-r", f"{first}-{last}", url],
                          capture_output=True, check=True).stdout

head = subprocess.run(["curl", "-sSI", "--max-time", "60", url],
                      capture_output=True, check=True).stdout.decode("utf-8", "replace")
total = int(re.search(r"(?i)content-length:\s*(\d+)", head).group(1))

tail = fetch(max(0, total - 70000), total - 1)
end = tail.rfind(b"PK\x05\x06")
size, offset = struct.unpack_from("<II", tail, end + 12)
zip64 = tail.rfind(b"PK\x06\x06")
if zip64 >= 0:
    _, size, offset = struct.unpack_from("<QQQ", tail, zip64 + 32)

directory = fetch(offset, offset + size - 1)
best, position = None, 0
while position < len(directory) and directory[position:position + 4] == b"PK\x01\x02":
    compressed, uncompressed = struct.unpack_from("<II", directory, position + 20)
    name_len, extra_len, comment_len = struct.unpack_from("<HHH", directory, position + 28)
    local, = struct.unpack_from("<I", directory, position + 42)
    name = directory[position + 46:position + 46 + name_len].decode("utf-8", "replace")
    extra = directory[position + 46 + name_len:position + 46 + name_len + extra_len]
    cursor = 0
    while cursor + 4 <= len(extra):                      # zip64 sizes live in an extra field
        tag, field = struct.unpack_from("<HH", extra, cursor)
        if tag == 1:
            values, at = [], cursor + 4
            for current in (uncompressed, compressed, local):
                if current == 0xFFFFFFFF and at + 8 <= len(extra):
                    values.append(struct.unpack_from("<Q", extra, at)[0]); at += 8
                else:
                    values.append(current)
            _, compressed, local = values
        cursor += 4 + field
    if name.endswith((".dmg", ".dmg.aea")) and (best is None or compressed > best[1]):
        best = (name, compressed, local)
    position += 46 + name_len + extra_len + comment_len

if best is None:
    sys.exit("no system image in this restore file")
name, compressed, local = best
header = fetch(local, local + 29)
name_len, extra_len = struct.unpack_from("<HH", header, 26)
print(name, local + 30 + name_len + extra_len, compressed)
PY
)

printf 'downloading %s (%.1f GB of the restore file)\n' "$MEMBER" "$(echo "$SIZE / 1000000000" | bc -l)"
IMAGE="$WORK/system.dmg"
if [[ "$MEMBER" == *.aea ]]; then
  curl -sS --max-time 300 -r "$OFFSET-$((OFFSET + 65535))" -o "$WORK/prologue" "$URL"
  KEY=$(swift "$ROOT/Scripts/aea-key.swift" "$WORK/prologue")
  curl -sS --max-time 7200 -r "$OFFSET-$((OFFSET + SIZE - 1))" -o "$WORK/system.aea" "$URL"
  echo "decrypting..."
  aea decrypt -i "$WORK/system.aea" -o "$IMAGE" -key-value "base64:$KEY"
  rm -f "$WORK/system.aea"
else
  curl -sS --max-time 7200 -r "$OFFSET-$((OFFSET + SIZE - 1))" -o "$IMAGE" "$URL"
fi

echo "mounting read-only..."
hdiutil attach "$IMAGE" -readonly -nobrowse -noverify -noautofsck -mountrandom "$MNT" >/dev/null

DOCK=$(find "$MNT" -type f -path "*/Dock.app/Contents/MacOS/Dock" 2>/dev/null | head -1)
[ -n "$DOCK" ] || { echo "no Dock in this image" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "$(dirname "$(dirname "$DOCK")")/Info.plist" 2>/dev/null || echo unknown)
DEST="$OUT/Dock-$(echo "$NAME" | sed -E 's/^UniversalMac_//; s/_Restore$//')"
cp "$DOCK" "$DEST"

echo "wrote $DEST (Dock $VERSION)"
echo "check it with: swift run dock-check $DEST"
