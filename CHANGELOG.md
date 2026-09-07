# Changelog

Notable changes, newest first.
Machine surfaces — exit codes, `--json`, `--machine`, `events.jsonl` — are contract and append-only; anything that changes one is called out here explicitly.

## Unreleased

### Releasing

- **The release is a pull request that is always open, and merging it is the release.**
  0.3.0 was cut by hand: six steps from a laptop shell, each one remembered.
  Now every push to `main` leaves exactly one pull request current — title `release: X.Y.Z`, branch `release/next`, one commit holding the `CHANGELOG.md` rename and the `SimmerVersion.string` bump, and the notes GitHub would publish as its body.
  Reading it is the review; merging it lands the release commit, and a job on `main` sees a version no tag names, tags it, and hands over to the publish path.
  So a release can be taken from a phone, and the decision stays exactly where it was: a person, in front of something they can read first.
  Nothing about what a release IS moves — `release.yml` is called rather than copied, so every check that stood before a tag still stands before it, on the same commit, in the same order.
  Only `main` acts: run from any other ref the workflow reports what a release would be and stops, so a dispatch from a branch cannot open a pull request out of that branch or tag a commit nobody released.
- **The version number is read out of the CHANGELOG rather than remembered.**
  `scripts/release.sh` is `docs/RELEASING.md` § What a version number means, as code: an entry under `### Machine surface` or `### The test seam` in `## Unreleased` makes the next release a **minor**, an empty section means there is nothing to release, and anything else is a **patch**.
  A minor is *declared* by writing under one of those headings, never guessed from prose — "adds a `--json` field" and "adds a menu row" are the same sentence to a machine.
  A **major** is not inferred at all: removing a field, renaming one and changing one's type read exactly like adding one, so it takes a label on the release pull request.
  All three kinds are declarable the same way — `release: major`, `release: minor`, `release: patch`, exactly one, two refused rather than chosen between — because "the rule was too cautious" is not the only reason to overrule it.
  Sometimes it is *we are shipping this as a patch anyway, and we know what that costs*, and a rule with no override is one that gets worked around outside the mechanism, where nothing records who decided or what the rule had said.
  So the pull request prints both: *"a **patch**, declared by label, where the rule read this as a **minor**"*.
  A table test drives the rule from `swift test`, so it rides every CI leg.
- **`release-check` is a check on the pull request**, and it is what makes the label safe.
  CI computes the number when it writes the branch; a label added afterwards changes the answer and nothing recomputes until the next push to `main`.
  The check re-derives it from `main` through the same label reader the branch was written with, and goes red on the mismatch — so a declared number is accepted and an undeclared one cannot slip through.
  On every other pull request it asks one question: is there still somewhere for the next change's notes to land.
- **`make release-check` stays, for a laptop, and now runs the same assertions CI does.**
  Its file checks *are* `scripts/release.sh check`, so a laptop and a runner cannot answer differently, and its epilogue points at pushing `main` rather than at tagging by hand.
  Tagging by hand still works and still publishes.

## 0.3.0 — 2026-09-07

### Added

- **`simmer update`** — is there a newer release, and what would install *this* copy.
  Bare, it reports and prints the command and installs nothing — the shape `simmer uninstall` established, for a stronger reason: an update replaces a running app and the binary the guard's LaunchAgent points at, and it can be asked for while a claim is live.
  Installing is a second, explicit thing to ask for, and it is the next two entries.
  The instruction follows how the copy got here — `brew upgrade simmer` for a Homebrew install, `git pull && make install` for a checkout, the one-paste installer otherwise — because "what is the newest release" has one answer and "how do you update" does not.
  `--json` carries `verdict`, `update_available`, `provenance`, `update_command` and `app_drift`; exit 0 means the check completed, 1 means it could not be made.
  A newer release existing is never a failure.
