# SpaceSwitch

**Make the macOS Space-switching animation as fast as you want.**

The slide between desktops — the one you get from a three-finger swipe, `Control + →`,
or Mission Control — takes about a third of a second on macOS, and there is no setting
anywhere to change it. SpaceSwitch adds the slider Apple never shipped.

[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](#compatibility)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)](#compatibility)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

```
$ sudo spaceswitch 0.35
SpaceSwitch is active on Dock (pid 9226).

  speed        0.35 of stock
  arrives in   108 ms (stock 317 ms)
  settles in   350 ms
  gain 11.969785  retention 0.353613
```

---

## Why `defaults write` doesn't fix this

Search for *"macOS space switch animation slow"* and every result tells you to run one
of these:

```bash
defaults write com.apple.dock workspaces-swoosh-animation-off -bool true   # dead
defaults write com.apple.dock expose-animation-duration -float 0.1         # dead
```

Neither does anything on any current macOS. Not "it stopped working" — those preference
keys **no longer exist as strings inside the Dock binary at all**:

```bash
$ strings -a /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock \
    | grep -cE 'workspaces-swoosh-animation-off|expose-animation-duration'
0
```

`workspaces-swoosh-animation-off` was real in Mac OS X Lion and removed over a decade
ago. `expose-animation-duration` only ever affected Mission Control's zoom, never the
Space slide. Both answers have been copied forward ever since.

The other common advice — **System Settings → Accessibility → Display → Reduce Motion** —
does work, but it is a blunt instrument: it replaces the slide with a cross-fade and
also flattens window minimising, Launchpad, Mission Control, notification transitions
and app switching across the whole system. If you only want the Space switch to be
quicker, it costs far too much.

**There is no preference for this because there is no duration to set.** See
[what it actually does](#what-it-actually-does).

## What it actually does

Dock does not play a timed animation for a Space switch. It runs a spring — a leaky
integrator — on a queue literally named `space-switcher-<uuid>`, stepped once per
display frame:

```
velocity = gain × (target − position) + retention × velocity
position = position + Δt × velocity
```

It stops when the spring settles (`|velocity| < 0.01`), not when a clock runs out.
Apple ships `gain = 2.0` and `retention = 0.695` as constants in `__TEXT,__const`.
That is the whole animation, and it is why no duration preference exists to expose.

SpaceSwitch rewrites five instructions in the running Dock process so those two
constants come from a page it controls, then solves for the pair that produces the
speed you asked for. Nothing is written to disk, nothing is patched on disk, and the
change disappears the moment Dock restarts.

There is a detailed write-up in [docs/REVERSE-ENGINEERING.md](docs/REVERSE-ENGINEERING.md).

### One slider

The slider scales the spring's time constant. `1.00` writes back Apple's own
constants exactly, and `0.50` really is half — the presets come out at 1.00, 0.76,
0.50, 0.34 and 0.21 of stock.

It needs no per-machine calibration, which is worth saying because it looks like it
should. `Δt` is your display's frame interval, so Apple's fixed constants do describe
a slightly different spring on every refresh rate — damping ratio 0.91 on a 60 Hz Mac
against 1.29 on 120 Hz ProMotion. But the velocity step carries no timestep:

```
velocity = gain × (target − position) + retention × velocity
```

so the coefficients fix the dynamics *per frame*, and `position += Δt × velocity`
compensates for the rest. Solving for 60, 120 or 144 Hz moves the gain by half a
percent and the retention not at all, and the resulting animation takes the same
wall-clock time either way. Mixed-refresh multi-monitor setups need no special
handling for the same reason.

| Preset | Speed | 120 Hz arrival | 60 Hz arrival | Overshoot |
|---|---|---|---|---|
| Default | 1.00 | 317 ms | 283 ms | none |
| Gentle | 0.75 | 242 ms | 217 ms | none |
| Balanced | 0.50 | 158 ms | 150 ms | none |
| Quick | 0.35 | 108 ms | 100 ms | none |
| Instant | 0.20 | 67 ms | 67 ms | none |

## Requirements

- Apple Silicon Mac (arm64e), macOS 13 Ventura or later
- **System Integrity Protection disabled** — see [below](#disabling-system-integrity-protection)
- Administrator access

## Install

### Homebrew

```bash
brew tap bisak/spaceswitch https://github.com/bisak/spaceswitch
brew install spaceswitch          # command line tool
brew install --cask spaceswitch   # app
```

### From source

```bash
git clone https://github.com/bisak/spaceswitch
cd spaceswitch
make              # list every target
make run          # build the app and launch it
make install      # install the command line tool and helper
```

Needs Xcode 26 or newer. macOS draws an app with the controls of the SDK it was
linked against, so building with an older Xcode than your system produces a
window that looks a release behind.

The app is an Xcode target; `SpaceSwitchKit`, the command line tool and the
tests are a Swift package the project depends on. That split is deliberate —
Homebrew builds the tool with `swift build` and never needs Xcode.

## Usage

### App

One slider. Drag it, and the change takes effect.

The first change asks for your password once, because writing to Dock needs root.
Everything after that is silent, including putting the setting back whenever Dock
restarts. Sliding all the way back to Default turns SpaceSwitch off entirely, and
**SpaceSwitch → Remove SpaceSwitch…** takes it off the machine.

There is nothing else to configure. Damping stays at whatever Apple's own constants
imply, because every value that differs enough to notice overshoots, and a desktop
that slides past and springs back reads as a glitch rather than a flourish.

### Command line

```bash
sudo spaceswitch 0.5        # set speed, 0.2 (fastest) to 1.0 (stock)
sudo spaceswitch balanced   # presets by name
spaceswitch presets         # the presets and how long each takes
spaceswitch status          # the saved setting; with sudo, what Dock is running
sudo spaceswitch revert     # back to Apple's constants

sudo spaceswitch install    # install the helper, so the setting survives restarts
sudo spaceswitch uninstall  # remove it and everything it wrote, and revert
```

## Disabling System Integrity Protection

**This is a real security tradeoff. Read this section rather than skipping it.**

### Why it's needed

SIP stops any process — including root — from reading or writing another process's
memory when that process is an Apple platform binary. Dock is one. Without SIP off,
`task_for_pid` on Dock returns `KERN_FAILURE` and SpaceSwitch cannot do anything at
all. There is no entitlement, no permission dialog and no App Store-friendly path
around this; Apple deliberately reserves that capability for its own signed tools.

### What you actually give up

Turning SIP off is not a single switch — it disables a bundle of protections:

- Processes can be attached to and modified by root (this is the one we need)
- `/System`, `/usr`, `/bin`, `/sbin` become writable by root
- Unsigned kernel extensions can load
- `dtrace` restrictions on system processes are lifted
- NVRAM protection is lifted

In practice, for a single-user development Mac, the meaningful change is that
**malware running as root gains capabilities it would not otherwise have**. SIP is a
defence-in-depth layer for the case where something already got root on your machine.
It is not what stops you being compromised in the first place — Gatekeeper,
notarisation, sandboxing, TCC and FileVault all keep working with SIP off.

Whether that trade is acceptable is genuinely your call, and it depends on what the
machine does. A shared machine, a work laptop under an MDM policy, or anything holding
credentials you cannot rotate: leave SIP on and don't use this tool. A personal
development Mac where you already run Homebrew, Xcode and unsigned binaries: the
marginal risk is small, and plenty of well-known developer tools (yabai's scripting
addition, older Karabiner versions, various debuggers) require exactly the same thing.

**SpaceSwitch will never disable SIP for you.** It detects the state, explains it, and
stops. Turning it off is a deliberate act performed from Recovery, by you.

### How to disable it

1. Shut the Mac down completely.
2. Press and **hold** the power button until "Loading startup options" appears.
3. Click **Options → Continue** to enter Recovery.
4. Choose **Utilities → Terminal** from the menu bar.
5. Run:

   ```bash
   csrutil disable
   ```

6. Confirm, then reboot normally.

Verify with `csrutil status`, which should report `disabled`.

> On a Mac with FileVault enabled you will be asked to unlock the disk first. That is
> expected. FileVault stays on and keeps working.

### How to re-enable it

Exactly the same steps, with `csrutil enable`. It is completely reversible, and nothing
SpaceSwitch does needs undoing first — the patch only ever existed in memory.

## What SpaceSwitch does not do

Worth being explicit, because "patches Dock" sounds alarming:

- **It does not modify any file on disk.** Not Dock, not the system volume, nothing.
  The Dock binary is byte-identical before and after.
- **It does not persist in Dock.** The change lives in one process's memory. `killall Dock`
  removes it completely and unconditionally — that is the escape hatch if anything ever
  looks wrong.
- **It does not disable SIP, ask you to run a curl-to-bash installer, or phone home.**
- **It refuses to write to anything it has not identified.** The five instructions are
  located by matching the *shape* of the code — a specific eight-instruction integrator
  and its preamble — not by hardcoded addresses. It verifies Apple's exact constants are
  present before touching anything, checks that the register it borrows is not used
  elsewhere, and aborts if any of that fails. On a macOS build it doesn't recognise it
  does nothing and says so.
- **It changes one animation.** Mission Control, Launchpad, window minimising and app
  switching are untouched.

## Compatibility

| | |
|---|---|
| Architecture | Apple Silicon (arm64e) only. Intel Macs are not supported. |
| macOS | Built and verified on macOS 26. Should work on 13+ wherever the integrator shape matches; it refuses safely when it doesn't. |
| Displays | Nothing to configure. The coefficients are per-frame, so refresh rate and multi-monitor setups make no practical difference. |

## Uninstall

```bash
sudo spaceswitch uninstall     # reverts Dock, removes the helper
brew uninstall spaceswitch
```

Or just `killall Dock` and delete the app. Nothing is left behind on the system volume.

## Disclaimer

**This software is provided "as is", without warranty of any kind, express or implied,
including but not limited to the warranties of merchantability, fitness for a particular
purpose and non-infringement. In no event shall the author or copyright holder be liable
for any claim, damages or other liability, whether in an action of contract, tort or
otherwise, arising from, out of or in connection with the software or the use or other
dealings in the software.**

Specifically and without limitation, the author accepts **no liability** for:

- Any consequence of disabling System Integrity Protection, including security
  compromise, malware, data loss or theft
- Any instability, crash, hang or data loss in Dock, the window server or macOS
- Any damage to hardware, software, or data, or any loss of business, profit or time
- Any breach of warranty, support agreement or corporate security policy resulting from
  modifying your system

This project is **not affiliated with, endorsed by, or connected to Apple Inc.** It
modifies the behaviour of Apple software in memory at runtime. Doing so may violate the
macOS software licence agreement. Determining whether you are permitted to run it is
your responsibility.

**You run this entirely at your own risk.** If any of the above is unacceptable to you,
do not use this software.

## Contributing

Issues and pull requests are welcome — particularly reports from macOS versions or
hardware I cannot test on. If SpaceSwitch refuses to find the integrator on your
machine, please open an issue with your macOS version, build number and Mac model.

## License

[GNU Affero General Public License v3.0 or later](LICENSE).

You may use, study, modify and redistribute this software. If you distribute it, or run
a modified version as a network service, you must make your source available under the
same licence.

## FAQ

**Does this work on Intel Macs?**
No. The patch is arm64e machine code. Intel support would need a separate implementation.

**Will a macOS update break it?**
It may. SpaceSwitch locates the code by shape rather than by address, so it survives
most recompilations, but a genuine rewrite of the animation would defeat it. It fails
safely: it refuses to patch rather than writing to a wrong address.

**Is this the same as yabai / Amethyst / Rectangle?**
No. Those are window managers. SpaceSwitch changes one animation and nothing else. It
does not require yabai's scripting addition, though both need SIP disabled for related
reasons.

**Can I make it truly instant, with no animation at all?**
`0.20` gets to about 75 ms, which reads as instant in practice. Going lower makes the
spring stiff enough to look like a hard cut, and on a trackpad swipe that fights the
gesture tracking. If you want no animation whatsoever, Reduce Motion is the honest
answer.

**Do I need to keep the app running?**
No. The app is just the settings window. The helper is a small background process that
only wakes when Dock restarts.

**Does it slow down my Mac or drain battery?**
No. It changes two floating-point constants Dock already reads every frame. There is no
polling, no injected code path and no additional work per frame.

**Why does it need root as well as SIP disabled?**
SIP disabled makes `task_for_pid` on a platform binary *possible*; root makes it
*permitted*. Both checks are separate and both must pass.
