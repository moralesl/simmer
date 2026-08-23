# Learnings

Everything this project has already paid for.
The point of the page is that nobody pays twice — a fresh session should read this and `BRIEF.md` and then know as much as the session that finished before it.

Three kinds of thing live here: platform traps, decisions already taken, and decisions still open.
The last section is the one to read first.

---

## 1. Open — needs a human

These are not blocked on work.
They are blocked on a person deciding.

| # | Question | Why it needs you |
|---|---|---|
| 1 | **Bundle id during development.** `io.github.moralesl.simmer` is *currently authorized* for notifications on Luis's Mac. macOS caches a permission verdict per bundle id **forever**, and a denial can never be undone for that id. A half-built v1 app could burn it. **Decided:** build against `io.github.moralesl.simmer.dev` and promote to the clean id only when the app is known-good. Also already burned and never reusable: `ai.causaprima.simmer.notifier`. | Kept here because it is irreversible and easy to forget. |
| 2 | **Distribution audience.** Answered once as "mixed, some non-technical", which is why `bootstrap.sh` exists. Worth re-confirming, because it decides whether a Homebrew tap or the one-paste line is the real channel — and therefore how much packaging work v1 owes. | Only you know who they are. |
| 3 | **Raycast / Alfred / SwiftBar.** Decided: **not** in v1; added afterwards. `simmer render <surface>` stays core and stays tested; only the shims are deferred. Left here because "afterwards" has no date yet. | Scheduling. |

---

## 2. Decisions already taken — do not relitigate

| Decision | Where it is recorded |
|---|---|
| Claims ledger replaces the single lease (`format=2`); `--force` is inert; the cap is human-only; a human may release any claim, an agent only its own | `CONTRACTS.md` § D1, with the four ambiguities that had to be resolved and why each way |
| A claim's **id is its owner** — one live claim per owner | `CONTRACTS.md` § D1 |
| Claims retire on **their own** battery floor; thermal ends all of them | `CONTRACTS.md` § D1 |
| A **passed cap keeps refusing** until a human moves it | `CONTRACTS.md` § D1 |
| No paid Apple signature, ever. Ad-hoc is enough | `PLATFORM-FACTS.md` |
| **v1 starts from zero.** The bash implementation and its 175-assertion suite are the *v0.1 spike*, archived, and inherited by nothing. v1 writes its own tests against `CONTRACTS.md` | this file, § 4 |
| **`simmer down` releases only your own claims — unless you are the human**, who may release any. Blessed 2026-08-23 | `CONTRACTS.md` § D1 |
| Versioning: the bash spike is **v0.1** (tagged; `v0.0-lease` is the pre-claims design). The Swift application is **v1** | this table |
| One Swift package, three products; the guard runs **both** ways — IOKit events in the app *and* a LaunchAgent tick as backstop, over one idempotent `tick()` | this file, § 5 |
| Never distribute a `.dmg` or a browser-downloaded zip | `PLATFORM-FACTS.md` |

---

## 3. Platform traps, each one paid for

`PLATFORM-FACTS.md` holds the verified facts about keeping the Mac awake and about notification identity.
These are the ones found *since*, and they are the kind that cost an hour each because nothing errors — the wrong thing simply happens.

### `command -v git` is not a check for git on macOS

On a Mac with no developer tools, `/usr/bin/git` **exists** — a 119 kB shim that pops Apple's "install the command line developer tools" dialog and exits non-zero.
So `command -v git` succeeds on exactly the machines where git does not work, which is a non-technical colleague's most likely starting state.
The same is true of `swiftc`.

Run the thing and look at its exit code: `git --version >/dev/null 2>&1`.

### A script piped from `curl` has no path, and `dirname` will lie about it

`SIMMER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` yields the **current working directory** under `curl … | bash`, because `BASH_SOURCE` is unset and `dirname ""` is `.`.
Nothing errors.
The installer then reads `$SIMMER_HOME/notifier/main.swift` from a directory that has nothing to do with the project.

Any script that reads files relative to itself must verify the guess against a file only it has, and fail loudly.
`bootstrap.sh` exists because of this.

### BSD `sed` has no `\b`

It matches nothing, silently.
This turned a differential harness into a machine that reported the clock ticking as a finding, twice, before it was spotted.
On macOS the word boundaries are `[[:<:]]` and `[[:>:]]`.

### Measure an exit code, not a pipeline's exit code

