<div align="center">

<img src="assets/icon-256.png" width="120" alt="simmer">

# simmer

**Keep your Mac awake for a bounded time — lid closed — then let it sleep again.**

[![test](https://github.com/moralesl/simmer/actions/workflows/test.yml/badge.svg)](https://github.com/moralesl/simmer/actions/workflows/test.yml) [![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey?logo=apple)](#) [![swift](https://img.shields.io/badge/swift-6-orange?logo=swift)](#) [![status](https://img.shields.io/badge/v1-swift-brightgreen)](docs/CONTRACTS.md)

</div>

## Install

One paste, one password, one click on Allow:

```bash
curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
```

That checks macOS 14+ and the Command Line Tools (Swift 6, so Xcode/CLT 16 or newer — it says so in one sentence rather than in compiler output), clones, compiles locally (which is why there is no Gatekeeper warning and no Apple account — see the FAQ), installs `Simmer.app` with its menu bar and background guard, shows the exact two-line sudo rule in full before `sudo` asks for your password once, and launches the app so the notification permission banner arrives carrying simmer's own icon. simmer never gives itself root: it shows you the rule and you approve it — see [SECURITY.md](SECURITY.md).

```bash
simmer 2h -r "big build"    # stay awake two hours, lid may close
simmer                      # how much longer, and who else is asking
simmer down                 # hand your claim back
simmer --help               # the rest, including the exit-code API
```

## What it looks like

Ambient truth at zero clicks — the countdown, and the `·2` says two actors hold claims right now:

<img src="assets/readme-menubar.png" width="580" alt="the simmer menu bar item: a pot, 14m·2">

Banners arrive as **Simmer**, with the pot icon — the app bundle is the notification identity, no Apple developer account involved.

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

AGENTS.md            working ON this repo: read order, commands, iron rules.
docs/FOR-AGENTS.md   USING simmer from an agent: budget, owners, obligations.
docs/CONTRACTS.md    the law, in prose: surface, exit codes, machine output,
                     and the reasoning behind every choice.
docs/PLATFORM-FACTS.md  what macOS actually does, verified — and the traps a
                     test cannot carry. Read this first.
docs/ROADMAP.md      decided but not built. docs/FAQ.md — short answers.
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

## How it compares

The honest version, including where something else is the better answer.

| | Holds a closed lid | Bounded by default | Several actors at once | Callable by an agent | Cost |
|---|---|---|---|---|---|
| **simmer** | yes — borrows `pmset -a disablesleep`, watchdog hands it back | yes; a deadline is required, and a human **cap** clips every claim | **yes** — counted claims, one per actor, nobody can end another's | exit codes + `--json` on every verb, and a written protocol ([FOR-AGENTS.md](docs/FOR-AGENTS.md)) | free, MIT |
| `caffeinate` (Apple) | no — power assertions cannot hold the lid on Apple silicon | yes (`-t`) | no | yes, but it cannot do the thing | free, built in |
| [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | no — an assertion wrapper, same ceiling as `caffeinate` | timer | no | no | free, MIT |
| [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) | yes, since 5.0 (a preference, off by default) | timers and triggers | no | no | free, App Store |
| [LidRun](https://lidrun.com/) | yes, in Pro; mechanism not documented | timer 30 min–8 h, charging-only, thermal, ~4–5% battery floor | no | no (it *detects* Claude Code and Cursor rather than being called by them) | free lid-**open**; $9 one-time for closed-lid |

**Pick something else when:** you want a polished GUI that notices your agent started on its own — LidRun is built for exactly that and costs less than lunch. You want a mature, free, App Store app and one person's laptop is the whole story — Amphetamine, and it has done lid-closed since 5.0. You only need the screen awake while you are sitting there — `caffeinate -d` is already installed.

**simmer is the answer when the machine is shared with things that are not you.** That is the one column nothing else has: a person, an agent and a build each hold their own claim, the Mac sleeps when the last one ends, and no actor can take another's time away — by construction, because a claim's id *is* its owner. The rest follows from it: `budget` exists so an agent can ask "is there room to start" before it starts, the cap exists so a person outranks every agent, and `--json` is on every verb because the caller is often not a human.

It also never asks for an account, a certificate, or a payment, and it compiles on your machine in about a minute — see the [FAQ](docs/FAQ.md) on why that is what makes it run with no Gatekeeper warning.

## The model

Awake time is **counted, not owned**.
You, an agent and a build can each hold a *claim*; the Mac stays awake until the last one ends, and nobody can take anybody else's away.

```
claims/terminal    ⌨️  refactor         until 17:00  ─┐
claims/agent:eval  🤖  eval batch       until 15:45   ├─ the machine
claims/run:4821    ⚙️  npm test         until 15:20  ─┘   sleeps at 17:00
cap                ⛔  nothing past     23:00        ──── unless you say sooner
```

The glyph is the door the claim came through — ⌨️ a prompt, 🖥️ the menu bar, 🚀 a launcher, ⚙️ a wrapped command, 🤖 an agent, 📜 something that never named itself.
With four claims live, "which of these is mine" is the question actually being asked.

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
`io.github.moralesl.simmer` is the production bundle id, promoted for v1.0.0.
Develop under a throwaway one — `make BUNDLE_ID=io.github.moralesl.simmer.dev3 app` — because macOS caches a notification permission verdict per bundle id forever and a denial can never be undone ([docs/PLATFORM-FACTS.md](docs/PLATFORM-FACTS.md) § 1).
Ids already spent are listed in the Makefile, next to the line that sets it.

Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).
Reporting something sensitive: [SECURITY.md](SECURITY.md).

## Uninstall

```bash
simmer uninstall   # what is installed, and the exact commands that remove it
```

It shows the commands rather than running them — the same way it shows the sudo rule at install time instead of escalating to apply it.
That also means you can read what is about to happen, and it cannot delete the bundle it is running from.
The commands come out resolved, so nothing depends on remembering that the one-paste installer put a checkout in `~/.local/share/simmer`.

The sudo rule is left out of them deliberately: removing it needs root, and simmer only ever removes what simmer wrote.
State (`~/.local/state/simmer/`) is yours to keep or delete.

## For agents

An agent doing long work on this Mac should hold its own claim — that is the point of the model.
The protocol is one page: [docs/FOR-AGENTS.md](docs/FOR-AGENTS.md).
The two-line version: `simmer budget --need 30m` before starting (exit 3 means the lid can interrupt you at any moment), and `simmer 45m -r "why" --owner agent:<work> --json` to claim.
Never `down --all`, never a human owner name.

The bash spike that preceded v1 lives at the git tag `v0.1` — reference only.

## License

MIT — see [LICENSE](LICENSE).
