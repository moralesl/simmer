# Learnings

Traps this project has already paid for, and the practices that caught them.
The point of the page is that nobody pays twice: everything here cost an hour or more, and almost none of it errors — the wrong thing simply happens.

The verified facts about keeping a Mac awake and about notification identity are in `PLATFORM-FACTS.md`.
The rules those facts produced are in `CONTRACTS.md`.
This page is what was learned the hard way in between.

## Platform traps

### `command -v git` is not a check for git on macOS

On a Mac with no developer tools, `/usr/bin/git` **exists** — a 119 kB shim that pops Apple's "install the command line developer tools" dialog and exits non-zero.
So `command -v git` succeeds on exactly the machines where git does not work, which is a non-technical colleague's most likely starting state.
The same is true of `swiftc`.

Run the thing and look at its exit code: `git --version >/dev/null 2>&1`.

### A script piped from `curl` has no path, and `dirname` will lie about it

`SIMMER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` yields the **current working directory** under `curl … | bash`, because `BASH_SOURCE` is unset and `dirname ""` is `.`.
Nothing errors.
The installer then reads its own files from a directory that has nothing to do with the project.

Any script that reads files relative to itself must verify the guess against a file only it has, and fail loudly.
`bootstrap.sh` clones the repository and works from the clone for this reason.

### A `curl | bash` installer can be cut off mid-download

A dropped connection or a proxy truncating the response leaves bash executing however much of the script arrived.
Everything therefore lives inside functions with a single `main "$@"` on the last line: a truncated download cannot call a function it never finished reading, so the failure mode is doing nothing rather than doing half an install.

### BSD `sed` has no `\b`

It matches nothing, silently.
On macOS the word boundaries are `[[:<:]]` and `[[:>:]]`.

### Measure an exit code, not a pipeline's exit code

`visudo -c -f file | head -3; echo $?` reports `head`'s status, which is always 0 — which once produced the conclusion that `visudo` accepts garbage.
It does not: broken → 1, valid → 0. Redirect, then measure.

### `launchctl bootout` returns before the job is gone

Poll `launchctl print` until it fails, or the following `bootstrap` fails with `5: Input/output error`.

### A malformed file in `/etc/sudoers.d` can break `sudo` entirely

Not just the rule — `sudo` itself, which on a laptop with one admin account is a genuinely bad afternoon.
`visudo -c -f <file>` needs no root to check a file you own.
Validate before installing, always: write the rule unprivileged, validate it, and only then install it as root.

### An installer that checks for a *capability* silently adopts a stranger's grant

Deciding whether to write a sudoers rule like this is wrong:

```bash
if sudo -nl /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  say "sudoers rule already in place"
```

That is a check for the **capability**, not for **its own file**.
Where the capability is already granted by some other file — on this project's first machine, `/etc/sudoers.d/awake`, written years earlier when the tool had a different name — the installer reports "already in place" on every run, never writes its own rule, and quietly runs on a grant it does not own.

Three consequences, and the third is the one that bites:

1. `make uninstall` announced that it was leaving `/etc/sudoers.d/simmer` alone — a file that had never existed.
   The uninstall instructions were wrong.
2. The real grant survived every uninstall, under a name nobody would think to look for.
3. Auditing the machine reported the rule as present and simmer-owned, because the only evidence anyone looked at was `sudo -nl`.

Check for the tool's **own file AND** the capability, and report the difference:

| own file | capability | say |
|---|---|---|
| present | yes | fine, nothing to do |
| absent | yes | *"something else already grants this — `sudo grep -rn disablesleep /etc/sudoers.d/`"*. Do not adopt it silently |
| absent | no | install it |

And uninstall may only claim to leave behind what it actually wrote.

A tool that gets renamed leaves grants and state under the old name, and nothing goes looking for them: this was the third pre-rename artifact found in one session, after a stale log in the state directory and a stale plugin in SwiftBar's tree.

### A notification denial is cached per bundle id, forever

macOS remembers the verdict against the **bundle id**, and a denial can never be undone for that id — not by reinstalling, not by deleting the bundle, only by hand in System Settings.
So bundle ids are a resource that can only be spent.

Two consequences worth designing around:

- **Develop under a throwaway id.** The Makefile defaults to a `.devN` id; the production id is promoted only once the app is known-good.
  Never let a half-built app ask for permission under the id you intend to ship.
- **A spike that builds an `.app` registers it with LaunchServices**, and that registration outlives the directory it was built in — a stale entry can point at a deleted path for weeks.
  It is invisible to every ordinary check: not on `PATH`, not in `~/Applications`, not a launchd job, and `mdfind` does not index `/private/tmp`.
  Only `lsregister` shows it.

```
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/\
LaunchServices.framework/Support/lsregister
"$lsregister" -dump | grep -c '<bundle id>'      # is it still known?
"$lsregister" -u /path/to/Some.app               # forget it
```

Build spikes under a `.spike` id, and unregister them when done.

### The notification grant belongs to the EXECUTABLE, not the bundle

With two executables in one ad-hoc-signed bundle, **each reads (and would request) its own authorization state.**

This is the costliest misread in the project's history, because both halves looked like evidence.
A CLI binary exec'd directly from `Contents/MacOS/` reported `notDetermined` right after a reinstall, which read as "reinstalling resets the grant" — while banners posted by the *app* kept working the whole time, on the same bundle id, across the same reinstall.
The tell was the status reading `notDetermined` at the very moment a correctly-branded banner sat on screen.

