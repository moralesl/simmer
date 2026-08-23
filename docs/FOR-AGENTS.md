# simmer, for agents

You are an agent doing long-running work on a Mac with simmer installed.
The machine sleeps when the lid closes — unless awake time is claimed.
This page is the protocol; the machine-readable surface it rests on is `CONTRACTS.md`.

## The one paragraph that matters

Awake time is **counted, not owned**.
Take your own claim under your own name; the Mac stays awake until the latest live claim ends.
You can never take time away from anyone else — and the same protection is owed back: **never claim human authority.**

## Name yourself

```bash
--owner agent:<work>        # e.g. agent:funnel-refactor
```

- One live claim per owner: a second claim under the same name *replaces* yours (that is a feature — `simmer 2h` twice moves your deadline, it does not stack).
- Concurrent agents each pick their own name, or they will fight over one claim.
- **Never** use the human owner names (`terminal`, `menubar`, `raycast`, `alfred`) and **never** set `SIMMER_HUMAN=1`.
  Nothing stops you technically — that is exactly why it is an obligation.
  Human primacy protects the person's time from your accidents; claiming their authority removes the protection.

## Before starting long work

```bash
simmer budget --need 30m     # is there room for 30 more minutes?
```

| exit | meaning | what you do |
|---|---|---|
| 0 | fits, or no deadline at all | proceed |
| 1 | not enough time left | wind down: write the handoff, do not start the batch |
| 3 | **nothing is claimed at all** | the lid can interrupt you at ANY moment — claim first |

3 is not a big 1: it is an absent guarantee, not a small budget.
Conflating them means working while the machine sleeps under you.

## Claim, extend, release

```bash
simmer 45m -r "eval batch" --owner agent:evals --json    # claim
simmer +15m --owner agent:evals --json                   # extend YOURS, from now
simmer down --owner agent:evals                          # release YOURS when done
simmer run --max 2h -- npm test                          # or: exactly while a command runs
```

- Every mutating command takes `--json` and answers with what changed plus the resulting aggregate — one call, no second round-trip.
- `simmer run` is the claim that cannot be forgotten: released on any exit, self-expiring within one chunk even after SIGKILL, and it never kills your command — `--max` bounds the awake time, not the work.
- Release what you claimed when you finish.
  The guard would catch it at the deadline anyway, but leaving claims behind is leaving your name on time nobody is using.

## What you may not do

- `simmer down --all` — refused for you, correctly.
  Ending work someone else started is not your call; ask the human.
- Moving the **cap** (`simmer cap …`) — it is the ceiling a person set.
  When your claim gets clipped or refused by it, `budget` tells you the truth: report it, do not retry with bigger numbers and do not route around it.
- Suppressing notifications — they are the human's window into what you hold.

## Parse only the machine surfaces

`--json`, `status --machine`, and the exit codes are contract; every human sentence may be reworded at any time.
`status --json` gives the aggregate at the top level and every claim in `.claims[]`.

## In your own test sandboxes

Isolate with `XDG_STATE_HOME=<tmp>` and `SIMMER_NOTIFY=none`, and fake the hardware through the seam (`SIMMER_FAKE_PMSET`, `SIMMER_FAKE_BATTERY`, `SIMMER_FAKE_NOW`, …) — never exercise the real switch to test your own code.
