# Changelog

Notable changes, newest first.
Machine surfaces — exit codes, `--json`, `--machine`, `events.jsonl` — are contract and append-only; anything that changes one is called out here explicitly.

## Unreleased

<!-- release: patch -->

### Fixed

- **The click's last word arrives, and so does the answer to Check for Updates….** 0.3.2 gave the *starting* banner of "Install it now" a body and left the ending banner of the same click without one, so every successful install finished with a notification macOS accepts and never presents — and with no app running to relaunch it was a bare title, the exact shape 0.3.1 was silent for. The completion banner now says which version you are on, the failure arm still says the menu bar did not come back, and **Check for Updates…** answers on every verdict rather than only when there is something to install: "you are up to date" was the commonest answer that menu item had and the one it never gave. **0.3.3 is the first version that answers Check for Updates…; the update *after* 0.3.3 is the first whose completion banner carries a body** — the banner at the end of a click is composed by the version being replaced, so installing 0.3.3 still ends with 0.3.2's wordless one. The shape is now refused at the type: no notification this tool constructs can reach the Notification Center with neither subtitle nor body, the spool drain and the app both refuse one and say so in `simmer.log`, and a structure test reads every construction in the source. A banner that could not even be queued — a symlink or a full disk at `notify-spool.jsonl` — leaves a line in `simmer.log`, a different file that survives the case which loses it; `Ledger.append` used to discard that failure, and 0.3.2 had made the spool the banner's only channel. The three strings chosen by hand for the install banners are pinned by equality rather than for being non-empty, an `update-in-progress` record stamped in the future ages out like any other instead of claiming to be installing forever, and `docs/PLATFORM-FACTS.md` § Notifications now holds the fact three comments in the code cite it for: a banner is offered, and nothing simmer may read says it was delivered or shown.
- **`npm run build` in the Raycast extension can no longer overwrite the extension Raycast has registered.** `ray build`'s output directory defaults to `~/.config/raycast/extensions/simmer/` and `-e dist` names the environment rather than a path, so the command the extension's own README hands a reader replaced the registered copy with a one-shot build of whichever checkout it ran in — twice from a worktree on 8 September, restored by hand. The script passes `-o dist` now, and a structure test holds every `ray build` in the manifest to a relative output path with no `..` and no shell expansion, so the flag cannot quietly leave again: the previous fix corrected three sentences and left the command armed.
- A sudoers rule whose runas spec is a GROUP list with no users in it is no longer counted as simmer's own capability. `(: ALL) NOPASSWD: …` runs as the invoking user, not as root — `sudoers(5)` says so in as many words — so `doctor` vouched for a guard whose `sudo -n` is refused on every tick, and `(: ALL) NOPASSWD: ALL` was read as a blanket root grant that does not exist. The other direction is fixed with it: `(#0)` is root by user-ID and used to be refused, which had `doctor` reporting no grant on a machine where the guard works.
- A cap record whose `expires` is too far OUT is damage too, not a ceiling that lasts until 2100. `until` and `expires` could each be in range, `expires` strictly after `until`, and the two mutually inconsistent — and every claim and every extend was then refused for 75 years, which is the lockout the range check exists to prevent arriving from the other side. Anything past the rollover the cap was written with is re-derived; the value `simmer cap` itself records reads back unchanged.
- A `notify-spool.jsonl.draining` sentinel that is the spool file under another name — a symlink to it, or a hard link — no longer posts every banner twice. It was read once as the unfinished drain, the unlink took the link and left the spool, and the rename then handed the same lines back as the fresh half. The two names are compared by the file they reach now, not by their paths. A stranded half that is a link to a file *elsewhere* still posts, and still leaves that file alone.

## 0.3.2 — 2026-09-08

### Fixed

