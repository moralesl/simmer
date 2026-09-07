# Releasing

A release is a tag, and a tag is the highest-consequence thing this repository can produce.

`bootstrap.sh` resolves the newest `v*` tag and installs **that**, so a tag decides what every new machine gets.
`simmer update` compares every existing install against the same tag, so it also decides what every machine already out there is told.
Neither is undone by the next commit.

Everything below exists so that decision is checked before it is taken, and taken by a person.

**A person still takes it. What they no longer do is type it.**
The decision is one click on a pull request they can read first; the six steps that used to follow it are the machine's.

## What happens when a pull request merges

The version in `Sources/SimmerCore/Version.swift` does **not** move.
It names the last release, and it is what `simmer --version` says, what the bundle carries, and what `simmer update` compares.
Between releases every install is honestly running that release.

The change's notes go under `## Unreleased` in `CHANGELOG.md`, in the pull request that makes the change.
Notes written later are written from `git log` by someone reconstructing decisions they were present for.

`main` re-runs the full matrix on push, and `main` is protected: every leg is a required check, force-pushes are refused, and conversations must be resolved.

And then one more thing happens, which is new.
`.github/workflows/release-pr.yml` reads the `## Unreleased` section it just gained and keeps a pull request current with what releasing it would look like:

| | |
|---|---|
| title | `release: X.Y.Z` |
| branch | `release/next`, rebuilt from `main` on every push and force-pushed |
| contents | one commit: the `CHANGELOG.md` rename and the `SimmerVersion.string` bump |
| body | the notes GitHub would publish, from the same extractor that will publish them |

So the backlog of a release is already written by the time anyone decides to cut one — and so is the release.

When `## Unreleased` is empty there is nothing to release, and no pull request: the workflow says so and stops.

## Cutting one

**Merge the release pull request.**

That is the whole procedure, and it is deliberately something you can do from a phone.
Read the body — those are the notes, and they are the release — then merge.

What follows is the machine's:

1. The merge lands `release: X.Y.Z` on `main`.
2. `release-pr.yml` sees a version in `Version.swift` that no tag names, re-checks the two files on that exact commit, and creates the annotated tag `vX.Y.Z`.
3. It calls `release.yml`, which runs the whole matrix again on the tagged commit, checks that the tag agrees with the compiled-in version, and publishes the GitHub Release from the CHANGELOG section.

Nothing is published until the matrix and the tag check have both passed — the same order as before, on the same commit.

### What decides the number

The rule is § What a version number means, below, and `scripts/release.sh` is that rule.
To see its answer without opening GitHub:

```bash
./scripts/release.sh next-version
```

A **minor** is inferred from where the notes were filed: an entry under `### Machine surface` or `### The test seam` in `## Unreleased` is what says so.
Prose is never read for hints — "adds a `--json` field" and "adds a menu row" are the same sentence to a machine, and guessing wrong in the permissive direction ships a contract change announced as a bug fix.
Anything else is a patch.

### Declaring the number instead

Two places to say it, for two different moments.

**In the CHANGELOG, with the notes.** One line anywhere under `## Unreleased`:

```markdown
## Unreleased

<!-- release: patch -->

### Machine surface
…
```

This is the ordinary one. It travels with the change, in the pull request that makes it, reviewed by whoever reviews the notes — so the release pull request **opens** at the right number instead of opening wrong and being corrected.
It is an HTML comment rather than a visible line for three reasons: it is an instruction to CI and not a note to whoever reads the release; a visible *"released as a patch"* under a heading called **Unreleased** is a claim about something that has not happened; and a `.md` diff on GitHub is raw markdown, so it is perfectly visible exactly where it is reviewed.

The declaration is **consumed** when the section is renamed.
It is an instruction about one release: surviving into the published notes would be a directive to CI in something people read, and surviving into the next `## Unreleased` would be a decision nobody took repeating itself.
`release-check` refuses a release section that still carries one.

**As a label on the release pull request** — `release: major`, `release: minor`, `release: patch`. Exactly one; two is refused rather than chosen between.
This is for afterwards, when the number is already written and somebody disagrees with it, and **it wins**: it is the later decision, taken looking at the release itself.

So the precedence is: **label → declaration in the CHANGELOG → the category rule.** The three words are identical in both places on purpose — one vocabulary, and a person who has seen either has seen both.

A **major** can only ever come from a declaration.
Removing a field, renaming one and changing one's type read exactly like adding one, so nothing can infer it — only a person knows which.
The other two exist because "the rule was too cautious" is not the only reason to overrule it: sometimes it is *we are shipping this as a patch anyway, and we know what that costs*, which is how 0.3.1 went out over a `### Machine surface` entry.

Whichever won says so, on the pull request:

> The number is `0.3.1`: a **patch**, declared in the CHANGELOG, where `docs/RELEASING.md` § What a version number means read this as a **minor**.

A rule with no override gets worked around outside the mechanism, where nothing records who decided or what the rule had said. This records both.

A label added after the branch was written changes the answer, and the branch is not rebuilt until the next push to `main` — so the `release-check` leg re-derives the number *including* label and declaration, and goes red on any mismatch.
That is what makes either of them a mechanism rather than a note, and it is why one reader (`scripts/release.sh`) serves both halves: two readers is how they would come to disagree on the one pull request where it matters.

To recompute immediately rather than waiting for the next push: **Actions → release-pr → Run workflow**, or

```bash
gh workflow run release-pr.yml --ref main -f bump=patch
```

The `bump` input is the same declaration, for a run that has no pull request to label yet; its default, `rule`, means no declaration at all.
For a number no bump can reach — jumping to `0.9.0`, say — there is no input: cut it by hand (§ From a laptop), which is a person at a keyboard, which is where an unusual release belongs.

