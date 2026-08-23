# Roadmap — decided but not built

Everything here was weighed deliberately; nothing may be implemented casually.
An entry leaves this page by landing **together with its tests** and a CONTRACTS.md row where it changes the surface.

| Next | What | Why it waits |
|---|---|---|
| Raycast / Alfred shims | Thin launchers over `simmer render <surface>`, which is already in the core and tested | First release feedback decides the shape |
| The Claude Code hook | The harness's own wakefulness becomes a claim like everybody else's (`SessionStart`/`SessionEnd`, owner `agent:claude-<session>`), plus budget context injected into prompts | The flagship integration; wants a stable CLI surface and `docs/FOR-AGENTS.md` adoption first |
| Homebrew tap | `brew install moralesl/tap/simmer` — brew guarantees the CLT, so the formula compiles locally | After the one-paste path has survived a second machine |
| `simmer watch` / `simmer why` | Consumers of `events.jsonl`, which is already written and contracted | Cheap once wanted; nothing may depend on them until contracted |
| `--lock` (lock the screen on take) | Named so no implementation invents behaviour for it | Enters the surface only together with its tests |
| "Keep awake while *this app* runs" | The GUI sibling of `simmer run` — pick from running applications | The most useful thing the app could offer that the CLI cannot, and the largest new surface |
| Stable self-signed signing cert | Would give the bundle one code identity across rebuilds | Only matters if per-executable grant behaviour (PLATFORM-FACTS.md) ever bites colleagues; ad-hoc works today |

Deliberately **not** planned: a SwiftBar plugin (decided 2026-08-23 — the app IS the menu bar; `render swiftbar` stays in the surface only until a contract revision retires it), a daemon, a config file, named presets — the model went a year without wanting them (flags plus three defaults covered every case), force semantics or owner juggling in the menu, and any paid Apple signature, ever.
