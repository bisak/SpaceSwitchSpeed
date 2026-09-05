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
# cannot otherwise attach to a platform binary. Root is not needed: Dock runs
# as you. If the attach is refused, try again under sudo.
#
#   bash spaceswitch-runtime.sh 0      # instant
#   bash spaceswitch-runtime.sh 0.5    # half as long
#   bash spaceswitch-runtime.sh 1      # back to stock

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/spaceswitch.py"
SPEED="${1:-}"

if [[ -z "$SPEED" ]]; then
    echo "usage: bash $(basename "$0") <speed 0..1>" >&2
    echo "       1 = stock macOS, 0 = instant" >&2
    exit 2
fi

if [[ ! -f "$TOOL" ]]; then
    echo "spaceswitch.py not found next to this script." >&2
    exit 1
fi

if csrutil status | grep -q "status: enabled"; then
    echo "System Integrity Protection is enabled, so a debugger cannot attach to Dock." >&2
    echo "Disable it from Recovery first." >&2
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

# lldb's -o cannot carry a multi-line script, so stage it in a file and exec it.
DRIVER="$(mktemp -t spaceswitch)"
trap 'rm -f "$DRIVER"' EXIT

cat >"$DRIVER" <<DRIVER_EOF
import lldb

plan = []
for line in """$PLAN""".strip().splitlines():
    _, off, hexbytes = line.split()
    plan.append((int(off, 16), bytes.fromhex(hexbytes)))

target = lldb.debugger.GetSelectedTarget()
proc = target.GetProcess()

mod = None
for m in target.module_iter():
    if m.GetFileSpec().GetFilename() == "Dock":
        mod = m
        break

if mod is None:
    print("FAIL: Dock module not found in the attached process")
else:
    base = mod.FindSection("__TEXT").GetLoadAddress(target)
    err = lldb.SBError()
    ok = 0
    for off, blob in plan:
        addr = base + off
        proc.WriteMemory(addr, blob, err)
        if not err.Success():
            print("FAIL: 0x%x: %s" % (addr, err))
            continue
        back = proc.ReadMemory(addr, len(blob), err)
        if back == blob:
            print("  0x%x now %s" % (addr, back.hex()))
            ok += 1
        else:
            print("FAIL: 0x%x reads back as %s" % (addr, back.hex() if back else "??"))
    print("RESULT %d/%d" % (ok, len(plan)))
DRIVER_EOF

echo
echo "Attaching to Dock (pid $DOCK_PID)..."

OUT="$(lldb --batch \
    -o "process attach --pid $DOCK_PID" \
    -o "script exec(open('$DRIVER').read())" \
    -o "detach" \
    -o "quit" 2>&1)"

echo "$OUT" | grep -E '^  0x[0-9a-f]+ now |^FAIL|^RESULT' || true

if ! echo "$OUT" | grep -q '^RESULT'; then
    echo "The patch did not run. Full lldb output:" >&2
    echo "$OUT" >&2
    exit 1
fi

if echo "$OUT" | grep -q '^FAIL'; then
    exit 1
fi

# Leaving Dock suspended would freeze Mission Control, so make sure it resumed.
sleep 1
STATE="$(ps -o stat= -p "$DOCK_PID" | tr -d ' ')"
if [[ "$STATE" == T* ]]; then
    echo "WARNING: Dock is still suspended. Resuming it." >&2
    kill -CONT "$DOCK_PID"
fi

echo
echo "Done. Try a three-finger swipe or Control+Arrow."
echo "Restore stock with: killall Dock"
