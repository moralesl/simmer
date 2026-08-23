# Using simmer as an agent

You are working on a Mac that may fall asleep and interrupt you.
simmer is how you buy a known amount of awake time, and how you find out how much is left.

This page is about *using* simmer.
If you are changing simmer itself, read [AGENTS.md](../AGENTS.md) instead.

## The one thing to understand first

Awake time is **counted, not owned**.
You, the human, and every build running right now each hold your own *claim*.
The Mac stays awake until the last live claim ends, and **you cannot touch anybody else's**.

Three consequences, and they are the whole model:

1. **You never have to negotiate.** Taking a claim always works if the machine can honour it. There is no lease to overwrite, no owner to displace, and `--force` does nothing.
2. **You release only your own.** `simmer down` hands back *your* claim. The machine may well stay awake afterwards, because somebody else is still holding one. That is correct, not a failure.
3. **The human outranks you, mechanically.** They can end any claim including yours, and they can set a **cap** that clips yours from above. Both are legitimate; neither is an error to route around.

## First choice: scope the claim to the command

```bash
simmer run -- npm test                        # awake exactly as long as this runs
simmer run -r "eval batch" -- uv run eval.py  # name the work
simmer run --max 2h -- ./long-job.sh          # hard cap on total awake time
```

`simmer run` claims awake time, keeps it renewed while the command runs, and releases it the moment the command exits — success, failure or signal.
Nothing to remember, nothing to hand back: **this is the claim that cannot be forgotten.** Prefer it whenever your long work *is* a command.

Two details worth knowing:

- It renews in chunks (45 min, refreshed every 20 min) rather than taking one long claim.
  Even if the runner is SIGKILLed — the one exit no cleanup can catch — the claim expires within a chunk on its own.
- `--max` bounds the awake time, not the job.
  When the budget runs out the claim lapses and a notification says so, but the command is **not** killed — stopping your work is never simmer's call.
  Decide yourself whether to wind down.

Concurrent runs are fine: each gets its own claim, identified by its pid.

The protocol below is the flexible alternative, for work that is not a single command: many tool calls, an interactive session, work spread across steps.

## The flexible alternative: the protocol in four commands

```bash
simmer 2h -r "refactor the funnel" --owner agent   # 1. claim time, say what for
simmer budget --need 20m || wind_down              # 2. before each big step
simmer budget --seconds                            # 3. how long have I got?
simmer down --owner agent                          # 4. finished early? give it back
```

## 1. Claim time when you start long work

```bash
simmer 2h -r "refactor the funnel" --owner agent
```

- **`-r`** — say what the work is.
  It shows in the human's menu bar, so they can see what is holding their machine awake without asking you.
- **`--owner`** — identify yourself. This is not decoration: **the owner IS your claim's identity.** It is how `simmer down` and `simmer +30m` know which claim is yours, and it is the name the human sees next to your reason.
- Pick a length you can justify.
  Two hours because the job needs two hours, not because two hours is a round number.

### Use the same owner every time, and make it yours alone

Your steps run as separate processes, so the owner has to be stable across them — that is what lets a later step extend or release the claim an earlier one took.
Pass the same `--owner` (or export `SIMMER_OWNER`) throughout a session.

If several agents may run at once, **namespace yourself**: `--owner agent:funnel`, `--owner agent:evals`.
Two agents both calling themselves `agent` share one claim slot, and the second one's claim replaces the first's.

### Do not claim human authority

Never pass `--owner terminal`, `menubar`, `raycast` or `alfred`, and never set `SIMMER_HUMAN=1`.
Those names carry the authority to end anybody's claim.
Nothing in simmer stops you — on a single-user Mac nothing could — which is exactly why this is an obligation rather than a mechanism.
Borrowing a human's authority to get past a refusal is the one thing this protocol asks you not to do.

## 2. Ask before you start something expensive

```bash
simmer budget --need 20m || echo "not enough time"
```

| Exit | Meaning | What to do |
|---|---|---|
| `0` | there is room, or no deadline exists | go ahead |
| `1` | less time remains than you asked for | do not start it — wind down |
| `3` | **nothing is holding the Mac awake** | the lid could interrupt you at any moment; claim some time, or tell the human |

`3` is not "a bit less time".
It is *no guarantee at all*, and treating it like a small budget is how you end up half-way through a file edit when the machine sleeps.

`budget` answers over the **aggregate** — the machine's actual guarantee — not over your own claim.
That is deliberate: whose claim provides the time does not change how long your work has.
So `budget` can say `0` when your own claim is nearly up, because somebody else's reaches further.
Use `budget` to decide whether to *start* work, and your own claim's `left` (from `.claims[]`) if you need to know when *you* stop being the reason.

## 3. Pace yourself against the clock

```bash
left=$(simmer budget --seconds)    # 4200 · or -1 for no deadline
```

Only trust the number when the exit code was `0`.
`-1` means no deadline is set, so there is no budget to pace against.

A reasonable rhythm:

