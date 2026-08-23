# Changelog

## 2.0.0-dev — 2026-08-23

**The lease becomes a ledger.** Awake time is now counted rather than owned: you,
an agent and a build each hold their own *claim*, the Mac stays awake until the
last one ends, and nobody can touch anybody else's. This is decision D1 in
[CONTRACTS.md](CONTRACTS.md), landed in the bash implementation first — on
purpose, so the suite covers claims under real multi-actor use before the Swift
rewrite changes the language, and a later divergence is attributable to Swift
rather than to the model.

The version is `2.0.0-dev` because the *contract* is v2's while the
implementation is still bash. `v1.0.0` is tagged, branch `v1` points at it, and
it is the reference `make diff` compares against.

### The model

- **Claims, `format=2`.** One key=value file per claim under
  `~/.local/state/simmer/claims/`. A claim's id is its owner, which is the whole
  ownership model: "extend/release/replace mine" needs no registry and cannot be
  ambiguous, and one actor physically cannot address another's file.
- **`--force` does nothing**, and says so. The conflict it resolved cannot occur.
  It stays in the surface because launcher shims and other people's scripts pass
  it, and erroring on a flag that became harmless would break callers for no gain.
- **`simmer cap 23:00`** — the ceiling only a human sets, clipping every claim
  present and future. `simmer cap` reads it, `simmer cap off` lifts it. A cap
  whose time has passed keeps refusing new claims until a human moves it: letting
  it lapse quietly would discard a decision a person made on purpose.
- **Human primacy.** A person can release any claim (`simmer down --all`); an
  agent only its own. Enforced against honest actors rather than as a security
  boundary — on a single-user Mac nothing could stop a process passing
  `--owner terminal`, so `docs/FOR-AGENTS.md` states it as an obligation.
- **The aggregate is what every surface reports.** The menu bar countdown, the
  5-minute warning and `budget` all answer over what the machine will actually
  do. Banners fire on aggregate changes only, so per-claim churn is silent.

### Also new

- **`--require-ac`** — the claim ends the moment the charger is unplugged. An
  overnight claim is only sane on mains power, so it ends at 90% rather than at
  the floor hours later.
- **A pre-floor warning at floor+10%**, once per claim, re-arming if the charger
  returns. Warning early is worth something because plugging in is still an
  option; at the floor itself the only thing left to report is that it is over.
- **`SIMMER_FAKE_NOW`** — the clock joins the test seam. Warn-once, the reminder
  interval and deadline crossings used to be reachable only by hand-writing
  timestamps into state files, which tests the fixture rather than the code.
- **`make diff`** — a differential harness. Drives two binaries through identical
  CLI scenarios, normalises what legitimately varies, and diffs. Contract lines
  (exit codes, `key=value`, JSON) must match exactly; prose may be reworded,
  which is contract guarantee 5 made executable. Scenarios that are *supposed* to
  differ are declared, so a delta quietly reverting is also a finding.
- **`claim_count`, `cap`, `capped` and a `claims[]` array** in the machine output.
  Append-only, so existing readers keep working.
- `simmer down` now confirms on stdout instead of succeeding silently.

### Migration

A `format=1` lease is read once, converted into a claim named by its owner, and
deleted. Nobody upgrading mid-lease loses awake time, and the two shapes never
coexist on disk — which is how a guard would otherwise learn to disagree with the
CLI.

### Deltas that will surprise a script

Every one is deliberate and recorded under D1 in CONTRACTS.md.

- `simmer down` releases **your** claim, not whoever's. From a non-tty caller
  holding no claim it is now **refused**, with the list of whose claims are live.
  Typed in a terminal it still releases everything, and names what it released.
- `simmer +20m` needs a claim of yours.
- `run`'s ownership proof moved from a `[run <pid>]` token in the reason to the
  owner itself (`run:<pid>`); the reason is just the command again.
- The suite grew from 95 assertions to 174 and its `lease()` fixture became
  `claim()`.

## 1.0.0 — 2026-08-21

First release. Extracted from a personal dotfiles repo into something
installable by someone else.

- `simmer <duration>` takes a lease on `pmset disablesleep` so the machine stays
  awake with the lid closed, and a LaunchAgent hands it back on the deadline, on
  a low battery, on `simmer down`, or when it finds the switch enabled with no
  lease behind it.
- `simmer budget --need 20m` answers *is there room to start this?* in the exit
  code — `0` room, `1` not enough, `3` no lease at all.
- `--owner` plus a refusal to replace another owner's lease without `--force`.
- Front-ends for SwiftBar, Raycast and Alfred, all shelling out to the one
  binary rather than reimplementing anything.
- Notifications post from a small bundled app, so they carry simmer's own name
  and icon instead of arriving as Script Editor.
- `SIMMER_FAKE_PMSET` / `SIMMER_FAKE_BATTERY` make the 43-assertion suite
  hermetic: no sudo, no real power state touched.

The lease file carries `format=1`. If its shape ever changes, that number moves
with it.