- **Pressing "Install it now" now shows that it is installing.** The click closed the menu and then nothing on screen said anything for the minute or two `make install` takes — the app posted a banner and it was never seen. The update row now reads *Installing 0.3.2…* and stops being clickable while the child runs, which is the one channel that cannot be held back by a Focus mode and can be re-read after a banner has faded; the banner itself now comes from the child through the spool, so it survives `Simmer.app` being replaced halfway through, and it carries a body — macOS accepts a notification with no informative text and never presents it. A refusal and a "nothing to install" each say so too; before this, three of the four endings of `update --apply` were silent when the menu had started it, because the child's stdout and stderr both go to `/dev/null`. And `simmer update --apply` writes one line to `simmer.log` when it starts and one for however it ended: the 0.3.1 click left no trace anywhere a person looks.
- A stranded `notify-spool.jsonl.draining` sentinel is recovered as the unfinished drain it is, rather than being every future banner, silently, forever: `moveItem` refuses an existing destination, and the `defer` that swept the sentinel only ever ran in-process. Its lines are drained too, and `maxAge` — not the crash — decides which of them still deserve a banner.
- `removeClaim` no longer answers "still matching" about a claim file that is GONE, so two ticks coinciding on one claim record one ending instead of two on `events.jsonl`. The tick that lost the race is also quiet about it: the outcome is correct, and an ERROR line per lost race teaches the log's reader to skim.
- `simmer guard --json` refuses and names `simmer status --json`, instead of accepting the flag, printing nothing and exiting 0 — the one verb `everyVerbHonoursJSON` was not walking.
- The cap record is range-checked at its own parser, the way a claim has always been: a corrupt `until` or `expires` is "this field is not a value" rather than a trap waiting on the first surface to do arithmetic on it. An `expires` that is not strictly after `until` is re-derived, so the ceiling keeps the night it was set for.
- A sudoers rule that runs as somebody other than root is no longer counted as simmer's own capability. A foreign `(operator) NOPASSWD: /usr/bin/pmset …` made `doctor` vouch for a guard whose `sudo -n` is refused on every tick.
- The SwiftBar menu's "more" and "Release mine" rows follow who holds a claim, the same rule as the app's menu. Both refuse at exit 1 under a name that holds nothing, and every row carries `refresh=true` — so they were clicks that did nothing, invisibly, whenever the claims on the machine were somebody else's.
- `bootstrap.sh` tells a tag from a branch instead of swallowing every failed fast-forward. A diverged checkout now dies naming the fix, where it used to print "updated the existing checkout" and hand the stale tree to `make install`.
- `docs/CONTRACTS.md` § the claim id now states the map the code has implemented since #11 shipped in 0.2.0 — case folding, the reserved shapes and the disjointness rule — where it still described the pre-fix owner→id passthrough; an implementation written to the old letter would have reintroduced the case-fold takeover and the forged-fingerprint attack. Description catching up with code: no machine surface moves in this release.

### Changed

- **The Raycast extension's dependencies move, and TypeScript moves one major rather than two.**
  `@raycast/api` 2.0.6 → 2.2.0, `@types/node` 22.19.17 → 26.4.0 and `typescript` 5.9.3 → 6.0.3, each read before it landed rather than merged on a green tick.
  Raycast publishes no changelog for the 2.x line, so the api bump was read as the diff between the two versions' own type declarations; the api version matches the installed Raycast, which is what `.github/dependabot.yml` says it has to do. The types bump was read against what the extension actually calls — `execFile`, `accessSync`, `watch`, `homedir`, `join`, `process.env`, none of it newer than Node 12, under a runtime Raycast declares as Node ≥ 22.22.2.
  TypeScript stops at 6.0.3 on purpose. 7.0 is the native compiler and ships no programmatic API before 7.1, so typescript-eslint refuses to load against it and the extension's ESLint step cannot pass — Raycast's own `ray build` is perfectly happy with 7.0.2, the block is the linter. 6.0.3 needs the identical migration, one `"types": ["node"]` line in `tsconfig.json`, because TypeScript 6.0 changed that default from `["*"]` to `[]` and without it nothing loads `@types/node` at all. So the work 7 will need is done, and what is left when the linter catches up is a version number.

## 0.3.1 — 2026-09-07

### Changed