The app's grant was never reset; the CLI's was never granted, so every CLI-posted banner silently dropped.
Consequences, all structural now:

- **The app is the only poster.** The CLI and the guard enqueue into `$STATE/notify-spool.jsonl`; the app drains it and posts, action buttons included.
  App not running = no banners, which is honest — the menu bar is gone then too.
- **The CLI never links UserNotifications at all** (enforced in `Package.swift`): asking it anything from the CLI answers a question about the wrong executable.
- `doctor` and `notify-test` read the app's heartbeat file (`$STATE/app.status`), never the notification centre.

### APFS is case-insensitive: `Simmer` and `simmer` in one directory are the same file

The obvious bundle layout — app executable `Contents/MacOS/Simmer`, CLI `Contents/MacOS/simmer` — self-destructs on a default APFS volume: the second `cp` silently overwrites the first, and the "app" then runs the CLI's `main`, prints a status line and exits.
Nothing errors; the bundle even signs.
The app executable is therefore `simmer-app` (`CFBundleExecutable` does not have to match the app's name), and the CLI keeps the `Contents/MacOS/simmer` path the docs promise.

### Two processes over one directory need a signal, not a faster poll

The menu bar and the CLI are separate processes over the same ledger, so a claim taken in a terminal is invisible to the app until it looks again.
Polling faster is the wrong fix: each refresh reads the power state, which costs a subprocess, so a shorter interval buys freshness with battery — and still shows a stale minute for most of every interval that straddles a minute boundary.
Watch the state that matters (`LedgerWatcher`), redraw when the display would actually change (`StatusTitle.secondsUntilChange`), and keep a coarse periodic backstop for whatever the watch cannot see.

### A seam that covers *most* of the side effects is not a seam

A predecessor implementation's suite advertised itself as hermetic: "no sudo, no real power state touched, nothing left behind".
It had ten `SIMMER_FAKE_*` variables covering the sleep switch, the battery, thermal pressure, the lock delay and the clock — and **zero** covering `caffeinate`, which every single claim spawned as a detached child process holding a real power assertion.

Found by checking for orphans before declaring the machine clean: **222 `caffeinate` processes**, 219 of them orphaned to `ppid 1`, 13 with no `-t` and therefore never expiring.
`pmset -g assertions` confirmed they were actively holding `PreventUserIdleSystemSleep` and `PreventDiskIdle`.
The machine had been prevented from idle-sleeping by leaked test fixtures.

Two independent causes, both instructive:

1. **The seam had a hole.** Anything with a side effect outside the process has to go through the seam, not just the things that are hard to test.
   `caffeinate` was easy to call and therefore never questioned.
2. **The test helper bypassed the only cleanup path.** A fixture deleted claim files directly, so the only code that killed the recorded child process never ran.
   A fixture that manipulates state behind the implementation's back will leak whatever the implementation was responsible for.

Hence: no detached child processes at all, and the idle-sleep assertion is held in-process (`Sources/SimmerApp/AppState.swift`), where it dies with the process — an orphan is structurally impossible because there is no child to leak.

### Other tools hold power assertions too, and none of them tell you

While auditing for simmer's own leaks, `caffeinate -i -t 300` processes kept reappearing.
They belonged to Claude Code: the binary spawns one per session so idle sleep does not interrupt a long turn.
Nothing in any configuration file mentions it; the parent of every one was a `claude` process.

Worth knowing for two reasons.
It is a false positive when auditing simmer, so match on simmer's own signature rather than on the process name.
And it is the sharpest argument for the editor integration on `ROADMAP.md`: the tool used to build simmer was itself holding an invisible, unaccountable, lid-incapable assertion.

### A CLT-only toolchain hides swift-testing from `swift test`

`Testing.framework` ships with the Command Line Tools, but outside every default search path — `swift test` fails with *no such module 'Testing'*, and once `-F` is added it still dies at runtime missing `lib_TestingInterop.dylib`.
Both live under `/Library/Developer/CommandLineTools/Library/Developer/` (`Frameworks/` and `usr/lib/`).
`make test` adds the four flags when that directory exists; under full Xcode they are absent and unneeded.
Never reach for `xcodebuild` — the fix stays inside SwiftPM.

## Practices that caught the above

### Drive the real install, not just the suite

175 hermetic assertions were green while `simmer budget --owner agent` still exited 1 on a flag it should ignore, and while `simmer extend` silently dropped `--owner` so the menu bar's Extend button addressed the wrong claim.
Both were found by running the installed tool the way a person would, on a real machine.
A suite tests what you thought of.

### Two suites, two questions

- **Is this implementation internally right?** Unit tests over the mechanics — parsing, the codec, aggregate ties, settle.
- **Does the built binary honour the contract?** An acceptance suite that drives the binary through its public surface, honouring `SIMMER_BIN` so it is not welded to one implementation.

The second is what catches a message, an exit code, a field name or a field's *type* drifting — precisely the class of change where every unit test still passes.
Where a rule can be a test rather than a sentence in a document, it is one: the sudoers rule's scope, the absence of self-escalation, that every documented verb resolves, and that yes/no fields are booleans are all asserted rather than remembered.
