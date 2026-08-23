# Design notes — proposals for v1

Interaction-design proposals, written down so they are decided rather than rediscovered halfway through.
Each is marked:

- **↑ take** — recommended, cheap, clearly better
- **~ consider** — real value, real cost; decide when you get there
- **↓ leave** — considered and deliberately not doing

Nothing here overrides `CONTRACTS.md`.
Where a proposal changes the contract it says so, and it needs a decision recorded there first.

---

## The CLI

### ↑ Regularise the grammar, keep the sugar

The spike's entry point is a pile of special cases because `simmer 2h` is a bare positional that has to be distinguished from every subcommand — including `+20m`, which needs its own glob branch.
Every new verb risks colliding with something that looks like a duration.

Proposal: canonical verbs, with today's spellings kept as documented aliases.

```
canonical                        alias (kept, documented, tested)
simmer claim 2h -r "reason"      simmer 2h -r "reason"
simmer extend 20m                simmer +20m
simmer release                   simmer down · off · stop
simmer release --all             simmer down --all
simmer cap 23:00 | cap off | cap
simmer status [--json|--machine] simmer
simmer budget · run · doctor · log · render · notify-test
```

Two things fall out.
A regular grammar can use a real argument parser (`swift-argument-parser`) instead of a hand-rolled `case`, which gets you `--help` per subcommand, typo suggestions and consistent error text for free.
And the canonical verbs finally **name the model**: the thing is a claim, so the verb should be `claim`, not `take`.
`simmer down` stays because it is muscle memory and it is lovely to type.

*Contract impact: additive.
The alias set is exactly today's surface.*

### ↑ `--json` on every command, not just `status` and `budget`

Today a mutating command prints prose and you need a second call to learn the new state.
That means the app either parses sentences (forbidden) or does two round-trips per action.

Proposal: every command accepts `--json` and returns one object — what changed, plus the resulting aggregate.

```jsonc
// simmer claim 2h -r build --json
{"action":"claimed","claim":{"owner":"terminal","until":1787254800,"reason":"build"},
 "clipped_by_cap":false,"state":"active","until":1787254800,"claim_count":2}
```

This is the single highest-value change for the app, and for any hook or script.
One code path, no parsing, no second call.

*Contract impact: additive.*

### ↑ Complete the exit-code table

`budget`'s codes are contractual and documented.
Every other command's are implied.
Publish them all in `--help` and in `CONTRACTS.md`, because a caller that has to guess treats every non-zero as fatal — and `simmer release` refusing because you hold no claim is not the same as it failing.

### ↑ Nudge an anonymous claimer, once

An agent that forgets `--owner` silently becomes `script`, and then its next step cannot find "its" claim.
Proposal: when a **non-tty** caller takes a claim without naming itself, print one line to stderr:

```
simmer: claimed as "script" — pass --owner agent:<work> to get your own slot
```

Not an error, not repeated, invisible to humans in a terminal.
It converts a silent misuse into a visible one.

### ~ `simmer forever` under the cap

`forever` exists and the guard nags every 30 minutes to make it hard to forget.
With a cap available, `--until <cap>` is strictly better in almost every case.
Keep `forever` (it is in the contract) but demote it: offer it in the menu bar only under ⌥, and have it print the cap when one is in force, since the honest answer to "forever" is then "until 23:00".

### ↑ No detached child processes. Hold the assertion in-process

The spike gave every claim a "second, independent clock": `nohup caffeinate -ims
-t <seconds> &`.
The reasoning was that if the guard died, that timer would still expire.

What it actually produced was **222 orphaned processes**, 13 of them with no
timeout at all, holding real power assertions on a machine that was supposed to be clean.
Every one was `ppid 1`, because `nohup` is exactly how you make a process nobody owns.

For v1, do not spawn anything. Hold the assertion in-process with
`IOPMAssertionCreateWithName`, and let it die with the process — which is the *correct* lifetime, not a limitation.
Three things fall out:

- An orphan becomes structurally impossible rather than merely unlikely. There is
  no child to leak.
- The "what if the guard dies" case is already covered better, by the LaunchAgent
  backstop tick that `BRIEF.md` commits to. A timer inside a process that has
  died is not a backstop; a separate scheduled process is.