- **The setup window says less.** The two update checkboxes had a paragraph each — eight sentences between them, in a window whose other three rows are a title and one line.
  Each is one line now, and each is the promise that decides its box: how little the daily check does, and that an install can never land on a live claim.
  Everything the paragraphs carried moved into `docs/FAQ.md` § The update check, which a new **Learn more…** link under the pair opens — so nothing is lost and nothing is on screen twice.
  `StructureTests` holds both halves: a caption that grows a second line fails, and so does a link whose anchor the FAQ no longer has.

### Releasing

- **The release is a pull request that is always open, and merging it is the release.**
  0.3.0 was cut by hand: six steps from a laptop shell, each one remembered.
  Now every push to `main` leaves exactly one pull request current — title `release: X.Y.Z`, branch `release/next`, one commit holding the `CHANGELOG.md` rename and the `SimmerVersion.string` bump, and the notes GitHub would publish as its body.
  Reading it is the review; merging it lands the release commit, and a job on `main` sees a version no tag names, tags it, and hands over to the publish path.
  So a release can be taken from a phone, and the decision stays exactly where it was: a person, in front of something they can read first.
  Nothing about what a release IS moves — `release.yml` is called rather than copied, so every check that stood before a tag still stands before it, on the same commit, in the same order.
  Only `main` acts: run from any other ref the workflow reports what a release would be and stops, so a dispatch from a branch cannot open a pull request out of that branch or tag a commit nobody released.
- **A release declares its own number, next to the notes that earned it.**
  One line anywhere under `## Unreleased` — `<!-- release: patch -->`, `minor` or `major` — travels with the change, in the pull request that makes it, reviewed by whoever reviews the notes.
  Without it the only override was a label on the release pull request, which made the mechanism's first act in front of somebody a wrong number to be corrected: this release would have opened as 0.4.0 and been relabelled to 0.3.1.
  An HTML comment rather than a visible line because it is an instruction to CI and not a note to whoever reads the release, because a visible *"released as a patch"* under a heading called **Unreleased** is a claim about something that has not happened, and because a `.md` diff is raw markdown — so it is visible exactly where it is reviewed and nowhere else.
  It is **consumed** when the section is renamed: a directive to CI has no business in published notes, and a one-release decision must not repeat itself at the next one. `release-check` refuses a release section that still carries one.
  Precedence is **label → declaration → the category rule**, because the label is the later decision and the one taken looking at the release itself; a misspelt or duplicated declaration is refused rather than ignored, since ignoring it ships the release at whatever the rule said while somebody believes they declared otherwise.
- **The version number is read out of the CHANGELOG rather than remembered.**
  `scripts/release.sh` is `docs/RELEASING.md` § What a version number means, as code: an entry under `### Machine surface` or `### The test seam` in `## Unreleased` makes the next release a **minor**, an empty section means there is nothing to release, and anything else is a **patch**.
  A minor is *declared* by writing under one of those headings, never guessed from prose — "adds a `--json` field" and "adds a menu row" are the same sentence to a machine.
  A **major** is not inferred at all: removing a field, renaming one and changing one's type read exactly like adding one, so it takes a label on the release pull request.
  All three kinds are declarable the same way — `release: major`, `release: minor`, `release: patch`, exactly one, two refused rather than chosen between — because "the rule was too cautious" is not the only reason to overrule it.
  Sometimes it is *we are shipping this as a patch anyway, and we know what that costs*, and a rule with no override is one that gets worked around outside the mechanism, where nothing records who decided or what the rule had said.
  So the pull request prints both, and which of the two said so: *"a **patch**, declared in the CHANGELOG, where the rule read this as a **minor**"*.
  A table test drives the rule from `swift test`, so it rides every CI leg.
- **`release-check` is a check on the pull request**, and it is what makes the label safe.
  CI computes the number when it writes the branch; a label added afterwards changes the answer and nothing recomputes until the next push to `main`.
  The check re-derives it from `main` through the same label reader the branch was written with, and goes red on the mismatch — so a declared number is accepted and an undeclared one cannot slip through.
  On every other pull request it asks one question: is there still somewhere for the next change's notes to land.
- **`make release-check` stays, for a laptop, and now runs the same assertions CI does.**
  Its file checks *are* `scripts/release.sh check`, so a laptop and a runner cannot answer differently, and its epilogue points at pushing `main` rather than at tagging by hand.
  Tagging by hand still works and still publishes.

