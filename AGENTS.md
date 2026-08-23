# Working on simmer

For agents (and humans) changing THIS repository.
For *using* simmer from an agent on some machine, read `docs/FOR-AGENTS.md` instead.

## Read first, in this order

1. `docs/CONTRACTS.md` — the law: surface, exit codes, machine output, and the reasoning behind every choice.
   Settled decisions are not relitigated.
2. `docs/LEARNINGS.md` — every trap already paid for.
   If your plan trips one, the plan is wrong.
3. `docs/PLATFORM-FACTS.md` — what macOS actually permits, each line bought with a failed attempt.
   Change nothing there without re-running the experiment and recording the new result.

## Commands

```bash
make test        # BOTH suites, hermetic: no sudo, no real power state, fake clock
make app         # assemble + ad-hoc sign Simmer.app (CLT only — never xcodebuild)
make install     # ~/Applications/Simmer.app + ~/.local/bin/simmer + the guard
make uninstall   # removes exactly what install wrote
```

## Iron rules

- **The test seam is load-bearing.** Every side effect outside the process goes through `SIMMER_FAKE_*` / `XDG_STATE_HOME` — a new side effect ships WITH its seam, or the suite is lying about being hermetic.
- **Exit codes and `--json`/`--machine` are API.** Human sentences may be reworded freely; a changed exit code or JSON field is a contract change and lands in `CONTRACTS.md` first.
  Machine fields are append-only.
- **Every mutation ends in `settle()`** — the one function that puts the switch where the ledger says.
  No second path to `disablesleep`, ever.
- **No detached child processes.** The spike leaked 222 orphaned caffeinates; v1 spawns nothing it does not wait for.
- **Only the app touches UserNotifications.** The CLI enqueues into the spool (`$STATE/notify-spool.jsonl`); the grant belongs to the app's executable (`docs/LEARNINGS.md`).
  The CLI target must not link SimmerNotifyKit.
- **Bundle ids are spent, never recovered.** Development builds use the `.devN` id from the Makefile; `io.github.moralesl.simmer` is promoted only at release.
  Never let a test bundle ask for notification permission under a production id.
- **SimmerCore stays pure**: no AppKit, no printing, no argv, no globals.
  The CLI and the app are renderers over it — that is what keeps them from disagreeing.

The bash spike (v0.1) that preceded this implementation lives at the git tag `v0.1` — reference material only; nothing imports from it.
