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
   🤖 agent · eval batch · until 00:30
   👤 terminal · overnight build · until 01:15
   battery 92% · floor 20%

$ simmer cap 02:00
⛔ nothing past 02:00 (2 h 45 min from now)

$ simmer down
⏾ released
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
**Five things end awake time, and only one of them is you remembering:** the deadline, the battery floor, thermal pressure (a hot machine with the lid closed is the one state you cannot notice), `simmer down`, and the guard finding the switch on with nothing claiming it.

```
simmer 2h ──┬─► sudo pmset -a disablesleep 1        (the lid stays awake)
            ├─► caffeinate -ims -t 7200             (second, independent clock)
            └─► claims/<you>: until, reason, battery floor
                         │
             the guard — every 30s, and at login
                         │
      ┌──────────────┬───┴────────────┬──────────────────┐
   deadline      battery below     simmer down      switch found on
    passed        ITS floor                        with nothing claiming it
      └──────────────┴────────────────┴──────────────────┘
                         ▼
        the last claim out: pmset disablesleep 0 · notify · log
```

That last branch is the important one: if the guard ever finds `disablesleep` enabled with nothing claiming it — because you typed `pmset` by hand, or a release was interrupted — it turns it back off.
**Forgetting becomes structurally impossible rather than merely unlikely.**

## Everybody gets their own claim

Awake time is **counted, not owned**.
You, an agent and a build can each hold a claim; the Mac stays awake until the last one ends, and nobody can take anybody else's away.

That is not a feature so much as the removal of one.
A single slot forces refusals, a `--force` flag and a rule about who may overwrite whom — and it is the wrong shape for a machine where a person, an agent and a test run all want the lid shut at once.
With claims counted, the entire conflict UX disappears: `--force` still parses and does nothing, because there is nothing left to force.

```
$ simmer status
☕ simmering until 17:00 · 2 h 0 min left · refactor
   🤖 agent:evals · eval batch · until 15:45
   ⚙ run:4821 · npm test · until 15:20
   👤 terminal · refactor · until 17:00
   on AC, battery 80% · floor 20%
   ⛔ nothing past 23:00 · set by terminal
```

**You have the final say, mechanically.** A person can end any claim (`simmer down --all`); an agent can only end its own.
And the **cap** is yours alone:

```bash
simmer cap 23:00     # nothing past 23:00, whoever asks and however long for
simmer cap           # what is it?
simmer cap off       # lift it
```

Claims request from below; the cap rules from above, clipping every claim present and future.
An agent that runs into it gets a truthful budget answer — `capped: true`, and prose saying asking for longer will not help — rather than an error to route around.

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
| `simmer 60m -r "reason"` | claim 60 minutes |
| `simmer run -- npm test` | claim scoped to the command: renewed while it runs, released on any exit; `--max 2h` caps it |
| `simmer 2h --min-battery 30` | custom battery floor (default 20%) |
| `simmer 2h --require-ac` | ends the moment the charger is unplugged |
| `simmer 2h --display-on` | keep the screen lit too — by default the screen may sleep while the Mac stays awake |
| `simmer --until 23:00` | absolute time instead of a duration |
| `simmer forever` | no deadline; reminds every 30 min, still stops on low battery |
| `simmer` | status, listing every live claim |
| `simmer +20m` | extend **your** claim, counted from now |
| `simmer down` | hand **your** claim back |
| `simmer down --all` | hand everything back (only a person may) |
| `simmer cap 23:00` · `cap off` | the ceiling nothing gets past |
| `simmer log` | what the guard has been doing |
| `simmer doctor` | health of the running system, plus a live notification test |

Durations are forgiving: `90`, `90m`, `1h`, `1h30m`, `45min`, `2h15`, `30s`.

## Menu bar — SwiftBar

The menu bar is the one indicator nothing can suppress.
It shows `☕ 42m`, turns orange under five minutes, shows `☕ ∞` for open-ended time, and goes red if it ever finds the switch on with nothing claiming it.
The countdown is the **aggregate** — when the Mac will actually sleep — and the dropdown lists each claim, extends, releases yours or all of them, and sets the cap, without a terminal.

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
| `3` | nothing claimed at all — sleep is allowed and the lid can interrupt |

`3` is deliberately not `1`: a small budget and an *absent guarantee* are different things, and code that conflates them keeps working while the machine sleeps underneath it.

Pass `--owner <name>`. It is not decoration: the owner **is** the claim's identity, so it is what lets a later step extend or release the claim an earlier one took, and it is the name shown next to your reason in the human's menu bar.
Several agents at once should namespace themselves (`--owner agent:funnel`).
An automated job cannot stamp over the twenty minutes a human set on purpose — not because simmer refuses, but because the two claims never touch.

`simmer status --machine` prints the aggregate as `key=value` lines for anything that wants to render it; `--json` adds a `claims` array with one entry per claim.

**Agents:** [docs/FOR-AGENTS.md](docs/FOR-AGENTS.md) is the short protocol — claim time, check the budget before each expensive step, wind down when the clock runs low, hand it back.
Written to be read by a model, not skimmed by one.

Wondering about Amphetamine, LidRun or plain `caffeinate`?
[docs/COMPARISON.md](docs/COMPARISON.md) is an honest comparison — including when NOT to use simmer.

## Development

```bash
make test    # the hermetic suite: no sudo, no real power state touched
make diff    # does this still answer what v1.0.0 answered?
```

The suite substitutes every power operation *and the clock* — `SIMMER_FAKE_PMSET`, `SIMMER_FAKE_BATTERY`, `SIMMER_FAKE_THERMAL`, `SIMMER_FAKE_NOW` — so it exercises the battery branch while the laptop is charging, crosses deadlines without waiting for them, and never changes your machine.

`make diff` is the second half: it drives two binaries through identical scenarios and diffs the answers, which is the only way to catch a message, an exit code or a field name drifting during a rewrite — the class of change where every individual test still passes.
Contract lines must match exactly; prose may be reworded.
See [CONTRACTS.md](CONTRACTS.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

`bin/simmer` targets `/bin/bash`, which is 3.2 on macOS — no `${var,,}`, no associative arrays.
A LaunchAgent should not depend on a Homebrew shell.

## Uninstall

```bash
make uninstall
sudo rm /etc/sudoers.d/simmer   # printed, not done for you
```

## License

MIT — see [LICENSE](LICENSE).
