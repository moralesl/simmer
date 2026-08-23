# Working on simmer

For agents (and humans) changing THIS repository.
For *using* simmer from an agent on some machine, read `docs/FOR-AGENTS.md` instead.

## Read first, in this order

1. `docs/CONTRACTS.md` — the law: surface, exit codes, machine output, and the reasoning behind every choice.
   Settled decisions are not relitigated.
2. `docs/PLATFORM-FACTS.md` — what macOS actually does, each line bought with a failed attempt, plus the traps that no test can carry.
   If your plan trips one, the plan is wrong, and nothing there changes without re-running the experiment and recording the new result.

## Commands

```bash
make test        # BOTH suites, hermetic: no sudo, no real power state, fake clock
make app         # assemble + ad-hoc sign Simmer.app (CLT only — never xcodebuild)
make install     # ~/Applications/Simmer.app + ~/.local/bin/simmer + the guard
make uninstall   # removes exactly what install wrote
```

`BRIEF.md` and `DESIGN-NOTES.md` guided the v1 rewrite and are not in the tree; what they decided is in `docs/CONTRACTS.md`, and their text is in git history.
Cite the contract, not them.

## Iron rules

- **The test seam is load-bearing.** Every side effect outside the process goes through `SIMMER_FAKE_*` / `XDG_STATE_HOME` — a new side effect ships WITH its seam, or the suite is lying about being hermetic.
- **Exit codes and `--json`/`--machine` are API.** Human sentences may be reworded freely; a changed exit code or JSON field is a contract change and lands in `CONTRACTS.md` first.
  Machine fields are append-only.
- **Every mutation ends in `settle()`** — the one function that puts the switch where the ledger says.
  No second path to `disablesleep`, ever.
- **No detached child processes.** The spike leaked 222 orphaned caffeinates; v1 spawns nothing it does not wait for.
- **Only the app touches UserNotifications.** The CLI enqueues into the spool (`$STATE/notify-spool.jsonl`); the grant belongs to the app's executable (`docs/PLATFORM-FACTS.md`).
  The CLI target must not link SimmerNotifyKit.
- **Bundle ids are spent, never recovered.** Development builds use the `.devN` id from the Makefile; `io.github.moralesl.simmer` is promoted only at release.
  Never let a test bundle ask for notification permission under a production id.
- **SimmerCore stays pure**: no AppKit, no printing, no argv, no globals.
  The CLI and the app are renderers over it — that is what keeps them from disagreeing.
- **simmer never escalates its own privileges.** The sudoers rule is composed in `SudoRule`, shown in full, and run by a human — no `osascript … with administrator privileges`, no Authorization Services.
  Widening the rule's scope, letting the app run it, or letting the installer's copy drift from `SudoRule` all fail `SudoRuleTests`.
- **Yes/no means a JSON boolean** on every surface except the flat `--machine` (and its `status --json` mirrors `on_battery`/`sleep_disabled`).
  Asserted against raw JSON text — `as? Bool` accepts `0`/`1` and would miss it.
- **A verb in `Normalize.verbs` must have a subcommand behind it.** Otherwise it reaches the raw parser, whose "Unexpected argument" is the one refusal in the surface that names no fix.
  `everyDocumentedVerbResolves` is the gate.

The bash spike (v0.1) that preceded this implementation lives at the git tag `v0.1` — reference material only; nothing imports from it.