- **`simmer update --apply` installs it**, for the person with no terminal to paste into — which is most of the people the menu bar exists for.
  It runs the command it would have printed and nothing else: no password, and never a script piped from the internet into a shell.
  A bundle install has the one-paste installer's checkout at `~/.local/share/simmer`, so the plan fetches the new tag there and runs `make install`; Homebrew gets `brew upgrade simmer`.
  It refuses in a developer's own checkout — that may hold local commits, an unfinished branch or a stash — and refuses when it cannot tell whether there is anything to install.
  `applied`, `steps` and `apply_error` on `--json`; exit 0 means nothing is left to do.
- **An update that fails says what did not finish.** `git -C … checkout --quiet v0.9.0 failed — fatal: reference is not a tree` names a command nobody typed, in a checkout most people do not know they have, and answers neither of the two questions that matter.
  The first line is now a sentence: which part of the update stopped — fetching the release, switching to it, installing it, relaunching the app — whether anything on the Mac changed, and the command that works from a terminal.
  The failing command and its stderr tail follow it, and the banner carries the sentence.
  A relaunch that fails is the one case that is not a failed install: the update landed, the exit code stays 0, and the sentence says to open Simmer.app rather than to run the installer again.
  Before this its only sign was the absence of "· Simmer.app relaunched" from a success line.
- **A menu row that copies says so.** Handing a command to the clipboard was the one menu action with no visible consequence: the menu closed, the clipboard had changed, and nothing on screen said which — indistinguishable from a row that did nothing.
  It now posts a banner naming the command.
  Raycast needed nothing: its own copy action shows a HUD when it fires.
- **The release notes, before you install anything.** `simmer update` prints the release's own page under the install command, the menu bar's update group carries **Release notes…**, and Raycast's check gets an *Open Release Notes* action.
  simmer composes the URL from the tag and fetches nothing for it — its one outbound request is still the `HEAD` that names the newest release, and the browser does the reading.
- **The same answer in four more places.** A conditional row in the menu bar carrying **Install it now** and the command to copy, plus a permanent "Check for Updates…" item; a footer that always says which version you are on and which is newest; an informational row in `doctor`; a row in the Raycast claims list and a "Simmer Check for Updates" command.
  All of them render from one `UpdateCommand` in the core, so they cannot disagree about what "up to date" means.
- **`Simmer.app` checks once a day**, off the main thread, and posts **one banner per new version** — never the same version twice, and nothing at all when you are current, ahead of the newest release, or the check could not answer.
  Before this the daily check updated the menu and said nothing, so a colleague who never opens the menu bar could be months behind with no way to find out; a banner a day for the same release would have been the other failure.
  A check you ask for by hand answers with its own banner and records the version too, so tomorrow's background check does not repeat what you have just read.
  Off via the setup window's checkbox or `SIMMER_NO_UPDATE_CHECK=1`.
- **`simmer update --auto on` lets the daily check install a release by itself** — off by default, and never while a claim is live.
  It exists for the copy nobody opens at all: a colleague's Mac where the menu bar is the only surface and "there is an update" has been sitting in it for three weeks.
  An update quits `Simmer.app`, replaces the binary the guard's LaunchAgent points at and compiles for a minute or two, so while somebody is holding the lid open it waits — that is precisely the walked-away window a claim exists to protect — and `Aggregate.compute` is what answers "is a claim live", never the claims directory.
  A release skipped that way is retried at the **next daily check**, not when the claim ends: an update that starts compiling the moment an overnight job hands the lid back is an update nobody is expecting.
  The whole decision is one pure function in the core with each refusal named (off · the check could not be made · nothing newer · already tried · a claim is live · the plan was refused), so "nothing happened" is always attributable.
  They are answered permanent-reason-first: telling somebody to wait for a claim to end, when the release will not be attempted after it ends either, is telling them to wait for nothing.
  **One unattended attempt per release.** A release that cannot be installed — a tag that will not fetch, a build that fails — would otherwise fail again at every daily check with a banner each time, which is the repetition "one banner per new version" exists to prevent, applied to the half of this feature that can go wrong.
  So the tag is recorded before the attempt starts (`update-attempted`, § Machine surface) and this path stands down from that one release and nothing else: the next release is attempted, `simmer update --apply` and **Install it now** always attempt, and turning `--auto on` again clears the record.
  Written before rather than after because the attempt quits `Simmer.app`; still seeing that release tomorrow is what proves it did not land.
  **A check that could not be made is its own reason**, not a shade of "nothing newer": that reading made a Mac which had been failing to reach GitHub for three weeks indistinguishable from one that was up to date, and it was the one reason this path deliberately does not log.
  Only the background pass installs; clicking "Check for Updates…" still gets the report and the button.
  `--auto off | status` for the other two, a second checkbox in the setup window that disables itself when the daily check above it is off, and `auto_update` on `update --json`.
  When it does install, it **replaces** the availability banner rather than adding to it: the announcement is recorded so nothing repeats it tomorrow, and the update path's own two banners are what you see.
