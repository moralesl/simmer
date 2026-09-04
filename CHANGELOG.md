# Changelog

Notable changes, newest first.
Machine surfaces — exit codes, `--json`, `--machine`, `events.jsonl` — are contract and append-only; anything that changes one is called out here explicitly.

## Unreleased

### Added

- **`simmer update`** — is there a newer release, and what would install *this* copy.
  It reports and prints the command; it never installs anything, for the same reason `simmer uninstall` shows commands rather than running them, and more so: an update replaces a running app and the binary the guard's LaunchAgent points at, and it can be asked for while a claim is live.
  The instruction follows how the copy got here — `brew upgrade simmer` for a Homebrew install, `git pull && make install` for a checkout, the one-paste installer otherwise — because "what is the newest release" has one answer and "how do you update" does not.
  `--json` carries `verdict`, `update_available`, `provenance`, `update_command` and `app_drift`; exit 0 means the check completed, 1 means it could not be made.
  A newer release existing is never a failure.
- **`simmer update --apply` installs it**, for the person with no terminal to paste into — which is most of the people the menu bar exists for.
  It runs the command it would have printed and nothing else: no password, and never a script piped from the internet into a shell.
  A bundle install has the one-paste installer's checkout at `~/.local/share/simmer`, so the plan fetches the new tag there and runs `make install`; Homebrew gets `brew upgrade simmer`.
  It refuses in a developer's own checkout — that may hold local commits, an unfinished branch or a stash — and refuses when it cannot tell whether there is anything to install.
  `applied`, `steps` and `apply_error` on `--json`; exit 0 means nothing is left to do.
- **The same answer in four more places.** A conditional row in the menu bar carrying **Install it now** and the command to copy, plus a permanent "Check for Updates…" item; a footer that always says which version you are on and which is newest; an informational row in `doctor`; a row in the Raycast claims list and a "Simmer Check for Updates" command.
  All of them render from one `UpdateCommand` in the core, so they cannot disagree about what "up to date" means.
- **`Simmer.app` checks once a day**, off the main thread, and posts no banner for it — it updates the menu and stops there.
  Off via the setup window's new checkbox or `SIMMER_NO_UPDATE_CHECK=1`.
- **`doctor` reports a half-finished install as red.** `Simmer.app` and the CLI are normally the same file, so a version disagreement between them means one was replaced and the other was not — which a package manager that upgrades only the CLI would produce routinely.
  Being merely out of date stays informational.

### Releasing, and the checks around it

- **A tag is now verified before anything is published.** `.github/workflows/release.yml` runs on a `v*` tag: the whole matrix (by reference to `test.yml`, not a second copy of it), then the one question only a tag can answer — does it name the version the binary reports, and does that version have CHANGELOG notes — and only then creates the GitHub Release from that section.
  It refuses to overwrite a release that already exists.
- **`make release-check`** asks the same questions before the tag exists: clean tree, on `main`, version not already tagged, notes present and non-empty, both suites green.
  It prints the notes and the two commands and tags nothing itself.
- **Two tests keep the version honest between releases.** The compiled-in version must have a CHANGELOG section — so a bump without notes fails in the pull request that bumps it — and there must always be an `Unreleased` section for the next change to land in.
- **The one-paste install runs in CI.** A macOS leg executes `bootstrap.sh` against the checkout under review: the clone, `make install`, the write to `/etc/sudoers.d`, the guard registration, and `simmer doctor`'s verdict on the result.
  Previously CI only asked whether the installer parsed.
- **`SIMMER_NO_LAUNCH=1`** installs everything except opening the app, for a machine with no login session — CI, or an install over SSH.
  The notification permission is a click by design, and the installer now says so instead of implying the install is finished.
- **`docs/RELEASING.md`** — what happens when a pull request merges (nothing: the notes go under `Unreleased` and the version does not move), how a release is cut, and what a version number promises.

### Machine surface

