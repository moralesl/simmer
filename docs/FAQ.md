# FAQ

Short answers.
The reasoning behind them is in `CONTRACTS.md`; what the platform permits is in `PLATFORM-FACTS.md`.

## Using it

**What does simmer actually do?** Borrows `pmset -a disablesleep` — the only thing that keeps a Mac running with the lid shut — with a deadline, and has a background guard hand it back.
It never leaves the switch on with nothing scheduled to turn it off.

**Why not `caffeinate`, Amphetamine, KeepingYouAwake or LidRun?** The full comparison, including where each of them is the better answer, is in the README ("How it compares").
The short version for `caffeinate`: it does not survive the lid.
On Apple silicon the machine sleeps the moment you close it no matter which assertions are held, so no assertion of any kind can be the mechanism — only `pmset -a disablesleep` holds a closed lid, and only root can set it. simmer does hold an idle-sleep assertion of its own, in-process, but that is belt-and-braces and never the thing doing the work.

**Why does it need my password?** Only root can flip that switch, and the guard has to be able to flip it back while nobody is at the keyboard.
So a two-line `/etc/sudoers.d` rule, scoped to exactly `pmset -a disablesleep 0` and `pmset -a disablesleep 1` and nothing else.
Asked once, at install, and the rule is printed in full before it is asked for. simmer never escalates its own privileges: it composes the command and shows it, and you run it — the app's setup window hands you the command rather than performing it, and `simmer doctor` prints it if it is missing ([SECURITY.md](../SECURITY.md)).

**How do I remove it?** `simmer uninstall`.
It lists what is on the machine and prints the exact commands that remove it, resolved — so nothing depends on remembering where the one-paste installer put its checkout.
It shows them rather than running them, for the same reason the sudo rule is shown rather than applied, and because a binary that deletes its own bundle mid-run is a worse idea than a paste.
The sudo rule is the one command that needs root, and it stays yours.
The uninstall removes exactly what the install wrote — nothing else, and it never touches a sudoers rule it cannot prove it wrote.
Your state (`~/.local/state/simmer/`) is left alone; delete it if you want the log and the claims gone too.

**I removed simmer but `sudo -l` still shows the pmset rule.** Look for it under another name: `sudo grep -rn disablesleep /etc/sudoers /etc/sudoers.d/`.
One tested machine carried a rule called `awake` from before the tool was renamed, and every simmer install adopted it silently instead of writing its own.

**What is a claim?** Your request for awake time: a deadline, a reason, a battery floor, and your name on it.
The Mac stays awake until the latest live claim ends.

**Why claims rather than one lease?** Because a person, an agent and a build routinely all want the lid shut at once.
A single slot forces refusals and a `--force` flag; counted claims mean the conflict cannot occur.
`--force` still parses and does nothing.

**`simmer down` didn't put my Mac to sleep.
Broken?** No — somebody else still holds a claim.
`simmer down` releases **yours**.
Use `simmer down --all` to end everything; only a human may.

**Why can an agent not use `down --all`?** Because ending work someone else started is not an agent's call.
A human can release any claim; an agent only its own.
It is enforced against honest actors, not as a security boundary — nothing stops a process passing `--owner terminal`, and on a single-user Mac nothing could.
The agent protocol states it as an obligation — [FOR-AGENTS.md](FOR-AGENTS.md).

**What is the difference between `simmer +30m` and `simmer 30m`?** `+30m` **adds** half an hour to your deadline; `30m` **sets** your deadline to half an hour from now.
So on a claim running until 23:00, `+30m` gets you 23:30 and `30m` gets you 30 minutes.
In the spike both meant the second thing, which meant `+15m` on a four-hour claim silently left fifteen minutes.

**What is the cap for?** "Nothing past 23:00, whoever asks."
It clips every claim, the ones already held and the ones taken later.
It is a human instrument: an agent can read it and gets a truthful `budget` answer when it hits it, but cannot move it.