`visudo -c -f file | head -3; echo $?` reports `head`'s status, which is always
0. The first attempt at validating a sudoers file concluded `visudo` accepted garbage.
   It does not: broken → 1, valid → 0. Redirect, then measure.

### `launchctl bootout` returns before the job is gone

Poll `launchctl print` until it fails, or the following `bootstrap` fails with `5: Input/output error`.
(Already in `PLATFORM-FACTS.md`; repeated because it bit again while uninstalling.)

### SwiftBar keeps per-plugin state as a mirrored path tree

Under `~/Library/Application Support/SwiftBar/Plugins/`, SwiftBar creates a directory *per component of the plugin's absolute path*.
Removing a plugin symlink leaves that tree behind, so a renamed plugin accumulates ghosts — `awake.10s.sh` was still there long after the tool was called `simmer`.
They are empty directories, so `rmdir` bottom-up is the right tool: it refuses if anything is actually in them, where `rm -rf` would not.

### Other tools hold power assertions too, and none of them tell you

While checking the machine was clean, `caffeinate -i -t 300` processes kept
reappearing.
They are **Claude Code's own** — the binary spawns one per session to stop idle sleep interrupting a long turn.
Zero hits for `caffeinate` in any steering file, settings file or hook; the parent of every one is a `claude` process.

Worth knowing for two reasons. It is a false positive when auditing simmer's own
leaks, so match on simmer's `-ims`/`-dims` signature rather than on the process name.
And it is the sharpest argument for the integration in `DESIGN-NOTES.md`: the tool being used to build simmer is itself holding an invisible, unaccountable, lid-incapable assertion.

### A seam that covers *most* of the side effects is not a seam

The spike's suite advertised itself as hermetic: "no sudo, no real power state
touched, nothing left behind".
It had ten `SIMMER_FAKE_*` variables covering the sleep switch, the battery, thermal pressure, the lock delay and the clock — and **zero** covering `caffeinate`, which every single claim spawned as a detached child process holding a real power assertion.

Found by checking for orphans before declaring the machine clean: **222
`caffeinate` processes**, 219 of them orphaned to `ppid 1`, 13 with no `-t` and therefore never expiring.
`pmset -g assertions` confirmed they were actively holding `PreventUserIdleSystemSleep` and `PreventDiskIdle`.
The machine had been prevented from idle-sleeping by leaked test fixtures.

Two independent causes, both instructive:

1. **The seam had a hole.** Anything with a side effect outside the process has to
   go through the seam, not just the things that are hard to test. `caffeinate`
   was easy to call and therefore never questioned.
2. **The test helper bypassed the only cleanup path.** `clear_all() { rm -f
   "$CLAIMS"/*; }` deleted claim files directly, and `retire_claim()` — the only
   code that kills the recorded child pid — never ran. A fixture that manipulates
   state behind the implementation's back will leak whatever the implementation
   was responsible for.

For v1: no detached child processes at all. See `DESIGN-NOTES.md`.

### A malformed file in `/etc/sudoers.d` can break `sudo` entirely

Not just the rule — `sudo` itself, which on a laptop with one admin account is a genuinely bad afternoon.
`visudo -c -f <file>` needs no root to check a file you own.
Validate before installing, always.

### bash 3.2 specifics (relevant to the archived implementation, and to any shell in this repo)

- **A `case` inside `$( )` breaks.** 3.2 reads the pattern's closing paren as the end of the substitution.
  Name a helper function instead.
- No `${var,,}`, no associative arrays, no `mapfile`.
- `set -e` tolerates a failing `&&` list as a statement — `[ x = y ] && echo` at the top level does not exit.
  Verified, because the opposite is widely assumed.

---

## 4. Process learnings

### Drive the real install, not just the suite

175 hermetic assertions were green while `simmer budget --owner agent` still exited 1 on a flag it should ignore, and while `simmer extend` silently dropped `--owner` so the menu bar's Extend button addressed the wrong claim.
Both were found by running the installed tool the way a person would, on the real machine.
A suite tests what you thought of.

### Two suites, two questions — the shape worth rebuilding

Both live in `archive/v0.1-spike/test/` now and gate nothing. The *shape* is what to
carry across:

- **Is this implementation internally right?** One hermetic suite over the whole
  CLI surface, honouring `SIMMER_BIN` so it is not welded to one binary. 175
  assertions, no sudo, no real power state touched, nothing left behind.
