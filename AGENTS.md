# simmer, for agents

**Using simmer** is the protocol for long work on a Mac that has it.
**Changing simmer** is for editing this repository.

---

# Using simmer

The machine sleeps when the lid closes — unless awake time is claimed.
Awake time is **counted, not owned**.
Take your own claim under your own name; the Mac stays awake until the latest live claim ends.
You can never take time away from anyone else — and the same protection is owed back: **never claim human authority.**

## A whole session

Every response below is real output — the test suite replays it against the binary.

```bash
# 1. Is there room to start? Nothing is claimed, so there is no guarantee at all.
$ simmer budget --need 30m --json
{"fits":false,"seconds_left":null,"state":"idle","need_seconds":1800,"claim_count":0,...}
# exit 3 — the lid can interrupt you at ANY moment. Claim before starting.

# 2. Claim, under your own name.
$ simmer 45m -r "eval batch" --owner agent:evals --json
{"action":"claimed","claim":{"id":"agent:evals","left":2700,...},"clipped_by_cap":false,
 "state":"active","left":2700,"claim_count":1,...}
# exit 0

# 3. Now the same question has an answer.
$ simmer budget --need 30m --json
{"fits":true,"seconds_left":2700,"state":"active","need_seconds":1800,"claim_count":1,...}
# exit 0 — proceed.

# 4. Taking longer than you thought? ADD to your deadline.
$ simmer +30m --owner agent:evals --json
{"action":"extended","claim":{"left":4500,...},"state":"active","left":4500,...}
# exit 0

# 5. Done. Hand it back.
$ simmer down --owner agent:evals --json
{"action":"released","released":["agent:evals"],"state":"idle","claim_count":0,...}
# exit 0
```

`simmer run --max 2h -- npm test` sidesteps all five steps for anything expressible as one command: the claim lives exactly as long as the process, renews while it runs, and is released on any exit — even SIGKILL.

## The exit codes are the contract

| exit | meaning | what you do |
|---|---|---|
| 0 | fits, or no deadline at all | proceed |
| 1 | not enough time left, or refused | wind down, or read `.error` |
| 3 | **nothing is claimed at all** | the lid can interrupt at ANY moment — claim first |

3 is not a big 1: it is an absent guarantee, not a small budget.
Conflating them means working while the machine sleeps under you.

## Ask again while you work

**Checking once at the start is not enough.** A claim can end before your work does without you doing anything wrong: the battery reaches its floor, the charger is unplugged on a `--require-ac` claim, the chip reports thermal pressure, or a human moves the cap.
Your process keeps running; your guarantee is gone, and nothing tells you.

So for work measured in hours, re-run `simmer budget --need <t>` between units of work — after each batch, each file, each test run.
Exit 3 mid-job means claim again before continuing.
Exit 1 means finish the current unit and write the handoff rather than starting another.

## Name yourself

`--owner agent:<work>`, e.g. `agent:funnel-refactor`.

- One live claim per owner: a second claim under the same name *replaces* yours.
  `simmer 2h` twice moves your deadline, it does not stack.
- Concurrent agents each pick their own name, or they fight over one claim.
- **Never** use a human owner name (`terminal`, `menubar`, `raycast`, `alfred`) and **never** set `SIMMER_HUMAN=1`.
  Nothing stops you technically — that is exactly why it is an obligation.
  Human primacy protects the person's time from your accidents.
- Inside a pty you are indistinguishable from a person, so simmer treats you as one and your default owner becomes the human `terminal`.
  The gate cannot see you; the name has to.

## What you may not do

- `simmer down --all` — ending work someone else started is not your call.
  Release your own with `simmer down --owner …`.
- `simmer cap …` — the cap is the ceiling a person set.
  When a claim is clipped or refused by it, report that and stop.
  Never retry with a bigger number and never route around it.
- Suppressing notifications — they are the human's window into what you hold.
- Installing simmer, or setting `pmset -a disablesleep` yourself.
  That switch has no expiry, nothing on screen indicates it, and it survives reboots — leaving it on is the exact failure simmer exists to prevent.

## Two shapes that mislead

**`clipped_by_cap: true` on a successful claim is not a refusal.** You got a shorter deadline than you asked for at exit 0; `until` says how short.
Asking for `8h` under a one-hour cap gives you one hour, and only that field says so.

**`budget`'s `seconds_left`** is a number when there is a deadline, `-1` when there is none, and `null` when nothing is claimed at all.
Switch on the exit code and the type never comes up.

## When simmer is not installed

Most Macs do not have it.
Absence is not an error to crash on and not a guarantee to assume: gate on `command -v simmer`, and where it is missing, say in your handoff that you had **no** protection from the lid rather than implying the machine stayed awake.

## Parse only the machine surfaces

`--json`, `status --machine` and the exit codes are contract; every human sentence may be reworded at any time.
`status --json` gives the aggregate at the top level and every claim in `.claims[]`, and every mutating command answers with what changed plus the resulting aggregate — one call, no second round-trip.

Testing your own code?
Isolate with `XDG_STATE_HOME=<tmp>` and `SIMMER_NOTIFY=none`, and fake the hardware through the seam (`SIMMER_FAKE_PMSET`, `SIMMER_FAKE_BATTERY`, `SIMMER_FAKE_NOW`, …).
Never exercise the real switch to test your own code.

---

# Changing simmer

## The shape of it

**One Swift package, three products** — `SimmerCore` (the logic, no AppKit, no printing), `simmer` (the CLI), and `Simmer.app` (menu bar + event-driven guard + notification identity, one bundle).
The guard runs both ways over one idempotent `tick()`: IOKit events in the app for instant response, and a LaunchAgent every 30 seconds as the backstop nobody can quit.

