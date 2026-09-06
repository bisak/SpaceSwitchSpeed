<p align="center">
  <img src="docs/images/banner.webp" alt="Space Switch Speed — the Speed slider set from Default to Quick, with Control and the arrow keys and a three-finger swipe driving Spaces across a MacBook Pro" width="100%">
</p>

# Space Switch Speed

**Make the macOS Space-switching animation as fast as you want.**

The slide between desktops — the one you get from a three-finger swipe, `Control + →`,
Mission Control, or moving in and out of a full-screen app — takes about a third of a
second, and macOS has no setting to change it. The `defaults write` commands you will
find online [stopped working years ago](#why-defaults-write-doesnt-fix-this). Space
Switch Speed adds the slider Apple never shipped.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)](#compatibility)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)](#compatibility)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

## Requirements

- An Apple Silicon Mac running macOS 15 Sequoia or later
- **SIP's debugging restrictions turned off** — one command in Recovery, and the
  only part of System Integrity Protection this needs. That is still a real tradeoff,
  so read [what it means](#system-integrity-protection) before installing
- An administrator account

## Install

### App

Download `SpaceSwitchSpeed-<version>.dmg` from the
[Releases](https://github.com/bisak/SpaceSwitchSpeed/releases) page, open it, and drag
Space Switch Speed into the Applications folder beside it. Then clear the download
quarantine:

```bash
xattr -dr com.apple.quarantine "/Applications/Space Switch Speed.app"
```

The app is signed for local use but not notarised by Apple, which needs a paid
Developer ID, so without that step macOS refuses to open it. If you would rather not
run a command, launch the app once, let it be blocked, then click **Open Anyway** in
**System Settings → Privacy & Security**. Control-clicking the app and choosing Open
does not work: Apple removed that bypass in macOS 15.

### From source

```bash
git clone https://github.com/bisak/SpaceSwitchSpeed
cd SpaceSwitchSpeed
make              # list every target
make run          # build the app and launch it
make install      # build the app and put it in /Applications
```

Needs Xcode 26 or newer, because macOS draws a window with the controls of the SDK it
was linked against, and an older Xcode produces one that looks a release behind.

## Usage

One slider. Drag it, and the change takes effect.

The first change asks for your password once, because writing to Dock needs root.
Everything after that is silent, including putting the setting back whenever Dock
restarts. After an update, the next change asks once more so the new version can
replace its helper. Sliding all the way back to Default turns Space Switch Speed off
entirely, and **Space Switch Speed → Remove Space Switch Speed…** takes it off the machine.

The setting is shared by every account on the Mac and applies to every logged-in
user's Dock, fast user switching included. From a standard account, each change asks
for an administrator's name and password.

That password installs a small background helper. macOS lists it under
**System Settings → General → Login Items & Extensions**; switch it off there and Dock
goes back to normal at once. This is everything it places on your Mac, and
**Remove Space Switch Speed…** deletes all of it:

- `/Library/LaunchDaemons/com.bisak.spaceswitchspeed.helper.plist`
- `/Library/PrivilegedHelperTools/com.bisak.spaceswitchspeed.helper`
- `/Library/Application Support/SpaceSwitchSpeed/`, which holds your setting

## System Integrity Protection

**This is a real security tradeoff. Read this section rather than skipping it.**

Space Switch Speed works by writing to the memory of Dock, a running Apple process, and
macOS forbids that for every process, root included, while System Integrity Protection
is fully on. There is no entitlement, permission dialog or App Store-friendly way around
it. Apple reserves that capability for its own tools.

SIP is not one switch, though. It is a set of protections, described on Apple's page
[About System Integrity Protection on your Mac](https://support.apple.com/en-us/102149),
and only one of them stands in the way: **Debugging Restrictions**, which governs
`task_for_pid` against Apple's own processes. You do not have to turn the rest off, and
you should not.

### Turn off only what it needs

1. Shut the Mac down completely.
2. Press and **hold** the power button until "Loading startup options" appears.
3. Click **Options → Continue** to enter
   [macOS Recovery](https://support.apple.com/en-us/102518).
4. Choose **Utilities → Terminal** from the menu bar.
5. Run:

   ```bash
   csrutil enable --without debug
   ```

6. Confirm, then restart normally.

`csrutil` warns that this is an unsupported configuration. That is expected: Apple does
not bless partial configurations, and what `--without debug` covers could change in a
future release. Afterwards `csrutil status` reports `unknown (Custom Configuration)` and
lists each protection separately:

| Protection | `csrutil disable` | `--without debug` |
|---|---|---|
| Filesystem Protections | off | **on** |
| Kext Signing | off | **on** |
| DTrace Restrictions | off | **on** |
| NVRAM Protections | off | **on** |
| BaseSystem Verification | off | **on** |
| Debugging Restrictions | off | off |

Filesystem Protections is the one worth keeping. With it on, root still cannot write to
`/System`, `/bin`, `/sbin`, `/usr` outside `/usr/local`, or Apple's app bundles, which is
how something that has got root would otherwise make itself permanent. What you give up
is narrower: anything already running as root can attach to any Apple process and read or
write its memory. That is a genuine loss of defence-in-depth, and it is exactly the
capability Space Switch Speed uses.

A full `csrutil disable` also works, and is what most guides tell you to run. It gives up
every row of that table for no additional benefit here.

### What it does not buy back

On Apple Silicon, SIP lives in the boot policy, and `csrutil` only ever lowers that
policy to **Permissive Security** — the same level a full `csrutil disable` sets. A
partial configuration restores the kernel-enforced protections above; it does not restore
Full Security. Gatekeeper, notarisation, sandboxing, TCC, FileVault and the sealed system
volume are unaffected either way.

Whether the trade is acceptable is your call. A shared Mac, a work laptop under an MDM
policy, or anything holding credentials you cannot rotate: leave SIP alone and don't use
this tool. A personal Mac where you already run unsigned binaries: the marginal risk is
small, and tools such as yabai's scripting addition ask for the same thing.

**Space Switch Speed will never change your SIP configuration for you.** It detects the
state, says so, and stops. Turning anything off is a deliberate act performed from
Recovery, by you.

### How to undo it

The same trip to Recovery, then:

```bash
csrutil clear
```

which drops the custom configuration and restores the default on the next boot. It is
completely reversible, and nothing Space Switch Speed does needs undoing first: the patch
only ever existed in memory.

> With FileVault on, Recovery asks you to unlock the disk first. That is expected, and
> FileVault stays on.

## How it works

Dock does not play a timed animation when you switch Space. It runs a spring: every
frame it moves the desktop a little closer to where it is going, and the animation ends
when the spring has settled, not when a clock runs out. Two constants in Dock's code set
how stiff that spring is, and they are what make the switch take a third of a second.

Space Switch Speed changes those two constants in the running Dock process. It rewrites
five instructions so that the constants are read from a page it controls, then solves
for the pair that produces the speed you asked for. Nothing is written to disk, and the
change disappears the moment Dock restarts, which is why a small helper puts it back.

The slider scales how long the spring takes. `1.00` writes back Apple's own constants
exactly, and `0.50` really is half. Refresh rate makes no difference to that, so there
is nothing to calibrate. There is no second control for damping, because every value
that differs enough from Apple's to notice overshoots, and a desktop that slides past
and springs back reads as a glitch rather than a flourish.

The disassembly, the constants, the patch and why it is safe are written up in
[docs/REVERSE-ENGINEERING.md](docs/REVERSE-ENGINEERING.md).

### Why `defaults write` doesn't fix this

Search for *"macOS space switch animation slow"* and every result tells you to run one
of these:

```bash
defaults write com.apple.dock workspaces-swoosh-animation-off -bool true
defaults write com.apple.dock expose-animation-duration -float 0.1
```

Neither does anything on any current macOS. `workspaces-swoosh-animation-off` was real
in Mac OS X Lion and was removed over a decade ago. `expose-animation-duration` only
ever affected Mission Control's zoom, never the Space slide. Neither string exists in
the Dock binary any more; both answers have simply been copied forward. There is no
preference to set because there is no duration: the animation is a spring, as above.

**Reduce Motion** (System Settings → Accessibility → Display) does work, but it
replaces the slide with a cross-fade and also flattens window minimising, Launchpad,
Mission Control, notification transitions and app switching across the whole system.
If you only want the Space switch to be quicker, it costs far too much.

### Where people keep asking

The question long predates this tool, and Apple's own forums are where it lands and
stops:

- [can I increase the speed of the switch spaces animation?](https://discussions.apple.com/thread/253938203)
  — closed, with Reduce Motion marked as the answer, at the cost described above.
- [Speed up desktop switching animation in macOS Tahoe](https://discussions.apple.com/thread/256195960)
  — ten replies, closed, no setting found.
- [Switching spaces animation is very slow on high refresh rate screens](https://discussions.apple.com/thread/256054548)
  — open, unresolved, and filed with Apple as a bug.

## What Space Switch Speed does not do

Worth being explicit, because "patches Dock" sounds alarming:

- **It does not modify any file on disk.** Not Dock, not the system volume, nothing.
  The Dock binary is byte-identical before and after.
- **It does not persist in Dock.** The change lives in one process's memory. `killall Dock`
  removes it completely and unconditionally, and that is the escape hatch if anything
  ever looks wrong.
- **It does not change your SIP configuration, run a curl-to-bash installer, or phone home.**
- **It does not write to anything it has not identified.** The instructions it changes
  are found by matching the shape of the code, not by hardcoded addresses, and it checks
  that Apple's exact constants are present before touching anything. On a macOS build it
  doesn't recognise, it does nothing and says so.
- **It changes one animation.** Mission Control, Launchpad, window minimising and app
  switching are untouched.

## Compatibility

| | |
|---|---|
| Architecture | Apple Silicon (arm64e) only. Intel Macs are not supported. |
| macOS | Verified against the Dock of every release listed [below](#which-versions-are-verified). macOS 15 Sequoia is the floor: 13 and 14 drive the animation from a fixed 60 Hz timestep rather than the display's, and Space Switch Speed refuses to patch them. |
| Displays | Nothing to configure, on any refresh rate or number of monitors. A speed setting takes the same wall-clock time on 60, 120 and 144 Hz, which is [not true of Apple's default](#faq). |
| SIP | Debugging restrictions off (`csrutil enable --without debug`) is all it needs; a full `csrutil disable` also works. Nothing else in SIP matters to it. |

### Which versions are verified

Each of these was checked by running the locator against the Dock binary from Apple's
restore image for that build, without patching anything. `make check-dock` does the same
for the Dock on your own Mac, and `make fetch-dock MACOS=15.0` gets any other release's:

| macOS | Dock | |
|---|---|---|
| 13.0 (22A380) | 2206 | refuses — fixed 60 Hz timestep |
| 14.0 (23A344) | 2273.1.100 | refuses — fixed 60 Hz timestep |
| 14.6.1 (23G93) | 2273.105 | refuses — fixed 60 Hz timestep |
| 15.0 (24A335) | 2341.0.1 | works |
| 15.6.1 (24G90) | 2341.6.1 | works |
| 26.0 (25A354) | 2427.0.4 | works |
| 26.2 (25C56) | 2427.2.4 | works |
| 26.4 (25E246) | 2427.4.7 | works |
| 26.6.2 (25G83) | 2427.6 | works |

## Uninstall

**Space Switch Speed → Remove Space Switch Speed…** puts Dock back, removes the helper and
everything it wrote, and quits, leaving only the app for you to move to the Trash.

Or just delete the app. The helper notices within a few minutes, puts Dock back and
removes itself, leaving nothing on the system volume. Moving or renaming the app is
fine; only the Trash counts. `killall Dock` undoes the patch immediately, at any time.

## FAQ

**Does this work on Intel Macs?**
No. The patch is arm64e machine code. Intel support would need a separate implementation.

**Will a macOS update break it?**
It may, and the honest answer is that recompiling Dock is enough to do it. The animation
is located by the data flow of its integrator, not by address and not by one fixed
sequence of instructions, because measuring real builds showed the compiler reorders
that sequence freely: between macOS 26.2 and 26.4 the operands of one commutative
multiply swapped, which was enough to defeat an earlier, stricter signature. Matching the
data flow instead absorbs that, and every release in the table above is checked.

A genuine rewrite still defeats it, and one has already happened once — macOS 15 moved
the animation from a fixed 60 Hz timestep to the display's real frame interval, which is
why 13 and 14 are not supported. Either way it fails safely: it refuses to patch rather
than writing to an address it has not positively identified, and `killall Dock` undoes
anything it has done.

**Is the animation slower on a 120 Hz or ProMotion display?**
Yes, and it is not your imagination. Dock's spring uses per-frame coefficients with a
timestep that macOS 15 takes from the display, so the same constants describe a
different system at every refresh rate. Measured from Apple's own values, the switch
settles in about 0.092 s at 60 Hz and 0.124 s at 120 Hz — a 60 Hz Mac's Space switch is
genuinely faster, and slightly bouncier, than a ProMotion one. There is no setting for
this and reporting it to Apple has not moved it. Space Switch Speed solves the spring
for whatever your display reports, so a given speed takes the same wall-clock time on
any of them. The [measurements are in the write-up](docs/REVERSE-ENGINEERING.md).

**Is this about "Spaces", "desktops" or "workspaces"?**
All the same thing. Apple's documentation calls them Spaces, Mission Control labels them
Desktop 1 and Desktop 2, and people arriving from Linux or Windows call them virtual
desktops or workspaces. Full-screen apps are Spaces too, so the same slide plays when you
move in and out of one, and the slider covers that as well.

**Is this the same as yabai / Amethyst / Rectangle?**
No. Those are window managers. Space Switch Speed changes one animation and nothing else. It
does not require yabai's scripting addition, though both need SIP's debugging
restrictions off for related reasons.

**Can I make it truly instant, with no animation at all?**
`0.20` arrives in under 70 ms, which reads as instant in practice. Going lower makes the
spring stiff enough to look like a hard cut, and on a trackpad swipe that fights the
gesture tracking. If you want no animation whatsoever, Reduce Motion is the honest
answer.

**Do I need to keep the app running?**
No. The app is just the settings window. The helper is a small background process that
only wakes when a Dock starts or stops, a user logs in or out, or the setting changes.

**Does it slow down my Mac or drain battery?**
No. It changes two floating-point constants Dock already reads every frame. There is no
polling, no injected code path and no additional work per frame.

**Why does it need root as well as the SIP change?**
Debugging restrictions off makes `task_for_pid` on a platform binary *possible*; root
makes it *permitted*. Both checks are separate and both must pass.

## Contributing

Issues and pull requests are welcome, particularly reports from macOS versions or
hardware I cannot test on. If Space Switch Speed refuses to find the integrator on your
machine, please open an issue with your macOS version, build number and Mac model,
and what the helper said about it:

```bash
log show --last 1h --predicate 'subsystem == "com.bisak.spaceswitchspeed"'
```

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

## License

[GNU Affero General Public License v3.0 or later](LICENSE).

You may use, study, modify and redistribute this software. If you distribute it, or run
a modified version as a network service, you must make your source available under the
same licence.
