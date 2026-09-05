#!/bin/bash
#
# Apply a Space-switch speed to the RUNNING Dock, without touching disk.
#
# spaceswitch.py works out which bytes to write; this script attaches to Dock
# and writes them into memory. Dock keeps its Apple signature, its private
# entitlements and the sealed system volume stay untouched, and `killall Dock`
# or a reboot restores stock behaviour.
#
# Requires System Integrity Protection to be disabled, because a debugger
# cannot otherwise attach to a platform binary.
#
#   sudo bash spaceswitch-runtime.sh 0      # instant
#   sudo bash spaceswitch-runtime.sh 0.5    # half as long
#   sudo bash spaceswitch-runtime.sh 1      # back to stock

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/spaceswitch.py"
SPEED="${1:-}"

if [[ -z "$SPEED" ]]; then
    echo "usage: sudo bash $(basename "$0") <speed 0..1>" >&2
    echo "       1 = stock macOS, 0 = instant" >&2
    exit 2
fi

if [[ ! -f "$TOOL" ]]; then
    echo "spaceswitch.py not found next to this script." >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run this with sudo." >&2
    exit 1
fi

if csrutil status | grep -q "status: enabled"; then
    echo "System Integrity Protection is enabled, so a debugger cannot attach to Dock." >&2
    echo "Disable it from Recovery first, or patch the file with spaceswitch.py." >&2
    exit 1
fi

DOCK_PID="$(pgrep -x Dock | head -1)"
if [[ -z "$DOCK_PID" ]]; then
    echo "Dock is not running." >&2
    exit 1
fi

# Human-readable summary, then the machine-readable plan.
python3 "$TOOL" --speed "$SPEED"
PLAN="$(python3 "$TOOL" --speed "$SPEED" --emit-lldb | grep '^WRITE ')"

if [[ -z "$PLAN" ]]; then
    echo "Nothing to write." >&2
    exit 1
fi

echo
echo "Attaching to Dock (pid $DOCK_PID)..."

lldb --batch \
     -o "process attach --pid $DOCK_PID" \
     -o "script
import lldb

plan = []
for line in '''$PLAN'''.strip().splitlines():
    _, off, hexbytes = line.split()
    plan.append((int(off, 16), bytes.fromhex(hexbytes)))

t = lldb.debugger.GetSelectedTarget()
p = t.GetProcess()

mod = None
for m in t.module_iter():
    if m.GetFileSpec().GetFilename() == 'Dock':
        mod = m
        break
if mod is None:
    raise SystemExit('Dock module not found')

base = mod.FindSection('__TEXT').GetLoadAddress(t)
err = lldb.SBError()
done = 0
for off, blob in plan:
    addr = base + off
    n = p.WriteMemory(addr, blob, err)
    if not err.Success() or n != len(blob):
        print('  FAILED at 0x%x: %s' % (addr, err))
        continue
    print('  wrote %d bytes at 0x%x' % (n, addr))
    done += 1
print('%d of %d writes applied' % (done, len(plan)))
" \
     -o "detach" \
     -o "quit"

echo
echo "Try a three-finger swipe or Control+Arrow."
echo "Restore stock with: killall Dock"
