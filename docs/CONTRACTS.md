# Contracts

**This page is the law, in prose.** What stays true across implementations: the surface, the exit codes, the machine output, and the reasoning behind each choice.

`Tests/SimmerAcceptanceTests` is the executable form of it.
It drives the built binary through its public surface and honours `SIMMER_BIN`, so **any** implementation that passes it under the seam variables below is a valid simmer — which is the question that matters: does it satisfy every row here, including the exit codes and the machine output, without root and without changing the machine under the tester?

Human-facing sentences may be reworded at any time.
Everything a script can read — exit codes, `--json`, `--machine`, `events.jsonl` — is contract, and machine fields are append-only.

## CLI surface

```
simmer <duration> [-r reason] [--min-battery N] [--until HH:MM] [--owner name]
       [--require-ac] [--display-on] [--force]   claim (or replace own) awake time
simmer forever [...]                            no deadline; reminded, floor still applies
simmer run [-r] [--max D] [--force] -- <cmd>    awake exactly while <cmd> runs
simmer +<duration> | extend <duration>          add to YOUR claim's deadline
simmer down                                     hand YOUR claim back
simmer down --all                               hand everything back (humans only)
simmer cap <HH:MM|duration> | cap off | cap     the human ceiling
simmer                                          human status, listing every claim
simmer status --machine | --json                machine status
simmer budget [--need D] [--seconds] [--json]   room to start something?
simmer log [n] · doctor · notify-test · --version · --help
simmer render swiftbar|raycast                 surfaces, drawn by the core
simmer update [--cached] [--apply]              is there a newer release? · install it
simmer update --auto on|off|status              may the daily check install one?
```

Durations: `90`, `90m`, `2h`, `1h30m`, `45min`, `30s`, `2H`, `1d`, `1d12h`.
Bare number = minutes; a trailing bare number after a unit is minutes (`2h15`).
Days exist because overnight is a first-class case — `--require-ac` was added for exactly it.

`--force` is accepted and does nothing.
It used to mean "stamp over someone else's lease"; the claims model removed the conflict it resolved.
It stays in the surface because launcher shims and other people's scripts pass it, and it prints a line saying it is inert rather than being silently ignored.

Every command reachable from a launcher also tolerates a trailing `-r <reason> --owner <name>`, because a launcher action appends both to whatever it produced whether the command has any use for a reason or not.

## Exit codes are API