- **`doctor` says when the Raycast extension has fallen behind.** It is the one installed part of simmer that `make install` cannot touch — TypeScript with its own npm tree, built and registered by Raycast — so a release moves the CLI, the app, the guard and the agent protocol forward and leaves the launcher surface where it was, with the new commands simply not in the root search and nothing anywhere saying so.
  A Raycast manifest carries no version, so the row compares the commands the checkout declares against the ones the registered copy can actually run, and the declarations of those on both sides.
  Absent where Raycast or the extension is not installed, ℹ where one side cannot be read, and never red — a stale renderer is not a broken install.
  The fix it prints is `npm ci && npm run dev`, which is what registers an extension; `npm run build` produces the store's artifact and hands Raycast nothing.
- **`docs/FAQ.md` § A release broke something — how do I go back?** The exact command per provenance, what a rollback does to your state (nothing: `format=2` since `0.1.0`, and every parser ignores keys it does not know), the two wrinkles below `0.2.0`, why Homebrew has no way back, and the one step that has to come first — `simmer update --auto off`, or the next daily check reinstalls what was rolled back.
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
- **The acceptance suite also runs against the release binary.** `swift test` compiles and runs everything at -Onone, so every lane here was answering its question about a build nobody installs — which is how `update --apply --json` came to behave differently in the binary users get than in the one the suites drive (see Fixed, below).
  `make test-release` points the suite at `.build/release/simmer` through the `SIMMER_BIN` seam it already honours, and CI runs it on both OS legs.
  A machine surface is only guaranteed for a build something actually exercises.
- **`docs/RELEASING.md`** — what happens when a pull request merges (nothing: the notes go under `Unreleased` and the version does not move), how a release is cut, and what a version number promises.

### Machine surface

- **New:** `update --json` (`action`, `verdict`, `installed`, `latest`, `update_available`, `provenance`, `update_command`, `app_version`, `app_drift`, `checked_at`, `cached`, `error`, `seamed`, `release_notes_url`), and the `update` and `app_version` rows in `doctor --json`.
  Nothing existing changed.
- **New seam:** `SIMMER_FAKE_APPLY=<file>` — `--apply`'s steps are recorded instead of run, which is how the plan is asserted without a build.
- **New seam:** `SIMMER_FAKE_APPLY_FAIL=<fetching|switching|installing|relaunching>` — which recorded step reports failure, so the failure half of `--apply` is testable without breaking an install.
  Anything that is not a phase fails nothing.
- **New seam:** `SIMMER_FAKE_LATEST=<tag|error>`.
  A process that is seamed at all and has not been given it reads nothing over the network, which is what keeps both suites hermetic.
- **New state:** `$XDG_STATE_HOME/simmer/update-check`, `update-check.off` and `update-announced`.
  None is a machine surface — `simmer update --json` is how anything else asks.
  `update-announced` is the version a person has been told about, which is a different fact from what the last check found and therefore a different file: `update-check` is overwritten by every check, including the ones nobody sees.
