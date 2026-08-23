# Contracts

What stays true across implementations.
The v0.1 spike (bash) and v1 (Swift) both honour this page; the test suite is the executable form of it, and any implementation that passes it under the seam variables below is a valid simmer.

**This page is the law, in prose.** v1 is being written from scratch and brings its own tests; it does not inherit the spike's harness.

Two instruments exist in `archive/v0.1-spike/`, and they are reference material rather than v1's gate — read them for what a thorough test of this contract looks like, then write v1's own:

- `make -C archive/v0.1-spike test` — 175 hermetic assertions over the surface below.
  Honours `SIMMER_BIN`, so it *can* be pointed at a v1 binary, but v1 owes no allegiance to it.
- `make -C archive/v0.1-spike diff` — a differential harness: identical CLI scenarios against two binaries, normalised and diffed, with contract-bearing lines compared exactly and prose allowed to differ.
  The idea is worth stealing even if the script is not.

Whatever v1 writes instead must still be able to answer: does an implementation satisfy every row below, including the exit codes and the machine output, without root and without changing the machine under the tester?
That is what the seam section exists for.

## CLI surface

```
simmer <duration> [-r reason] [--min-battery N] [--until HH:MM] [--owner name]
       [--require-ac] [--display-on] [--force]   claim (or replace own) awake time
simmer forever [...]                            no deadline; reminded, floor still applies
simmer run [-r] [--max D] [--force] -- <cmd>    awake exactly while <cmd> runs
simmer +<duration> | extend <duration>          move YOUR claim's deadline, from now
simmer down                                     hand YOUR claim back
simmer down --all                               hand everything back (humans only)
simmer cap <HH:MM|duration> | cap off | cap     the human ceiling
simmer                                          human status, listing every claim
simmer status --machine | --json                machine status
simmer budget [--need D] [--seconds] [--json]   room to start something?
simmer log [n] · doctor · notify-test · --version · --help
simmer render swiftbar|raycast|alfred [query]   surfaces, drawn by the core
```

Durations: `90`, `90m`, `2h`, `1h30m`, `45min`, `30s`, `2H`.
Bare number = minutes.

`--force` is accepted and does nothing.
It used to mean "stamp over someone else's lease"; the claims model removed the conflict it resolved.
It stays in the surface because launcher shims and other people's scripts pass it, and it prints a line saying it is inert rather than being silently ignored.

Every command reachable from a launcher also tolerates a trailing `-r <reason> --owner <name>`, because the Alfred action appends both to whatever the filter produced whether the command has any use for a reason or not.

## Exit codes are API