- **Does it still answer what the previous one answered?** Identical CLI scenarios
  driven against two binaries, output normalised for everything that legitimately
  varies (epochs, wall-clock times, durations, pids, versions), then diffed.

The second is the only instrument that catches a message, an exit code, a field
name or a state value drifting, because that is precisely the class of change
where every individual unit test still passes. It found `budget` silently dropping
the "of 2 h 0 min" half of its answer.

Its comparison levels encode contract guarantee 5 directly: **contract-bearing
lines must match exactly, prose may be reworded.** Without that split it is
unrunnable during a rewrite, when every sentence gets retyped. Scenarios that are
*supposed* to differ are declared as such, so a delta quietly reverting is also a
finding.

### The reference must be pinned

The archived `make diff` compares against the **`v0.0-lease` tag** — the pre-claims design — never `HEAD~1`.
The recorded deltas only differ from *that* design; a moving reference turns each of them into a failure the day after it lands.
A tag and a branch sharing a name makes `git show v1:path` ambiguous, which is why the tags are `v0.1` and `v0.0-lease` and there is no branch of either name.

### The spike is reference, not a foundation

The bash implementation satisfies the whole contract and has 175 hermetic
assertions behind it. It is still archived rather than carried forward, and the
call was Luis's: it was a spike, and a rewrite that starts by inheriting the
previous thing's harness is not a rewrite.

What that costs, stated plainly so nobody rediscovers it as a surprise: v1 begins
with **no executable specification**. `CONTRACTS.md` is prose, and prose does not
fail a build. The differential idea — identical CLI scenarios against two
binaries, contract-bearing lines compared exactly and prose free to differ — was
the brief's named safety mechanism for the port, and it does not apply to a
from-scratch build with nothing to differ against.

So the first real deliverable of v1 is not a feature. It is the test seam
(`SIMMER_FAKE_NOW`, `SIMMER_FAKE_PMSET`, `SIMMER_FAKE_BATTERY`,
`SIMMER_FAKE_THERMAL`, `XDG_STATE_HOME`) plus tests written fresh against the
contract, because without those the guard's branches — deadline crossings,
warn-once, the battery floor, thermal — are reachable only by waiting for real
time to pass on a real battery. That is the one thing worth mining the archive
for: not its code, but the fact that it could test all of that without root and
without touching the machine.

### Raise the judgment calls when you make them, not in the summary

The honest failure of the session that produced this page: a long stretch of work went by with real decisions taken inside it — how to resolve D1's four ambiguities, whether a passed cap should block, whether to skip `make uninstall` because it deletes the notification identity — and they were reported afterwards rather than surfaced as they came up.
Everything is written down and reversible, but reading a list of settled decisions is not the same as being asked.
Surface them at the moment of decision.

---

## 5. The shape v1 is being built to

Decided, with the reasoning, so it does not get re-argued:

**One Swift package, three products.**

```
SimmerCore   the logic. No AppKit, no printing, no argv.
             claims · ledger · cap · aggregate · settle · tick · budget ·
             render · the power seam · the clock seam
simmer       the CLI. argv → SimmerCore. Thin on purpose, because the
             acceptance suite drives THIS and nothing else.
Simmer.app   menu bar (own NSStatusItem) + event-driven guard + the notifier,
             merged. The bundle IS the notification identity. The CLI binary
             lives in Contents/MacOS/ and is symlinked onto PATH.
```

**The guard runs both ways, over one function.** `SimmerCore.tick()` is pure and idempotent — it reads the ledger and settles the switch, never a delta — so it is safe to call from two places at once:

```
tick()
  ▲            ▲
  │            └─ LaunchAgent, StartInterval 30 + RunAtLoad   (backstop)
  └─ the app's IOKit callbacks: lid, power, thermal            (instant)
```

Event-driven alone was rejected: a login item is a process a user can quit, and the thing being guarded can flatten a battery.
`RunAtLoad` is also what heals a `disablesleep` left on by a crash or typed by hand, which is the property that makes forgetting structurally impossible rather than merely unlikely.

**Deferred on purpose:** the Raycast, Alfred and SwiftBar shims.
`simmer render <surface>` stays in the core and stays tested; only the files that call it wait.

**Not yet contracted, and nothing may depend on them:** `--lock`, `events.jsonl`, `simmer watch`, `simmer why`.
See `BRIEF.md`.
