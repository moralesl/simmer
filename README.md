<div align="center">

<img src="assets/icon-256.png" width="120" alt="simmer">

# simmer

**Keep your Mac awake for a bounded time — lid closed — then let it sleep again.**

[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?logo=apple)](#) [![status](https://img.shields.io/badge/v2-being%20built-orange)](docs/V2-BRIEF.md)

</div>

## What this repository is right now

**v2 is being built as a fresh Swift application.** There is no installable release in the working tree at the moment.
The tree is set up so that work can start from what was learned rather than from what was shipped:

```
docs/CONTRACTS.md    the law, in prose. What stays true across implementations,
                     and the decisions behind it. v2 brings its own tests; this
                     is what they have to prove.
docs/LEARNINGS.md    every trap already paid for, every decision already taken,
                     and the ones still open. Read this first.
docs/V2-BRIEF.md     the decided shape, and the verified platform facts — most of
                     them bought with failed attempts. Do not re-derive them.
docs/FOR-AGENTS.md   the protocol an agent follows when using simmer.

archive/v1-bash/     the previous implementation, complete and runnable, with its
                     own suite. A spike, kept for reference: read it, then write
                     the Swift version from the contract. Nothing in v2 imports,
                     copies or sources anything from it.
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

## Running the old one in the meantime

`archive/v1-bash/` is a complete, tested implementation of the contract above.
It is frozen, but it works:

```bash
cd archive/v1-bash && make install
```

See [archive/v1-bash/README.md](archive/v1-bash/README.md) for what that installs and how to remove it again.

## Development

There is nothing at the top level to build yet — that is the point of this
commit. v2 starts from `docs/`, not from a diff.

The archived implementation still stands entirely on its own:

```bash
make -C archive/v1-bash test    # 175 assertions, hermetic
make -C archive/v1-bash diff    # against the v1.0.0 tag
make -C archive/v1-bash install # if you want a working simmer meanwhile
```

Wondering about Amphetamine, LidRun or plain `caffeinate`?
[docs/COMPARISON.md](docs/COMPARISON.md) is an honest comparison — including when NOT to use simmer.

## License

MIT — see [LICENSE](LICENSE).
