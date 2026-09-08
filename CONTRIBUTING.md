# Contributing

simmer borrows a switch that has no expiry of its own and hands it back on a deadline.
That is the whole product, so the bar for changes is less "does it work" and more "can it still not forget".

## Before you write code

```bash
make test          # both Swift suites, hermetic: no sudo, no real power state, fake clock
make test-release  # the acceptance suite again, against the release binary — see Tests, below
make test-raycast  # only if you are touching integrations/raycast — see Tests, below

# and while you are fixing one thing, one test rather than all of them:
LC_ALL=C swift test $(make -s print-test-flags) --filter <TestName>
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
| `Tests/SimmerAcceptanceTests` | `make test-release` | does the **release** binary honour it too |
| `integrations/raycast/tests` | `make test-raycast` | does the extension still read the contract the binary emits |

Any of those, filtered to one test or one suite, is `LC_ALL=C swift test $(make -s print-test-flags) --filter <TestName>` — the same build, the flags the `test` target passes, printed by a target that echoes `$(TEST_FLAGS)` and nothing else.
Never bare `swift test --filter`: a machine with only the Command Line Tools ships `Testing.framework` outside the default search paths, so bare `swift test` compiles nothing (`no such module 'Testing'`) and has been seen exiting **0** while failing to compile — a green gate over nothing.
Where an Xcode is the selected toolchain the target prints an empty line, the substitution expands to nothing, and the command is plain `swift test --filter <TestName>` — which is correct there: the flags exist only for the CLT.

The acceptance suite honours `SIMMER_BIN`, so it can be pointed at any implementation of `CONTRACTS.md` — that is what makes it the executable form of the contract rather than a description of this code.
`bridge.test.mts` is the same idea from the other side of the pipe.

`swift test` compiles and runs at -Onone, so `make test` alone answers its question about a build nobody installs.
`make test-release` asks it again of `.build/release/simmer`, which is what every user runs: `update --apply --json` once printed its whole object from the debug binary and zero bytes from the release one, and both Swift lanes were green.
Optimised builds are free to differ, so a surface guarantee is only guaranteed where this lane says so.

`make test` cannot see `integrations/raycast`, so a change to the extension with only `make test` green is a change nothing checked.
Touching both sides means both commands; CI runs all three either way.
And `AgentDocTests` replays the session in `AGENTS.md` against the built binary — editing that session is editing a test.

A behaviour change without a test that would have caught the old behaviour is not finished.
Where a rule can be a test instead of a sentence in a document, make it a test: several already are (the sudo rule's scope, the absence of self-escalation, that every documented verb resolves).

## Pull requests

- One concern per PR, and say which contract row it touches, if any.
- Note anything you did that is not the obvious approach, and why, at the point where you did it.
- CI runs the Swift suites on macOS 14 and 15, assembles the bundle, lints the templates and the installer, and runs the extension's lane twice — once as pure units on Linux, once against the built binary on macOS.
  A seventh leg, `release-check`, asks whether there is still somewhere for the next change's notes to land — and, on the release branch, whether the version number still matches what the rule says.
  All of it must be green.

## Releases

You do not need to touch the version, and you should not.
It moves once, in a release commit CI writes, and `docs/RELEASING.md` is that procedure.

What your pull request owes a release is its notes, under `## Unreleased` in `CHANGELOG.md`.
Where you put them decides the next version number: an entry under `### Machine surface` or `### The test seam` makes it a **minor**, anything else a **patch** — so a contract change filed under `### Added` is a minor that ships as a patch.
Nothing reads your prose for hints; the heading is what says so.
To decide the number outright, put one line under `## Unreleased` in the same pull request — `<!-- release: patch -->`, `minor` or `major` — and it is reviewed along with your notes; a maintainer can still overrule it with a matching label on the release pull request, which then says both the number and what the rule had read.

**Say when your change first shows, because it is not always the version that ships it.** A change to what the app or the CLI does — a menu-bar row, a new flag, a different exit code — first shows in **the version that carries it**: the reader installs that version, and from then on it is your code running.
A change to the installer's own feedback — the plan `update --apply` prints, the banners at either end of an "Install it now" click, the line it writes to `simmer.log` — first shows on the update **after** the release that ships it, because **the version being replaced** is the one running the plan and composing those banners; your new wording ships inert and gets its first run one update later.
0.3.3's entry is the worked example, and says both halves in one sentence: "0.3.3 is the first version that answers Check for Updates…; the update *after* 0.3.3 is the first whose completion banner carries a body".
Put that in the note rather than leaving it to be discovered: "the completion banner now carries a body", filed plainly under the release that adds the body, is a promise that release cannot keep, and the reader who clicks Install, sees the old wordless banner and files a bug is reading the notes correctly.

Every push to `main` then keeps one pull request open titled `release: X.Y.Z`, carrying the version bump and the notes GitHub would publish.
Merging it is the release.

## What is deliberately not wanted

`docs/ROADMAP.md` closes with a list — a SwiftBar plugin, a daemon, a config file, named presets, force semantics, any paid Apple signature.
Each was weighed and declined; the reasoning is there.
An issue arguing one of them through is welcome, a PR implementing one unannounced is not.
