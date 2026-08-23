# Platform facts — verified, do not re-derive

Every line below was bought with a failed attempt.
Re-deriving it costs the same again, so this page is quarantined from the planning documents: nothing here is a plan or an opinion, and nothing here should be changed except by running the experiment again and finding a different answer.

Tested on macOS 26.5.1, Apple silicon, August 2026, unless a line says otherwise.

| Fact | Status |
|---|---|
| Ad-hoc app shows its own NSStatusItem (menu bar) | ✅ verified — 🍲 + countdown + working dropdown, eyes-on |
| Native admin prompt (`do shell script … with administrator privileges`) from an unsigned context | ✅ verified — ran as root after one password dialog. **Deliberately not used:** it means an app-composed shell string running as root, so simmer shows the command and a human runs it instead (`SECURITY.md`) |

### Keeping the machine awake

| Fact | Consequence |
|---|---|
| `caffeinate` assertions do **not** survive the lid | it cannot be the mechanism |
| `pmset -a disablesleep 1` is the only thing that holds a closed lid | needs root |
| That setting has no expiry, no indicator, and **survives reboots** | the entire reason a guard exists |
| It needs root → a `/etc/sudoers.d` rule | **the main onboarding blocker for non-technical users** |
| `caffeinate -ims` leaves the display free to sleep; `-dims` holds it | the spike defaulted to `-ims`, which is right |
| `launchctl bootout` returns *before* the job is gone | wait for it, or `bootstrap` fails with `5: Input/output error` |

**Closed 2026-08-22: there is no unprivileged path to holding the lid.** Tested: an IOKit assertion with `AppliesOnLidClose` returns `kIOReturnNotPrivileged` (0xe00002c1) for a non-root process, on both `PreventSystemSleep` and `PreventUserIdleSystemSleep`; the identical assertion without the property succeeds, which is merely what caffeinate already does.
Independent confirmation: LidRun, a commercial product for exactly this use case ("keep Claude Code running when your MacBook is closed"), ships `pmset -a disablesleep` behind a privileged helper with auto-reversion and a 20% battery floor — simmer's architecture, including the same default.
The sudoers rule stays, as a validated design rather than a workaround; the remaining softening is packaging: show the exact command at install time and let the person run it.

### Notifications

A notification carries the name and icon of **the bundle that posted it**.
Always.
No flag changes this.
Every attempt below was actually run:

| Transport | Displays? | Identity | Notes |
|---|---|---|---|
| `osascript` | ✅ | Script Editor | works; quill icon; alert style must be Banners |
| SwiftBar URL scheme | ✅ | SwiftBar | honours title, subtitle and body |
| Shortcuts (`/usr/bin/shortcuts run`) | ✅ | Shortcuts | **title is the shortcut's name**; body via Shortcut Input |
| `terminal-notifier` (own identity) | ❌ | — | 2017 binary; registers in the legacy DB, never shown |
| **`terminal-notifier -sender <id>`** | ✅ | **the named app** | posts AS another installed app — Safari's icon displayed, verified by screenshot. The one mechanism that changes an icon without a paid signature |
| AppleScript applet with own bundle | ❌ | Script Editor | applets do **not** own their notifications — attributed to the OSA host |
| **Our own ad-hoc-signed bundle** | ✅ | **our own icon and name** | THE answer — see the verified recipe below. Earlier failures were a cached per-bundle-id denial from a first run in `/tmp`, not a platform refusal |

**Constraint from Luis: no paid signature — everything self-built.** And that constraint is satisfiable, verified end to end on 2026-08-22:

### The verified recipe: own-icon notifications, zero dollars

1. A ~40-line Swift binary calling `UNUserNotificationCenter` (`requestAuthorization`, then post; keep the process alive ~25s so the permission flow can complete).
2. Wrap it in a minimal `.app` bundle: `Info.plist` with bundle id, name and `CFBundleIconFile`, the `.icns` in `Resources`.
3. **Ad-hoc sign it** (`codesign --force --deep --sign -`).
   No certificate of any kind is needed — verified by A/B test against a trusted self-signed cert; both behave identically.
4. Install to `~/Applications`, register: `lsregister -f <app>`.
5. Launch once via LaunchServices (`open -a`). macOS shows the permission request **as a notification banner carrying the app's own icon** — not a modal dialog.
6. The user clicks Allow once — the same one-time step Slack or any real app requires.
   From then on, banners carry the app's own name and icon.

Traps, each personally paid for:

- **A denial is cached per bundle id, forever**, and can only be undone by hand in System Settings — not by reinstalling, not by deleting the bundle.
  A first run from `/tmp` that gets refused poisons that id for good, which once produced two false "structurally impossible" conclusions.
  So bundle ids are a resource that can only be spent: develop under a throwaway `.devN` id and promote the production id only once the app is known-good.
- **The grant belongs to the EXECUTABLE, not the bundle.** With two executables in one bundle, each reads (and would request) its *own* authorization state.
  A CLI binary in `Contents/MacOS/` reporting `notDetermined` while the app's banners work perfectly, on the same bundle id, is not a reset grant — it is the CLI's own, never granted.
  Hence: the app is the only poster, the CLI enqueues into `$STATE/notify-spool.jsonl`, and `doctor` reads the app's heartbeat rather than asking the notification centre a question about the wrong binary.
  Asserted by `StructureTests.theCLICannotReachTheNotificationCentre`.
