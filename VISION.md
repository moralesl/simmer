# Vision

Whether a thing belongs in simmer at all.

`docs/ROADMAP.md` says what is decided and not yet built; `docs/CONTRACTS.md` says what is law once it is.
This page comes before both: the test a proposal has to pass to be worth a roadmap row, and the list of things that have already failed it, each with its reason — so the reason is what gets argued with, never the entry.

## The one sentence

**simmer lends a Mac's sleep switch to several actors at once, for a bounded time each, and hands it back by itself.**

Every word is load-bearing.
*Lends*: the switch is never exposed, only leased.
*Several actors*: a person, an agent and a build each hold their own claim, and the machine sleeps when the last one ends.
*Bounded*: a deadline is required, and a human cap clips every claim.
*By itself*: a background watchdog puts the switch where the ledger says, so nothing depends on anyone remembering.

## What fits

A proposal belongs when it does all of these.
One it cannot do is a reason to say no, not a detail to fix later.

1. **It ends by itself.** Every new way to hold the lid arrives with the thing that lets go of it — a deadline, a floor, a process exit, a ceiling that lifts itself at 09:00.
   Open-ended time is allowed only because it reminds every thirty minutes.
2. **It answers to a machine as well as to a person.** An exit code with one meaning per value, `--json` on every verb that has a machine answer, and a refusal of the flag on every verb that does not.
   The caller is often not a human, and a silently ignored flag is indistinguishable from one that worked.
3. **It leaves the switch leased.** Every mutation ends in the one function that reads the ledger and puts the switch where it says.
   A second path to `disablesleep` is the failure the tool exists to prevent, arriving from inside.
4. **It counts, and never owns.** No actor's time at another's expense, by construction rather than by refusal: a claim's id is its owner, so an actor naming itself names nobody else's file.
   A person outranks every agent through the cap and `down --all`; an agent never claims that authority.
5. **It says what it did, and what it did not.** "Clipped by the cap" on a successful claim, "one banner per release" rather than one a day, "the ceiling stays" under every release, "may have slept" rather than "slept".
   Reassurance the tool cannot back is a lie with a delay on it.
6. **It proves itself.** Behaviour lands with tests behind the seam, and a claim about what macOS does is measured and written into `docs/PLATFORM-FACTS.md` before anything is built on it.
   A surface nothing asserts is a surface that will drift.
7. **It costs nothing to trust.** No account, no payment, no certificate, no telemetry, one outbound `HEAD` request that carries a version and nothing else, and a build that compiles on your own machine in about a minute.

## What is resisted

Each of these has been asked for, or would be the obvious next thing, and each stays out for the reason beside it.
An entry moves off this list only when its reason is rewritten here, and never because the entry became easy.

| Resisted | Why |
|---|---|
| A daemon, or any long-running service | The guard is one idempotent tick, run two ways: IOKit events in the app for instant response and a LaunchAgent every thirty seconds as the backstop nobody can quit. A daemon would be a second implementation of the aggregate, and the two would disagree. |
| A config file, named presets | Flags plus three defaults covered every case for a year. A config file is state that decides things nobody can see deciding — the same shape as the switch this tool exists to hide. |
| `--force`, owner juggling, "take over" | The conflict they would resolve cannot occur: one live claim per owner, and no owner can address another's. There is nothing left to force. |
| Ending anyone's work | simmer never kills a command it wrapped, never refuses a release, and heals toward sleep. Stopping is never the thing it stands in the way of, and starting or continuing is never its decision. |
| Assertion-based keep-awake | `caffeinate` and every wrapper over power assertions cannot hold a closed lid on Apple silicon. The reason simmer exists is that the only mechanism that can is a switch with no way back. |
| A second reader of the ledger | Every renderer — the menu bar, the launcher extension, a script — consumes `status --json`, so one place decides what is held. A surface that parses the claim files becomes a second aggregate. |
| Telemetry, analytics, an account | The one outbound request names the newest release and carries a version. Knowing how the tool is used is not worth being a tool that reports on its user. |
| A paid Apple signature, notarisation, a prebuilt download | Compiling locally is what makes the bundle run with no Gatekeeper wall and no quarantine flag. A cask is ruled out for the same reason; a Homebrew formula that builds from source is not. |
| Deciding for the person | The cap is a human instrument alone. The unattended install is off until asked and never runs while a claim is live. A new default that acts on someone's behalf has to name the person who asked for it. |
| A knob for every rule | The cap lifts at the first 09:00 after its own time, the floor defaults to 20%, the warning fires five minutes out. Each is one rule with no special case, and a setting for it would be one more thing to hold in your head — which is the problem being solved. |

## How to use this page

Check a request against both lists before designing anything.
Something that fits none of the seven is asked which of them it serves; something on the second list is answered with its row.
When a row here turns out to be wrong, the fix is a pull request that rewrites the reason, and the discussion is about the reason.
