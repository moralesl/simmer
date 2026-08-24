# simmer, for agents

You are an agent doing long-running work on a Mac with simmer installed.
The machine sleeps when the lid closes — unless awake time is claimed.
This page is the protocol; the machine-readable surface it rests on is `CONTRACTS.md`.

## The one paragraph that matters

Awake time is **counted, not owned**.
Take your own claim under your own name; the Mac stays awake until the latest live claim ends.
You can never take time away from anyone else — and the same protection is owed back: **never claim human authority.**

## A whole session, start to finish

Every response below is real output, not an illustration.

```bash
# 1. Is there room to start? Nothing is claimed, so there is no guarantee at all.
$ simmer budget --need 30m --json
{"fits":false,"seconds_left":null,"state":"idle","need_seconds":1800,"claim_count":0,...}
# exit 3 — the lid can interrupt you at ANY moment. Claim before starting.

# 2. Claim, under your own name.
$ simmer 45m -r "eval batch" --owner agent:evals --json
{"action":"claimed","claim":{"id":"agent:evals","until":1787561100,"left":2700,...},
 "clipped_by_cap":false,"state":"active","until":1787561100,"left":2700,"claim_count":1}
# exit 0

# 3. Now the same question has an answer.
$ simmer budget --need 30m --json
{"fits":true,"seconds_left":2700,"state":"active","need_seconds":1800,"claim_count":1,...}
# exit 0 — proceed.

# 4. Taking longer than you thought? ADD to your deadline.
$ simmer +30m --owner agent:evals --json
{"action":"extended","claim":{"until":1787562900,"left":4500,...},"state":"active",...}
# exit 0

# 5. Done. Hand it back.
$ simmer down --owner agent:evals --json
{"action":"released","released":["agent:evals"],"state":"idle","until":0,"claim_count":0,...}
# exit 0
```

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

## While you work, ask again

**Checking once at the start is not enough, and this is the mistake worth spelling out.** A claim can end before your work does, without you doing anything wrong: the battery reaches its floor, the charger is unplugged on a `--require-ac` claim, the chip reports thermal pressure, or a human moves the cap.
Your process keeps running; your guarantee is gone.

What that looks like — the same call as before, after the floor retired the claim mid-run:

```bash
$ simmer budget --need 10m --json
{"fits":false,"seconds_left":null,"state":"idle","need_seconds":600,"claim_count":0,...}
# exit 3 — back to no guarantee, and nothing told you
```

So for work measured in hours: **re-run `simmer budget` between units of work**, at whatever granularity a lost hour would hurt — after each batch, each file, each test run.
Exit 3 mid-job means claim again before continuing.
Exit 1 means finish the current unit and write the handoff rather than starting another.

`simmer run -- <cmd>` sidesteps all of this for anything you can express as one command: the claim lives exactly as long as the process, renews itself while it runs, and is released on any exit — even SIGKILL, where it self-expires within one chunk.

## Claim, extend, release

```bash
simmer 45m -r "eval batch" --owner agent:evals --json    # claim
simmer +15m --owner agent:evals --json                   # add 15m to YOURS
simmer down --owner agent:evals                          # release YOURS when done
simmer run --max 2h -- npm test                          # or: exactly while a command runs
```

- **`+15m` adds to your deadline; `15m` sets it.** Use `+` for "this is taking longer than I thought" and a bare duration for "this is how long I now need in total" — the first can never cost you time you already hold.
- Every mutating command takes `--json` and answers with what changed plus the resulting aggregate — one call, no second round-trip.
  So do `log` and `doctor`; `notify-test`, `render` and `run` refuse the flag rather than ignore it.
- `simmer run` is the claim that cannot be forgotten: released on any exit, self-expiring within one chunk even after SIGKILL, and it never kills your command — `--max` bounds the awake time, not the work.
- Release what you claimed when you finish.
  The guard would catch it at the deadline anyway, but leaving claims behind is leaving your name on time nobody is using.

## When a call is refused

Exit 1 with `{"action":"refused","error":"…"}`.
Read the `error`; these are the ones you will actually meet.

| What you get | What it means | What you do |
|---|---|---|
| `battery 15% <= floor 20%. Plug in, or lower --min-battery.` | on battery, below the floor | do not start. Report it — you cannot plug the machine in |
| `already at the cap (11:00). Only a human can move it.` | your deadline is the human ceiling | work within it, or ask the person. Never retry with a bigger number |
| `only a person can set the cap` / `lift the cap` | you tried to move the ceiling | you may read the cap, never move it |
| `the cap is 09:00, which has passed…` | a stale human decision is blocking every new claim | report it and stop; only `simmer cap off` clears it, and that is the human's |
| `--require-ac, and this Mac is on battery.` | the claim's premise is already false | drop `--require-ac`, or report that mains power is needed |
| `'down --all' ends claims that are not yours` | correctly refused | release your own with `simmer down` |

`clipped_by_cap: true` on a **successful** claim is not a refusal: you got a shorter deadline than you asked for, and `until` says how short.
Read it — do not assume you got what you requested.

```bash
$ simmer 8h --owner agent:evals --json
{"action":"claimed","claim":{"left":3600,...},"clipped_by_cap":true,"capped":true,...}
# exit 0, and you have one hour, not eight
```

## When simmer is not installed

Most Macs do not have it.
Absence is not an error to crash on and not a guarantee to assume:

```bash
if command -v simmer >/dev/null 2>&1; then
  simmer budget --need 30m --json    # act on the exit code
else
  : # no simmer here — proceed, but you have NO protection from the lid.
    # Say so in your handoff rather than pretending the machine will stay awake.
fi
```

Never install it, and never set `pmset -a disablesleep` yourself.
That switch has no expiry, nothing on screen indicates it, and it survives reboots — leaving it on is the exact failure simmer exists to prevent.

## What you may not do

- `simmer down --all` — refused for you, correctly.
  Ending work someone else started is not your call; ask the human.
- Moving the **cap** (`simmer cap …`) — it is the ceiling a person set.
  When your claim gets clipped or refused by it, `budget` tells you the truth: report it, do not retry with bigger numbers and do not route around it.
- Suppressing notifications — they are the human's window into what you hold.

## Parse only the machine surfaces

`--json`, `status --machine`, and the exit codes are contract; every human sentence may be reworded at any time.
`status --json` gives the aggregate at the top level and every claim in `.claims[]`.

One shape to be careful with: `budget`'s `seconds_left` is a number when there is a deadline, `-1` when there is none, and `null` when nothing is claimed at all.
Switch on the exit code and the type never comes up.

## In your own test sandboxes

Isolate with `XDG_STATE_HOME=<tmp>` and `SIMMER_NOTIFY=none`, and fake the hardware through the seam (`SIMMER_FAKE_PMSET`, `SIMMER_FAKE_BATTERY`, `SIMMER_FAKE_NOW`, …) — never exercise the real switch to test your own code.