**Only `main` acts.** Dispatched from any other ref, `release-pr.yml` reports what a release from that ref would be and stops — nothing is pushed, opened, tagged or published.
Without that, a dispatch from a feature branch would have built `release/next` out of *that* branch, and a bumped version on it would have been tagged and published from a commit nobody released.

## When the automatic pull request is wrong

It is a pull request.
Close it, and the next push to `main` opens a fresh one from whatever `## Unreleased` says then.

Do not commit to `release/next` — it is rebuilt from `main` and force-pushed on every push, so anything committed there is gone at the next one.
The way to change what the release says is to change `CHANGELOG.md` on `main`, and the pull request comes back changed.

## What the tag push does

`.github/workflows/release.yml`, in three jobs, and nothing is published until the first two pass:

| job | asks |
|---|---|
| `suites` | the whole test matrix, **by reference** to `test.yml` rather than a second copy of it — six legs, two macOS versions, the CLT-only toolchain, the extension, shellcheck, and the one-paste install |
| `tag` | does the tag name the version the binary reports, and does that version have a CHANGELOG section |
| `publish` | creates the GitHub Release with `make release-notes` as its body |

The `tag` job is the one check that only a tag can make.
A `v0.3.0` tag on a tree that says `0.2.0` is not cosmetic: `bootstrap.sh` installs the tag, the binary reports the other number, and `simmer update` then tells every existing install it is current when it is not — silently, to everybody.

`publish` refuses to overwrite a release that already exists.
A published release is something people have read and linked to; replacing its notes from a re-run would rewrite it under them.
Deleting it first is cheap and is a person's decision: `gh release delete vX.Y.Z`.

**Three ways in, one behaviour.**
A tag pushed by a person still starts it directly.
`release-pr.yml` cannot rely on that — events raised by the workflow token do not create workflow runs, which is a documented rule of GitHub Actions and not a quirk of this repository — so it *calls* `release.yml` instead, in the same run, with the tag as an input.
`workflow_dispatch` with a `tag` input is the third, for re-running a publish by hand.

## From a laptop

The old six steps still work, and `make release-check` is still the gate in front of them:

```bash
make release-check
```

It refuses a dirty tree, a branch other than `main`, a version that is already tagged, a missing or empty CHANGELOG section, and a red suite — then prints the notes GitHub will carry.
The file assertions in it are `scripts/release.sh check`, which is character-for-character what CI's `release-check` leg runs on the pull request: one implementation, so a laptop and a runner cannot answer differently.

It deliberately does not tag anything itself.
It is the same shape `simmer uninstall` uses, for the same reason: an irreversible act that happens rarely, in front of a person who is already at a keyboard, is better as a command they can read first.

To cut one entirely by hand — the path for when the automatic one cannot run, or when you are fixing forward past it:

```bash
./scripts/release.sh next-version          # what the rule says
./scripts/release.sh write X.Y.Z           # both files, together
git commit -am 'release: X.Y.Z'
make release-check
git push origin main                       # CI tags it from here
```

The push is enough: `release-pr.yml` on `main` finds a version with no tag and takes it from there.
Tagging by hand still works too, and still starts `release.yml`:

```bash
git tag -a vX.Y.Z -m 'simmer X.Y.Z'
git push origin vX.Y.Z
```

## Undoing one

Only worth attempting immediately, and it is a race with the installer:

```bash
gh release delete vX.Y.Z --yes
git push --delete origin vX.Y.Z
```

Anyone who ran `bootstrap.sh` in between has that version, and `simmer update` will offer them the newest tag *after* the deletion — which is why the checks are all before the tag and none of them after.
A broken release is fixed forward with a new patch version, not by deleting history.

Deleting the tag alone is not enough to stop it coming back: `main` still carries a version no tag names, so the next push to `main` tags it again.
Fixing forward is the way out, and it is the only one this repository supports.

## What a version number means

- **Machine surfaces are append-only** (`CONTRACTS.md`): exit codes, `--json`, `--machine`, `events.jsonl`.
  Adding a field is a minor.
  Removing one, renaming one, **or changing one's type** is a major.
- Human-facing sentences may be reworded in any release; nothing may parse them.
- A new seam variable is a minor, and it must appear in `CONTRACTS.md` § The test seam in the same change — any implementation of the contract has to honour it.

Those first and third bullets are the two headings the version rule reads: an entry under **`### Machine surface`** or **`### The test seam`** in `## Unreleased` makes the next release a minor.
Writing one there is how the release is told; a machine-surface change filed under `### Added` is a minor that ships as a patch.
That is everything the rule can work out on its own — and § Declaring the number instead is how a person overrules it, in either direction, on the record.

**And what it promises in the other direction: that you can go back.** State is append-only in practice as well as on paper — `format=2` claim files with the same key set since `0.1.0`, and parsers that ignore keys they do not know — so an older binary reads what a newer one wrote.
The exact command per provenance, the two wrinkles below `0.2.0`, and the reason a rollback has to be preceded by `simmer update --auto off` are in `FAQ.md` § A release broke something.
That is what makes "fixed forward with a new patch version" (§ Undoing one) a reasonable thing to ask of someone: they have a way to wait it out.

## What Luis had to switch on once

Two repository settings, neither of which a workflow can set for itself:

- **Allow GitHub Actions to create and approve pull requests.**
  Without it `gh pr create` returns 403 and the release pull request never opens.
  ```bash
  gh api -X PUT repos/moralesl/simmer/actions/permissions/workflow \
    -F default_workflow_permissions=read \
    -F can_approve_pull_request_reviews=true
  ```
  The default token stays read-only; every job that writes asks for exactly what it writes.
- **`release-check` as a required status check on `main`**, beside the six `test.yml` legs.
  It is what stops a `release: major` label from being silently ignored.
