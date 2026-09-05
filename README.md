# macos-spaceswitch

Set how long the macOS Space-switch animation takes. Covers both the three-finger
swipe and Control+Arrow, on a continuous scale from stock to instant.

macOS exposes no setting for this. The duration is two hardcoded constants inside
Dock, and this tool rewrites them.

```
sudo bash spaceswitch-runtime.sh 0.6
```

The argument is a speed from 0 to 1. `0` is stock macOS, `1` is instant. Scaling
is linear in duration, so the number is also the fraction of the animation
removed.

## Requires SIP disabled

There is no way around this. The constants live inside a signed platform binary,
so reaching them means either attaching a debugger to Dock or editing a file on
the sealed system volume. Both need System Integrity Protection off.

Disable it from Recovery with `csrutil disable`, then reboot. This lowers the
security of the machine. It is a real tradeoff, not a formality.

Reduce Motion is **not** a substitute. Both constants are unconditional
immediates with no reduce-motion branch anywhere near them. Reduce Motion changes
what WindowServer draws, not how long it takes.

## Usage

Inspect what is currently installed. Reads only, safe with SIP on:

```
./spaceswitch.py --show
```

Preview a change without writing anything:

```
./spaceswitch.py --speed 0.6
```

Apply to the running Dock. Nothing on disk changes, and `killall Dock` restores
stock behaviour:

```
sudo bash spaceswitch-runtime.sh 0.6
```

Set an exact duration instead of a speed:

```
./spaceswitch.py --ms 90
```

Patch the file on disk for a persistent change. See the warning below:

```
sudo ./spaceswitch.py --speed 0.6 --apply
```

## Which method to use

Prefer the runtime patch. Dock keeps its genuine Apple signature and its private
entitlements, the sealed volume is untouched, and a reboot undoes everything.

The on-disk patch survives reboots but is not recommended. Editing the file
invalidates Dock's signature, and re-signing ad-hoc makes AMFI deny the
`com.apple.private.SkyLight.*` entitlements Dock depends on. It also needs
Authenticated Root disabled and a freshly blessed snapshot, and every macOS
update reverts it.

## How it works

Dock holds two separate 0.25 second constants in the Space-switch path:

| name | what it times |
|---|---|
| `transition` | the duration Dock uses for its own Space transition |
| `crossfade` | sent to WindowServer over XPC as `xfade-duration`, timing the space transform and alpha blend |

Both are `fmov d0, #0.25` immediates. The tool rewrites them together so the two
phases stay in step. Patching only the first, which is what yabai's scripting
addition does, leaves the crossfade running.

The ARM64 `fmov` immediate cannot encode anything between 0 and 0.125 seconds,
which is most of the useful range. So the tool picks the smallest encoding that
expresses the value exactly:

- **stock** restores Apple's original bytes
- **instant** becomes `movi d0, #0`
- **anything else** becomes a PC-relative `ldr d0, <literal>`, with the double
  stored in 16 bytes of zero padding between `__auth_stubs` and `__objc_stubs`

Returning to stock hands that padding back, so the binary ends up byte-identical
to Apple's.

Durations shorter than one display frame are indistinguishable from instant and
only add latency, so they snap to zero. The frame time comes from the main
display's actual refresh rate.

Call sites are found by the instructions that follow them, which the patch never
touches. That makes the tool idempotent: it reads back whatever is installed and
can move to any other value, including all the way back to stock, without
reverting first. It refuses to run if a signature does not match exactly once, or
if anything it did not write is sitting in the literal slot.

See [NOTES.md](NOTES.md) for the reverse-engineering detail, including the
constants that look relevant but are not.

## Compatibility

Verified on macOS 26.6.2, build 25G83, arm64e. Because sites are located by byte
signature rather than fixed offset, point releases that shift code around should
still work. A release that changes the surrounding instructions will not, and the
tool will say so rather than write to the wrong place.

Apple Silicon only. The Intel slice is not handled.

## Status

The byte-level behaviour is verified against a copy of the Dock binary: both
sites resolve uniquely, every encoding disassembles correctly, arbitrary values
round-trip, and returning to stock is byte-identical.

The on-screen result is not verified. That needs SIP disabled, which was not the
case on the machine this was written on.