- **A bundle built anywhere gets registered with LaunchServices**, and the registration outlives the directory it was built in — invisible to every ordinary check, because it is not on `PATH`, not in `~/Applications`, not a launchd job, and `mdfind` does not index `/private/tmp`.
  Only `lsregister` shows it, so build spikes under a `.spike` id and unregister them when done:

```
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister
"$lsregister" -dump | grep -c '<bundle id>'      # is it still known?
"$lsregister" -u /path/to/Some.app               # forget it
```
- `UNErrorDomain Code=1` while the permission banner is pending means "not YET authorized".
  Checking the API state races against the human clicking Allow.
- The permission request only fires when launched via LaunchServices, not when the binary is executed directly.
- The community never found this because their tools (terminal-notifier, alerter) are bare binaries, not installed app bundles — alerter borrows `com.apple.Terminal`'s identity instead.
  An installed, registered, ad-hoc bundle is the missing move.

### Distribution — for colleagues and for OSS

The Gatekeeper fact that shapes everything: quarantine only attaches to *browser-style downloads*.
`git clone`, `brew`, and `curl` set no quarantine xattr, so an ad-hoc bundle **built or fetched that way runs with no warnings**.
A `.dmg` or a zip downloaded in a browser would hit "unidentified developer" — so we simply never distribute that way.

| Audience | Channel | Why it works |
|---|---|---|
| Developers / OSS | **Homebrew tap**: `brew install moralesl/tap/simmer` (on `ROADMAP.md`) | having brew *guarantees* the Xcode CLT, so the formula compiles locally — no binary blobs in git, `brew upgrade` for updates |
| Non-technical colleagues | **one pasted line**: `curl -fsSL …/bootstrap.sh \| bash` | checks for CLT (offers `xcode-select --install`), builds, registers, launches once, and ends with "click Allow on the banner that just appeared" |
| Never | committed binaries, .dmg, .zip | binaries in git rot and repel reviewers; browser downloads hit Gatekeeper |

The one-time permission banner *is* the onboarding: the installer's last act should be launching the app so the banner (with the pot icon) is on screen at the moment the instructions say "click Allow".

The menu bar remains the channel that cannot be suppressed and is identical across surfaces by construction; notifications are now its equal rather than its apology.

## What none of this removes

The privileged step is irreducible.
There is no unprivileged path to holding a closed lid, which was closed negatively on 2026-08-22 and independently confirmed by a commercial product shipping the same architecture.
So `pmset -a disablesleep` behind a `/etc/sudoers.d` rule is a **validated design**, not a workaround, and the only thing left to improve is how gracefully it is asked for.

## Facts for anyone touching the installer or the build

Each cost an hour, and none of them errors — the wrong thing simply happens.

- **`command -v git` is not a check for git.** On a Mac with no developer tools `/usr/bin/git` exists: a shim that pops Apple's installer dialog and exits non-zero.
  So `command -v` succeeds on exactly the machines where git does not work, which is a new colleague's most likely starting state.
  Same for `swiftc`.
  Run the thing and look at its exit code.
- **A script piped from `curl` has no path on disk.** `dirname "${BASH_SOURCE[0]}"` yields the *current working directory*, silently, so anything read relative to the script comes from somewhere unrelated.
  `bootstrap.sh` clones and works from the clone for this reason.
- **A malformed file in `/etc/sudoers.d` can break `sudo` entirely** — not just the rule — which on a laptop with one admin account is a genuinely bad afternoon.
  `visudo -c -f <file>` needs no root to check a file you own, so validate before installing, always.
- **An installer that checks for a *capability* adopts a stranger's grant.** `sudo -nl /usr/bin/pmset …` answers "is this allowed", not "did I write it": where another file already grants it, the installer reports success forever, never writes its own rule, and then lies during uninstall about a file that never existed.
  Check for the own file **and** the capability, and report the difference.
- **`launchctl bootout` returns before the job is gone.** Poll `launchctl print` until it fails, or the following `bootstrap` dies with `5: Input/output error`.
- **A CLT-only toolchain hides swift-testing.** `Testing.framework` ships with the Command Line Tools but outside every default search path, so `swift test` reports *no such module 'Testing'* and, once `-F` is added, dies at runtime missing `lib_TestingInterop.dylib`.
  Both live under `/Library/Developer/CommandLineTools/Library/Developer/`; `make test` adds the flags when that directory exists.
  Never reach for `xcodebuild` — the fix stays inside SwiftPM.
- **APFS is case-insensitive**, so `Contents/MacOS/Simmer` and `Contents/MacOS/simmer` are the same file: the second copy silently overwrites the first and the "app" runs the CLI's `main`, prints a status line and exits.
  The bundle even signs.
  Asserted by `StructureTests.theBundlesTwoExecutablesHaveCaseDistinctNames`.
- **Other tools hold power assertions and none of them announce it.** Claude Code spawns a `caffeinate -i` per session, which is a false positive when auditing simmer's own leaks — match on simmer's signature, not on the process name.
  It is also the sharpest argument for the editor integration on `ROADMAP.md`: the tool used to build simmer was itself holding an invisible, lid-incapable assertion.

Everything else this project learned the hard way is now enforced rather than remembered — the seam's completeness, the sudoers rule's scope and validation order, that simmer never escalates its own privileges, that a truncated installer runs nothing, that every documented verb resolves, that yes/no fields are booleans, and that two processes over one ledger need a signal instead of a faster poll.
Those live in `Tests/`, next to the thing they constrain.