- **New:** `update --json` (`action`, `verdict`, `installed`, `latest`, `update_available`, `provenance`, `update_command`, `app_version`, `app_drift`, `checked_at`, `cached`, `error`, `seamed`), and the `update` and `app_version` rows in `doctor --json`.
  Nothing existing changed.
- **New seam:** `SIMMER_FAKE_APPLY=<file>` — `--apply`'s steps are recorded instead of run, which is how the plan is asserted without a build.
- **New seam:** `SIMMER_FAKE_LATEST=<tag|error>`.
  A process that is seamed at all and has not been given it reads nothing over the network, which is what keeps both suites hermetic.
- **New state:** `$XDG_STATE_HOME/simmer/update-check` and `update-check.off`.
  Neither is a machine surface — `simmer update --json` is how anything else asks.

### Fixed

- **A new subcommand can no longer be unreachable.** The sugar layer's verb list and the parser's subcommand list are two hand-kept lists in two files, and a name missing from the first made a working command report "did not understand the duration".
  A structural test now derives both from the source and fails if they disagree.

## 0.2.0 — 2026-08-28

A hardening release.
Nothing about using simmer changes: the same commands, the same exit codes, the same contract.
What changes is how much of that contract the binary enforces, and how many of its surfaces stay truthful when something underneath them fails.

### Upgrading from 0.1.0

**A claim taken under an owner containing a capital letter is migrated for you.**
`agent:CI-nightly` used to be its own filename and now resolves to a fingerprinted one, because APFS folds case and two owners differing only in case shared a claim file.
The migration runs on the first invocation of any command; where a migrated claim meets one already under the new name, the later deadline wins.
Nothing is required of you, and an unwritable state directory only means it is retried next run.

**`budget` can refuse an open-ended claim.**
It answers about the earliest clock rather than the deadline alone, so `seconds_left: -1` with exit 1 is now possible when the battery floor will end the claim first.
Branch on the exit code rather than on `seconds_left == -1`.

### Added

- **A Raycast extension** (`integrations/raycast/`) — six commands over the contract: the live countdown in the root search, a claims list showing who holds the Mac and why, and claim / extend / release / cap.
  It reads `status --json` and `render raycast`, never the ledger, so one place still decides what is held.
- **The agent protocol installs itself.**
  `make install` renders the "Using simmer" half of `AGENTS.md` as a Claude Code skill wherever `~/.claude` already exists, so agents in other repositories on the same Mac can read it.
  Generated, never copied — a second copy drifts, and the only reader who would notice is the agent holding the stale one.
- **A cap lets go of its own night.**
  A ceiling set for 23:00 lifts itself at the next 09:00 rather than refusing every claim the following morning, and every surface says when it ends.
  `cap_expires` carries it on the machine surfaces.
- **Releasing says what it did *not* clear.**
  A standing ceiling survives `down` — correctly — and is now mentioned, on stdout, in the banner and in the Raycast HUD.
- **`budget` reports the battery clock.**
  `battery_seconds_left`, `battery`, `on_battery` and `min_battery` on `budget --json`, so a caller sees the other ending without a second call.
- **`seamed`** on `status --machine`, `status --json`, `budget --json` and the human output, so a stray `SIMMER_FAKE_*` export cannot produce a confident answer about a Mac that will sleep the moment the lid closes.
- **`doctor` gained four rows:** whether the installed agent protocol is current, whether the passwordless sudo grant is exactly the two invocations `SECURITY.md` promises, whether the guard reads the same ledger this shell does, and whether every file in the claims directory is one its owner can address.

### Removed

- **The Alfred renderer.** `simmer render alfred` and the roadmap entry behind it are gone; the Raycast extension is the launcher surface. One that is used beats two that are half-kept, and a surface nobody drives is a contract nobody checks.
  `alfred` is also no longer one of the names that counts as a person — `terminal`, `menubar` and `raycast` are.

### The ledger

- **A claim's id is the name of its file, and nothing else.**
  The `id=` line inside a record is a copy for whoever reads it, never an authority, so no record can rename itself out of reach of `down`.
- **Temp files stage outside `claims/`**, which is the one directory that *is* the list of live claims.
  Debris an interrupted write left behind is inert, and debris an older version already left is removable rather than permanent.
