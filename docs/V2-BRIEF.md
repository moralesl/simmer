# simmer v2 — brief for a fresh start

v1 works, is tested and is in use. This document exists so a rebuild starts from
what was *learned* rather than from what was *shipped*. Read the "verified
platform facts" section before designing anything — most of it was bought with
failed attempts, and re-deriving it costs the same again.

## What v2 is for

**One core, three ways to reach it, and no seams between them.**

- **CLI** — for people in a terminal and for agents
- **Menu bar** — the always-visible truth, which macOS cannot suppress
- **Launcher (Raycast)** — status and control without a terminal

Judged against three audiences, in this order:

1. **An agent** can take, check and hand back time, and can tell how much is left,
   without parsing prose.
2. **A human** can see at a glance what is holding their Mac awake and why.
3. **A non-technical colleague** can install it and use it without a terminal.

Point 3 is the one v1 fails. Everything else is refinement.

## Keep — v1 got these right

- **The lease and the guard.** Borrow the switch with a deadline; something other
  than memory hands it back. Four release conditions: deadline, battery floor,
  explicit release, and *found enabled with no lease* (the self-healing branch,
  which is what makes forgetting structurally impossible).
- **One writer of state.** Exactly one component touches `pmset` and the lease.
- **The test seam.** Every OS read/write behind a function that tests can
  substitute. It is why the suite is hermetic, and it is the single best decision
  in v1. Generalise it: any OS call, not just power.
- **The agent contract.** `budget --need 20m` answering in the exit code —
  `0` room, `1` not enough, `3` no lease at all. `3` must stay distinct from `1`:
  a small budget and an absent guarantee are different things.
- **`--owner` plus refusal.** An automated job must not silently overwrite a
  lease a human set.

## Change — each earned by a specific failure

1. **The core renders every surface.** v1 had three separate renderers (SwiftBar
   130 lines, Alfred 127, Raycast ×4) parsing the same state. That duplication
   produced six copies of a binary-resolver, two Raycast commands that were dead
   for a day, and a menu bar icon drawn twice. v2: `simmer render menubar|raycast`
   in the core. Front-ends become one line, and a fourth surface costs one line.

2. **Swift, not bash.** Two reasons. `/bin/bash` is 3.2, which cost real bugs
   (`shift` under `set -e`, `${var,,}`, array quoting, `eval` in tests). And a
   signed bundle is the *only* way to own the notification identity — in Swift
   that stops being a fight.

3. **One app, not four moving parts.** v1 is a script, a LaunchAgent, a SwiftBar
   plugin and launcher scripts. A Swift menu-bar app can *be* the menu bar, the
   guard (as a login item) and the notifier, with a small CLI alongside sharing
   the same state. A non-technical colleague then installs **one thing**.

4. **Spike every platform primitive before designing on it.** The notification
   layer was rebuilt four times because an unverified assumption became a
   premise. Write five lines, watch it work, *then* design.

5. **Anything OS-version-dependent is a setting plus a self-test, on day one.**
   `simmer notify-test` should have been the first design, not the fifth.

6. **Start extracted, complete.** README with badges, ARCHITECTURE, CHANGELOG,
   CI and a `make`-style interface in the *initial* commit. v1 accreted these
   over six commits and still reads that way.

## Verified platform facts — do not re-derive these

Tested on macOS 26.5.1, Apple silicon, August 2026.

### Keeping the machine awake

| Fact | Consequence |
|---|---|
| `caffeinate` assertions do **not** survive the lid | it cannot be the mechanism |
| `pmset -a disablesleep 1` is the only thing that holds a closed lid | needs root |
| That setting has no expiry, no indicator, and **survives reboots** | the entire reason a guard exists |
| It needs root → a `/etc/sudoers.d` rule | **the main onboarding blocker for non-technical users** |
| `caffeinate -ims` leaves the display free to sleep; `-dims` holds it | v1 default is `-ims`, which is right |
| `launchctl bootout` returns *before* the job is gone | wait for it, or `bootstrap` fails with `5: Input/output error` |

