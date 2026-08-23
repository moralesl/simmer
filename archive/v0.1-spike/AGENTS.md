# Working on simmer

For *using* simmer as an agent, read [docs/FOR-AGENTS.md](docs/FOR-AGENTS.md).
This page is about changing it.

## Shape

One bash script (`bin/simmer`), one LaunchAgent template, a directory of small state files, and front-ends that all shell out to the script.
Nothing else.
The thing being guarded can flatten a battery, so the code guarding it should fit in your head.
[ARCHITECTURE.md](ARCHITECTURE.md) has the diagram and the reasoning; [CONTRACTS.md](CONTRACTS.md) is the law.

A Swift rewrite is in progress — see [../../docs/BRIEF.md](../../docs/BRIEF.md).
The bash implementation is the reference until the suite passes against the Swift one.

## Constraints that are not negotiable

- **`/bin/bash`, which is 3.2 on macOS.** No `${var,,}`, no associative arrays, no `mapfile`.
  A LaunchAgent must not depend on a Homebrew shell.
  CI asserts this by running under `/bin/bash` explicitly.
  A trap worth knowing: **a `case` inside `$( )` breaks** — 3.2 reads the pattern's closing paren as the end of the substitution. Name the helper instead.
  Another: **BSD `sed` has no `\b`.** It matches nothing and reports no error, which is how a differential run once flagged the clock ticking as a finding. Use `[[:<:]]` / `[[:>:]]`.
- **The guard uses `sudo -n` and nothing else.** A watchdog that can prompt for a password is a watchdog that hangs while the machine stays awake.
- **`simmer status --machine`, `--json` and `budget`'s exit codes are public contracts.** The menu bar, the launchers and other people's scripts read them.
  Fields are append-only. `format=2` in a claim file exists so a shape change is detectable; bump it if you change it.
- **Every mutation ends in `settle`.** It is the only function that touches the switch, which is what makes "nothing leaves `disablesleep` on without something scheduled to turn it off" a property you can check by reading one function rather than a promise you have to audit at every call site.
- **Every power read and every reading of `now` goes through its seam function.** A branch that reads the real clock or the real battery becomes untestable, which in practice means untested.

## Before you commit

```bash
make test     # the hermetic suite: no sudo, no real power state touched
make diff     # differential against v1 as committed
make check    # is this checkout what is actually installed
bash -n bin/simmer
```

`make test` proves this implementation is internally right.
`make diff` proves it still agrees with the previous one — the only instrument that catches a message, an exit code, a field name or a state value drifting, because that is the class of change where every individual test still passes.
It ends in `0 unexpected` or it is not ready.

A difference that is *supposed* to exist gets declared in `differential.sh` as a `differ` scenario, with a one-line reason.
A `differ` scenario that stops differing is as much a finding as a new failure: it means a delta was quietly reverted.

Test the failure case, not the happy path.
Most bugs found here were found that way: `shift` under `set -e`, `${var,,}` on bash 3.2, `pipefail` turning a correct refusal into a failed assertion, a `case` inside `$( )`, an applet that cannot own its own notification identity.

## Two things that look wrong and are not

- The menu bar uses SF Symbols rather than the app artwork — monochrome and light/dark-aware is correct up there.
- `--force` is still in the CLI surface and does nothing.
  Launcher shims and other people's scripts pass it; erroring on a flag that has become harmless would break callers for no gain, and ignoring it silently would hide the model change from whoever typed it.
  So it prints one line saying it is inert.

## Where the reasoning lives

Anything surprising in `bin/simmer` has the reason next to it, not in a commit message — the next reader is an agent with no git history in context.
Design decisions that span files, and the deltas from v1, are in [CONTRACTS.md](CONTRACTS.md) under D1.
