<div align="center">

<img src="assets/icon-256.png" width="120" alt="simmer">

# simmer

**Keep your Mac awake for a bounded time — lid closed — then let it sleep again.**

[![test](https://github.com/moralesl/simmer/actions/workflows/test.yml/badge.svg)](https://github.com/moralesl/simmer/actions/workflows/test.yml) [![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![platform](https://img.shields.io/badge/platform-macOS%2011%2B-lightgrey?logo=apple)](#install) [![dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)](#install)

</div>

```
$ simmer 2h -r "overnight build"
☕ simmering until 01:15 (2 h 0 min) · overnight build
   lid may close · battery 92% · releases below 20%

$ simmer
☕ simmering until 01:15 · 1 h 58 min left · overnight build

$ simmer down
⏾ Sleep allowed again
```

## Why this exists

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

## How it works

simmer never exposes the switch.
It *borrows* it, with a deadline, and a background watchdog hands it back.
**Five things end a lease, and only one of them is you remembering:** the deadline, the battery floor, thermal pressure (a hot machine with the lid closed is the one state you cannot notice), `simmer down`, and the guard finding the switch on with no lease behind it.

```
simmer 2h ──┬─► sudo pmset -a disablesleep 1        (the lid stays awake)
            ├─► caffeinate -dims -t 7200            (second, independent clock)
            └─► lease file: until, reason, owner, battery floor
                         │
             the guard — every 30s, and at login
                         │
      ┌──────────────┬───┴────────────┬──────────────────┐
   deadline      battery below     simmer down      switch found on
    passed          floor                           with no lease
      └──────────────┴────────────────┴──────────────────┘
                         ▼
            release: pmset disablesleep 0 · notify · log
```

That last branch is the important one: if the guard ever finds `disablesleep` enabled with no lease behind it — because you typed `pmset` by hand, or a release was interrupted — it turns it back off.
**Forgetting becomes structurally impossible rather than merely unlikely.**

## Install

```bash
git clone https://github.com/moralesl/simmer
cd simmer
make install
```

Clone it anywhere — the installer resolves its own location, so nothing is tied to a particular path.

That links `simmer` into `~/.local/bin` and starts the guard as a LaunchAgent.

### Notifications

simmer's banners carry **simmer's own name and icon**.
At install, `make install` compiles a ~60-line Swift notifier from `notifier/main.swift`, wraps it in an app bundle with the pot icon, signs it ad-hoc and registers it — no certificate, no Apple account. macOS shows a one-time permission banner (with the pot icon); click **Allow** once and that is the entire setup.

This works where every CLI notification tool fails because macOS attributes a banner to the *bundle* that posts it and silently drops unknown identities — a bare binary is such an identity, an installed registered bundle is not.
The recipe and its traps are in [docs/V2-BRIEF.md](docs/V2-BRIEF.md); the transport is switchable and testable:

```bash
simmer notify-test                 # one labelled banner per transport
export SIMMER_NOTIFY=bundle        # or shortcut · swiftbar · osascript · say · none
```

No Swift compiler on the machine?
The installer says so and banners fall back to `osascript` (posting as *Script Editor*).
Fix later with `xcode-select --install` and another `make install`.
The menu bar works regardless and can never be suppressed.

## Usage

| Command | Effect |
|---|---|
| `simmer 60m -r "reason"` | lease for 60 minutes |
| `simmer 2h --min-battery 30` | custom battery floor (default 20%) |
| `simmer 2h --display-on` | keep the screen lit too — by default the screen may sleep while the Mac stays awake |
| `simmer --until 23:00` | absolute time instead of a duration |
| `simmer forever` | no deadline; reminds every 30 min, still stops on low battery |
| `simmer` | status |
| `simmer +20m` | extend, counted from now |
| `simmer down` | hand it back immediately |
| `simmer log` | what the guard has been doing |
| `simmer doctor` | health of the running system, plus a live notification test |

Durations are forgiving: `90`, `90m`, `1h`, `1h30m`, `45min`, `2h15`, `30s`.

## Menu bar — SwiftBar

The menu bar is the one indicator nothing can suppress.
It shows `☕ 42m`, turns orange under five minutes, shows `☕ ∞` for an open-ended lease, and goes red if it ever finds the switch on with no lease.
The dropdown extends or releases without a terminal.

```bash
brew install --cask swiftbar
ln -sf ~/workspace/tools/simmer/integrations/swiftbar/simmer.10s.sh \
       "$(defaults read com.ameba.SwiftBar PluginDirectory)/"
```

## Launcher — Raycast

Free tier is enough.
Point Raycast at the folder once:

> Settings → Extensions → Script Commands → Add Directories →
> `~/workspace/tools/simmer/integrations/raycast`

Then `⌥␣ simmer` shows the live state **inline in the root search**, without selecting anything, plus commands to start, extend and release.
Typing `simmer 90m` or `simmer 23:00` starts exactly that.

Alfred users: `make workflow` builds `integrations/alfred/Simmer.alfredworkflow` — double-click to import.
It needs the paid Powerpack, which is why Raycast is the documented path.

## For scripts and agents

`simmer budget` answers the question a long-running job actually has — *is there room to start this?* — in the exit code:

```bash
simmer budget --need 20m || echo "not enough time left, wind down"
```

| Exit | Meaning |
|---|---|
| `0` | there is room, or there is no deadline |
| `1` | not enough time left |
| `3` | no lease at all — sleep is allowed and the lid can interrupt |

`3` is deliberately not `1`: a small budget and an *absent guarantee* are different things, and code that conflates them keeps working while the machine sleeps underneath it.

Pass `--owner <name>` when taking a lease. simmer refuses to replace a lease held by a different owner unless you add `--force`, so an automated job cannot silently stamp over the twenty minutes a human set on purpose.

`simmer status --machine` prints the full state as `key=value` lines for anything that wants to render it.

**Agents:** [docs/FOR-AGENTS.md](docs/FOR-AGENTS.md) is the short protocol — take a lease, check the budget before each expensive step, wind down when the clock runs low, hand it back.
Written to be read by a model, not skimmed by one.

Wondering about Amphetamine, LidRun or plain `caffeinate`?
[docs/COMPARISON.md](docs/COMPARISON.md) is an honest comparison — including when NOT to use simmer.

## Development

```bash
make test    # 43 assertions, no sudo, no real power state touched
```

The suite substitutes the four power operations via `SIMMER_FAKE_PMSET` and `SIMMER_FAKE_BATTERY`, so it can exercise the battery branch while the laptop is charging and never changes your machine.
See [ARCHITECTURE.md](ARCHITECTURE.md).

`bin/simmer` targets `/bin/bash`, which is 3.2 on macOS — no `${var,,}`, no associative arrays.
A LaunchAgent should not depend on a Homebrew shell.

## Uninstall

```bash
make uninstall
sudo rm /etc/sudoers.d/simmer   # printed, not done for you
```

## License

MIT — see [LICENSE](LICENSE).
