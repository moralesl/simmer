# Working on simmer

For *using* simmer as an agent, read [docs/FOR-AGENTS.md](docs/FOR-AGENTS.md).
This page is about changing it.

## Shape

One bash script (`bin/simmer`), one LaunchAgent template, one state file, and front-ends that all shell out to the script.
Nothing else.
The thing being guarded can flatten a battery, so the code guarding it should fit in your head.
[ARCHITECTURE.md](ARCHITECTURE.md) has the diagram and the contracts.

## Constraints that are not negotiable

- **`/bin/bash`, which is 3.2 on macOS.** No `${var,,}`, no associative arrays, no `mapfile`.
  A LaunchAgent must not depend on a Homebrew shell.
  CI asserts this by running under `/bin/bash` explicitly.
- **The guard uses `sudo -n` and nothing else.** A watchdog that can prompt for a password is a watchdog that hangs while the machine stays awake.
- **`simmer status --machine` and `budget`'s exit codes are public contracts.** The menu bar, the launchers and other people's scripts read them.
  `format=1` in the lease exists so a shape change is detectable; bump it if you change it.

## Before you commit

```bash
make test     # the hermetic suite: no sudo, no real power state touched
make check    # is this checkout what is actually installed
bash -n bin/simmer
```

The suite substitutes power state through `SIMMER_FAKE_PMSET` and `SIMMER_FAKE_BATTERY`.
Keep every new power read behind those four functions — otherwise the branch you add becomes untestable, which in practice means untested.

Test the failure case, not the happy path.
Most bugs found here were found that way: `shift` under `set -e`, `${var,,}` on bash 3.2, `pipefail` turning a correct refusal into a failed assertion, an applet that cannot own its own notification identity.

## Two things that look wrong and are not

- The menu bar uses SF Symbols rather than the app artwork — monochrome and light/dark-aware is correct up there.
- Notifications post through SwiftBar when it is running, otherwise as "Script Editor".
  Owning the icon needs a signed app bundle; an AppleScript applet does not inherit its own identity.
  See the comment above `notify()`.
