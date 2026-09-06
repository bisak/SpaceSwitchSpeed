# Security

## Reporting something

Use GitHub's [private vulnerability reporting](https://github.com/bisak/SpaceSwitchSpeed/security/advisories/new).
That is the channel I watch, and it keeps the report between us until there is a fix
worth announcing.

I maintain this on my own, so I won't promise a response time. In practice you will hear
what I think within a few days. I'll credit you in the release notes unless you would
rather I didn't. There is no bounty.

## Already known, so not a finding

**SIP's debugging restrictions have to be off.** Space Switch Speed cannot open Dock's
task port with them on, and the tradeoff is spelled out in
[the README](README.md#system-integrity-protection). Reports that come down to "weakening
SIP weakens macOS" are correct and already documented, so I'll close them.

**Admin users can write the settings file.** Deliberate, and explained below.

**`killall Dock` undoes everything.** The patch only ever exists in memory. That is the
escape hatch, not a weakness.

## Where the boundary actually is

Worth knowing before you go looking, because it decides what counts:

- `/Library/LaunchDaemons/com.bisak.spaceswitchspeed.helper.plist` and
  `/Library/PrivilegedHelperTools/com.bisak.spaceswitchspeed.helper` are root-owned and
  not group- or world-writable. The installer checks that `/Library/PrivilegedHelperTools`
  is root-owned with no group or other write bit before it installs there, and refuses if
  it isn't. A way past that check is a real finding.

- `/Library/Application Support/SpaceSwitchSpeed` is `root:admin`, mode `0775`, so any
  admin user can write `config.json` without an authorisation prompt. This is on purpose:
  the alternative is a password prompt every time the slider moves, and an admin user on
  macOS can become root anyway. The file expresses one number, and it is clamped to
  0.2–1.0 before it reaches the patcher.

- The root helper writes to Dock's memory and does nothing else. No socket, no XPC
  service, no network input, and no argument that names something to run.

So the findings I want are: a way for a **non-admin** user to change what the root helper
does, a path where the helper reads or runs something an unprivileged user controls, or a
way to make the patcher write outside the words it verified first.

## Versions

The most recent release. I don't backport.
