<div align="center">

<img src="assets/icon-256.png" width="120" alt="simmer">

# simmer

**Keep your Mac awake for a bounded time — lid closed — then let it sleep again.**

[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?logo=apple)](#) [![status](https://img.shields.io/badge/v1-swift-brightgreen)](docs/BRIEF.md)

</div>

## Install

One paste, one native password dialog, one click on Allow:

```bash
curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
```

That checks the Command Line Tools are genuinely present, clones, compiles locally (which is why there is no Gatekeeper warning and no Apple account — see the FAQ), installs `Simmer.app` with its menu bar and background guard, shows the exact two-line sudo rule before asking for your password once, and launches the app so the notification permission banner arrives carrying simmer's own icon.

```bash
simmer 2h -r "big build"    # stay awake two hours, lid may close
simmer                      # how much longer, and who else is asking
simmer down                 # hand your claim back
simmer --help               # the rest, including the exit-code API
```

## What this repository is

**v1: one Swift package, three products** — `SimmerCore` (the logic, no AppKit, no printing), `simmer` (the CLI), and `Simmer.app` (menu bar + event-driven guard + notification identity, one bundle).
The guard runs both ways over one idempotent `tick()`: IOKit events in the app for instant response, and a LaunchAgent every 30 seconds as the backstop nobody can quit.

```
Sources/SimmerCore/  claims · ledger · cap · aggregate · settle · tick ·
                     budget · render · the power seam · the clock seam
Sources/SimmerCLI/   argv in, exit code out. Thin on purpose.
Sources/SimmerApp/   NSStatusItem · IOKit callbacks · UNUserNotificationCenter
Tests/               unit suite + an acceptance suite that drives the BUILT
                     binary under the seam variables (honours SIMMER_BIN)

docs/CONTRACTS.md    the law, in prose: surface, exit codes, machine output,
                     and the reasoning behind every choice.
docs/LEARNINGS.md    every trap already paid for. Read this first.
docs/BRIEF.md        what v1 is; docs/PLATFORM-FACTS.md — what macOS permits.
docs/DESIGN-NOTES.md interaction design, marked take/consider/leave.

archive/v0.1-spike/  the bash spike that proved the model. Reference only;
                     v1 imports nothing from it.
```

## Why it exists

`caffeinate` does not survive the lid.
On Apple silicon the machine sleeps the moment you close it, no matter which assertions are held.
The only thing that keeps it running is:

```bash
sudo pmset -a disablesleep 1
```

And that is a switch with no way back.
It has no expiry, nothing on screen indicates it, and **it survives reboots**.
Set it before a flight, forget it, and you find a flat battery in your bag.
That is not a hypothetical — it is why this tool exists.

simmer never exposes that switch.
It *borrows* it, with a deadline, and a background watchdog hands it back.

## The model

Awake time is **counted, not owned**.
You, an agent and a build can each hold a *claim*; the Mac stays awake until the last one ends, and nobody can take anybody else's away.

```
claims/terminal    👤  refactor         until 17:00  ─┐
claims/agent:eval  🤖  eval batch       until 15:45   ├─ the machine
claims/run:4821    ⚙   npm test         until 15:20  ─┘   sleeps at 17:00
cap                ⛔  nothing past     23:00        ──── unless you say sooner
```

A claim's id **is** its owner, which is the whole ownership model: "extend mine", "release mine" and "replace mine" need no registry and cannot be ambiguous, because one actor physically cannot address another's file.
There is no `--force` — the conflict it existed to resolve cannot occur.

And you have the final say, mechanically: a person can end any claim, an agent only its own, and the **cap** is a human instrument alone.
Claims request from below; the cap rules from above.

The full contract, including the reasoning behind each of those choices, is [docs/CONTRACTS.md](docs/CONTRACTS.md).

## Development

```bash
make test        # both suites: unit + acceptance over the built binary.
                 # Hermetic — no sudo, no real power state, the clock is fake.
make app         # assemble and ad-hoc sign Simmer.app (CLT only, no Xcode)
make install     # ~/Applications/Simmer.app + ~/.local/bin/simmer + the guard
make uninstall   # removes exactly what install wrote
```

The acceptance suite honours `SIMMER_BIN`, so it can gate any implementation of [docs/CONTRACTS.md](docs/CONTRACTS.md) — that is what makes it the executable form of the contract.
During development the app builds under the bundle id `io.github.moralesl.simmer.dev`; the clean production id is spent only at release, because macOS caches a notification permission verdict per bundle id forever ([docs/LEARNINGS.md](docs/LEARNINGS.md) § 1).

Wondering about Amphetamine, LidRun or plain `caffeinate`?
[archive/v0.1-spike/COMPARISON.md](archive/v0.1-spike/COMPARISON.md) is an honest comparison — including when NOT to use simmer.
It is in the archive because it will be rewritten against v1, not because it stopped being true.

## License

MIT — see [LICENSE](LICENSE).