| Command | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `budget` | fits / no deadline | not enough time | — | **nothing claimed at all** |
| `run -- cmd` | *(command's own exit code, passed through untouched)* ||||
| take/extend/down/cap | ok | refused (floor, cap, authority, parse) | — | — |
| `doctor` | healthy | something red | — | — |

`budget`'s 3-vs-1 split is load-bearing: 1 is a small budget, 3 is an absent guarantee.
Callers that conflate them keep working while the machine sleeps.

## Machine-readable output

`status --machine`: `key=value` lines — `state` (active·forever·idle·orphan), `until` (epoch, 0=none), `left`, `left_short`, `reason`, `owner`, `min_battery`, `battery`, `on_battery`, `sleep_disabled`, `since`, `claim_count`, `cap` (epoch, 0=none).
`status --json` / `budget --json`: the same data as one JSON object; numbers are numbers, `fits` is `true|false|null`, `seconds_left` is `-1` for no deadline, `capped` is `true` when the deadline reported IS the cap, and `claims` is an array with one object per live claim (`id`, `owner`, `until`, `left`, `reason`, `min_battery`, `require_ac`, `since`, `human`).
Fields are append-only; removing or renaming one is a major version.

**The top-level fields describe the AGGREGATE** — what the machine will actually do — and the descriptive ones (`reason`, `owner`, `min_battery`, `since`) come from the claim that *defines* the aggregate deadline.
With one claim that is the same answer the single-lease shape gave, which is why every existing reader keeps working.
Per-claim detail is in `claims`, never in `--machine`: that format stays flat so a menu bar can read it without `jq`.

## State

`${XDG_STATE_HOME:-~/.local/state}/simmer/`:

- `claims/<id>` — one `format=2` key=value file per claim, written via temp-file
  + rename, never edited in place.
- `cap` — the human ceiling, same discipline.
- `simmer.log`.
- in v1, additionally an append-only `events.jsonl` (one JSON object per transition: `v`, `ts`, `event`, `reason`, `owner`, …).

A `format=1` lease is read **once**, converted into a claim, and deleted.
An implementation must do this migration: someone upgrading mid-lease must not silently lose awake time they are relying on, and must never end up with both shapes on disk, which is how a guard learns to disagree with the CLI.

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
| `SIMMER_NOTIFY=<transport\|none>` | notification routing |
| `SIMMER_NOTIFIER_APP=<path>` | notifier bundle override |
| `SIMMER_BIN=<path>` | which binary integrations exec |
| `XDG_STATE_HOME=<dir>` | state isolation |
| `SIMMER_RUN_CHUNK` / `SIMMER_RUN_INTERVAL` | run's renewal clocks |

**Every side effect outside the process must be behind this seam, not merely the ones that are awkward to test.** The spike learned this by leaking 222 orphaned `caffeinate` processes from a suite that called itself hermetic: ten seam variables, and none of them covering the one call that spawned a detached child holding a real power assertion.
If an implementation shells out or spawns anything, that has a `SIMMER_FAKE_*` too.

`SIMMER_FAKE_NOW` is not a convenience.
Warn-once, the reminder interval and deadline crossings are the paths a differential run has to compare, and without a substitutable clock they are reachable only by hand-writing timestamps into state files — which tests the fixture rather than the code.

## Behavioural guarantees

1. Five things end awake time; only one is remembering: a claim's deadline (or the cap clipping it), the battery floor (on battery only), its charger disappearing if it asked for one, thermal pressure, explicit release, and the guard reverting a switch it finds enabled with no claim behind it.
2. The switch is never exposed, only leased.
   **Every mutation ends in one function that reads the ledger and puts the switch where it says** — that is what makes "no code path leaves `disablesleep` on without something scheduled to turn it off" a property rather than a promise.
3. A warning fires once, ~5 minutes before the **aggregate** deadline; open-ended time reminds every 30 minutes; a claim on battery warns once at floor+10%, re-arming if the charger returns.
4. One actor cannot touch another's awake time.
   Not by refusal — by construction: a claim's id is its owner, so no actor can address another's.
5. Human-facing sentences may be reworded at any time; parse `--json`/`--machine`.
   `make diff` enforces this asymmetry: contract lines must match exactly, prose differences are reported and allowed.
6. Reverting an **orphan** — the switch on with nothing claiming it — is allowed to anyone, always.
   Stopping is never the thing simmer stands in the way of.

## D1 — the claims ledger

**Approved 2026-08-23.
Landed in bash on 2026-08-23 (`format=2`), before the Swift rewrite**, so the suite covers claims under real multi-actor use before the language changes and a differential divergence is attributable to Swift rather than to the model.

The ledger replaces the single lease: owner conflicts and `--force` disappear, `state`/`until` aggregate over claims.
Human primacy is part of the contract: a human can release ANY claim, an agent only its own, and a human-set **cap** clips every claim present and future — claims request from below, the cap rules from above.

### Resolved while landing it

D1 left four things underdetermined.
These are the readings the implementation and the suite encode; they are settled, not open.

| Question | Resolution | Why this one |
|---|---|---|
| What is a claim's identity? | **The owner.** One live claim per owner, id = owner sanitised into a filename. | "Extend/release/replace *mine*" needs no registry and cannot be ambiguous, and an actor physically cannot name another's file. Actors that are genuinely several things make their identity unique (`run:<pid>`); concurrent agents should too (`--owner agent:funnel`). |
| "floor/thermal end all of them" | Claims retire on **their own** floor; the last one out flips the switch. Thermal ends everything, unconditionally. | With the default floor everywhere — the normal case — the floor *does* end all of them. Per-claim means an agent asking `--min-battery 60` cannot drag a human's claim down with it, which the all-at-once reading would allow. Heat is a fact about the machine, not about anyone's plan for it, so it has no per-claim setting. |
| Which claim's `reason`/`owner`/`floor` does `--machine` report? | The claim that **defines the aggregate deadline**. | One coherent rule, and identical to the single-lease answer whenever there is one claim — so every existing reader keeps working. |
| A cap whose time has passed | **Refuses new claims**, in every surface, until a human moves or lifts it. | Letting it expire quietly would discard a decision a person made on purpose. Failing toward *sleep* is simmer's bias, and the refusal names the fix (`simmer cap off`) so it is a visible gate rather than a trap. |

Human primacy is enforced against honest actors, not as a security boundary: nothing stops a process passing `--owner terminal`, and on a single-user Mac nothing could.
What it buys is that an agent following the protocol cannot take a human's time away by accident, which is the failure that actually happens.
The agent protocol states the obligation not to claim human authority.
It is being rebuilt for v1; the v0.1 wording is at `archive/v0.1-spike/FOR-AGENTS.md`.

### Deltas from `format=1`, each deliberate

| v0.1 spike | v1 | Why |
|---|---|---|
| a second owner is refused | gets its own claim | D1 |
| `--force` replaces a lease | inert, and says so | nothing left to force |
| `simmer down` releases whoever's lease | releases **yours** | an agent must not end a human's claim |
| `simmer down` from a non-tty holding no claim released everything | **refused**, with the list | same reason. A human in that position still releases everything, and is told whose it was |
| `simmer +20m` needed no ownership | needs a claim of yours | "extend" has to mean something specific once there are several |
| `run` proved ownership with a `[run <pid>]` token in the reason | owner is `run:<pid>`; the reason is just the command | the identity moved to where identity lives |
| a `run` could be replaced mid-flight | cannot happen | D1, by construction |

### Also landed with it

- `--require-ac` — the claim ends the moment the charger goes.
  An overnight claim is only sane on mains power; when the cable goes the assumption behind it is gone too, so it ends at 90% rather than at the floor hours later.
- a pre-floor warning at floor+10% — the point of warning early is that plugging in is still an option.
  At the floor itself the only thing left to report is that it is over.
- `SIMMER_FAKE_NOW`.

## v1 surface additions — blessed 2026-08-23, all additive

The DESIGN-NOTES "take" items, adopted as contract:

- **Canonical verbs, sugar kept.** `claim` / `extend` / `release` are the grammar; `simmer 2h`, `simmer +20m`, `simmer down|off|stop` stay as documented, tested aliases.
  The alias set is exactly the surface above.
- **`--json` on every command**, not just `status` and `budget`.
  A mutating command returns one object: what changed plus the resulting aggregate — `{"action":"claimed|extended|released|cap_set|cap_lifted|refused", "claim": {…}, "clipped_by_cap":bool, "state", "until", "left", "claim_count", "cap", "capped"}`.
  A refusal with `--json` prints `{"action":"refused","error":"…"}` and still exits 1.
- **The exit-code table is complete and published** (in `--help` and here): budget 0/1/3 · run passes through · claim/extend/release/cap 0 ok, 1 refused · doctor 0/1.
  Parse errors are 1, never an ArgumentParser 64.
- **The anonymous-claimer nudge.** A non-tty caller taking a claim without naming itself gets one stderr line — not an error, not repeated, invisible to humans in a terminal.
- **`events.jsonl` is contracted** as append-only state (§ State above): one object per transition with `v`, `ts`, `ts_human`, `event`, and the event's details (`owner`, `reason`, `until`, `why`, …).
  Events observed: `claim`, `extend`, `release`, `release_all`, `retire`, `cap_set`, `cap_lifted`, `switch_on`, `switch_off`, `orphan_heal`, `thermal_release`, `warn`, `prefloor_warn`, `remind`, `migrate`.
  Order is chronological — the switch flips before the claim file lands, and the stream says so.
  Fields are append-only.
  Nothing reads it yet; `watch`/`why` stay uncontracted.
- **`simmer guard`** is the tick's CLI spelling — what the LaunchAgent runs.
  It never prompts (sudo -n or nothing) and exits 1 only when the switch could not be moved.

## Not yet contracted

- `--lock` (lock the screen on take).
  Listed here so no implementation invents behaviour for it; it enters the surface above only together with its tests.
- `events.jsonl`, `simmer watch`, `simmer why` — planned, see `BRIEF.md`.
  Nothing may depend on them yet.
