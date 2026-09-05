# Reverse-engineering notes

Target: `/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock`, arm64e slice
at file offset `0x530000`, macOS 26.6.2 build 25G83. Virtual addresses below are
as linked, with `__TEXT` at `0x100000000`.

## There is no preference for this

Dock reads floating-point preference values at exactly three keys:
`spacesbar-distance`, `com.apple.springing.delay`, and `genie-speed`. None
relates to Space switching.

This was established by decoding every call to Dock's typed preference helpers
and by enumerating the preference APIs it imports. Dock has no `doubleForKey:`,
`floatForKey:` or `integerForKey:` selector at all, so there is no second path.
Both duration values are immediate operands compiled into the instruction stream.

`firenze-animation-time` exists as a string in the binary and looks promising.
It belongs to Launchpad and is never referenced from the Space-switch path.

## The two constants

| name | vmaddr | file offset | role |
|---|---|---|---|
| `transition` | `0x100284104` | `0x7b4104` | duration passed to Dock's Space transition routine at `0x10014d2ac` |
| `crossfade` | `0x1002852c8` | `0x7b52c8` | duration passed to `0x100286c2c`, which sends it as `xfade-duration` |

Both are `fmov d0, #0.25`, encoded `00 10 6A 1E`.

### transition

Sits in the Space-switch path immediately before a call that leads to
`CGSSpaceSetFrontPSN`. The callee calls `CACurrentMediaTime`, which is how the
units were confirmed as seconds: elsewhere in the same family of code a duration
is added to `CACurrentMediaTime()` to form a deadline.

This is the instruction yabai's scripting addition patches, matched with the
signature `00 10 6A 1E A8 ?? ?? D1 ?? 01 ?? F8`.

### crossfade

`0x100286c2c` creates an `SLSTransaction`, applies `SLSTransactionSetSpaceTransform`
three times and `SLSTransactionSetSpaceAlpha`, and packs the Double into an XPC
dictionary under the key `xfade-duration`. That dictionary build lives at
`0x1002769c4`, where `v4` becomes `xfade-duration` and `v0`–`v3` become `x`, `y`,
`w`, `h`.

This is the visible slide. yabai does not patch it.

## Constants that look relevant but are not

Ruled out so the tool does not touch them:

- `0x100289598` and `0x1002895dc`. Rubber-band overscroll coefficient. The
  surrounding code is the classic `x / (1 + x*d/c)` rubber-band formula.
- `0x100326eb4`. A quarter-frame phase offset, computed next to
  `SLSDisplayGetTiming`. Vsync alignment, not a duration.
- `0x10028e79c`. Scales an existing duration by 0.25, but only in the
  rubber-band case, selected by `fcsel`.
- Several sites pairing `#0.25` with `#5.0` via `fcsel`. This is the
  shift-key slow-motion path, gated by `slow-motion-allowed`.

## Reduce Motion does not apply

Both duration sites are unconditional. No compare, no `fcsel`, no branch selects
a different value.

Dock references the reduce-motion flag in three places in its entire text
segment, all of them generic accessibility-flag accessor thunks sitting beside
the ones for Increase Contrast and Reduce Transparency. None is near the
Space-switch code.

## Instruction encoding

`fmov d0, #imm8` uses the AArch64 8-bit floating-point immediate, giving
`(1 + efgh/16) × 2^exp` with `exp` in `[-3, 4]`. The smallest positive magnitude
is `2^-3 = 0.125`.

That covers 0.125 to 0.242 in steps of 0.0078, and 0.25 to 0.484 in steps of
0.0156. It cannot express anything in `(0, 0.125)`, which is most of the range
worth having. Hence the literal pool.

Encodings used:

| value | instruction | word |
|---|---|---|
| stock 0.25 s | `fmov d0, #0.25` | `0x1E6A1000` |
| instant | `movi d0, #0` | `0x2F00E400` |
| anything else | `ldr d0, <literal>` | `0x5C000000 \| imm19 << 5` |

## Literal pool

16 bytes of zero padding between `__TEXT,__auth_stubs` (ends `0x100343010`) and
`__TEXT,__objc_stubs` (starts `0x100343020`). Confirmed all-zero in the stock
binary.

PC-relative `ldr` literal reach is ±1 MB. Both sites are within 782 KB of the
pool, so a single shared literal serves both.

The pool is only written when a site currently points at it, or when it is
all-zero. Moving to an encoding that needs no literal zeroes it again.

## Locating sites across builds

Sites are matched by the instructions that follow them, which the patch never
modifies:

| name | signature after the instruction |
|---|---|
| `transition` | `A8 ?? ?? D1 ?? 01 ?? F8` (`sub x8, x29, #imm` / `ldur x0, [x8, #imm]`) |
| `crossfade` | `E0 03 13 AA E1 03 15 AA F4 03 1B AA` (`mov x0, x19` / `mov x1, x21` / `mov x20, x27`) |

Each matches exactly once in the arm64e slice. The tool requires exactly one
match and accepts any of the three known instruction forms at the site, which is
what makes it re-adjustable without reverting.

## Why this needs SIP

Dock is a platform binary carrying `com.apple.private.SkyLight.*` entitlements.
Attaching a debugger to it requires SIP off. Editing it on disk additionally
requires Authenticated Root off, breaks its signature, and costs it the private
entitlements it needs, which is why the runtime patch is the recommended path.