- **New:** `auto_update` (boolean) on `update --json`, and the `raycast_extension` row in `doctor --json`.
  Nothing existing changed.
- **New:** `update --auto <on|off|status> --json` is its own object — `action` (`auto_update_on`·`auto_update_off`·`checked`), `auto_update`, `background_check`, `seamed` — because it answers about a setting rather than about a release.
  It refuses `--apply` and `--cached` rather than dropping one of them, and a value other than `on`/`off`/`status` is refused in simmer's voice with the refusal object on stdout.
- **New seam:** `SIMMER_FAKE_RAYCAST=<dir>` — where Raycast keeps locally built extensions, for the `raycast_extension` row.
- **New state:** `$XDG_STATE_HOME/simmer/update-attempted` — the release the once-a-day check has already tried to install by itself, so it is not tried again unattended.
  A third fact about the same tag and therefore a third file, beside `update-check` (what was found) and `update-announced` (what was said).
  Not a machine surface; cleared when a person turns unattended installs on.
- **`steps` on `update --apply --json` is documented as the plan's steps**, which is what it has always carried.
  The law said "the commands it ran", and on an install where `Simmer.app` was running, four commands run and three are in the array — the reopen is composed from the app's heartbeat after the plan is built, which is why it has a phase of its own.
  No field changed; the sentence describing one did.
- **New state:** `$XDG_STATE_HOME/simmer/auto-update.on`, present when unattended installs are on.
  It spells the opposite direction to `update-check.off` on purpose: each file's absence has to be the safe default.

### Fixed

- **`update --apply` answered with nothing at all from the binary users get.** In the RELEASE build it ran the whole plan, exited with the right code, and emitted zero bytes — `--json` and the human form alike, and on the nothing-to-do and refused paths too, which run no steps at all.
  What was lost is the answer itself: markers on either side of one call show the array holding **one line where the CLI built it** and **empty where `Runtime.emit` read it**, one call later.
  Not a buffering problem — a probe build writing through a bare `write(2)` loop emitted nothing for that same non-empty line.
  Both supported macOS versions, and the debug build every suite drove printed it correctly, as did the same source at `-Onone`, and as did `update --json`, whose answer has always been built in `SimmerCore` and delivered unmodified.
  To a caller, exit 0 with an empty stream is indistinguishable from a command that worked and had nothing to say — the one shape "honoured or refused, never accepted and dropped" exists to prevent.
  So the whole answer for every ending of an `--apply`, human and machine, exit code included, is now assembled in one place in the core (`UpdateCommand.applyOutcome`) and delivered unmodified, instead of the CLI building or amending an Outcome inside its own switch at four call sites.
  That is also where it belonged: SimmerCore stays pure and the surfaces render over it, and four surfaces render an update.
  No field, no exit code and no seam changed.
  **What is not pinned is why an optimised build drops it**, and this entry does not guess: `doctor --json` assembles its Outcome in the CLI in exactly the same shape and has never lost a byte, so "do not build an Outcome in the CLI" is not a rule this defect earns.
  The guarantee that replaces it is a lane, not a pattern — `make test-release` runs the acceptance suite against `.build/release/simmer` on both OS legs, and it failed on both the first time it ran.
- **A new subcommand can no longer be unreachable.** The sugar layer's verb list and the parser's subcommand list are two hand-kept lists in two files, and a name missing from the first made a working command report "did not understand the duration".
  A structural test now derives both from the source and fails if they disagree.