- **Case is part of a claim id.**
  APFS folds it and the ledger is the same filesystem, so `Terminal` and `terminal` are two claims rather than one file with two names — and the human-owner test reads either spelling as the person it names.
- **`reason` and `owner` cannot carry a line ending.**
  The record is newline-delimited `key=value` with a last-key-wins parser, and agent-composed text and pasted commit messages are ordinary inputs here, so both fields are folded rather than refused.
  They have a length too: a reason is a label for a menu bar, not a document.
- **State is created 0700/0600.**
  Reasons carry customer and project names and the log keeps every one of them, dated.
  An existing directory keeps the mode it has rather than being tightened behind your back.

### Handing the machine back

- **A removal that did not happen is not announced.**
  `down`, `down --all`, `cap off`, the lease migration and the notification spool all report what they actually did; a release that cannot reach the disk is refused rather than claimed.
- **Thermal pressure ends everything, unconditionally** — including when a claim file cannot be removed, where the guard now reports the truth and exits 1 rather than appending `thermal_release` every tick at exit 0.
- **`make uninstall` hands the machine back before removing the means to.**
  It releases first, stops if the switch is still on, and names the manual revert; `simmer uninstall` says the same to anyone following its printed commands instead.
- **The guard reads the ledger this shell writes.**
  The state directory is baked into the LaunchAgent at install time, since an agent inherits nothing from the shell that installed it, and `doctor` detects a split.

### What the surfaces report

- **`budget` answers about the earliest clock.**
  A deadline is one of them and on battery it is rarely the first, so the battery floor is part of the verdict — using macOS's own time-to-empty estimate, and reporting `null` rather than a guess while there is none.
- **`cap` counts only the clips that reached disk**, and copies its owner into the record folded, so an announced ceiling is one that exists.
- **`simmer run` reports a claim it could not release** rather than finishing silently at exit 0.
- **`orphan_heal` is recorded only for heals that happened** — in the ordinary missing-sudo-rule state that was 2,880 false events a day.
- **`simmer log` serves the folded copy the ledger holds**, so no reason can forge whole records in `simmer.log` or in `log --json`.
- **A replacement that ends sooner says so**, which matters most under the anonymous default: two agents that both forget `--owner` are both `script`.
- **`doctor` and `uninstall` read what sudo actually grants** from the rule listing rather than from an exit code that returns 0 on every admin Mac.
- **A pipe in a reason stays text.**
  SwiftBar reads everything after the first `|` as parameters, and `simmer run` records the command it wraps as the reason.

### Time and arithmetic

- **`--until 23:00` means 23:00.**
  Rolling to tomorrow moves to the same wall clock rather than adding 86,400 seconds, which on the two nights a year the clocks change landed a day late or an hour short.
  Also reachable through `simmer cap HH:MM`.
- **A duration too large to be real is refused**, with a one-year ceiling and every multiply overflow-checked — Swift's arithmetic traps rather than wrapping, and `SIGTRAP` is not in the published exit table.

### The test seam

- **A faked facet is faked wholesale.**
  `SIMMER_FAKE_BATTERY` covers the time-to-empty estimate as well as the percentage, `none` included, which is what `pmset` itself reports for the first minute after every unplug.
- **`SIMMER_BIN` is honoured only when the power seam is active.**
  It lands in every SwiftBar `bash=`, and in a real install the running binary is already the installed path.

### Documentation

`docs/CONTRACTS.md` describes the binary again: the new machine fields, the new seam variable, `SIMMER_BIN`'s conditionality and the `budget` exit-code change.
`AGENTS.md` also loses a promise it could not keep — `simmer run` does not release "on any exit, even SIGKILL", because nothing runs after `SIGKILL`; it is self-revoking within one chunk.

## 0.1.0 — 2026-08-24

First public release.
Counted claims with deadlines keep a Mac awake with the lid closed; a background watchdog puts it back to normal no matter how the claim ends.
CLI, menu bar app, and a contract agents can rely on.
