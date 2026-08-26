# Working on simmer

For agents (and humans) changing THIS repository.
For *using* simmer from an agent on some machine, read `docs/FOR-AGENTS.md` instead.

## The shape of it

**One Swift package, three products** — `SimmerCore` (the logic, no AppKit, no printing), `simmer` (the CLI), and `Simmer.app` (menu bar + event-driven guard + notification identity, one bundle).
The guard runs both ways over one idempotent `tick()`: IOKit events in the app for instant response, and a LaunchAgent every 30 seconds as the backstop nobody can quit.

```
Sources/SimmerCore/  claims · ledger · cap · aggregate · settle · tick ·
                     budget · render · the power seam · the clock seam
Sources/SimmerCLI/   argv in, exit code out. Thin on purpose.
Sources/SimmerApp/   NSStatusItem · IOKit callbacks · UNUserNotificationCenter
Tests/               unit suite + an acceptance suite that drives the BUILT
                     binary under the seam variables (honours SIMMER_BIN)

integrations/raycast/ the Raycast extension: TypeScript, its own npm tree and
                     tests. A fourth renderer over `status --json` — it must
                     never read $STATE/claims itself, or it acquires its own
                     opinion about what is held.

AGENTS.md            this page: read order, commands, iron rules.
docs/FOR-AGENTS.md   USING simmer from an agent: budget, owners, obligations.
docs/CONTRACTS.md    the law, in prose: surface, exit codes, machine output,
                     and the reasoning behind every choice.
docs/PLATFORM-FACTS.md  what macOS actually does, verified — and the traps a
                     test cannot carry. Read this first.
docs/ROADMAP.md      decided but not built. docs/FAQ.md — short answers.
```

## Read first, in this order

1. `docs/CONTRACTS.md` — the law: surface, exit codes, machine output, and the reasoning behind every choice.
   Settled decisions are not relitigated.
2. `docs/PLATFORM-FACTS.md` — what macOS actually does, each line bought with a failed attempt, plus the traps that no test can carry.
   If your plan trips one, the plan is wrong, and nothing there changes without re-running the experiment and recording the new result.

## Commands

```bash
make test          # both SWIFT suites, hermetic: no sudo, no real power state
make test-raycast  # the extension's lane: `make test` cannot see it
make app           # assemble + ad-hoc sign Simmer.app (CLT only — never xcodebuild)
make install       # ~/Applications/Simmer.app + ~/.local/bin/simmer + the guard
make uninstall     # removes exactly what install wrote
```

**`make test` does not test the extension.** `swift test` cannot see `integrations/raycast`, so a change to `src/*.tsx` followed by a green `make test` has verified nothing about it.
Touching both sides means both commands.

`BRIEF.md` and `DESIGN-NOTES.md` guided the Swift rewrite and are not in the tree; what they decided is in `docs/CONTRACTS.md`, and their text is in git history.
Cite the contract, not them.

## Iron rules

- **The test seam is load-bearing.** Every side effect outside the process goes through `SIMMER_FAKE_*` / `XDG_STATE_HOME` — a new side effect ships WITH its seam, or the suite is lying about being hermetic.
- **Exit codes and `--json`/`--machine` are API.** Human sentences may be reworded freely; a changed exit code or JSON field is a contract change and lands in `CONTRACTS.md` first.
  Machine fields are append-only.
- **Every mutation ends in `settle()`** — the one function that puts the switch where the ledger says.
  No second path to `disablesleep`, ever.
- **No detached child processes.** The spike leaked 222 orphaned caffeinates; simmer spawns nothing it does not wait for.
- **Only the app touches UserNotifications.** The CLI enqueues into the spool (`$STATE/notify-spool.jsonl`); the grant belongs to the app's executable (`docs/PLATFORM-FACTS.md`).
  The CLI target must not link SimmerNotifyKit.
- **Bundle ids are spent, never recovered.** `io.github.moralesl.simmer` is the production id, promoted for the Swift rewrite — never point that line at a fresh id to try something.
  Develop under a throwaway (`make BUNDLE_ID=…dev3 app`); the Makefile keeps the ledger of ids already burned.
  Never let a test bundle ask for notification permission under a production id.
- **SimmerCore stays pure**: no AppKit, no printing, no argv, no globals.
  The CLI and the app are renderers over it — that is what keeps them from disagreeing.
- **Every surface consumes the contract, never the ledger.** A surface that parses `$STATE/claims/*` itself becomes a second implementation of the aggregate, and the two disagree the first time cap clipping changes.
  The Raycast extension shells out to `status --json` for the list and `render raycast` for its one-line root-search subtitle, for exactly that reason.
- **simmer never escalates its own privileges.** The sudoers rule is composed in `SudoRule`, shown in full, and run by a human — no `osascript … with administrator privileges`, no Authorization Services.
  Widening the rule's scope, letting the app run it, or letting the installer's copy drift from `SudoRule` all fail `SudoRuleTests`.
- **Yes/no means a JSON boolean** on every surface except the flat `--machine` (and its `status --json` mirrors `on_battery`/`sleep_disabled`).
  Asserted against raw JSON text — `as? Bool` accepts `0`/`1` and would miss it.
- **A verb in `Normalize.verbs` must have a subcommand behind it.** Otherwise it reaches the raw parser, whose "Unexpected argument" is the one refusal in the surface that names no fix.
  `everyDocumentedVerbResolves` is the gate.
- **No surface may cost a caller awake time it already holds.** `extend` adds; a button or menu item saying "more" adds.
  Anything that *sets* a deadline says so in its label, because the one thing this tool exists to prevent is time quietly disappearing.
  `extendingALongClaimByALittleNeverShortensIt` and `moreTimeExtendsTheMenuBarsOwnClaimRatherThanReplacingIt` are the gates; the app's banner button goes through the same branch, and the Raycast extension's own gate is `integrations/raycast/tests/args.test.mts`.
- **`--json` is honoured or refused, never accepted and dropped.** A silently ignored flag is indistinguishable from one that worked — that is how `--help` came to promise a surface four commands did not have.
  `everyVerbHonoursJSON` walks the whole verb list, so a new command cannot join the surface without answering the question.
- **A flag's own validation belongs to simmer, not to ArgumentParser.** Parser diagnostics name internal subcommand spellings nobody typed and write nothing to stdout, so a `--json` caller gets an empty stream instead of the contracted refusal object.
  Take the value as `String`, validate it, and refuse through `Outcome.failure` — as `budget --need` and `claim --min-battery` do.

The bash spike that preceded this implementation lives in the maintainer's development archive, at its `v0.1` tag — reference material only; nothing imports from it, and it is not in this repository's history.
