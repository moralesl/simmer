# simmer v2 — brief for a fresh start

v1 works, is tested and is in use. This document exists so a rebuild starts from
what was *learned* rather than from what was *shipped*. Read the "verified
platform facts" section before designing anything — most of it was bought with
failed attempts, and re-deriving it costs the same again.

## Decided 2026-08-23: fresh Swift v2, v1 frozen as the executable spec

Luis approved the rewrite. The shape:

- **One .app** containing everything: the menu bar (own NSStatusItem, pot icon),
  the guard (event-driven — IOKit power/battery/thermal callbacks instead of a
  30s poll), the notifier (the bundle IS the identity), and the CLI as a binary
  inside `Contents/MacOS/`, symlinked onto PATH. Raycast/Alfred stay shims that
  exec the CLI — adding a surface must stay a one-file affair.
- **CONTRACTS.md is the law.** The CLI surface, exit codes, machine output and
  the test seam stay byte-compatible, so the v1 suite (92 assertions) runs
  unmodified against the v2 binary — differential testing against v1 is the
  safety mechanism that replaces incremental caution.
- **Install**: clone/brew → build → ONE native admin password prompt (spike B,
  verified: `do shell script … with administrator privileges` works from an
  unsigned context and runs as root) writes the sudoers rule → notification
  permission banner (verified earlier, own icon) → done. No pasted sudo, no
  cert, no account, nothing downloaded past Gatekeeper.
- **Git**: same repo; tag `v1`, branch `v1`; `main` becomes Swift when the suite
  passes against it; v1 may be pruned later.
- Spike A (ad-hoc NSStatusItem) — see facts table; Spike B — passed.

## D1 (proposed): the claims ledger — the outside-the-box change

v1 models ONE lease with an owner, which forces conflict rules (`--force`,
refusals). Reality is concurrent: an agent needs until 15:00, the human until
15:30, a build until 14:45. Power management itself is counted assertions, not a
single switch — simmer should be too:

- `simmer 2h -r x` creates a **claim** (id, owner, reason, deadline). Everyone
  can hold one; nobody can touch anyone else's. `--force` and owner refusal
  disappear *by construction* (contract guarantee 4 gets stronger, not weaker).
- The machine stays awake until the LATEST live claim; the guard retires claims
  individually on their deadlines; floor/thermal end all of them.
- `budget` answers over the aggregate (the machine's guarantee, which is what an
  agent actually needs); `status` lists claims; the menu bar shows the union
  countdown with per-claim release.
- `simmer down` releases *your* claims; `down --all` everything.

**Human primacy — the condition D1 was approved under.** The human has the final
say, mechanically, not by convention:

- A human can release ANY claim; an agent can release only its own. The menu bar
  is a human surface, so every release control there acts with human authority.
- **The cap**: `simmer cap 23:00` (menu bar: "Nothing past…") is a human-set
  ceiling that clips every claim, current and future. Claims request from below;
  the cap rules from above. An agent hitting the cap gets a truthful budget
  answer, not an error to route around.
- **What the human sees**: the menu bar countdown is the AGGREGATE — what the
  machine will actually do — with the dropdown listing each claim as
  `owner · reason · until` (👤 you, 🤖 agent, ⚙ run:…), each with its own
  release. Notifications fire on aggregate changes only (latest deadline moved,
  everything released, floor/thermal) — never per-claim spam.

