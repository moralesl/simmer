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

3. **One app, not four moving parts.** Now unblocked for zero dollars: the
   ad-hoc recipe means the app can own its notification identity, so the menu
   bar, the guard and the notifier can be one locally-built bundle with the pot
   icon everywhere.

   (previously:) v1 is a script, a LaunchAgent, a SwiftBar
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

**Closed 2026-08-22: there is no unprivileged path to holding the lid.**
Tested: an IOKit assertion with `AppliesOnLidClose` returns `kIOReturnNotPrivileged`
(0xe00002c1) for a non-root process, on both `PreventSystemSleep` and
`PreventUserIdleSystemSleep`; the identical assertion without the property succeeds,
which is merely what caffeinate already does. Independent confirmation: LidRun, a
commercial product for exactly this use case ("keep Claude Code running when your
MacBook is closed"), ships `pmset -a disablesleep` behind a privileged helper with
auto-reversion and a 20% battery floor — simmer's architecture, including the same
default. The sudoers rule stays, as a validated design rather than a workaround;
the remaining softening is packaging: offer the one sudo command interactively at
install.

### Notifications

A notification carries the name and icon of **the bundle that posted it**. Always.
No flag changes this. Every attempt below was actually run:

| Transport | Displays? | Identity | Notes |
|---|---|---|---|
| `osascript` | ✅ | Script Editor | works; quill icon; alert style must be Banners |
| SwiftBar URL scheme | ✅ | SwiftBar | honours title, subtitle and body |
| Shortcuts (`/usr/bin/shortcuts run`) | ✅ | Shortcuts | **title is the shortcut's name**; body via Shortcut Input |
| `terminal-notifier` (own identity) | ❌ | — | 2017 binary; registers in the legacy DB, never shown |
| **`terminal-notifier -sender <id>`** | ✅ | **the named app** | posts AS another installed app — Safari's icon displayed, verified by screenshot. The one mechanism that changes an icon without a paid signature |
| AppleScript applet with own bundle | ❌ | Script Editor | applets do **not** own their notifications — attributed to the OSA host |
| **Our own ad-hoc-signed bundle** | ✅ | **our own icon and name** | THE answer — see the verified recipe above. Earlier failures were a cached per-bundle-id denial from a first run in `/tmp`, not a platform refusal |

**Constraint from Luis: no paid signature — everything self-built.** And that
constraint is satisfiable, verified end to end on 2026-08-22:

### The verified recipe: own-icon notifications, zero dollars

1. A ~40-line Swift binary calling `UNUserNotificationCenter`
   (`requestAuthorization`, then post; keep the process alive ~25s so the
   permission flow can complete).
2. Wrap it in a minimal `.app` bundle: `Info.plist` with bundle id, name and
   `CFBundleIconFile`, the `.icns` in `Resources`.
3. **Ad-hoc sign it** (`codesign --force --deep --sign -`). No certificate of any
   kind is needed — verified by A/B test against a trusted self-signed cert;
   both behave identically.
4. Install to `~/Applications`, register: `lsregister -f <app>`.
5. Launch once via LaunchServices (`open -a`). macOS shows the permission
   request **as a notification banner carrying the app's own icon** — not a
   modal dialog.
6. The user clicks Allow once — the same one-time step Slack or any real app
   requires. From then on, banners carry the app's own name and icon.

Traps, each personally paid for:

- **A denial is cached per bundle id, forever.** The first attempt ran from
  `/tmp`, was refused, and every later test against that id inherited the
  refusal — which produced two false "structurally impossible" conclusions.
  Burned ids on Luis's machine: `ai.causaprima.simmer.notifier`. Production
  should start clean, e.g. `io.github.moralesl.simmer`.
- `UNErrorDomain Code=1` while the permission banner is pending means "not YET
  authorized". Checking the API state races against the human clicking Allow.
- The permission request only fires when launched via LaunchServices, not when
  the binary is executed directly.
- The community never found this because their tools (terminal-notifier,
  alerter) are bare binaries, not installed app bundles — alerter borrows
  `com.apple.Terminal`'s identity instead. An installed, registered, ad-hoc
  bundle is the missing move.

### Distribution — for colleagues and for OSS

The Gatekeeper fact that shapes everything: quarantine only attaches to
*browser-style downloads*. `git clone`, `brew`, and `curl` set no quarantine
xattr, so an ad-hoc bundle **built or fetched that way runs with no warnings**.
A `.dmg` or a zip downloaded in a browser would hit "unidentified developer" —
so we simply never distribute that way.

| Audience | Channel | Why it works |
|---|---|---|
| Developers / OSS | **Homebrew tap**: `brew install moralesl/tap/simmer` | having brew *guarantees* the Xcode CLT, so the formula compiles the notifier locally — no binary blobs in git, `brew upgrade` for updates |
| Non-technical colleagues | **one pasted line**: `curl -fsSL …/install.sh \| bash` | checks for CLT (offers `xcode-select --install`), builds, registers, launches once, and ends with "click Allow on the banner that just appeared" |
| Never | committed binaries, .dmg, .zip | binaries in git rot and repel reviewers; browser downloads hit Gatekeeper |

The one-time permission banner *is* the onboarding: the installer's last act
should be launching the app so the banner (with the pot icon) is on screen at
the moment the instructions say "click Allow".

The menu bar remains the channel that cannot be suppressed and is identical
across surfaces by construction; notifications are now its equal rather than its
apology.

## Open decisions — for Luis, before coding

1. ~~Apple Developer Program~~ **Decided: no paid signature, everything
   self-built.** The icon question therefore hangs on spike 2 (self-signed cert).
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

## Do these three spikes before anything else

1. **Closed-display without root.** Is Amphetamine's public API real and usable?
   If yes, the scariest install step disappears.
2. ~~A signed/self-signed notifier~~ **Done, positive — better than hoped.**
   Ad-hoc suffices; the verified recipe is above. The A/B against a trusted
   self-signed cert showed no difference, so no certificate step exists at all.

Spike 1 (closed-display without root) is closed, negative — see the awake facts.
The privileged step is irreducible; v2's job is to make it graceful (one prompted
sudo at install), not to remove it.

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
