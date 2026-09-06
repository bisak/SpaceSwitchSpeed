# How the Space-switch animation works, and how SpaceSwitch changes it

Findings from macOS 26.6.2 (build 25G83), `Dock` 1.8 (2427.6), arm64e. Addresses are
as-linked, with `__TEXT` at `0x100000000`.

## There is no duration

The first thing to establish is what the animation *is*, because the widely repeated
answers are all wrong. Dock does not run a timed curve for a Space switch. It runs a
spring on a dispatch queue named `space-switcher-<uuid>`, and the loop lives at
`__text:0x100150f2c`:

```asm
loop:
100150f2c  fsub d19, d1, d17        ; error = target - position
100150f30  ldr  d20, [x20, #0x150]  ; velocity
100150f34  fmul d20, d20, d2        ; velocity *= retention (0.695)
100150f38  fadd d19, d19, d19       ; error *= 2            <- the gain
100150f3c  fadd d19, d19, d20       ; velocity = gain*error + retention*velocity
100150f40  str  d19, [x20, #0x150]
100150f44  fmul d20, d8, d19        ; dt * velocity
100150f48  fadd d17, d17, d20       ; position += dt * velocity
```

Termination is a settle test, not a clock: `fabs`/`fcmp` against `[0x10036f250]`
(`0.01`) on the velocity, then a position tolerance from `[x20+0xf0]`. The animation
ends when the spring stops moving.

That is why `defaults write com.apple.dock workspaces-swoosh-animation-off` and
`expose-animation-duration` do nothing — neither string exists in the binary any more —
and why Apple ships no preference. There is no duration value to expose.

## The constants

All read from `__TEXT,__const`:

| Address | Value | Role |
|---|---|---|
| `0x10036f5d0` | `0.695` | velocity retention |
| `0x10036f5d8` | `0.85` | rubber-band velocity damping |
| `0x10036f5e8` | `0.8` | rubber-band stiffness |
| `0x10036f5e0` | `-0.8` | rubber-band stiffness, upper bound |
| `0x10036f250` | `0.01` | settle epsilon |
| `0x10037c290` | `1e-09` | display timing scale, ns → s |
| `0x10037c288` | `0.0166667` | frame interval fallback (60 Hz) |

The gain is not a constant — it is the instruction `fadd d19, d19, d19`, a hardcoded
doubling.

## The timestep is the display's frame interval

`d8` is the loop's timestep and arrives as an argument. Tracing back through the
dispatcher at `0x100150d64` to the helper at `0x10028975c`:

```asm
10028976c  ldr  w1, [x20, #0x30]
100289778  bl   _SLSDisplayGetTiming
10028977c  ldr  x8, [sp]
100289780  ucvtf d0, x8
10028978c  fmul d0, d0, d1          ; x 1e-9  (nanoseconds to seconds)
10028979c  fcsel d0, d1, d0, eq     ; fall back to 1/60 when timing is 0
```

This matters more than it looks. Because `dt` varies but the coefficients do not,
**Apple's spring is a different continuous-time system on every refresh rate**:

| Refresh | Damping ratio ζ | Dominant τ | Character |
|---|---|---|---|
| 60 Hz | 0.911 | 0.092 s | underdamped, slight ring |
| 90 Hz | 1.116 | 0.110 s | overdamped |
| 120 Hz | 1.289 | 0.124 s | overdamped |
| 144 Hz | 1.412 | 0.130 s | overdamped |

A 60 Hz Mac's Space switch is genuinely faster and slightly bouncier than a 120 Hz
one, from the same constants.

It matters less than it looks for changing them, though, and that is worth recording
because the opposite is the intuitive conclusion. The velocity step carries no
timestep, so the coefficients fix the dynamics per frame and `position += dt · velocity`
absorbs the difference. Solving the same speed setting for 60, 120 and 144 Hz gives
gains of 6.7133, 6.7467 and 6.7522 with identical retention, and the animation takes
the same wall-clock time on any of them. SpaceSwitch therefore does not detect the
refresh rate at all; it uses a fixed reference purely to report predicted times.

The discrete loop's characteristic polynomial is `z² − (1 + a − dt·g)z + a`, whose roots
are real above roughly 75 Hz and complex below it. Both branches must be handled or the
tool is wrong on 60 Hz hardware.

## The patch

Five instructions, all in the preamble and loop:

```asm
100150ef0  adrp x11, 0x10036f000     ->  adrp x11, <scratch page>
100150ef4  ldr  d2, [x11, #0x5d0]    ->  ldr  d2, [x11, #0]      retention
100150ef8  movi.2d v3, #0            ->  ldr  d3, [x11, #8]      gain
100150efc  adrp x11, 0x10036f000         (untouched)
...
100150f38  fadd d19, d19, d19        ->  fmul d19, d19, d3
...
100150f78  fsub d19, d3, d17         ->  fneg d19, d17
```

Three details make this safe rather than lucky:

**Repointing `x11` is local.** The compiler emitted five redundant `adrp x11, 0x10036f000`
instructions in a row. The one at `0x150efc` re-establishes `x11` before its next use at
`0x150f00`, so changing the first one affects only the two loads between them. SpaceSwitch
verifies that re-establishing `adrp` is present and refuses to patch without it.

**Borrowing `v3` is safe.** `movi.2d v3, #0` zeroes 128 bits; `ldr d3` zeroes the top
half and loads the bottom. The only later read is the scalar `fsub d19, d3, d17`, so
nothing observes the difference. The tool scans from the load to the last use and
refuses if anything else writes that register.

**The rubber band keeps working.** `fsub d19, d3, d17` computed `0 − position` and
relied on `d3` being zero. Since `d3` now holds the gain, it becomes `fneg d19, d17`,
which is exactly equivalent. This branch only runs when you swipe past the first or
last Space.

Scratch memory is `mach_vm_allocate`d inside Dock and checked to be within `adrp`
range (±4 GB), so nothing in the mapped image is overwritten to make room.

## Locating it without hardcoded addresses

Addresses change with every Dock build, so SpaceSwitch matches the *shape* of the
integrator: an eight-instruction window pinned by `fadd dE, dE, dE` where destination
and both sources are the same register, surrounded by a load/multiply/accumulate/store
of a velocity at a consistent offset, and a position update. That pattern must match
exactly once in `__text`. From there it walks back for the preamble and forward for the
rubber band, and validates that the retention constant really is `0.695` before writing.

Anything that fails produces a refusal, not a guess.

## Reverting without stored state

The stock words are all recoverable from what remains:

- the original `adrp` page — from the untouched redundant `adrp` two instructions later
- the retention offset — the constants are a contiguous block, so it is the neighbouring
  load's offset minus 8 (checked at patch time, and the patch is refused if it does not hold)
- the gain and rubber-band instructions — fully determined by the register numbers

So `revert` reconstructs Apple's exact five words with nothing persisted. `killall Dock`
remains the unconditional escape hatch, since the patch only ever exists in memory.

## Privileges

`task_for_pid` against Dock needs two separate things:

- **SIP disabled**, because Dock is an Apple platform binary and AMFI otherwise refuses
- **root**, because SIP being off makes the operation possible, not permitted

Self-signing `com.apple.system-task-ports` does not work: AMFI kills the process. That
entitlement is reserved for Apple-signed tools, which is why `lldb` can attach
unprivileged and nothing else can.