**The cap time has passed and now nothing can be claimed.** That is deliberate.
Letting it lapse quietly would throw away a decision you made on purpose.
`simmer cap off` lifts it, `simmer cap <time>` moves it, and every surface says which.

**Why did my two-hour claim end at 40%?** The battery floor, which defaults to 20% and only applies on battery power.
Each claim carries its own, so `--min-battery 60` gets you exactly that without dragging anybody else's claim down.
Thermal pressure is the one condition that ends everything at once — it is a fact about the machine, not about anyone's plan.

**Will it kill my long-running job when time runs out?** Never.
`simmer run --max 2h` bounds the *awake time*, not the job: the claim lapses, a notification says so, and the command keeps running.
Stopping your work is not simmer's decision.

**Does the screen stay on?** No, by default.
You took a claim because you are walking away, so a lit screen costs exactly the battery the floor exists to protect — and with the lid shut it is off anyway.
`--display-on` for demos and kiosks.

**Is my laptop locked in my bag?** That is your Lock Screen setting, not simmer's — but simmer is the tool that turns a lax setting into a *running, unlocked* laptop in a bag, so it says so when it takes a claim and `doctor` reports it.

**Nothing appears when a claim ends.** Notifications are optional and fire on **aggregate** changes only, never per claim.
`simmer notify-test` fires one test banner and tells you exactly why nothing arrives when it does not — simmer posts under its own name or not at all, never as Script Editor or any other borrowed identity.
The menu bar always tells the truth and cannot be suppressed.

## Building it

**Why is there no download link?** macOS attaches its quarantine flag to browser-style downloads and nothing else, so a `.dmg` would hit "unidentified developer".
Source fetched by `git` or `curl` and compiled locally runs with no warning, no certificate and no Apple account.

**Why does a banner carry simmer's own icon with no Apple Developer account?** Because macOS attributes a notification to the *bundle* that posts it, and an installed, LaunchServices-registered, ad-hoc-signed app bundle is a real bundle.
Verified against a trusted self-signed certificate: no difference.
The recipe and its traps are in `PLATFORM-FACTS.md`.

**Does simmer spawn background processes?** No.
It holds its power assertion in-process, so there is nothing to orphan.
The bash spike used a detached `caffeinate` per claim and leaked 222 of them; see `PLATFORM-FACTS.md`.

**Where is the state?** `$XDG_STATE_HOME/simmer/` (default `~/.local/state/simmer/`): one flat `key=value` file per claim under `claims/`, the `cap`, and the log.
Flat rather than JSON so a menu bar can read it without making `jq` a prerequisite for seeing a countdown.
Written temp-file-then-rename, never edited in place.

**Can I script against it?** Yes, and only against `--json` / `--machine` and the exit codes.
Human sentences may be reworded at any time.
`budget` answers the decision question in its exit code: `0` there is room, `1` not enough, `3` **nothing is holding the Mac awake** — which is an absent guarantee, not a small budget, and code that conflates the two keeps working while the machine sleeps under it.

**Is there a Raycast extension?** Yes — [`integrations/raycast/`](../integrations/raycast/), six commands, install in one `npm ci && npm run dev`.
It shows the claims list, which is the thing a one-line launcher cannot: who holds the lid, until when, and why.
It reads `status --json` for the list, so it can never disagree with the CLI about what is held, and `simmer render raycast` for the countdown it shows under the command title in the root search — the same one-line surface a script command would use.
Alfred is still on the roadmap ([ROADMAP.md](ROADMAP.md)) — `simmer render alfred` is in the core and tested, waiting on someone with the paid Powerpack.
A SwiftBar plugin is deliberately never coming — the app is the menu bar.

**Where is the bash version?** In the maintainer's development archive, at its `v0.1` tag — a complete, tested implementation of the same contract that proved the model and bought the platform facts.
Nothing in the Swift implementation imports from it, so it lives neither in the working tree nor in this repository's history.