```
Sources/SimmerCore/   claims · ledger · cap · aggregate · settle · tick ·
                      budget · render · the power seam · the clock seam
Sources/SimmerCLI/    argv in, exit code out. Thin on purpose.
Sources/SimmerApp/    NSStatusItem · IOKit callbacks · UNUserNotificationCenter
Tests/                unit suite + an acceptance suite that drives the BUILT
                      binary under the seam variables (honours SIMMER_BIN)
integrations/raycast/ the Raycast extension: TypeScript, its own npm tree and
                      tests. A fourth renderer over `status --json`.
docs/CONTRACTS.md     the law: surface, exit codes, machine output, reasoning.
docs/PLATFORM-FACTS.md  what macOS actually does, verified.
docs/ROADMAP.md       decided but not built. docs/FAQ.md — short answers.
```

## Read first, in this order

1. `docs/CONTRACTS.md` — the law.
   Settled decisions are not relitigated.
2. `docs/PLATFORM-FACTS.md` — each line bought with a failed attempt, plus the traps no test can carry.
   If your plan trips one, the plan is wrong, and nothing there changes without re-running the experiment and recording the result.

## Commands

```bash
make test          # both Swift suites, hermetic: no sudo, no real power state
make test-raycast  # the extension's lane — `make test` cannot see it
make app           # assemble + ad-hoc sign Simmer.app (CLT only — never xcodebuild)
make skill         # render the protocol above into ~/.claude/skills/simmer
make install       # the app, the CLI, the guard — and the skill, where ~/.claude exists
make uninstall     # removes exactly what install wrote
```

The skill is **generated** from this page's `# Using simmer` half, so it cannot drift from it.
That is how the protocol reaches agents that have no checkout — which is all of them.
`SkillTests` asserts the extraction, since a renamed heading would still exit 0 and still write a file.

Touching both sides means both commands.
And do not run the commands these documents quote: `PLATFORM-FACTS.md` contains `pmset -a disablesleep`, and `SudoRule` renders a real sudoers edit that a human applies.

## Iron rules

- **The test seam is load-bearing.** Every side effect outside the process goes through `SIMMER_FAKE_*` / `XDG_STATE_HOME` — a new side effect ships WITH its seam, or the suite is lying about being hermetic.
- **Exit codes and `--json`/`--machine` are API.** Human sentences may be reworded freely; a changed exit code or JSON field is a contract change and lands in `CONTRACTS.md` first.
  Machine fields are append-only.
- **Every mutation ends in `settle()`** — the one function that puts the switch where the ledger says.
  No second path to `disablesleep`, ever.
- **No detached child processes.** The spike leaked 222 orphaned caffeinates; simmer spawns nothing it does not wait for.
- **Only the app touches UserNotifications.** The CLI enqueues into the spool (`$STATE/notify-spool.jsonl`); the grant belongs to the app's executable (`docs/PLATFORM-FACTS.md`).
  The CLI target must not link SimmerNotifyKit.
- **Bundle ids are spent, never recovered.** `io.github.moralesl.simmer` is production — never point that line at a fresh id to try something.
  Develop under a throwaway (`make BUNDLE_ID=…dev3 app`); the Makefile keeps the ledger of ids already burned.
- **SimmerCore stays pure**: no AppKit, no printing, no argv, no globals.
  The CLI and the app are renderers over it — that is what keeps them from disagreeing.
- **Every surface consumes the contract, never the ledger.** A surface that parses `$STATE/claims/*` itself becomes a second implementation of the aggregate, and the two disagree the first time cap clipping changes.
  The Raycast extension shells out to `status --json` for exactly that reason.
- **simmer never escalates its own privileges.** The sudoers rule is composed in `SudoRule`, shown in full, and run by a human — no `osascript … with administrator privileges`, no Authorization Services.
  Widening its scope, letting the app run it, or letting the installer's copy drift all fail `SudoRuleTests`.
- **Yes/no means a JSON boolean** on every surface except the flat `--machine` (and its `status --json` mirrors `on_battery`/`sleep_disabled`).
  Asserted against raw JSON text — `as? Bool` accepts `0`/`1` and would miss it.
- **A verb in `Normalize.verbs` must have a subcommand behind it.** Otherwise it reaches the raw parser, whose "Unexpected argument" is the one refusal in the surface that names no fix.
  `everyDocumentedVerbResolves` is the gate.
- **No surface may cost a caller awake time it already holds.** `extend` adds; anything that *sets* a deadline says so in its label, because the one thing this tool exists to prevent is time quietly disappearing.
  The gates are `extendingALongClaimByALittleNeverShortensIt`, `moreTimeExtendsTheMenuBarsOwnClaimRatherThanReplacingIt`, and `integrations/raycast/tests/args.test.mts`.
- **`--json` is honoured or refused, never accepted and dropped.** A silently ignored flag is indistinguishable from one that worked — that is how `--help` came to promise a surface four commands did not have.
  `everyVerbHonoursJSON` walks the whole verb list.
- **A flag's own validation belongs to simmer, not to ArgumentParser.** Parser diagnostics name internal subcommand spellings nobody typed and write nothing to stdout, so a `--json` caller gets an empty stream instead of the contracted refusal object.
  Take the value as `String`, validate it, and refuse through `Outcome.failure`.
- **The session above is a fixture.** `AgentDocTests` replays it against the built binary, so a renamed field or a changed exit code fails there too.
  Editing it is editing a test.

The bash spike that preceded this implementation lives in the maintainer's development archive, at its `v0.1` tag — reference material only; nothing imports from it, and it is not in this repository's history.
`BRIEF.md` and `DESIGN-NOTES.md` guided the Swift rewrite; what they decided is in `docs/CONTRACTS.md`, and their text is in git history.
Cite the contract, not them.
