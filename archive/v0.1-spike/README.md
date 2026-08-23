# archive/v0.1-spike — the bash spike

This is simmer v0.1, implemented in bash: one script, one LaunchAgent, a directory of claim files, and shims for SwiftBar, Raycast and Alfred.
It is complete, tested and it works.
It is here because v2 is a fresh Swift application, and this is **not** dead code:

- **It is the executable specification.** `docs/CONTRACTS.md` says what must stay true; this is the thing that already does it.
  When the contract is ambiguous, read this.
- **It carries its own differential.** `make diff` in here compares this code against the `v0.0-lease` tag — the single-lease design that came before the claims ledger.
- **It still runs.** `make -C archive/v0.1-spike install`.

Nothing in v1 should import, copy or `source` anything from this directory.
Read it, then write the Swift version from the contract.

## What lives here

```
bin/simmer          the whole implementation (~1900 lines, heavily commented --
                    the reasoning is next to the code, deliberately, because the
                    next reader is an agent with no git history in context)
install.sh          links the binary, starts the guard, builds the notifier,
                    offers the sudoers rule
bootstrap.sh        the one-paste remote install: clones, then hands over
Makefile            install · check · uninstall · icon · workflow
test/               its own suite: 175 assertions + the differential harness
notifier/           ~60 lines of Swift + Info.plist. THE VERIFIED RECIPE for
                    notifications that carry simmer's own name and icon with no
                    certificate and no Apple account. v2 absorbs this into the
                    app; read it before rewriting it.
FOR-AGENTS.md       the agent protocol as v0.1 stated it -- rebuilt for v1
COMPARISON.md       honest comparison with Amphetamine, LidRun, caffeinate
launchd/            the guard's LaunchAgent template
sudoers.d/simmer    the two-line passwordless pmset rule, with its reasoning
integrations/       SwiftBar · Raycast · Alfred. Shims of a dozen lines each --
                    the core renders every surface (`simmer render <surface>`),
                    so these carry only each host's metadata and a resolver.
README-USAGE.md     v1's own user-facing README: install, usage, menu bar setup
ARCHITECTURE.md     why it is shaped this way. Much of it still applies to v1.
AGENTS.md           how to work on it, including the bash 3.2 traps
CHANGELOG.md        1.0.0 (single lease) and 2.0.0-dev (the claims ledger)
```

## Version numbers in here are stale, on purpose

The code calls itself `1.0.0` and `2.0.0-dev`.
The project renumbered afterwards and this whole directory is **v0.1**; the Swift application is v1.
Frozen code was left alone rather than churned to match.

Two tags matter:

- **`v0.1`** — this, the claims ledger implemented in bash.
  Landing the model change before the language change was deliberate: a later divergence between this and a Swift build would then be attributable to Swift and not to the model.
  That plan was dropped in favour of a clean rewrite, but the sequencing still bought a fully specified model.
- **`v0.0-lease`** — the older single-lease design, with owner refusals and `--force`.
  What `make diff` in here compares against; every deliberate difference from it is recorded in `docs/CONTRACTS.md` under D1.

## Installing and removing it

```bash
make -C archive/v0.1-spike install   # links ~/.local/bin/simmer, starts the guard,
                                     # offers the sudo rule
make -C archive/v0.1-spike check     # health report; expected to be fully green
make -C archive/v0.1-spike test      # 175 assertions, hermetic
make -C archive/v0.1-spike uninstall # removes the guard and the symlink
```

Two cautions, both learned the hard way:

1. **`make uninstall` deletes `~/Applications/Simmer.app`.** That bundle is the *notification identity*, not v1 code, and macOS caches permission verdicts per bundle id forever.
   If the intent is to stop using this implementation, boot out the agent and remove the symlink by hand and leave the bundle alone.
2. **Never move this directory while the guard is installed.** The LaunchAgent names `bin/simmer` by absolute path.
   A guard whose program has moved is the exact trap simmer exists to prevent: nothing would hand the switch back.
   Uninstall first, then move.
