# simmer v1 — the brief

simmer keeps a Mac awake for a bounded time with the lid closed, then lets it sleep again.
This document says what v1 **is**.
The law it must satisfy is `CONTRACTS.md`; what the platform actually permits is `PLATFORM-FACTS.md`; what has already been learned and what is still open is `LEARNINGS.md`.

There was a bash spike before this, at `archive/v0.1-spike/`.
It proved the model and bought the platform facts, and it is inherited by nothing.

## What it is

**One Swift package.
Three products.**

```
SimmerCore    the logic. No AppKit, no printing, no argv, no globals.
              claims · the ledger · the cap · the aggregate · settle · tick ·
              budget · render · the power seam · the clock seam

simmer        the CLI. argv in, exit code out. Thin on purpose: everything it
              can do, SimmerCore does, so the app and the CLI cannot disagree.

Simmer.app    the menu bar (its own NSStatusItem), the event-driven guard, and
              the notifier — merged into one bundle. The bundle IS the
              notification identity, which is the only way a banner carries
              simmer's own name and icon without a paid signature. The CLI binary
              ships inside Contents/MacOS/ and is symlinked onto PATH.
```

One bundle rather than three parts, because it is the only version a non-technical colleague can install unaided, and because the notification identity has to be a real installed app anyway.

## The model, in one paragraph

Awake time is **counted, not owned**.
Everyone — a person, an agent, a build — holds their own *claim*; the machine stays awake until the latest live one ends; nobody can touch anybody else's, because a claim's id **is** its owner.
Above all of them sits the one control only a human has: the **cap**.
Claims request from below, the cap rules from above.

That removes an entire user interface rather than adding one.
With a single slot, two actors wanting awake time at once forces refusals, a `--force` flag and a rule about who may overwrite whom.
With claims counted, none of that exists to design.

`CONTRACTS.md` has the surface, the exit codes, the machine output and the reasoning behind every choice, including the four ambiguities that had to be resolved to get here.

## The guard runs both ways, over one function

```
SimmerCore.tick()      pure · idempotent · reads the ledger, never a delta
     ▲            ▲
     │            └─ LaunchAgent, StartInterval 30 + RunAtLoad   (backstop)
     └─ the app's IOKit callbacks: lid, power, thermal            (instant)
```

Event-driven alone was considered and rejected.
A login item is a process a user can quit, and the thing being guarded can flatten a battery.
`RunAtLoad` is also what heals a `disablesleep` left on by a crash or typed by hand — the property that makes forgetting *structurally impossible* rather than merely unlikely.

Because `tick()` reads the ledger and settles the switch rather than applying a change, two callers racing is harmless.
That is a requirement on its design, not a hope.

## Install

One paste, and one password prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
```

Which does: check that the Command Line Tools are genuinely there (`/usr/bin/git` exists even when they are not — see `LEARNINGS.md`), clone, build, install, and ask **once** for an administrator password through a native macOS dialog after printing the exact two-line sudo rule it is about to install.
Then launch the app once so the notification permission banner appears with simmer's own icon, and the last instruction is "click Allow".

Never a `.dmg`, never a browser-downloaded zip: macOS attaches quarantine to browser-style downloads and nothing else, so source fetched by `git` or `curl` and compiled locally runs with no Gatekeeper warning, no certificate and no Apple account.

The privileged step has one rule of its own: **the installer checks for its own
file, not merely for the capability.** The spike checked `sudo -nl` and therefore adopted a grant left by the tool's previous name, never wrote its own rule, and told people to remove a file that did not exist (`LEARNINGS.md`).
Finding the capability granted by something else is a thing to *report*, never to assume.

Developers get a Homebrew tap instead — having brew *guarantees* the Command Line Tools, so the formula can compile locally with no binaries in git.

## In scope for v1

- The CLI surface in `CONTRACTS.md`, complete, with its exit codes and machine output.
- The claims ledger, the cap, human primacy, `--require-ac`, the pre-floor warning.
- The menu bar: ambient truth at zero clicks, the 80% actions at one, ⌥ as the power layer, and "Copy as CLI command" on every action — the menu teaches the CLI instead of hiding it.
- The guard, both ways.
- Notifications from simmer's own bundle, on **aggregate** changes only.
- The test seam and tests written fresh against the contract.
  **This is the first deliverable, before any feature** — see below.
- `bootstrap.sh` and the one-password install.

## Deliberately not in v1

| Deferred | Why |
|---|---|
| Raycast, Alfred, SwiftBar shims | The app has its own menu bar now, so a SwiftBar plugin would be a second competing one. `simmer render <surface>` stays in the core and stays tested; only the files that call it wait. Added after the first release. |
| `events.jsonl`, `simmer watch`, `simmer why` | Good ideas, and cheap once the ledger exists. Not contracted, so nothing may depend on them yet. |
| `--lock` (lock the screen on take) | Listed so no implementation invents behaviour for it. It enters the surface together with its tests. |
| A Homebrew tap | After the one-paste path works. |
| The Claude Code hook | The flagship integration, and it has a concrete motivating case: Claude Code already spawns its own invisible `caffeinate` per session (`DESIGN-NOTES.md`). The strong version is that the harness's wakefulness becomes a claim like everybody else's. Plus the `SessionStart` / `UserPromptSubmit` hooks that turn the agent protocol from prose an agent must remember into a gate the harness enforces. Wants a stable CLI first. |

## Start with the seam, not a feature

The spike could exercise every branch of the guard without root and without touching the machine under the tester, because four power reads and the clock all went through substitutable functions.
That is the single most valuable thing to copy, and copying it first is not optional:

```
SIMMER_FAKE_PMSET      the sleep switch is a file's 0/1
SIMMER_FAKE_BATTERY    "12:1" — 12%, on battery
SIMMER_FAKE_THERMAL    thermal warning level
SIMMER_FAKE_LOCKDELAY  screen-lock grace after the lid closes
SIMMER_FAKE_NOW        the clock. Relative arithmetic reads it; absolute
                       formatting is unaffected
SIMMER_HUMAN=1         the caller carries human authority
XDG_STATE_HOME         state isolation
```

Without `SIMMER_FAKE_NOW` in particular, deadline crossings, warn-once and the reminder interval are reachable only by waiting for real time to pass on a real battery — which in practice means they go untested, which in practice means the guard's most important branches are the least verified ones.

## The one open question that blocks the app

The notification bundle id.
A permission verdict is cached per bundle id **forever**, and a denial can never be undone for that id.
Build against a development id and promote to the clean one only when the app is known-good.
`LEARNINGS.md` § 1 has the detail and the already-burned ids.
