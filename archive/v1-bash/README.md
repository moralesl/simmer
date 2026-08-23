# archive/v1-bash — the previous implementation

This is simmer implemented in bash: one script, one LaunchAgent, a directory of claim files, and shims for SwiftBar, Raycast and Alfred.
It is complete, tested and it works.
It is here because v2 is a fresh Swift application, and this is **not** dead code:

- **It is the executable specification.** `docs/CONTRACTS.md` says what must stay true; this is the thing that already does it.
  When the contract is ambiguous, read this.
- **It is the differential reference.** `make diff` at the repository root compares a candidate binary against the `v1.0.0` tag — which is this code.
- **It still runs.** `cd archive/v1-bash && make install`.

Nothing in v2 should import, copy or `source` anything from this directory.
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
notifier/           ~60 lines of Swift + Info.plist. THE VERIFIED RECIPE for
                    notifications that carry simmer's own name and icon with no
                    certificate and no Apple account. v2 absorbs this into the
                    app; read it before rewriting it.
launchd/            the guard's LaunchAgent template
sudoers.d/simmer    the two-line passwordless pmset rule, with its reasoning
integrations/       SwiftBar · Raycast · Alfred. Shims of a dozen lines each --
                    the core renders every surface (`simmer render <surface>`),
                    so these carry only each host's metadata and a resolver.
README-USAGE.md     v1's own user-facing README: install, usage, menu bar setup
ARCHITECTURE.md     why it is shaped this way. Much of it still applies to v2.
AGENTS.md           how to work on it, including the bash 3.2 traps
CHANGELOG.md        1.0.0 (single lease) and 2.0.0-dev (the claims ledger)
```

## Which version is this, exactly

`2.0.0-dev`: the **v2 contract** — the claims ledger, the cap, human primacy, `--require-ac`, the pre-floor warning, `SIMMER_FAKE_NOW` — implemented in bash.
That sequencing was deliberate.
Landing the model change before the language change means a later divergence between this and the Swift build is attributable to Swift, and not to the model.

`v1.0.0` (tagged, and branch `v1`) is the older single-lease design.
That tag is what `make diff` compares against, and every deliberate difference from it is recorded in `docs/CONTRACTS.md` under D1.

## Installing and removing it

```bash
cd archive/v1-bash
make install       # links ~/.local/bin/simmer, starts the guard, offers the sudo rule
make check         # health report; expected to be fully green
make uninstall     # removes the guard and the symlink
```

Two cautions, both learned the hard way:

1. **`make uninstall` deletes `~/Applications/Simmer.app`.** That bundle is the *notification identity*, not v1 code, and macOS caches permission verdicts per bundle id forever.
   If the intent is to stop using this implementation, boot out the agent and remove the symlink by hand and leave the bundle alone.
2. **Never move this directory while the guard is installed.** The LaunchAgent names `bin/simmer` by absolute path.
   A guard whose program has moved is the exact trap simmer exists to prevent: nothing would hand the switch back.
   Uninstall first, then move.
