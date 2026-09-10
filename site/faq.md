---
title: Space Switch Speed FAQ — macOS Space animation answers
og_title: Space Switch Speed FAQ
description: Will a macOS update break it, is it slower on ProMotion, can the animation go entirely, does it need root, and is it the same thing as yabai. Answered.
schema: faq
heading: FAQ
---

# Frequently asked questions

## Will a macOS update break it?

It may. The animation is found by the shape of its code rather than by address, which has
held across every release from macOS 15.0 to 27.0 beta 8, but a real rewrite of Dock would
defeat it. When that happens it refuses to patch rather than guessing, and `killall Dock`
clears anything it had already done.

## Is the animation slower on a 120 Hz or ProMotion display?

Yes. Dock's spring runs per frame, so the same constants animate about a third slower on a
120 Hz display than on a 60 Hz one, and Apple has not changed that. Space Switch Speed does
not read the refresh rate; each stop is roughly the same fraction of Apple's timing on any
display, within a tenth at Balanced and a fifth at Instant. There is a
[full explanation with the measurements](/SpaceSwitchSpeed/high-refresh-rate/).

## Is this about "Spaces", "desktops" or "workspaces"?

All the same thing. Full-screen apps are Spaces too, so the slider covers moving in and out
of those as well.

## Can I remove the animation entirely?

Instant covers the distance in 50–70 ms, which reads as a cut. Anything faster fights the
trackpad's gesture tracking. For no animation at all, use Reduce Motion in System Settings
→ Accessibility → Display, which also flattens every other animation on the system.

## Does it slow down my Mac or use battery?

No. It changes two numbers Dock already reads every frame. The helper waits on events and
wakes once a minute to check nothing was missed. No code is injected.

## Is this the same as yabai, Amethyst or Rectangle?

No. Those are window managers. This changes one animation.
[Tools that do the same job are compared here.](/SpaceSwitchSpeed/alternatives/)

## Why does it need root as well as the SIP change?

The SIP change makes attaching to Dock possible; root makes it permitted. Both checks are
separate. Self-signing the entitlement does not work either, because AMFI reserves it for
Apple-signed tools.

## Why doesn't `defaults write com.apple.dock workspaces-swoosh-animation-off` work?

Because that key was removed from Dock over a decade ago, and the string is not in the
binary any more. `defaults write` never fails, so a command that does nothing looks
identical to one that works. There is
[a longer answer, with a verified list of which Dock keys are still alive](/SpaceSwitchSpeed/why-defaults-write-doesnt-work/).

## Does it modify Dock or anything on the system volume?

No. The Dock binary on disk is byte-identical before and after. The change lives in the
memory of one running process, and everything the app writes to disk is
[listed in full](/SpaceSwitchSpeed/install/#uninstalling).

## Does it work on an Intel Mac, or on macOS 13 or 14?

No. Apple Silicon and macOS 15 Sequoia or later only. macOS 13 Ventura and 14 Sonoma drive
the animation from a fixed 60 Hz timestep rather than the display's, so the code shape never
matches and they are refused rather than patched.

## Is it safe to turn SIP's debugging restrictions off?

It is a real tradeoff, not a formality. `csrutil enable --without debug` keeps filesystem
protections, kext signing, DTrace restrictions, NVRAM protections and BaseSystem
verification, and gives up only the ability to stop a root process attaching to another
process. On a shared or managed Mac, don't. There is
[a full breakdown of what you keep and what you give up](/SpaceSwitchSpeed/install/#system-integrity-protection).

## How do I uninstall it completely?

Space Switch Speed → Remove Space Switch Speed… puts Dock back, removes everything it
installed and quits; then move the app to the Trash. Deleting the app alone also works — the
helper notices within a few minutes, restores Dock and removes itself.

## Is it free?

Yes, and open source under the AGPL-3.0-or-later.
[The source is on GitHub.](https://github.com/bisak/SpaceSwitchSpeed)
