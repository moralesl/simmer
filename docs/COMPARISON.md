# Choosing a keep-awake tool

simmer is not the right answer for everyone, and pretending otherwise would be the fastest way to lose your trust.
This page compares the four realistic options honestly — including the two commercial ones — so you can pick the tool that actually fits.
If that is Amphetamine or LidRun, use them; they are good products.

## The field

| Capability | caffeinate | Amphetamine | LidRun | simmer |
|---|---|---|---|---|
| Survives lid close (Apple silicon) | ✗ | ✓ (closed-display mode) | ✓ (`pmset disablesleep` via privileged helper) | ✓ (`pmset disablesleep` via leased switch) |
| Bounded, self-revoking sessions | ✓ (`-t` timer) | ✓ (session timers) | ✓ (30 min–8 h) | ✓ (deadline + guard that reverts an orphaned switch) |
| Battery floor | ✗ | ✓ (trigger option) | ✓ (~4–5%) | ✓ (20% default, per-lease flag) |
| Thermal release | ✗ | ✗ | ✓ | ✓ |
| Screen-lock control on lid close | ✗ | ✓ (explicit per-trigger options) | not documented | ✗ — known gap, tracked |
| Agent / query API | ✗ | ✗ | ✗ | ✓ (`budget --need` exit codes, `--seconds`, `status --machine`) |
| Scriptable | ✓ | GUI only — no contract to script against | GUI + one-keystroke lid close (⌥L), webhooks (Pro) | ✓ — the CLI *is* the tool |
| Triggers / process detection | ✗ | ✓ (app running, battery, display, …) | ✓ (auto-detects Claude Code, Cursor, Docker, Ollama) | ✗ |
| Notifications under own identity | n/a | ✓ | ✓ | ✓ (locally built, ad-hoc-signed bundle) |
| Source / auditability | Apple, opaque | closed | closed | MIT, ~one bash script, 59-test hermetic suite |
| Price | free (built in) | free (App Store) | $9–19 one-time | free |

Two of these — LidRun and simmer — are architecturally the same tool: `pmset -a disablesleep` behind a privileged path, with auto-reversion and a battery floor.
The differences are packaging, price, and who the primary user is.

## When to choose which

- **Amphetamine** — you want a GUI with rich triggers (start a session when an app is running, stop on battery) and you care about explicit control over screen locking with the lid closed; it is the only tool that offers that today.
- **LidRun** — you want a polished paid product with zero setup: session timers, thermal and battery safeguards, and process auto-detection out of the box, for a one-time $9–19.
- **caffeinate** — your machine's lid stays open and you only need to hold off idle sleep; it is already installed and one flag away.
- **simmer** — agents drive the machine and need a queryable contract (`simmer budget --need 20m` before each expensive step), you want to read every line that runs as root, or a team wants the tool free and forkable.

## The locking question

For **every** `disablesleep`-based tool — LidRun and simmer alike — the security situation with the lid closed is the same: the machine is awake, and whether it is *locked* depends on your macOS setting "require password after display is turned off".
If that setting is lax, closing the lid on a leased machine leaves an unlocked, running computer in your bag.
The tool cannot paper over this; only Amphetamine offers explicit lock control today.

simmer does not have a lock-on-lease feature yet.
That is a real gap, it is named here rather than buried, and it is tracked as future work.
Until then: set "require password" to *immediately* and the question answers itself.

## Why this page exists

"Why not just use X?" is the first question a colleague asks, and a README that only lists strengths has already answered it dishonestly.
The table above is the same one we used to decide simmer was worth building — including the two rows (triggers, lock control) where the competitors win.