**Open research, high value:** Amphetamine documents a *public* API for
closed-display mode. If that is real, a signed helper could hold the lid **without
root**, removing the sudoers step entirely. Nobody has checked. Do this first —
it may reshape the whole install story.

### Notifications

A notification carries the name and icon of **the bundle that posted it**. Always.
No flag changes this. Every attempt below was actually run:

| Transport | Displays? | Identity | Notes |
|---|---|---|---|
| `osascript` | ✅ | Script Editor | works; quill icon; alert style must be Banners |
| SwiftBar URL scheme | ✅ | SwiftBar | honours title, subtitle and body |
| Shortcuts (`/usr/bin/shortcuts run`) | ✅ | Shortcuts | **title is the shortcut's name**; body via Shortcut Input |
| `terminal-notifier` | ❌ | — | 2017 binary, `NSUserNotification`; registers in the legacy DB, never shown |
| AppleScript applet with own bundle | ❌ | Script Editor | applets do **not** own their notifications — attributed to the OSA host |
| **Our own ad-hoc-signed bundle** | ❌ | — | `UNErrorDomain Code=1 "Notifications are not allowed"`. Tried in `/tmp` and `~/Applications`, registered with `lsregister`, with and without `LSUIElement` |

**Conclusion: simmer's own icon on a banner requires a Developer ID signature.**
Ad-hoc signing is refused. That is a paid Apple Developer account plus a signing
step, and it is a real decision rather than a technicality.

Until then the menu bar is the honest primary channel: it cannot be suppressed,
it is always correct, and it is identical across surfaces by construction.

## Open decisions — for Luis, before coding

1. **Apple Developer Program, $99/yr?** Unlocks: simmer's own notification icon,
   a notarised app colleagues install without Gatekeeper warnings, and a
   Homebrew cask. Without it, v2's notifications look exactly like v1's.
   *Recommendation: yes, if this is really going to the team.*
2. **Architecture: one app or several parts?** A single menu-bar app as guard +
   UI + notifier, started as a login item — or v1's split (LaunchAgent guard,
   separate UI, separate notifier). *Recommendation: one app; it is the only
   version a non-technical colleague can install unaided.*
3. **Does the sudoers rule survive?** Depends entirely on the closed-display API
   research above. Do that spike before committing to an install story.
4. **Distribution.** Homebrew cask of a signed `.app`, a DMG, or a tap for the
   CLI? Depends on 1.
5. **Raycast: script commands or a real extension?** Script commands are free and
   already work. An extension buys a live list view and Raycast Store
   distribution — worth it only for reach. *Recommendation: script commands
   first.*
6. **Keep the name, repo and bundle id?** No reason to change them.

## Do these two spikes before anything else

1. **Closed-display without root.** Is Amphetamine's public API real and usable?
   If yes, the scariest install step disappears.
2. **A signed notification.** Only meaningful after decision 1. Prove a banner
   appears from a Developer ID-signed bundle *before* building anything on it.

Neither is a day's work, and both change the design.

## Starting prompt

```
Read docs/V2-BRIEF.md in ~/workspace/tools/simmer, plus ARCHITECTURE.md and
docs/FOR-AGENTS.md for the current design and the agent contract.

I want to rebuild simmer as v2: one core with three interaction surfaces (CLI,
menu bar, Raycast) that an agent can drive and a human can observe, and that a
non-technical colleague can install without a terminal. Same product, better
built.

Start with the two spikes named in the brief — the closed-display API without
root, and a signed notification from our own bundle. Show me the results before
designing anything. Do not carry over v1 code; carry over the contracts:
the lease and guard semantics, budget's exit codes, --owner, and the test seam.

The brief lists six open decisions. Ask me the ones that block you, in the order
they block you.
```