- **A failing `update --apply` reported its failure before the plan it describes.** `simmer update --apply > log 2>&1` — which is how anybody reports this going wrong — read back with "Could not install simmer 0.3.0" on the first line and "▸ updating simmer 0.2.0 → 0.3.0" on the third.
  `print` goes through stdio, which block-buffers when stdout is not a terminal, while a refusal is written straight to the stderr descriptor: correct on a tty, backwards in every log a person would send you.
  Stdout is now flushed before any stderr is written, so one command writing to both comes back in the order it said things.
  An acceptance test asserts it through a single descriptor, because two pipes cannot see a sequence at all.
- **`make test-raycast` tests the checkout rather than whatever is installed.** The extension resolves its own binary — `~/.local/bin/simmer` first — so the lane measured the installed copy, and a change adding a `--json` field was red with "update --json lost release_notes_url": a message naming the field and not the cause, green again only after `make install`, while the Swift lane had been green all along.
  It now builds and points `SIMMER_BIN` at the same debug product `make test` drives.

## 0.2.0 — 2026-08-28

A hardening release.
Nothing about using simmer changes: the same commands, the same exit codes, the same contract.
What changes is how much of that contract the binary enforces, and how many of its surfaces stay truthful when something underneath them fails.

### Upgrading from 0.1.0

**A claim taken under an owner containing a capital letter is migrated for you.** `agent:CI-nightly` used to be its own filename and now resolves to a fingerprinted one, because APFS folds case and two owners differing only in case shared a claim file.
The migration runs on the first invocation of any command; where a migrated claim meets one already under the new name, the later deadline wins.
Nothing is required of you, and an unwritable state directory only means it is retried next run.

**`budget` can refuse an open-ended claim.** It answers about the earliest clock rather than the deadline alone, so `seconds_left: -1` with exit 1 is now possible when the battery floor will end the claim first.
Branch on the exit code rather than on `seconds_left == -1`.

### Added

- **A Raycast extension** (`integrations/raycast/`) — six commands over the contract: the live countdown in the root search, a claims list showing who holds the Mac and why, and claim / extend / release / cap.
  It reads `status --json` and `render raycast`, never the ledger, so one place still decides what is held.
- **The agent protocol installs itself.** `make install` renders the "Using simmer" half of `AGENTS.md` as a Claude Code skill wherever `~/.claude` already exists, so agents in other repositories on the same Mac can read it.
  Generated, never copied — a second copy drifts, and the only reader who would notice is the agent holding the stale one.
- **A cap lets go of its own night.** A ceiling set for 23:00 lifts itself at the next 09:00 rather than refusing every claim the following morning, and every surface says when it ends.
  `cap_expires` carries it on the machine surfaces.
- **Releasing says what it did *not* clear.** A standing ceiling survives `down` — correctly — and is now mentioned, on stdout, in the banner and in the Raycast HUD.
- **`budget` reports the battery clock.** `battery_seconds_left`, `battery`, `on_battery` and `min_battery` on `budget --json`, so a caller sees the other ending without a second call.
- **`seamed`** on `status --machine`, `status --json`, `budget --json` and the human output, so a stray `SIMMER_FAKE_*` export cannot produce a confident answer about a Mac that will sleep the moment the lid closes.
- **`doctor` gained four rows:** whether the installed agent protocol is current, whether the passwordless sudo grant is exactly the two invocations `SECURITY.md` promises, whether the guard reads the same ledger this shell does, and whether every file in the claims directory is one its owner can address.

### Removed

- **The Alfred renderer.** `simmer render alfred` and the roadmap entry behind it are gone; the Raycast extension is the launcher surface.
  One that is used beats two that are half-kept, and a surface nobody drives is a contract nobody checks.
  `alfred` is also no longer one of the names that counts as a person — `terminal`, `menubar` and `raycast` are.

### The ledger

- **A claim's id is the name of its file, and nothing else.** The `id=` line inside a record is a copy for whoever reads it, never an authority, so no record can rename itself out of reach of `down`.
- **Temp files stage outside `claims/`**, which is the one directory that *is* the list of live claims.
  Debris an interrupted write left behind is inert, and debris an older version already left is removable rather than permanent.
