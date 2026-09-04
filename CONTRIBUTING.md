# Contributing

simmer borrows a switch that has no expiry of its own and hands it back on a deadline.
That is the whole product, so the bar for changes is less "does it work" and more "can it still not forget".

## Before you write code

```bash
make test          # both Swift suites, hermetic: no sudo, no real power state, fake clock
make test-raycast  # only if you are touching integrations/raycast — see Tests, below
```

If that is not green on a clean checkout, stop and open an issue — nothing else is worth diagnosing first.

Then read, in this order:

1. [`docs/CONTRACTS.md`](docs/CONTRACTS.md) — the law: surface, exit codes, machine output, and the reasoning behind each choice.
   Settled decisions are not relitigated; if you think one is wrong, say so in an issue before building on the alternative.
2. [`docs/PLATFORM-FACTS.md`](docs/PLATFORM-FACTS.md) — what macOS actually does, each line bought with a failed attempt, plus the traps that no test can carry.
   If your plan trips one, the plan is wrong, and nothing there changes without re-running the experiment and recording the new result.
3. [`AGENTS.md`](AGENTS.md) — the protocol agents follow, and the iron rules for changing this repository.

## The rules that will get a change sent back

- **A new side effect ships with its seam.** Everything outside the process — every power read, the one power write, the clock, state, notifications — goes through `SIMMER_FAKE_*` / `XDG_STATE_HOME`.
  A suite that calls itself hermetic while one call reaches the real machine is lying, and that is not a hypothetical: the predecessor leaked 222 orphaned `caffeinate` processes exactly that way.
- **Exit codes and `--json` / `--machine` are API.** Human sentences may be reworded freely.
  A changed exit code, a renamed field, or a field that changes type is a contract change: it lands in `CONTRACTS.md` first, with a test.
  Machine fields are append-only.
- **Every mutation ends in `settle()`.** One function reads the ledger and puts the switch where it says.
  No second path to `disablesleep`, ever — that is what makes "nothing is left holding the lid with nothing scheduled to release it" a property rather than a hope.
- **Nothing detached, nothing escalated.** No background children simmer does not wait for, and no self-escalation: the privileged rule is composed, shown in full, and run by a human (`Sources/SimmerCore/Model/SudoRule.swift`).
- **Only the app posts notifications.** macOS binds the grant to the executable that asked; the CLI enqueues into the spool.
  The CLI target must not link `SimmerNotifyKit`.
- **`SimmerCore` stays pure** — no AppKit, no printing, no argv, no globals.
  The CLI and the app are renderers over it, which is what keeps them from disagreeing.

## Tests

Three lanes, three questions:

| Suite | Command | Question it answers |
|---|---|---|
| `Tests/SimmerCoreTests` | `make test` | do the mechanics work — parsing, the codec, aggregate ties, settle |
| `Tests/SimmerAcceptanceTests` | `make test` | does the **built binary** honour the contract |
| `integrations/raycast/tests` | `make test-raycast` | does the extension still read the contract the binary emits |

The acceptance suite honours `SIMMER_BIN`, so it can be pointed at any implementation of `CONTRACTS.md` — that is what makes it the executable form of the contract rather than a description of this code.
`bridge.test.mts` is the same idea from the other side of the pipe.

`make test` cannot see `integrations/raycast`, so a change to the extension with only `make test` green is a change nothing checked.
Touching both sides means both commands; CI runs all three either way.
And `AgentDocTests` replays the session in `AGENTS.md` against the built binary — editing that session is editing a test.

A behaviour change without a test that would have caught the old behaviour is not finished.
Where a rule can be a test instead of a sentence in a document, make it a test: several already are (the sudo rule's scope, the absence of self-escalation, that every documented verb resolves).

## Pull requests

- One concern per PR, and say which contract row it touches, if any.
- Note anything you did that is not the obvious approach, and why, at the point where you did it.
- CI runs the Swift suites on macOS 14 and 15, assembles the bundle, lints the templates and the installer, and runs the extension's lane twice — once as pure units on Linux, once against the built binary on macOS.
  All of it must be green.

## Releases

You do not need to touch the version.
It moves once, in a release commit, and `docs/RELEASING.md` is that procedure — including what happens when a pull request merges, which is: the notes go under `## Unreleased` and nothing else changes.

## What is deliberately not wanted

`docs/ROADMAP.md` closes with a list — a SwiftBar plugin, a daemon, a config file, named presets, force semantics, any paid Apple signature.
Each was weighed and declined; the reasoning is there.
An issue arguing one of them through is welcome, a PR implementing one unannounced is not.
