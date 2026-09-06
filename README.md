<p align="center">
  <img src="docs/images/banner.webp" alt="SpaceSwitchSpeed — make the macOS Space switch as fast as you want" width="100%">
</p>

# SpaceSwitchSpeed

**Make the macOS Space-switching animation as fast as you want.**

The slide between desktops, the one you get from a three-finger swipe, `Control + →`
or Mission Control, takes about a third of a second, and macOS has no setting to
change it. The `defaults write` commands you will find online
[stopped working years ago](#why-defaults-write-doesnt-fix-this). SpaceSwitchSpeed
adds the slider Apple never shipped.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)](#compatibility)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)](#compatibility)
[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

## Requirements

- An Apple Silicon Mac running macOS 15 Sequoia or later
- **System Integrity Protection disabled.** That is a real tradeoff, so read
  [what it means](#disabling-system-integrity-protection) before installing
- An administrator account

## Install

### App

Download `SpaceSwitchSpeed-<version>.dmg` from the
[Releases](https://github.com/bisak/spaceswitchspeed/releases) page, open it, and drag
SpaceSwitchSpeed into the Applications folder beside it. Then clear the download
quarantine:

```bash
xattr -dr com.apple.quarantine /Applications/SpaceSwitchSpeed.app
```

The app is signed for local use but not notarised by Apple, which needs a paid
Developer ID, so without that step macOS refuses to open it. If you would rather not
run a command, launch the app once, let it be blocked, then click **Open Anyway** in
**System Settings → Privacy & Security**. Control-clicking the app and choosing Open
does not work: Apple removed that bypass in macOS 15.

### From source

```bash
git clone https://github.com/bisak/spaceswitchspeed
cd spaceswitchspeed
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
replace its helper. Sliding all the way back to Default turns SpaceSwitchSpeed off
entirely, and **SpaceSwitchSpeed → Remove SpaceSwitchSpeed…** takes it off the machine.

The setting is shared by every account on the Mac and applies to every logged-in
user's Dock, fast user switching included. From a standard account, each change asks
for an administrator's name and password.

That password installs a small background helper. macOS lists it under
**System Settings → General → Login Items & Extensions**; switch it off there and Dock
goes back to normal at once. This is everything it places on your Mac, and
**Remove SpaceSwitchSpeed…** deletes all of it:

- `/Library/LaunchDaemons/com.bisak.spaceswitchspeed.helper.plist`
- `/Library/PrivilegedHelperTools/com.bisak.spaceswitchspeed.helper`
- `/Library/Application Support/SpaceSwitchSpeed/`, which holds your setting

## Disabling System Integrity Protection

**This is a real security tradeoff. Read this section rather than skipping it.**

SpaceSwitchSpeed works by writing to the memory of Dock, a running Apple process, and
macOS forbids that for every process, root included, while System Integrity Protection
is on. There is no entitlement, permission dialog or App Store-friendly way around it.
Apple reserves that capability for its own tools.

Apple's page [About System Integrity Protection on your Mac](https://support.apple.com/en-us/102149)
explains exactly what it protects. In short, SIP stops root from modifying the system
volume, loading unsigned kernel extensions and attaching to Apple's processes, and that
last one is what SpaceSwitchSpeed needs. Gatekeeper, notarisation, sandboxing, TCC and
FileVault all keep working with SIP off. What you give up is a defence-in-depth layer
for the case where something has already got root on your machine.

Whether that trade is acceptable is your call. A shared Mac, a work laptop under an MDM
policy, or anything holding credentials you cannot rotate: leave SIP on and don't use
this tool. A personal development Mac where you already run unsigned binaries: the
marginal risk is small, and tools such as yabai's scripting addition need exactly the
same thing.

**SpaceSwitchSpeed will never disable SIP for you.** It detects the state, says so, and
stops. Turning it off is a deliberate act performed from Recovery, by you.

### How to disable it

Apple documents the procedure in
[Disabling and Enabling System Integrity Protection](https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection).
On an Apple Silicon Mac:

1. Shut the Mac down completely.
2. Press and **hold** the power button until "Loading startup options" appears.
3. Click **Options → Continue** to enter
   [macOS Recovery](https://support.apple.com/en-us/102518).
4. Choose **Utilities → Terminal** from the menu bar.
5. Run:

   ```bash
   csrutil disable
   ```

6. Confirm, then restart normally.

Verify with `csrutil status`, which should report `disabled`.

> With FileVault on, Recovery asks you to unlock the disk first. That is expected, and
> FileVault stays on.

### How to re-enable it

The same steps with `csrutil enable`. It is completely reversible, and nothing
SpaceSwitchSpeed does needs undoing first: the patch only ever existed in memory.

## How it works

Dock does not play a timed animation when you switch Space. It runs a spring: every
frame it moves the desktop a little closer to where it is going, and the animation ends
when the spring has settled, not when a clock runs out. Two constants in Dock's code set
how stiff that spring is, and they are what make the switch take a third of a second.

SpaceSwitchSpeed changes those two constants in the running Dock process. It rewrites
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

## What SpaceSwitchSpeed does not do

Worth being explicit, because "patches Dock" sounds alarming:

- **It does not modify any file on disk.** Not Dock, not the system volume, nothing.
  The Dock binary is byte-identical before and after.
- **It does not persist in Dock.** The change lives in one process's memory. `killall Dock`
  removes it completely and unconditionally, and that is the escape hatch if anything
  ever looks wrong.
- **It does not disable SIP, run a curl-to-bash installer, or phone home.**
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
| macOS | Verified against the Dock of every release listed [below](#which-versions-are-verified). macOS 15 Sequoia is the floor: 13 and 14 drive the animation from a fixed 60 Hz timestep rather than the display's, and SpaceSwitchSpeed refuses to patch them. |
| Displays | Nothing to configure. The coefficients are per-frame, so refresh rate and multi-monitor setups make no practical difference. |
| SIP | Off, or a custom configuration with debugging restrictions off (`csrutil enable --without debug`). Nothing else in SIP matters to it. |

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

**SpaceSwitchSpeed → Remove SpaceSwitchSpeed…** puts Dock back, removes the helper and
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

**Is this the same as yabai / Amethyst / Rectangle?**
No. Those are window managers. SpaceSwitchSpeed changes one animation and nothing else. It
does not require yabai's scripting addition, though both need SIP disabled for related
reasons.

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

**Why does it need root as well as SIP disabled?**
SIP disabled makes `task_for_pid` on a platform binary *possible*; root makes it
*permitted*. Both checks are separate and both must pass.

## Contributing

Issues and pull requests are welcome, particularly reports from macOS versions or
hardware I cannot test on. If SpaceSwitchSpeed refuses to find the integrator on your
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