- **Case is part of a claim id.** APFS folds it and the ledger is the same filesystem, so `Terminal` and `terminal` are two claims rather than one file with two names — and the human-owner test reads either spelling as the person it names.
- **`reason` and `owner` cannot carry a line ending.** The record is newline-delimited `key=value` with a last-key-wins parser, and agent-composed text and pasted commit messages are ordinary inputs here, so both fields are folded rather than refused.
  They have a length too: a reason is a label for a menu bar, not a document.
- **State is created 0700/0600.** Reasons carry customer and project names and the log keeps every one of them, dated.
  An existing directory keeps the mode it has rather than being tightened behind your back.

### Handing the machine back

- **A removal that did not happen is not announced.** `down`, `down --all`, `cap off`, the lease migration and the notification spool all report what they actually did; a release that cannot reach the disk is refused rather than claimed.
- **Thermal pressure ends everything, unconditionally** — including when a claim file cannot be removed, where the guard now reports the truth and exits 1 rather than appending `thermal_release` every tick at exit 0.
- **`make uninstall` hands the machine back before removing the means to.** It releases first, stops if the switch is still on, and names the manual revert; `simmer uninstall` says the same to anyone following its printed commands instead.
- **The guard reads the ledger this shell writes.** The state directory is baked into the LaunchAgent at install time, since an agent inherits nothing from the shell that installed it, and `doctor` detects a split.

### What the surfaces report

- **`budget` answers about the earliest clock.** A deadline is one of them and on battery it is rarely the first, so the battery floor is part of the verdict — using macOS's own time-to-empty estimate, and reporting `null` rather than a guess while there is none.
- **`cap` counts only the clips that reached disk**, and copies its owner into the record folded, so an announced ceiling is one that exists.
- **`simmer run` reports a claim it could not release** rather than finishing silently at exit 0.
- **`orphan_heal` is recorded only for heals that happened** — in the ordinary missing-sudo-rule state that was 2,880 false events a day.
- **`simmer log` serves the folded copy the ledger holds**, so no reason can forge whole records in `simmer.log` or in `log --json`.
- **A replacement that ends sooner says so**, which matters most under the anonymous default: two agents that both forget `--owner` are both `script`.
- **`doctor` and `uninstall` read what sudo actually grants** from the rule listing rather than from an exit code that returns 0 on every admin Mac.
- **A pipe in a reason stays text.** SwiftBar reads everything after the first `|` as parameters, and `simmer run` records the command it wraps as the reason.

### Time and arithmetic

- **`--until 23:00` means 23:00.** Rolling to tomorrow moves to the same wall clock rather than adding 86,400 seconds, which on the two nights a year the clocks change landed a day late or an hour short.
  Also reachable through `simmer cap HH:MM`.
- **A duration too large to be real is refused**, with a one-year ceiling and every multiply overflow-checked — Swift's arithmetic traps rather than wrapping, and `SIGTRAP` is not in the published exit table.

### The test seam

- **A faked facet is faked wholesale.** `SIMMER_FAKE_BATTERY` covers the time-to-empty estimate as well as the percentage, `none` included, which is what `pmset` itself reports for the first minute after every unplug.
- **`SIMMER_BIN` is honoured only when the power seam is active.** It lands in every SwiftBar `bash=`, and in a real install the running binary is already the installed path.

### Documentation

`docs/CONTRACTS.md` describes the binary again: the new machine fields, the new seam variable, `SIMMER_BIN`'s conditionality and the `budget` exit-code change.
`AGENTS.md` also loses a promise it could not keep — `simmer run` does not release "on any exit, even SIGKILL", because nothing runs after `SIGKILL`; it is self-revoking within one chunk.

## 0.1.0 — 2026-08-24

First public release.
Counted claims with deadlines keep a Mac awake with the lid closed; a background watchdog puts it back to normal no matter how the claim ends.
CLI, menu bar app, and a contract agents can rely on.