| Command | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `budget` | fits | not enough time on the earliest clock | — | **nothing claimed at all** |
| `run -- cmd` | *(command's own exit code, passed through untouched)* ||||
| take/extend/down/cap | ok | refused (floor, cap, authority, parse) | — | — |
| `doctor` | healthy | something red | — | — |
| `update` | the check completed — newer or not | **could not check** | — | — |
| `update --apply` | nothing left to do: installed, or already current | could not be done | — | — |

`budget`'s 3-vs-1 split is load-bearing: 1 is a small budget, 3 is an absent guarantee.
Callers that conflate them keep working while the machine sleeps.

**`update`'s 0 does not mean "you are current"** — it means the question was answered, and the answer is in `update_available`.
A newer release existing is not a failure of anything, which is the same reading that keeps "out of date" out of `doctor`'s red rows; the one non-zero exit is not knowing.
So a caller can tell "you are current" from "nobody could tell", which is the distinction that matters to anything automated.

**"The earliest clock" is not always the deadline** — see § Two clocks.
An open-ended claim can now answer `1`, which it could not before 0.2.

## Machine-readable output

`status --machine`: `key=value` lines — `state` (active·forever·idle·orphan), `until` (epoch, 0=none), `left`, `left_short`, `reason`, `owner`, `min_battery`, `battery`, `on_battery`, `sleep_disabled`, `since`, `claim_count`, `cap` (epoch, 0=none), `cap_expires` (epoch the cap lifts itself, 0=none), `seamed` (`1` when any `SIMMER_FAKE_*` is in force — see § The test seam).
`status --json` / `budget --json`: the same data as one JSON object; numbers are numbers, `fits` is `true|false|null`, `seconds_left` is a number, `-1` for no deadline, or `null` when nothing is claimed (see below), `capped` is `true` when the deadline reported IS the cap, `cap_expires` is when the cap lifts itself, and `claims` is an array with one object per live claim (`id`, `owner`, `until`, `left`, `reason`, `min_battery`, `require_ac`, `since`, `human`).
Both carry `seamed` (boolean).
`status --json` also carries `version`.
`budget --json` also carries `battery`, `on_battery`, `min_battery` and `battery_seconds_left` — see § Two clocks.

**"No deadline" is spelled two ways, deliberately, and here is which.** `until` is `0`; a per-claim `left` and `budget`'s `seconds_left` are `-1`; the *aggregate* `left` is `0`, because it is a countdown and there is nothing to count.

**`budget --json`'s `seconds_left` has a third value, and it is not a fourth spelling of "no deadline".** It is `null` when `state` is `idle` or `orphan` — nothing is claimed, so there is no clock to read at all, and an absent clock is not `-1` seconds on one any more than it is `0`.
The three readings map onto the exit codes: a number with `0`/`1`, `-1` with `0` or `1`, `null` with `3`.
`-1` with `1` is the one combination that needs saying out loud, because it did not exist before 0.2: an open-ended claim has no deadline, and if the battery clock (below) runs out before the work does, "anything fits" is false about a claim with no `until`.
A caller that switches on the exit code never has to inspect the type; one that reads the field must accept all three.
`fits` is `null` on the same principle whenever no `--need` was given: no question was asked.
Read `state == "forever"` — or `until == 0` — as the question "is there a deadline at all"; never infer it from a `left` of 0, which an active claim reaches legitimately in its final second.
The two spellings are frozen: both shipped before the first tagged release and the append-only rule covers conventions, not only names.
Fields are append-only; removing or renaming one is a major version, **and so is changing one's type.**

**Yes/no fields are JSON booleans**, everywhere they appear: `require_ac`, `human`, `capped`, `clipped_by_cap`, `fits`, and every boolean in `events.jsonl`.
The two exceptions are the flat surfaces, which have no types at all: `--machine` emits `0`/`1`, and `status --json` keeps `on_battery` and `sleep_disabled` as `0`/`1` because they mirror `--machine` field for field.
A reader must never have to discover that one field answers the same question in a different type than its neighbour, and one field must never carry two types across two surfaces of the same binary.
The acceptance suite asserts this against the raw JSON text, because `JSONSerialization` bridges `0`/`1` to `Bool` and would let exactly that drift through a typed assertion.

`update --json`: `action` (`checked`, or `updated`/`refused` under `--apply`), `verdict` (`current`·`available`·`ahead`·`unknown`), `installed`, `latest` (the release tag as published, `v` and all, or `null`), `update_available` (boolean), `provenance` (`homebrew`·`bundle`·`checkout`·`unknown`), `update_command`, `app_version` (the installed bundle's, or `null`), `app_drift` (boolean), `checked_at`, `cached` (boolean), `error` (or `null`), `seamed` (boolean), `release_notes_url` (the page for `latest`, or `null`), `auto_update` (boolean — whether the daily check may install what it finds), `install_source` (the checkout this copy was built in, or `null`), `install_source_kind` (`installer`·`checkout`·`gone`·`none`).

**`release_notes_url` is composed, never fetched.** It is `<repository>/releases/tag/<latest>`, and it is `null` unless `latest` parses as a version — the tag arrives as the last path component of a redirect and round-trips through a `key=value` cache file, and this is the field a surface hands to a browser.
Reading the notes costs simmer no request: the one outbound request stays the `HEAD` that names the newest tag, and the browser fetches the page.

`update --auto <on|off|status> --json` answers about the setting rather than about a release, so it is its own object: `action` (`auto_update_on`·`auto_update_off` when it changed, `checked` when it did not), `auto_update` (boolean), `background_check` (boolean), `seamed` (boolean).
It makes no request and installs nothing, so it may not be combined with `--apply` or `--cached` — one of the two would be silently dropped, which is the failure `--json`-or-refuse exists to prevent.
`background_check` is in that object because unattended installs ride on the app's once-a-day check: with the check off, `auto_update: true` is a setting that cannot fire, and a caller has to be able to learn both facts from one call.
A value other than `on`, `off` or `status` is refused by simmer, in simmer's voice, with the refusal object on stdout.

**`latest` keeps the `v`; the human surfaces drop it.** The field is the string a caller hands to `git checkout` or matches against a release page, so it is the tag verbatim.
A sentence that puts `v0.3.0` next to `0.2.0` reads like two different kinds of thing, so the prose says `0.3.0` — presentation, which guarantee 5 leaves free.

**`provenance` decides `update_command`, and that is the whole reason it is a field.** "What is the newest release" has one answer; "how do you update" does not.
Telling a Homebrew user to re-run the one-paste installer would put a second, unmanaged copy beside the managed one; telling someone with a checkout to `brew upgrade` names a formula they do not have.
Both are derived from the path the running binary resolves to and from what the bundle records about itself, never from a preference.

**`install_source` is the second half of that question, and it is two new fields rather than a fifth `provenance` value.**
A bundle is the same bundle whichever checkout assembled it, so `make install` stamps `$(CURDIR)` into the bundle's `Info.plist` as `SimmerInstallSource` and `install_source` reports it back.
`install_source_kind` places that path against this Mac: `installer` (it is `~/.local/share/simmer`, the checkout `bootstrap.sh` maintains — machinery, and the only checkout simmer moves onto a tag), `checkout` (somebody's working repository, which is pulled and rebuilt only when it is clean and on the branch the remote calls default), `gone` (recorded and no longer on disk), `none` (nothing to point at — Homebrew, or a bundle with no stamp and no installer checkout).
A bundle installed by a simmer older than the stamp carries none, and is placed as `installer` where that checkout exists, which is what every bundle was assumed to be before.
`provenance` itself stays `homebrew`·`bundle`·`checkout`·`unknown`: it is a closed set that readers switch on exhaustively — this repository's own Raycast extension among them — so its values are frozen the way its name is, and a new distinction arrives as a new field.

**`update --apply` adds `applied` (boolean), `steps` (**the plan's steps**, in order) and `apply_error`** (only when it could not).
What the plan consists of follows `install_source_kind`: `installer` fetches the tag and runs `make install` there, `checkout` fetches, fast-forwards the default branch and runs `make install` there, Homebrew is one `brew upgrade`, and `gone`/`none` refuse.
A `checkout` plan refuses rather than running whenever the tree is dirty, the head is detached, the branch is not the remote's default, or that default cannot be read locally — the read is local, so a checkout that cannot answer refuses instead of waiting on the network.
`action` is `updated` when something was installed, `checked` when there was nothing to install, and `refused` when it could not be done.
`steps` is the plan — what installing this copy consists of — and it is the same list whether every step ran, one failed, or there was nothing to do (then it is empty).
Bringing `Simmer.app` back afterwards is **not** in it: the reopen is decided from the app's heartbeat rather than from the plan, it carries the `relaunching` phase precisely because it is not one of the plan's own steps, and what reports it is `applied` staying true with the sentence naming what did not finish.
A caller that wants to know whether the menu bar came back reads that sentence, not the array.

**`doctor`'s `raycast_extension` row is informational and often absent.** The Raycast extension is the one installed part of simmer that `make install` cannot touch — TypeScript with its own npm tree, built and registered by Raycast — so a release can move the CLI, the app, the guard and the agent protocol forward and leave the launcher surface where it was, with the new commands simply not in the root search.
A Raycast manifest carries **no version** (Raycast's own documentation: during development a manifest declares no `version`), so the comparison is the set of commands the checkout declares against the commands the registered copy can actually run — in its manifest *and* with a built `<name>.js` beside it — plus, for commands present on both sides, whether the declaration differs.
Raycast copies each command's declaration verbatim, which is what makes that sound; and unlike comparing build and source timestamps it stays true when the extension was registered from a different checkout than the one this binary knows about, which is the normal case for a bundle install.
The row is **absent** where Raycast or the extension is not installed — an uninstalled launcher is not a finding — and **ℹ** where one side cannot be read (a Homebrew install has no checkout; a checkout predating the extension has no `integrations/raycast`).
Never red, for the reason `agent_protocol` is never red: a stale renderer is not a broken install, and a row that can go red for it teaches the reader to skim the ones that mean something.

**And "current" here means the manifests agree, not that the code does.** A change confined to the extension's TypeScript — a bug fix inside `claims.tsx`, a reworded empty state — declares nothing new, so a copy Raycast built before it still reads as current.
That is a known limit rather than an oversight, and it is the price of the only comparison that stays true when the registered extension was built from a different checkout than provenance points at.
The row is worth having anyway: what it *does* catch is the case nobody can otherwise see, a release that added a command which is simply not in the root search.
Anything stronger needs a build stamp the extension does not currently write.

**`app_drift` is the one update-shaped thing that is a fault.** `make install` symlinks the CLI at the copy inside the bundle, so the two are normally one file and cannot differ.
When they do, the menu bar, the event-driven half of the guard and the notification identity are all the previous version running against the current ledger — which is why `doctor` reports it red while it reports being out of date as information.

**The top-level fields describe the AGGREGATE** — what the machine will actually do — and the descriptive ones (`reason`, `owner`, `min_battery`, `since`) come from the claim that *defines* the aggregate deadline.
With one claim that is the same answer the single-lease shape gave, which is why every existing reader keeps working.
Per-claim detail is in `claims`, never in `--machine`: that format stays flat so a menu bar can read it without `jq`.

## Two clocks

A claim ends at whichever comes first: its **deadline**, or the **battery floor** it was taken with.
`budget` is the command that answers "is there room to start", so it answers about the earlier of the two.
Reporting only the deadline meant `fits: true` with four hours of `seconds_left` about a claim sitting one point above a floor the guard would enforce within thirty seconds.

`battery_seconds_left` is how long until the battery reaches this aggregate's floor: macOS's own time-to-empty estimate, scaled by the fraction of the charge sitting above the floor.
Linear on purpose — that is the assumption the system's estimate already embodies, and a second discharge model would only disagree with the first.

It is `null` where there is no clock to read: on AC, while the estimate is still calibrating, and when nothing is claimed at all — with no claim, `min_battery` is a default rather than anyone's decision, and a number there would describe a guarantee nobody asked for.
It is `0`, never `null`, at or below the floor: the clock has run out, which is a reading and not an absence.
That distinction is the whole point, and getting it wrong made the answer non-monotonic — 21% refusing while 20% agreed.

`seconds_left` still means the deadline and nothing else, and is still `-1` for an open-ended claim.
Neither field changed meaning when the second clock arrived; `fits` and the exit code are what widened, and they widened toward the question the caller was always asking.

## State

`${XDG_STATE_HOME:-~/.local/state}/simmer/`:

- `claims/<id>` — one `format=2` key=value file per claim, written via temp-file
  + rename, never edited in place.
    The id is derived from the owner — see § The claim id.
- `cap` — the human ceiling, same discipline.
- `simmer.log`.
- `update-check` — what the last release check found, `key=value`.
  Not a machine surface: `simmer update --json` is how anything else asks, so this stays an implementation detail rather than a fifth format to keep append-only.
  It records whether the check was `seamed`, and an unseamed reader discards a seamed record — a `SIMMER_FAKE_LATEST` left exported in a shell rc must not put "Update available: 9.9.9" in a person's menu bar.
  It also records the **version that wrote it**, and a reader that is not that version discards it too: `latest` is a fact about the repository, but the verdict is a comparison against whoever asked, and both live in this one file.
  Two minutes after 0.3.0 was installed, `doctor` reported "simmer 0.3.0 is ahead of the newest release (0.2.0)" from an answer 0.2.0 had recorded before the tag existed.
- `update-check.off` — present when a person has turned the app's once-a-day check off.
- `auto-update.on` — present when a person has asked the once-a-day check to *install* what it finds.
  It and `update-check.off` spell opposite directions on purpose: each file's **absence** has to be the safe default, so checking is on unless turned off and installing is off unless turned on.
  One fact per file, neither a machine surface, and `doctor` and the setup window read a person's decision without asking whether the app is running.
- `update-announced` — the newest release a person has already been TOLD about, `key=value`.
  A different fact from what the last check found, and therefore a different file: `update-check` is overwritten by every check, including the ones nobody sees, while this records what was said rather than what was read.
  It is what makes the app's daily check post one banner per new version instead of one a day — and a check somebody asked for by hand records it too, so tomorrow's background check does not repeat what they have just read.
  An unattended install suppresses that banner rather than adding to it: the update path posts its own two about the same version, and the announcement is still recorded so nothing repeats it tomorrow.
- `update-attempted` — the release the once-a-day check has already TRIED to install by itself, `key=value`.
  A third fact about the same tag, and therefore a third file: what the last check found, what a person has been told, and what this Mac has tried.
  Written **before** the attempt starts, because the attempt quits `Simmer.app` and there is nothing left to write it afterwards; still seeing that release on the next daily check is what proves the attempt did not land.
  Its absence is the safe default in the same way `auto-update.on`'s presence is: with no record, the next check tries.
  Cleared when a person turns unattended installs **on**, so asking for them is asking for an attempt — and not when they turn them off, because nothing reads it while off and forgetting it there would make the answer depend on which way the switch moved last.
- `update-in-progress` — the release an install **now under way** is installing, `key=value` (`target`, `started_at`, `installed`).
  A fourth fact about the same tag, and therefore a fourth file: what the last check found, what a person has been told, what this Mac has tried by itself, and what is happening right now.
  Written by the app before it spawns `simmer update --apply`, so the menu tells the truth from the first time it is opened after the click — the menu being the one channel that cannot be suppressed and can be re-read, which a banner is neither.
  Read back **only by the version that wrote it**, exactly as `update-check` is, and that is what ends it on the good path: the app that comes back is the new version, so the record it left behind is invisible to it and nothing has to delete anything.
  The child clears it on every ending that installed nothing, the app clears it if the child exits while the app is still alive, and `started_at` ages it out after fifteen minutes — the backstop for a child killed outright while the app was quit.
  `target=` empty is a legitimate value and not the same as no record: it means an install is under way whose target the reader cannot name, and the row says so rather than dropping the fact.
- additionally, an append-only `events.jsonl` (one JSON object per transition: `v`, `ts`, `event`, `reason`, `owner`, …).

A `format=1` lease is read **once**, converted into a claim, and deleted.
An implementation must do this migration: someone upgrading mid-lease must not silently lose awake time they are relying on, and must never end up with both shapes on disk, which is how a guard learns to disagree with the CLI.

### The claim id

The whole ownership model rests on one property: **two different owners must never be handed the same claim file.** So the map from owner to id is contracted, not left to an implementation.

- **A filename-safe owner IS its own id, unaltered** — ASCII letters, digits and `._:-`, within the length budget below.
  That covers every owner any surface produces (`terminal`, `menubar`, `agent:evals`, `run:4821`), so no filename ever moves and nothing is owed a migration.
- **Otherwise:** unsafe characters flatten to `_`, **and a fingerprint of the original owner is appended** — `agent:a/b` → `agent:a_b-e6a27fc6`.
- The fingerprint is FNV-1a over the raw owner's UTF-8, as 8 lowercase hex digits.
  It must **not** come from a per-process-seeded hash: an id that moves between invocations leaves an actor unable to address the claim it just wrote, which is worse than the collision it would be fixing.
- The length budget is `NAME_MAX` **minus the temp-file suffix the rename goes through**, not `NAME_MAX` — a claim written under `<id>.tmp.<pid>` and renamed into place needs the temporary name to fit too.
  An over-long owner is truncated *before* the fingerprint is appended, never after, so cutting the stem cannot merge two names that differ only past the cut.

Flattening alone is many-to-one, and an implementation that stops there hands two actors the same file.
`agent:a/b` and `agent:a_b` collided, so an unrelated one-minute claim silently destroyed a two-hour one: no refusal, no warning, nothing in any output to read.
Every non-ASCII owner collapsed the same way (`agent:über`, `agent:öber` → `agent:_ber`).
That is the one failure this tool exists to prevent, arriving through the mechanism the model calls impossible.

A fingerprint is collision-*resistant*, not injective, and this says which it is: two mangled owners can still meet, at even odds somewhere around 77,000 distinct ones on a single Mac.
The failure it replaces needed two.

## The test seam

Any implementation MUST honour these, or it cannot be tested without root and without changing the machine under the tester:

| Variable | Effect |
|---|---|
| `SIMMER_FAKE_PMSET=<file>` | the sleep switch is that file's `0`/`1` |
| `SIMMER_FAKE_BATTERY=<pct>:<on_batt>` | e.g. `12:1` |
| `SIMMER_FAKE_THERMAL=<0\|N>` | thermal warning level |
| `SIMMER_FAKE_LOCKDELAY=<seconds>` | screen-lock grace after the lid closes |
| `SIMMER_FAKE_NOW=<epoch>` | **the clock.** Relative arithmetic reads from it; absolute formatting is unaffected |
| `SIMMER_HUMAN=1` | the caller carries human authority regardless of owner |
| `SIMMER_NOTIFY=<transport\|none>` | `none` silences. There is exactly one transport: the CLI enqueues into `$STATE/notify-spool.jsonl` and the app — the only executable holding a notification grant — posts. The spool is the assertable surface |
| `SIMMER_NOTIFIER_APP=<path>` | **retired in the rewrite** (was: notifier bundle override). The spool lives under `XDG_STATE_HOME`, so notification routing is seam-isolated by construction; see PLATFORM-FACTS.md on per-executable grants |
| `SIMMER_FAKE_LATEST=<tag\|error>` | the newest published release, e.g. `v0.3.0`; `error` is the offline path. **A process that is seamed at all and has not been given this reads nothing over the network** — while a `SIMMER_FAKE_*` is in force nothing this process reports is about this machine, and a live network read would be the one exception. That is what makes the suite hermetic without a rule anyone has to remember |
| `SIMMER_FAKE_CHECKOUT=<branch>:<default>:clean\|dirty[:<ahead>]` | what a working checkout looks like — the read that decides whether `--apply` may pull and rebuild the checkout a bundle was installed from. The optional fourth field is how many commits the branch has that its upstream does not (`none` for a branch tracking nothing); **absent means zero**, so every three-field value written before it existed still says what it said. Anything else — a fifth field, a count that is not a non-negative number — answers "cannot read this checkout", which refuses; a malformed count must not quietly mean "in step", because that is the one value that lets the plan run. Seamed for the reason `SIMMER_FAKE_LATEST` is: the real probe spawns `git` in a directory a fixture named, and a seamed process that has not been told what to answer reads nothing |
| `SIMMER_FAKE_APPLY=<file>` | `--apply`'s steps are appended to this file and reported as having succeeded, instead of being run. `--apply` spawns `git` and `make`, and anything spawned has a seam — the suite that called itself hermetic leaked 222 `caffeinate` processes through exactly this gap |
| `SIMMER_FAKE_APPLY_FAIL=<phase>` | which recorded step reports failure instead of success: `fetching`, `switching`, `installing` or `relaunching`. With `SIMMER_FAKE_APPLY` alone every step succeeds, so the failure half of `--apply` — the sentence a person reads on the worst day this feature has — was reachable only by breaking a real install. Named by phase because the phase decides the sentence, and because `relaunching` is not one of the plan's own steps. Anything that is not a phase fails nothing: a typo must not silently turn a failure test green |
| `SIMMER_FAKE_BATTERY_TIME=<seconds>` | macOS's own time-to-empty estimate, which `budget` scales into the battery clock — see § Two clocks |
| `SIMMER_BIN=<path>` | which binary integrations exec, **honoured only while `SIMMER_FAKE_PMSET` is also set**. It decides what a menu-bar or launcher row executes, which is not a decision one unguarded environment variable may make on a real install; there it is redundant anyway, because the binary knows its own path |
| `SIMMER_SKILL_DIR=<dir>` | where the generated agent protocol lives, for `doctor`'s staleness row. Needed because `homeDirectoryForCurrentUser` reads the passwd entry and ignores `HOME`, so this one read would otherwise reach the tester's real `~/.claude` |
| `SIMMER_FAKE_RAYCAST=<dir>` | where Raycast keeps locally built extensions (`~/.config/raycast/extensions`), for `doctor`'s `raycast_extension` row. It names the extensions *directory* rather than the extension, so "Raycast is not installed" stays reachable in a test; `HOME` is consulted before the passwd entry for the same reason `SIMMER_SKILL_DIR` exists |
| `XDG_STATE_HOME=<dir>` | state isolation |
| `SIMMER_RUN_CHUNK` / `SIMMER_RUN_INTERVAL` | run's renewal clocks |

Two more are read but are not seams — they are ordinary configuration, listed here because a reader looking for "what does this binary read from the environment" should find all of it in one place:

| Variable | Effect |
|---|---|
| `SIMMER_OWNER=<name>` | the default owner, when no `--owner` is given |
| `SIMMER_NONINTERACTIVE=1` | never prompt for sudo, even on a tty |
| `SIMMER_NO_UPDATE_CHECK=1` | the app never checks for a newer release on its own. `simmer update`, typed by someone who is asking, is never suppressed by it — a command that answered "not checking" to the question "check" would be the silent-drop failure in a new place |

**Every side effect outside the process must be behind this seam, not merely the ones that are awkward to test.** A suite that called itself hermetic leaked 222 orphaned `caffeinate` processes exactly this way: ten seam variables, and none of them covering the one call that spawned a detached child holding a real power assertion (`PLATFORM-FACTS.md`).
If an implementation shells out or spawns anything, that has a `SIMMER_FAKE_*` too.

`SIMMER_FAKE_NOW` is not a convenience.
Warn-once, the reminder interval and deadline crossings are the paths a differential run has to compare, and without a substitutable clock they are reachable only by hand-writing timestamps into state files — which tests the fixture rather than the code.

## Behavioural guarantees

1. Five things end awake time; only one is remembering: a claim's deadline (or the cap clipping it), the battery floor (on battery only), its charger disappearing if it asked for one, thermal pressure, explicit release, and the guard reverting a switch it finds enabled with no claim behind it.
2. The switch is never exposed, only leased.
   **Every mutation ends in one function that reads the ledger and puts the switch where it says** — that is what makes "no code path leaves `disablesleep` on without something scheduled to turn it off" a property rather than a promise.
3. A warning fires once, ~5 minutes before the **aggregate** deadline; open-ended time reminds every 30 minutes; a claim on battery warns once at floor+10%, re-arming if the charger returns.
4. An actor that names only itself cannot touch another's awake time.
   Not by refusal — by construction: a claim's id is its owner, so an actor addressing itself addresses nothing else.
   The construction is exactly as strong as the owner→id map being one-to-one, which is why that map is contracted in § State rather than left to an implementation: while it was many-to-one, two honest actors with different names met in the same file and the shorter claim won.
   A caller that *names someone else* is a different question, answered under human primacy below and in `SECURITY.md`.
5. Human-facing sentences may be reworded at any time; parse `--json`/`--machine`.
   A differential harness is the instrument that enforces this asymmetry — contract-bearing lines must match exactly, prose differences are reported and allowed — and it is the only thing that catches a field name, an exit code or a field's *type* drifting.
6. Reverting an **orphan** — the switch on with nothing claiming it — is allowed to anyone, always.
   Stopping is never the thing simmer stands in the way of.

## The claims ledger

A ledger of claims rather than a single lease: owner conflicts and `--force` disappear, and `state`/`until` aggregate over claims.
Human primacy is part of the contract: a human can release ANY claim, an agent only its own, and a human-set **cap** clips every claim present and future — claims request from below, the cap rules from above.

### The four readings the model does not determine on its own

These are the readings the implementation and the suite encode.
They are settled, not open.

| Question | Resolution | Why this one |
|---|---|---|
| What is a claim's identity? | **The owner.** One live claim per owner, id = owner sanitised into a filename, **fingerprinted when sanitising changed it** (§ State). | "Extend/release/replace *mine*" needs no registry and cannot be ambiguous, and an actor naming only itself cannot name another's file. The sanitising must stay one-to-one for that to hold at all — it did not, and a one-minute claim ate a two-hour one. Actors that are genuinely several things make their identity unique (`run:<pid>`); concurrent agents should too (`--owner agent:funnel`). |
| "floor/thermal end all of them" | Claims retire on **their own** floor; the last one out flips the switch. Thermal ends everything, unconditionally. | With the default floor everywhere — the normal case — the floor *does* end all of them. Per-claim means an agent asking `--min-battery 60` cannot drag a human's claim down with it, which the all-at-once reading would allow. Heat is a fact about the machine, not about anyone's plan for it, so it has no per-claim setting. |
| Which claim's `reason`/`owner`/`floor` does `--machine` report? | The claim that **defines the aggregate deadline**. | One coherent rule, and identical to the single-lease answer whenever there is one claim — so every existing reader keeps working. |
| A cap whose time has passed | **Refuses new claims**, in every surface, until it **lifts itself at the next 09:00** — or a human moves or lifts it sooner. | A cap answers a question about *tonight*, so it must hold for the whole of tonight: failing toward sleep is simmer's bias, and quietly lapsing at 23:01 would throw away the decision at the moment it mattered. But the same ceiling still standing at 11:00 the next morning is a lockout nobody chose, whose fix was explained in a notification eleven hours ago. The rollover is what makes the gate real *and* survivable. The refusal names both exits, so neither is a surprise. |
| When exactly does a cap lift itself? | The **first 09:00 strictly after the cap's own time**, recorded as `expires` when the cap is written. Not configurable. | One rule, no special cases. It does mean a *daytime* ceiling (`simmer cap 2h` at 11:00) stays a gate until the following morning — rare, deliberate, and it still ends by itself; a second rule to shave that would cost more legibility than it buys. A knob for the rollover hour would be one more thing to hold in your head, which is the problem this solves. |

Human primacy is enforced against honest actors, not as a security boundary: nothing stops a process passing `--owner terminal`, and on a single-user Mac nothing could.
What it buys is that an agent following the protocol cannot take a human's time away by accident, which is the failure that actually happens.
The agent protocol states the obligation not to claim human authority: `AGENTS.md`, in the repository root.

### Deltas from `format=1`, each deliberate

An implementation migrating a single-lease predecessor owes these differences; the reasoning is what keeps them from being re-argued.

| single lease (`format=1`) | claims (`format=2`) | Why |
|---|---|---|
| a second owner is refused | gets its own claim | awake time is counted, not owned |
| `--force` replaces a lease | inert, and says so | nothing left to force |
| `simmer down` releases whoever's lease | releases **yours** | an agent must not end a human's claim |
| `simmer down` holding no claim released everything | **refused**, with the list | ending work you did not start deserves an explicit flag. A human is pointed at `down --all` — their authority, stated; an agent is not, because that call is not theirs |
| `simmer +20m` needed no ownership | needs a claim of yours | "extend" has to mean something specific once there are several |
| `simmer +20m` set the deadline to now+20m | **adds** 20 minutes to it | see § Surface guarantees — a "+" that subtracts is the one surprise this tool cannot afford |
| `run` proved ownership with a `[run <pid>]` token in the reason | owner is `run:<pid>`; the reason is just the command | the identity moved to where identity lives |
| a `run` could be replaced mid-flight | cannot happen | by construction: its owner is `run:<pid>` |

### Part of the same model

- `--require-ac` — the claim ends the moment the charger goes.
  An overnight claim is only sane on mains power; when the cable goes the assumption behind it is gone too, so it ends at 90% rather than at the floor hours later.
- a pre-floor warning at floor+10% — the point of warning early is that plugging in is still an option.
  At the floor itself the only thing left to report is that it is over.
- `SIMMER_FAKE_NOW`.

## Surface guarantees

All additive to the surface above:

- **Canonical verbs, sugar kept.** `claim` / `extend` / `release` are the grammar; `simmer 2h`, `simmer +20m`, `simmer down|off|stop` stay as documented, tested aliases.

- **`extend` adds; it never shortens.** `simmer +20m` on a claim due at 23:00 means 23:20, not "20 minutes from now".
  The word and the `+` both mean addition to every reader, and the earlier from-now reading could silently discard hours: a 4-hour claim plus `+15m` left fifteen minutes, reported as `{"action":"extended"}`.
  Losing awake time is the one thing this tool exists to prevent, so a surface where the fix for "I need slightly longer" can cost hours is wrong however well documented.
  `simmer <duration>` remains the way to *set* a deadline from now, and the two spellings now mean visibly different things.
  A claim already past its deadline but not yet retired extends from **now**, never from the stale deadline — otherwise the addition lands in the past.
  The alias set is exactly the surface above.
- **`--json` on every command that has a machine answer**: `claim`, `extend`, `release`, `cap`, `status`, `budget`, `log`, `doctor`, `update`.
  A mutating command returns one object: what changed plus the resulting aggregate — `{"action":"claimed|extended|released|cap_set|cap_lifted|refused", "claim": {…}, "clipped_by_cap":bool, "state", "until", "left", "claim_count", "cap", "capped", "cap_expires"}`, where `cap_expires` says when the ceiling lifts itself (0 = no cap).
  Bare `cap --json` spells the same field `expires`, because every field in that object is already about the cap.
  `notify-test` and `render` have none and **refuse** the flag rather than accepting and ignoring it: a flag that is silently dropped is indistinguishable, to the caller, from one that worked.
  (`render`'s surfaces *are* its machine output; `--json` there would be a fourth surface nobody asked for.)
  `everyVerbHonoursJSON` is the gate — it walks the whole verb list, so a new command cannot join the surface without answering this question one way or the other.
  A refusal with `--json` prints `{"action":"refused","error":"…"}` and still exits 1.
- **The exit-code table is complete and published** (in `--help` and here): budget 0/1/3 · run passes through · claim/extend/release/cap 0 ok, 1 refused · doctor 0/1.
  Parse errors are 1, never an ArgumentParser 64.
- **The anonymous-claimer nudge.** A non-tty caller taking a claim without naming itself gets one stderr line — not an error, not repeated, invisible to humans in a terminal.
- **`events.jsonl` is contracted** as append-only state (§ State above): one object per transition with `v`, `ts`, `ts_human`, `event`, and the event's details (`owner`, `reason`, `until`, `why`, …).
  Events observed: `claim`, `extend`, `release`, `release_all`, `retire`, `cap_set`, `cap_lifted`, `cap_expired`, `switch_on`, `switch_off`, `orphan_heal`, `thermal_release`, `warn`, `prefloor_warn`, `remind`, `migrate`.
  Order is chronological — the switch flips before the claim file lands, and the stream says so.
  Fields are append-only.
  Nothing reads it yet; `watch`/`why` stay uncontracted.
- **`simmer update` reports; installing is a second, explicit thing to ask for.** Bare, it prints the command for the copy it is running from and stops there — `--apply` runs it, and `--auto on` lets the daily check run it (both below).
  An update replaces a running app and the binary the guard's LaunchAgent points at, and it can be asked for while a claim is live — so the default shape is `simmer uninstall`'s, for the same reason: an operation that happens rarely, in front of a person already at a keyboard, is better as a command they can read first than as a button that acts on their behalf.
  What the two additions buy is the case that shape does not serve — a person with no terminal, and a copy nobody opens — and each pays for it separately: `--apply` by running only the command it would have printed, `--auto` by being off until asked and refusing while a claim is live.
  `--cached` reports the last check and makes no network request, which is what every surface that is not the one being asked uses — `doctor`, the menu bar, a launcher row.
  `doctor` therefore answers the same on a train as in the office.
- **One outbound request, and it is the only one.** A `HEAD` to `github.com/moralesl/simmer/releases/latest`, whose redirect names the newest tag.
  It carries a `simmer/<version>` User-Agent and nothing else: no identifier, no machine detail, no telemetry, ever.
  The app makes it at most once a day; `simmer update` makes it when asked.
  A check that finds a version nobody has been told about posts **one** banner and records the tag in `update-announced` (§ State), so the cost of the feature is one banner per release rather than one a day — and being months behind is no longer something a Mac can be silently.
- **`--apply` runs the command it would have printed, and never anything else.** Three properties hold, and they are what make it something this tool can offer at all rather than a convenience bolted on:
  1. **It never pipes the network into a shell.** The printed command for a bundle install is `curl … | bash`; the plan updates the installer's own checkout (`~/.local/share/simmer`) and runs `make install` there — local files, the same recipe `bootstrap.sh` would have run.
     An acceptance test asserts that nothing executed contains `curl`, `bash` or a pipe.
  2. **It needs no root.** `make install` never touches sudo.
     The privileged rule is installed once, by a human, and an update does not renew it — so "simmer never gives itself root" is untouched.
  3. **It refuses rather than guesses.** A developer's own checkout is never moved onto a tag: it may hold local commits, an unfinished branch or a stash, and a person running from a checkout has a terminal by definition.
     An install this cannot place, or one with no checkout to build from, is refused with the command that does work.
     Not knowing whether there is an update refuses too.
- **A step that fails says what did not finish, and what to do.** Each step carries the part of the update it is doing — fetching the release, switching to it, installing it, relaunching the app — and the first line of the failure is a sentence naming that part, whether anything on the Mac changed, and the command that works from a terminal.
  The failing command and its stderr tail stay underneath it, and in `--json`'s `apply_error` unchanged: the sentence is for the person, the command is what a caller has always parsed.
  `relaunching` is the one phase that is not a failed install — the update landed and the menu bar did not come back — so it exits 0, keeps `applied: true`, sets no `apply_error`, and says to open the app rather than to run the installer again.
- **The unattended install is off by default, and a live claim refuses it.** With `simmer update --auto on`, the app's once-a-day check may install what it finds — the same `simmer update --apply` a person's click runs, so there is one implementation and one set of tests.
  Everything must hold, and the decision is one pure function in the core with each refusal named — `off`, `cannotTell`, `nothingNewer`, `alreadyTried`, `claimIsLive`, `planRefused` — so that "nothing happened" is always attributable.
  They are answered permanent-reason-first: a person told to wait for a claim to end, when the release will not be attempted after it ends either, has been told to wait for nothing.
  `cannotTell` is its own reason rather than a shade of `nothingNewer` because a Mac that cannot reach GitHub and a Mac with nothing to install need different things done about them — and it is logged, which the ordinary daily answers (`off`, `nothingNewer`) are not.
  **`Aggregate.compute` is what answers "is a claim live"**, never the claims directory: a surface that reads the ledger itself becomes a second implementation of the aggregate.
  An update quits `Simmer.app`, replaces the binary the guard's LaunchAgent points at, and compiles for a minute or two — while a claim is live that is exactly the walked-away window a claim exists to protect, so it waits.
  A release skipped for that reason is retried at the **next daily check**, not when the claim ends: an update that starts compiling the moment an overnight job hands the lid back is an update nobody is expecting.
  **One unattended attempt per release**, recorded in `update-attempted` (§ State) before it starts.
  A release that cannot be installed — a tag that will not fetch, a build that fails — otherwise fails again at every daily check, with a banner each time, which is the repetition "one banner per new version" exists to prevent applied to the half of the feature that can go wrong.
  So this path stands down from that one release and from nothing else: the next release is attempted, a person's `simmer update --apply` always attempts, the menu bar's **Install it now** always attempts, and turning `--auto on` again clears the record.
  Only the background pass may install; `force` — a person who just clicked "Check for Updates…" — gets the report and the button, because installing under a click that asked a question is the surprise the whole feature is built to avoid.
  The completion banner is `--apply`'s own, through the spool, which is what lets it survive the app being replaced and relaunched in between; nothing posts a second one.
  And it does not add to the availability banner, it **replaces** it: when the check's answer is about to be installed, the "one banner per new version" announcement is recorded and not posted, because the update path is already going to post two about that same version.
  Going back is `FAQ.md` § A release broke something, and it begins with `--auto off` — otherwise the next daily check reinstalls what was rolled back.
- **`simmer guard`** is the tick's CLI spelling — what the LaunchAgent runs.
  It never prompts (sudo -n or nothing) and exits 1 only when the switch could not be moved.

## Not yet contracted

- `--lock` (lock the screen on take).
  Listed here so no implementation invents behaviour for it; it enters the surface above only together with its tests.
- `simmer watch`, `simmer why` — planned consumers of `events.jsonl`, see `ROADMAP.md`.
  Nothing may depend on them yet.
