# Using simmer as an agent

You are working on a Mac that may fall asleep and interrupt you. simmer is how you buy a known amount of awake time, and how you find out how much is left.

This page is about *using* simmer.
If you are changing simmer itself, read [AGENTS.md](../AGENTS.md) instead.

## First choice: scope the lease to the command

```bash
simmer run -- npm test                        # awake exactly as long as this runs
simmer run -r "eval batch" -- uv run eval.py  # name the work; the pid is added for you
simmer run --max 2h -- ./long-job.sh          # hard cap on total awake time
```

`simmer run` takes the lease, keeps it renewed while the command runs, and releases it the moment the command exits — success, failure or signal.
Nothing to remember, nothing to hand back: **this is the lease that cannot be forgotten.** Prefer it whenever your long work *is* a command.

Two details worth knowing:

- It renews in chunks (45 min, refreshed every 20 min) rather than taking one long lease.
  Even if the runner is SIGKILLed — the one exit no cleanup can catch — the lease expires within a chunk on its own.
- `--max` bounds the awake time, not the job.
  When the budget runs out the lease lapses and a notification says so, but the command is **not** killed — stopping your work is never simmer's call.
  Decide yourself whether to wind down.

The protocol below is the flexible alternative, for work that is not a single command: many tool calls, an interactive session, work spread across steps.

## The flexible alternative: the protocol in four commands

```bash
simmer 2h -r "refactor the funnel" --owner agent   # 1. buy time, say what for
simmer budget --need 20m || wind_down              # 2. before each big step
simmer budget --seconds                            # 3. how long have I got?
simmer down                                        # 4. finished early? give it back
```

## 1. Take a lease when you start long work

```bash
simmer 2h -r "refactor the funnel" --owner agent
```

- **`-r`** — say what the work is.
  It shows in the human's menu bar, so they can see what is holding their machine awake without asking you.
- **`--owner agent`** — identify yourself.
  This is what lets simmer refuse to let you overwrite a lease a human set on purpose.
- Pick a length you can justify.
  Two hours because the job needs two hours, not because two hours is a round number.

If someone already holds a lease, this **fails** and tells you who:

```
simmer: menubar holds a lease until 15:20 (watching the deploy).
```

That is not an error to route around.
**Never add `--force`** — it throws away a decision a person made.
Either work inside the time they set, or ask them.

## 2. Ask before you start something expensive

```bash
simmer budget --need 20m || echo "not enough time"
```

| Exit | Meaning | What to do |
|---|---|---|
| `0` | there is room, or no deadline exists | go ahead |
| `1` | less time remains than you asked for | do not start it — wind down |
| `3` | **nothing is holding the Mac awake** | the lid could interrupt you at any moment; take a lease, or tell the human |

`3` is not "a bit less time".
It is *no guarantee at all*, and treating it like a small budget is how you end up half-way through a file edit when the machine sleeps.

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
simmer down
```

If you finish early, give the time back — an idle lease keeps someone's laptop awake for no reason.
You do not need to own the lease to release it; stopping is always allowed.

## Extending

Extending **your own** lease is fine, but say so out loud:

```bash
simmer +30m    # then tell the human you did it, and why
```

Silently extending past the box a human set turns a 30-minute favour into an afternoon.
If you need substantially more time, ask instead.

## Reading the state

Prefer `--json`: one object, correctly escaped, numbers as numbers.
Two lines of `jq` cover most needs:

```bash
simmer status --json | jq -r .state    # active · forever · idle · orphan
simmer status --json | jq .left        # seconds remaining
```

The object carries the same fields as `--machine` below, plus `owner` and `version`:

```json
{"state":"active","until":1787254800,"left":1500,"left_short":"25m",
 "reason":"big build","min_battery":20,"battery":92,"on_battery":1,
 "sleep_disabled":1,"since":1787253300,"owner":"agent","version":"1.0.0"}
```

`simmer budget --json` answers the decision question in the same shape — `{"fits":true,"seconds_left":4200,"state":"active","need_seconds":1200}`.
`fits` is `null` when no `--need` was given; `seconds_left` is `null` only when the state is `idle` or `orphan`.
It is output only: the exit codes above apply unchanged, so `simmer budget --json --need 20m || wind_down` still works.

No `jq` in your environment?
`simmer status --machine` prints the same state as key=value lines:

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
owner=agent
```

Use `budget` to *decide* and `--json` (or `--machine`) to *render*.
Do not parse the human sentences from `simmer` or `simmer budget` — they are written for people and may be reworded.

## Things not to do

- **Do not call `pmset -a disablesleep` yourself.** It has no expiry, nothing shows it on screen, it survives reboots, and it is exactly the trap simmer exists to prevent. simmer's watchdog will revert it within 30 seconds anyway.
- **Do not use `--force`** over someone else's lease.
- **Do not assume a lease exists.** Check with `budget`; exit `3` is common.
- **Do not use `simmer forever`** unless a human asked for it.
  It has no deadline and only a low battery will stop it.
