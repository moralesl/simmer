# Roadmap — decided but not built

Everything here was weighed deliberately; nothing may be implemented casually.
An entry leaves this page by landing **together with its tests** and a CONTRACTS.md row where it changes the surface.

| Next | What | Why it waits |
|---|---|---|
| The Claude Code hook | The harness's own wakefulness becomes a claim like everybody else's (`SessionStart`/`SessionEnd`, owner `agent:claude-<session>`), plus budget context injected into prompts | The flagship integration; wants a stable CLI surface and `AGENTS.md` adoption first |
| Homebrew tap | `brew install moralesl/tap/simmer` — a **formula**, compiled locally, never a cask (below) | After the one-paste path has survived a second machine, and after the guard can be registered without `make` |
| `simmer watch` / `simmer why` | Consumers of `events.jsonl`, which is already written and contracted | Cheap once wanted; nothing may depend on them until contracted |
| `--lock` (lock the screen on take) | Named so no implementation invents behaviour for it | Enters the surface only together with its tests |
| "Keep awake while *this app* runs" | The GUI sibling of `simmer run` — pick from running applications | The most useful thing the app could offer that the CLI cannot, and the largest new surface |
| Stable self-signed signing cert | Would give the bundle one code identity across rebuilds | Only matters if per-executable grant behaviour (PLATFORM-FACTS.md) ever bites colleagues; ad-hoc works today |

**The tap is a formula, and a cask is ruled out.** A cask can only ship a prebuilt artifact — there is no build-from-source cask — and Homebrew Cask quarantines what it downloads, with no `--no-quarantine` left in Homebrew 6.
An ad-hoc signed bundle behind a quarantine flag is the Gatekeeper wall that compiling locally exists to avoid (PLATFORM-FACTS.md), and the only ways around it are a notarised signature, which is deliberately never, or asking every colleague to clear an extended attribute.
So the formula builds both binaries from source and installs the bundle inside its own prefix, with the CLI a symlink to the copy in `Contents/MacOS` — the topology `make install` already produces, which is what keeps the CLI and the app one file and their versions incapable of drifting.
`/Applications/Simmer.app` becomes a symlink to the stable `opt` prefix rather than a second bundle, and whether macOS accepts a symlinked bundle for `SMAppService` login-item registration is the one thing to establish before any of this is written.

**Two things the tap cannot do, and one of them blocks it.** Cask has `uninstall launchctl:` and no install-time counterpart, and a formula may not ask for root — so neither the LaunchAgent nor the sudoers rule can come from `brew`.
The rule is already a human step by design (SECURITY.md) and stays one.
The guard is not: it is generated and bootstrapped inside `make install`, which means `make` is currently the only thing that can produce a working watchdog.
That belongs in the binary — `simmer install-guard`, callable by the Makefile, `bootstrap.sh`, a formula's caveat or a person who copied the app by hand — and it is worth doing whether or not the tap ever lands.

**Landed 2026-08-25 — the Raycast integration**, as a native extension in `integrations/raycast/` rather than the thin shim this page assumed.
The reason it changed shape: a script command prints one line and fires one verb, and the thing worth having in a launcher is the claims list — three actors can hold the lid at once, and the question is usually *whose* claim the 40 minutes is.
That needs a view.
It reads `status --json` only, never the ledger, so `Aggregate.compute` stays the single place that decides what is held.
`simmer render raycast` keeps its job: it is the line under the command title in the root search, refreshed on Raycast's background tick, so the launcher row, the menu bar and any third-party script command all read the same because one place decides the wording.
The extension reads `status --json` for the list and `render raycast` for the glance — machine surface where it needs fields, human surface where it needs a sentence.

Deliberately **not** planned: a SwiftBar plugin (decided 2026-08-23 — the app IS the menu bar; `render swiftbar` stays in the surface only until a contract revision retires it), a daemon, a config file, named presets — the model went a year without wanting them (flags plus three defaults covered every case), force semantics or owner juggling in the menu, and any paid Apple signature, ever.
