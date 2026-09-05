# macos-spaceswitch

Make the macOS Space transition faster. Covers the three-finger swipe and
Control+Arrow, continuously adjustable rather than on/off.

Confirmed working on macOS 26.6.2 (25G83), Apple Silicon.

```
bash spaceswitch-runtime.sh 0.25
```

The argument is a multiplier on settling time. `1` is stock, `0.25` settles four
times as fast. `0.25`–`0.5` is the useful range; see Ringing below.

## Requires SIP disabled

The constants live inside a signed platform binary, so a debugger has to attach
to Dock. Disable System Integrity Protection from Recovery with `csrutil
disable`. Root is not required afterwards, since Dock runs as you.

Reduce Motion is not a substitute and does not affect this.

## How it works

There is no duration to change. Dock animates the transition with a leaky
integrator on its own `space-switcher` dispatch queue:

```
velocity = gain × (target − position) + A × velocity      gain = 2, A = 0.695
position += timestep × velocity
```

It ends when the spring settles, not when a clock expires, which is why macOS
ships no setting and why there is no constant to zero out. Settling time is
proportional to `1 − A`, so the tool scales that term. `--speed` is a straight
multiplier on settling time.

`A` is a double in `__TEXT,__const`, loaded by `ldr d2, [x11, #0x5d0]`. Dock
reads that same constant from four places, so overwriting it would retime
unrelated animations. Instead the tool repoints only the integrator's own load
to eight unused bytes of padding between `__objc_methlist` and `__const`, and
writes the chosen value there. Everything else keeps `0.695`.

The integrator is located by a unique 32-byte signature of its inner loop, not a
fixed offset, so the patch is not tied to one build. Reverting restores the
original load and clears the slot, leaving the binary byte-identical to Apple's.

## Ringing

`A` is velocity *retention*, so `1 − A` is the damping term. Raising the speed
therefore also lowers damping — the knob is not orthogonal.

| speed | A | behaviour |
|---|---|---|
| 1 (stock) | 0.695 | no overshoot |
| 0.5 | 0.8475 | subtle ringing |
| 0.25 | 0.9238 | subtle ringing |
| 0.1 | 0.9695 | visible ringing |

Stock sits just barely on the non-oscillating side, so any speed-up crosses into
oscillation. What matters is how fast it decays (`√A` per step), which is why
0.25 looks clean and 0.1 does not. Values are clamped at `A = 0.97`.

Making speed independent of damping would mean scaling the gain too. That is the
hardcoded `fadd d19, d19, d19`, so it needs an instruction rewrite and a second
constant slot. Not currently done.

## Usage

```
./spaceswitch.py --show              # read current state (safe with SIP on)
./spaceswitch.py --speed 0.25        # preview
bash spaceswitch-runtime.sh 0.25     # apply to the running Dock
bash spaceswitch-runtime.sh 1        # back to stock
./spaceswitch.py --damping 0.9       # set A directly
```

The runtime patch touches memory only. `killall Dock` reverts it, and it does
not survive a reboot. Patching the file on disk with `--apply` persists but
breaks Dock's signature and costs it the private entitlements it needs; it also
requires Authenticated Root disabled. Not recommended.

## History

The first version of this tool patched two `fmov d0, #0.25` constants, one of
which Dock sends WindowServer as `xfade-duration`. They looked convincing and
did nothing: breakpoints showed zero hits during real Space switches. They belong
to a different transition. See [NOTES.md](NOTES.md).
