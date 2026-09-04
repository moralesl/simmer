# Releasing

A release is a tag, and a tag is the highest-consequence thing this repository can produce.

`bootstrap.sh` resolves the newest `v*` tag and installs **that**, so a tag decides what every new machine gets.
`simmer update` compares every existing install against the same tag, so it also decides what every machine already out there is told.
Neither is undone by the next commit.

Everything below exists so that decision is checked before it is taken, and taken by a person.

## What happens when a pull request merges

Nothing.
That is the point.

- The version in `Sources/SimmerCore/Version.swift` does **not** move.
  It names the last release, and it is what `simmer --version` says, what the bundle carries, and what `simmer update` compares.
  Between releases every install is honestly running that release.
- The change's notes go under `## Unreleased` in `CHANGELOG.md`, in the pull request that makes the change.
  Notes written later are written from `git log` by someone reconstructing decisions they were present for.
- `main` re-runs the full matrix on push, and `main` is protected: every leg is a required check, force-pushes are refused, and conversations must be resolved.

So the backlog of a release is already written by the time anyone decides to cut one.

## Cutting one

1. `git switch main && git pull`
2. In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z — YYYY-MM-DD` and put a fresh, empty `## Unreleased` above it.
3. Bump `SimmerVersion.string` in `Sources/SimmerCore/Version.swift`.
   **In the same commit as step 2** — `StructureTests` asserts that the compiled-in version has a CHANGELOG section, so the two moving together is enforced rather than remembered.
4. Commit as `release: X.Y.Z`.
5. `make release-check`.
   It refuses a dirty tree, a branch other than `main`, a version that is already tagged, a missing or empty CHANGELOG section, and a red suite — then prints the notes GitHub will carry and the two commands to run.
6. Run them:

   ```bash
   git push origin main
   git tag -a vX.Y.Z -m 'simmer X.Y.Z'
   git push origin vX.Y.Z
   ```

`make release-check` deliberately does not tag anything itself.
It is the same shape `simmer uninstall` uses, for the same reason: an irreversible act that happens rarely, in front of a person who is already at a keyboard, is better as a command they can read first.

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

## Undoing one

Only worth attempting immediately, and it is a race with the installer:

```bash
gh release delete vX.Y.Z --yes
git push --delete origin vX.Y.Z
```

Anyone who ran `bootstrap.sh` in between has that version, and `simmer update` will offer them the newest tag *after* the deletion — which is why the checks are all before the tag and none of them after.
A broken release is fixed forward with a new patch version, not by deleting history.

## What a version number means

- **Machine surfaces are append-only** (`CONTRACTS.md`): exit codes, `--json`, `--machine`, `events.jsonl`.
  Adding a field is a minor.
  Removing one, renaming one, **or changing one's type** is a major.
- Human-facing sentences may be reworded in any release; nothing may parse them.
- A new seam variable is a minor, and it must appear in `CONTRACTS.md` § The test seam in the same change — any implementation of the contract has to honour it.
