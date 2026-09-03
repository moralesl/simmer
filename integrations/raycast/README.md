# simmer for Raycast

Seven commands in the root search, over the same contract everything else reads.

| Command | What it does |
|---|---|
| **Simmer Status** | the countdown **in the root search itself** — no window, refreshed on Raycast's background tick |
| **Simmer Claims** | who is holding this Mac awake, until when, and why — with the actions on `⌘K` |
| **Simmer for** | a duration, a wall clock (`23:00`), or `forever`, plus an optional reason |
| **Simmer Longer** | adds to *your* deadline, counted from your current one |
| **Simmer Down** | hands Raycast's claim back |
| **Nothing Past** | the evening ceiling no claim may cross, or lift it |
| **Simmer Check for Updates** | asks GitHub which release is newest, and shows the command that installs it |

Typing "simmer" shows the state without opening anything:

```
Simmer Status   ☕ 42m left · until 17:00 · plan review · 3 claims
Simmer Claims   who is holding this Mac awake, and the actions
```

## Why an extension and not a script command

A script command can do one of the two things wanted here, not both.
`mode: inline` prints the state in the root search — which is why **Simmer Status** is a `no-view` command with an `interval`, doing exactly that job through `updateCommandMetadata`.
What it cannot do is the **claims list**: three actors can hold the lid open at once, and the question is usually *whose* claim the 40 minutes is, not *how long* is left.
That needs a view, and a view needs an extension.

Two states are visible here and nowhere else in a GUI: an **orphan** (the switch is on and nothing claims it) and a claim held while `disablesleep` is somehow off.
Both are one row with the fix attached.

The two surfaces split cleanly: the list reads `status --json` because it needs fields, and the root-search line **is** `simmer render raycast` because it needs a sentence.
Nothing here rewords that sentence — the menu bar, this row, and anyone else's script command should read the same, and that is only true while one place decides the wording.

Raycast's background refresh floor is one minute, and it is best-effort on a busy machine.
So the line says `42m left` rather than a ticking second count: it is a glance, and it is honest about being one.
The live countdown inside **Simmer Claims** ticks every second, locally, from `until`.

## Install

```bash
npm ci
npm run dev     # registers the extension with Raycast, then ⌃C — it stays
```

`npm run dev` has to run once **in a terminal**: it needs a live TTY to hand the built extension to Raycast, and in a non-interactive shell it builds, reports success, and registers nothing.
After that the extension is registered and the dev server is no longer needed — `⌃C` leaves it in place.
Run it again after any change to `package.json`, since that is the manifest Raycast registered.

Then, in Raycast, search for "Simmer" and **press ↵ on Simmer Status once**.

That last step is not optional and it is not a bug: Raycast disables background refresh by default and activates it only when the command is first opened, or when it is enabled by hand in the command's preferences.
Until then the row shows a crossed-out refresh icon and the countdown stays blank.
One keystroke, once per machine.

## Development

```bash
npm test        # pure units + a contract suite against the BUILT simmer binary
npm run typecheck
npm run lint    # ray lint: manifest, icons, ESLint, Prettier
npm run build   # ray build: what the store would check
```

`npm test` runs two kinds of test:

- `tests/args.test.mts`, `tests/format.test.mts` — pure.
  The load-bearing one is that "more time" builds `extend` and can never build `claim`: a bare duration *sets* the deadline from now, so a `+15m` button that claimed would take 25 minutes away from a claim with 40 left.
  `AGENTS.md` states it for every surface; that file enforces it.
- `tests/bridge.test.mts` — runs the real binary through simmer's own test seam (`XDG_STATE_HOME` in a temp dir, every power read faked, `SIMMER_NOTIFY=none`), so a renamed JSON field or a changed exit code fails here instead of showing up as an empty list in Raycast.
  It honours `SIMMER_BIN` like the Swift acceptance suite, and skips itself when simmer is not installed.

`ray lint` reports one known failure: `author` is validated against a registered Raycast Store handle, and this extension is not published.
Everything else in `ray lint` is green, and `ray build` — which is what actually has to pass — has no such check.

CI runs the typecheck, ESLint and both test suites.
It does **not** run `ray lint` or `ray build`: the `ray` CLI is macOS-only and expects a local Raycast, so those two are local steps and this note is here instead of a green badge that would imply otherwise.

## Notes

- **Binary discovery.** Raycast runs with a minimal PATH, so `src/simmer.ts` looks in `~/.local/bin`, the `Simmer.app` bundle, `/usr/local/bin` and `/opt/homebrew/bin`, after the optional `simmerPath` preference and `SIMMER_BIN`.
  A machine without simmer gets a calm empty state, never a red error screen.
- **Owner.** Every mutation is `--owner raycast`, which is a human owner name in `SimmerEnvironment.isHumanOwnerName` — that is what grants this surface the authority to release everything and to move the ceiling.
  An agent must never borrow it (`AGENTS.md`).
- **The only command that opens a socket** is **Check for Updates**, and only when you run it.
  The claims list reads `simmer update --cached`, which answers from the record `Simmer.app` refreshes once a day and makes no request — so opening a launcher view never waits on GitHub.
  Neither surface installs anything: they hand over the command, because an update replaces a running app and the binary the guard points at.
- **No polling.** The countdown ticks locally from `until`; the list re-reads only when `$STATE/claims` or `$STATE/cap` changes, which is the same watch `LedgerWatcher` arms.
- **The icon** is `assets/simmer.png`, the 512px face out of the shared `assets/icon.icns`.
  To regenerate: `iconutil -c iconset ../../assets/icon.icns -o /tmp/simmer.iconset` and copy `icon_512x512.png`.