### Fixed

- **A verdict cached by the version you replaced is no longer repeated as this one's.**
  Two minutes after installing 0.3.0, `doctor` reported "simmer 0.3.0 is ahead of the newest release (0.2.0)" and the menu footer said "newest": 0.2.0 had recorded that answer the day before the 0.3.0 tag existed, and the new binary read the file as a fact about now.
  The record carries the version that wrote it, and a reader that is not that version treats it as absent — so the first `doctor`, menu tick or `--cached` read after an install says "not checked yet", and `Simmer.app`'s daily check fires instead of skipping on a freshness stamp it did not write.
  A cached answer older than a day now says how old it is, on the footer, the `doctor` row and the launcher's accessory.
- **`make install` records which checkout it ran in, and every sentence about "the installer's checkout" follows it.**
  The bundle is the same bundle whichever checkout assembled it, so simmer assumed `~/.local/share/simmer` — the path `bootstrap.sh` uses — whatever the truth was.
  On a Mac installed with `make install` from its own checkout that produced a `doctor` footer telling the reader to run `make -C ~/.local/share/simmer install` in a directory that is not there, a Raycast row claiming there was no checkout to compare the extension against while the checkout sat one directory away, and an `update --apply` that refused for the same reason.
  `$(CURDIR)` is now stamped into the bundle's `Info.plist` (`SimmerInstallSource`), and the update command, the repair command, `doctor`'s rows and the Raycast comparison are all derived from it.
  A bundle installed by an older simmer carries no stamp and is placed exactly as it was before: the installer's checkout, if that is on the Mac.
- **`update --apply` works on a Mac installed from a checkout.**
  It pulls that checkout and re-runs `make install` — the two commands the same copy already prints — and only when the tree is clean and on the branch the remote calls default.
  Anything else refuses by name: uncommitted changes, another branch, a detached head, a remote whose default branch cannot be read locally, or a recorded checkout that has been moved or deleted.
  **Local commits included** — a clean tree on `main` holding work nobody has pushed passed both other conditions, and the plan's own steps did not catch it either, because `git merge --ff-only @{u}` succeeds against an upstream that is already an ancestor: it is a no-op, so `make install` shipped the developer's unreleased tree and `--apply` reported success naming a release the installed binary does not report.
  The refusal names the count and the command that clears it, and a branch tracking nothing refuses too — there is no upstream to update from.
  "A developer's own checkout is never moved onto a tag" still holds; it was about local commits and unfinished branches, and no checkout but the installer's is moved onto a tag.
- **The Raycast check says the same thing the CLI does.** Its provenance line read "installed as Simmer.app" for every bundle, which is what the CLI's own prose used to say; it now names the checkout the bundle was built in, or says that checkout is no longer there.
  A simmer too old to carry the fields says what it said before.

### Machine surface

- `update --json` gains **`install_source`** (the checkout this copy was built in, or `null`) and **`install_source_kind`** (`installer`·`checkout`·`gone`·`none`).
  Appended, like every field after the first release.
  **`provenance` keeps its four values** — `homebrew`·`bundle`·`checkout`·`unknown` — because it is a closed set that every reader switches on exhaustively, this repository's own Raycast extension included; a fifth value would have broken each of them.
- **`SIMMER_FAKE_CHECKOUT`** joins the test seam: `<branch>:<default branch>:clean|dirty[:<ahead>]`, the read that decides whether `--apply` may pull a working checkout.
  A seamed process without it reads nothing, exactly as one without `SIMMER_FAKE_LATEST` does.
  The optional fourth field is how many commits the branch has that its upstream does not — `none` for a branch tracking nothing — and **absent means zero**, so every three-field value still says what it said.
  A count that is not a non-negative number answers "cannot read this checkout" rather than "in step": in step is the one value that lets the plan run, and a typo must not be the thing that grants it.
- The `update-check` state file gains an `installed=` line. It is not a machine surface — `simmer update --json` is how anything else asks — and a file written by an older simmer is read as absent rather than misread.

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