- **more than ~15 minutes left** — carry on normally
- **under ~10 minutes** — stop starting new work.
  Spend what is left writing the handoff: what is done, what is not, and the exact next step
- **under ~2 minutes** — save, commit if that is appropriate, and stop

Report the remaining time when you report progress, so the human can watch the budget shrink without asking.

## 4. Hand it back

```bash
simmer down --owner agent
```

If you finish early, give the time back — an idle claim keeps someone's laptop awake for no reason.

Two things this will *not* do, and both are correct:

- It will not turn the switch off if somebody else still holds a claim.
- It will **refuse** if you hold no claim of your own and somebody else does, telling you whose they are. Do not reach for `--all`: that is the human's control, and it is refused to you.

## Extending

Extending **your own** claim is fine, but say so out loud:

```bash
simmer +30m --owner agent    # then tell the human you did it, and why
```

Silently extending past the box a human set turns a 30-minute favour into an afternoon.
If you need substantially more time, ask instead.

## The cap

A human can set a ceiling: `simmer cap 23:00` means nothing runs past 23:00, whoever asks and however long they ask for.

You will meet it in one of three ways, and none of them is an error to work around:

```bash
$ simmer 6h -r "long eval" --owner agent
☕ simmering until 23:00 (7 h 12 min) · long eval
   clipped by the cap at 23:00               # you got less than you asked for

$ simmer budget --json | jq .capped
true                                         # asking for longer will not help

$ simmer 2h --owner agent
simmer: the cap is 23:00, which has passed. A human lifts it with 'simmer cap off'.
```

The right response to a cap is to plan inside it, or to tell the human what you would need and why.
`simmer cap` reads it; setting or lifting it is refused to you.

## Reading the state

Prefer `--json`: one object, correctly escaped, numbers as numbers.
Two lines of `jq` cover most needs:

```bash
simmer status --json | jq -r .state    # active · forever · idle · orphan
simmer status --json | jq .left        # seconds remaining, over the aggregate
```

The top-level fields describe **the machine** — what it will actually do.
`.claims` is the list of who is holding it, and `.claim_count` how many.

```json
{"state":"active","until":1787254800,"left":1500,"left_short":"25m",
 "reason":"big build","min_battery":20,"battery":92,"on_battery":1,
 "sleep_disabled":1,"since":1787253300,"owner":"agent",
 "claim_count":2,"cap":1787272800,"capped":false,
 "claims":[{"id":"agent","owner":"agent","until":1787254800,"left":1500,
            "reason":"big build","min_battery":20,"require_ac":0,
            "since":1787253300,"human":false},
           {"id":"terminal","owner":"terminal","until":1787253900,"left":600,
            "reason":"watching the deploy","min_battery":20,"require_ac":0,
            "since":1787253300,"human":true}],
 "version":"2.0.0-dev"}
```

Useful one-liners:

```bash
simmer status --json | jq '.claims[] | select(.owner=="agent") | .left'   # my own time
simmer status --json | jq '[.claims[] | select(.human)] | length'         # is a person holding it?
simmer status --json | jq -r '.claims[] | "\(.owner): \(.reason)"'        # who and what for
```

`simmer budget --json` answers the decision question in the same shape — `{"fits":true,"seconds_left":4200,"state":"active","need_seconds":1200,"claim_count":2,"cap":0,"capped":false}`.
`fits` is `null` when no `--need` was given; `seconds_left` is `null` only when the state is `idle` or `orphan`.
It is output only: the exit codes above apply unchanged, so `simmer budget --json --need 20m || wind_down` still works.

No `jq` in your environment?
`simmer status --machine` prints the aggregate as key=value lines:

```
state=active        active · forever · idle · orphan
until=1787254800    epoch seconds; 0 means no deadline
left=1500           seconds remaining
left_short=25m      preformatted, for display
reason=big build
min_battery=20
battery=92
on_battery=1
sleep_disabled=1
since=1787253300
owner=agent
claim_count=2
cap=1787272800      the human's ceiling; 0 means none
```

`--machine` is the aggregate only — it stays flat so a menu bar can read it without `jq`.
Per-claim detail is `--json` and nowhere else.

Use `budget` to *decide* and `--json` (or `--machine`) to *render*.
Do not parse the human sentences from `simmer` or `simmer budget` — they are written for people and may be reworded.

## Things not to do

- **Do not call `pmset -a disablesleep` yourself.** It has no expiry, nothing shows it on screen, it survives reboots, and it is exactly the trap simmer exists to prevent. simmer's watchdog will revert it within 30 seconds anyway.
- **Do not claim human authority** — no `--owner terminal`/`menubar`, no `SIMMER_HUMAN=1`. See above.
- **Do not use `simmer down --all`.** It is refused to you, and it is refused for a reason.
- **Do not try to move the cap.** Also refused. Plan inside it, or ask.
- **Do not bother with `--force`.** It does nothing; there is nothing left to force.
- **Do not assume a claim exists.** Check with `budget`; exit `3` is common.
- **Do not use `simmer forever`** unless a human asked for it.
  It has no deadline and only a low battery, heat or the cap will stop it.
