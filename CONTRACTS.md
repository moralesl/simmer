# Contracts

What stays true across implementations. v1 (bash) and v2 (Swift) both honour this
page; the v1 test suite is the executable form of it, and any implementation that
passes the suite under the seam variables below is a valid simmer.

## CLI surface

```
simmer <duration> [-r reason] [--min-battery N] [--until HH:MM] [--owner name]
       [--display-on] [--force]                 take (or replace own) awake time
simmer forever [...]                            no deadline; reminded, floor still applies
simmer run [-r] [--max D] [--force] -- <cmd>    awake exactly while <cmd> runs
simmer +<duration> | extend <duration>          move the deadline, from now
simmer down | off | stop | release              hand it back
simmer                                          human status
simmer status --machine | --json                machine status
simmer budget [--need D] [--seconds] [--json]   room to start something?
simmer log [n] · doctor · notify-test · --version · --help
simmer render swiftbar|raycast|alfred [query]   surfaces, drawn by the core
```

Durations: `90`, `90m`, `2h`, `1h30m`, `45min`, `30s`, `2H`. Bare number = minutes.

## Exit codes are API

| Command | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `budget` | fits / no deadline | not enough time | — | **no lease at all** |
| `run -- cmd` | *(command's own exit code, passed through untouched)* ||||
| take/extend/down | ok | refused (floor, owner, parse) | — | — |
| `doctor` | healthy | something red | — | — |

`budget`'s 3-vs-1 split is load-bearing: 1 is a small budget, 3 is an absent
guarantee. Callers that conflate them keep working while the machine sleeps.

## Machine-readable output

`status --machine`: `key=value` lines — `state` (active·forever·idle·orphan),
`until` (epoch, 0=none), `left`, `left_short`, `reason`, `owner`, `min_battery`,
`battery`, `on_battery`, `sleep_disabled`, `format`, `version`.
`status --json` / `budget --json`: the same data as one JSON object; numbers are
numbers, `fits` is `true|false|null`, `seconds_left` is `-1` for no deadline.
Fields are append-only; removing or renaming one is a major version.

## State

`${XDG_STATE_HOME:-~/.local/state}/simmer/` — the lease (`format=` versioned,
written via temp-file + rename, never edited in place), the log, and in v2 an
append-only `events.jsonl` (one JSON object per transition: `v`, `ts`, `event`,
`reason`, `owner`, …). v2 reads a v1 lease once at migration.

## The test seam

Any implementation MUST honour these, or it cannot be tested without root and
without changing the machine under the tester:

| Variable | Effect |
|---|---|
| `SIMMER_FAKE_PMSET=<file>` | the sleep switch is that file's `0`/`1` |
| `SIMMER_FAKE_BATTERY=<pct>:<on_batt>` | e.g. `12:1` |
| `SIMMER_FAKE_THERMAL=<0|N>` | thermal warning level |
| `SIMMER_NOTIFY=<transport|none>` | notification routing |
| `SIMMER_NOTIFIER_APP=<path>` | notifier bundle override |
| `SIMMER_BIN=<path>` | which binary integrations exec |
| `XDG_STATE_HOME=<dir>` | state isolation |
| `SIMMER_RUN_CHUNK` / `SIMMER_RUN_INTERVAL` | run's renewal clocks |

## Behavioural guarantees

1. Five things end awake time; only one is remembering: deadline, battery floor
   (on battery only), thermal pressure, explicit release, and the guard reverting
   a switch it finds enabled with no lease behind it.
2. The switch is never exposed, only leased. No code path leaves `disablesleep`
   on without something scheduled to turn it off.
3. A warning fires once, ~5 minutes before the deadline; open-ended time reminds
   every 30 minutes.
4. One actor cannot silently take over another's awake time (v1: owner refusal +
   `--force`; v2 claims model, if adopted: impossible by construction).
5. Human-facing sentences may be reworded at any time; parse `--json`/`--machine`.

## Known v1→v2 deltas (each requires a decision recorded here)

- D1 **approved 2026-08-23**: claims ledger replaces the single lease — owner
  conflicts and `--force` disappear; `state`/`until` aggregate over claims.
  Human-primacy rules are part of the contract: a human can release ANY claim
  (`down --all` in the menu bar and CLI); an agent may only release its own; and
  a human-set **cap** (`simmer cap 23:00`) clips every claim, present and
  future — claims request from below, the cap rules from above. Sequencing:
  landed in v1/bash FIRST (format=2) so the ported suite covers claims before
  the Swift rewrite — a differential run must attribute divergence to the
  language change, not the model change.
- Planned, not yet contracted: `--lock` (lock the screen on take). Listed here
  so no implementation invents behaviour for it; it enters the surface above
  only together with its tests.