- It goes behind the seam like everything else, so a test never touches real
  power state.

Worth being precise about what is lost: nothing that mattered. An IOKit assertion
cannot hold a closed lid — `PLATFORM-FACTS.md` closed that question negatively — so `caffeinate` was never the thing keeping the machine awake with the lid shut.
`pmset -a disablesleep` is.
The child process was belt-and-braces for *idle* sleep only, and it cost 222 orphans.

### ↓ A daemon, a config file, named presets

The spike went ten months without wanting any of them.
Flags plus three defaults (20% floor, 30s tick, 10-point pre-floor margin) covered every case.
Add them when something concrete needs them, not before.

---

## The menu bar

### ↑ The title should say *who*, not only how long

With claims, the interesting ambient fact is no longer just the countdown — it is whether the thing holding your Mac awake is you or something else.
A count costs three characters and answers it at zero clicks:

```
🍲            idle
🍲 42m        one claim, yours
🍲 1h20·3     three claims — worth opening the menu
🍲 8m         orange under five minutes
⚠️             orphan: the switch is on and nothing claims it
```

### ↑ Actionable notifications

The app owns the notification bundle, so its banners can carry buttons.
The spike physically could not do this — it shelled out to a helper.
This is the single change that makes simmer feel like an app rather than a CLI with a menu attached.

| Banner | Buttons |
|---|---|
| five minutes left | **Extend 30m** · Release · Show claims |
| battery near the floor | **Keep going anyway** · Release now |
| thermal release | Show why |
| orphan switch healed | Show log |

`Extend 30m` from a banner is the exact moment someone wants it, and today it costs finding a terminal.

### ↑ A first-run window, not terminal prose

For a non-technical colleague, the install currently ends with paragraphs in a terminal.
Proposal: on first launch, one small panel with three rows, each with a button and a live tick:

```
  Sleep switch      ⚠️  needs one administrator password   [ Set up ]
  Notifications     ⚠️  waiting for permission             [ Ask again ]
  Start at login    ○   not enabled                        [ Enable ]
```

That is `simmer doctor` made visible, it is the natural home for the privileged step, and it turns the riskiest part of onboarding into three obvious buttons.

### ↑ Lead the menu with why, then act

Ambient truth is zero clicks; the first line of the menu should be one click to *why*, before any action:

```
  Awake until 17:00 — 3 claims
  ────────────────────────────
  👤 you · refactor            until 17:00
  🤖 agent:evals · eval batch  until 15:45
  ⚙  run:4821 · npm test       until 15:20
  ────────────────────────────
  Extend +15m                  ⌥ +3h
  Release mine                 ⌥ Release everything (3)
  ────────────────────────────
  Nothing past…             ▸  tonight 23:00 · in 1 hour · pick a time…
  Settings…
```

Two details worth keeping: **⌥ is the power layer** (the macOS-native convention) so destructive and advanced actions are never one slip away; and every action offers **Copy as CLI command** under ⌥, so the menu teaches the CLI instead of hiding it.
That is the agent-tool bridge in one feature.

### ↑ Destructive actions name their blast radius

"Release everything" ends work an agent started.
It should say how much — *Release everything (3)* — and live behind ⌥, consistent with the power layer.
Cheap, and it makes the irreversible thing deliberate.

### ~ Claim by watching something

`simmer run -- <cmd>` is the claim that cannot be forgotten, and it is terminal-only.
The GUI equivalent would be "Keep awake while… ▸ *this app is running*", picking from running applications.
It is the most useful thing the app could offer that the CLI cannot, and it is also the largest new surface.
Post-v1 unless it turns out to be small.

### ↓ Force semantics, owner juggling, transport pickers in the menu

Never.
They are CLI concerns, and two of them no longer exist.

---

## Naming

One thing to settle early because it appears in the menu, the banners and the help: the model is *claims*, so the language should be claims throughout — "you hold a claim", "release yours", "3 claims".
The spike drifted between "lease", "claim" and "take" and it read as three different tools.
Pick claims and never say lease again outside `archive/`.