Cost: state becomes a claims dir instead of one lease file (format=2), and the
v1 suite's owner-refusal assertions become documented deltas. Benefit: the
entire conflict UX disappears, and multi-agent machines (Luis's reality) stop
fighting over one slot.

## Also new in v2 (cheap now, designed in rather than bolted on)

- **events.jsonl** — append-only, versioned event stream (took, extended,
  warned, released+why). Feeds `simmer log`, the menu bar history, and:
- **`simmer watch`** — stream events as they happen; agents react instead of
  poll, and hooks become composition (`simmer watch | while read …`) instead of
  a feature.
- **`simmer why`** — "why is this Mac awake?" / "why did it sleep at 03:12?"
  answered from events, for humans.
- **`--lock`** — lock the screen when taking a claim (the gap COMPARISON.md
  names; Amphetamine is currently the only tool offering it).

## Menu bar design

The menu bar has exactly two jobs: **ambient truth** (zero clicks) and the
**80% actions** (one click). Everything else is deliberately CLI.

- Icon = template SF Symbol + countdown text: quiet moon when idle, `42m` when
  active, orange under 5 min, red for orphan/error. Light/dark follows the
  system because template images do.
- Idle menu: presets 30m · 1h · 2h · 4h, "Until…", nothing else.
- Active menu: status header (until · reason · battery/floor), per-claim rows
  when D1 lands, Extend +15m / +1h, Release.
- **⌥ (Option) is the power layer**, the macOS-native convention: holding ⌥
  swaps Extend→+3h, Release→Release all, reveals "forever", and turns every
  action into **"Copy as CLI command"** — the menu teaches the CLI instead of
  hiding it, which is the agent-tool bridge in one feature.
- Settings window (login item, default floor, transport, doctor, log): behind a
  single "Settings…" item. Never in the top level.
- Never in the menu at all: force semantics, owner juggling, transports.

## Build phases

0. **D1 lands in v1/bash first** (format=2 claims dir, aggregate budget/status,
   cap, human-primacy release rules) plus a `SIMMER_FAKE_NOW` seam — nine
   `date +%s` call sites currently make warn-once / remind / deadline-crossing
   testable only via hand-written timestamps, and those are exactly the paths a
   differential run must compare. Also lands here: `--require-ac` (release when
   the charger disappears — an overnight lease is only sane on the charger) and
   a pre-floor warning at floor+10% ("plug in, or I hand the switch back
   soon"). Rationale for the sequencing: the suite then covers claims under
   real multi-agent use BEFORE the language changes, so a differential
   divergence is attributable to Swift, not to the new model.
1. `Sources/SimmerCore` — claims, guard logic, budget, render, seam.
2. CLI target passing the ported v1 suite (byte-compatible surface).
3. The app: NSStatusItem + event-driven guard + notifier merged; differential
   runs against v1 throughout.
4. Install: build + admin prompt + permission banner; brew tap.
5. Swap main; tag v1 (prune later at Luis's call).
6. **The Claude Code hook** — the flagship integration, possible because no
   competitor has a query API: `integrations/claude-code/` ships a SessionStart
   hook injecting one line of context ("simmer: no claim — the lid can
   interrupt you") and a UserPromptSubmit hook that appends a line ONLY when
   `budget` exits 1 or 3. The FOR-AGENTS protocol moves from prose an agent
   must remember to a gate the harness enforces — the enforcement-ladder move,
   applied to simmer itself. `simmer watch` gets its first consumer.

## Verified platform facts — do not re-derive these

New for v2 (2026-08-23):

| Fact | Status |
|---|---|
| Native admin prompt (`do shell script … with administrator privileges`) from an unsigned context | ✅ verified — ran as root after one password dialog |
| Ad-hoc app shows its own NSStatusItem (menu bar) | ✅ verified — 🍲 + countdown + working dropdown, eyes-on |


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
Read CONTRACTS.md, docs/V2-BRIEF.md, ARCHITECTURE.md and docs/FOR-AGENTS.md in
~/workspace/tools/simmer. v1 (bash, on main until the swap) is the reference
implementation and its test suite is the acceptance test.

Build simmer v2: one Swift .app containing the menu bar, the event-driven guard,
the notifier and the CLI, per the decided shape and build phases in the brief.
The CLI surface, exit codes, machine output and test seam are contract-frozen —
the v1 suite must pass unmodified against the v2 binary before anything else is
polished. Decision D1 (claims ledger) is approved/rejected in CONTRACTS.md — read
it there, do not relitigate it.

Start with phase 0: D1 in the EXISTING bash v1 (claims ledger, cap, human
primacy, SIMMER_FAKE_NOW, --require-ac, pre-floor warning), suite extended to
cover it, committed atomically. Only then begin Swift. Work in phases with
atomic commits; differential-test against the v1 binary in the fake environment
after every phase. Platform facts in the brief are verified
— do not re-spike them. Ask Luis only what a phase genuinely blocks on.
```
