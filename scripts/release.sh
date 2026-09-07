#!/usr/bin/env bash
#
# The release rules, in one place, so CI and a laptop cannot disagree about
# them.
#
# A tag is the highest-consequence thing this repository can produce
# (docs/RELEASING.md), and until now every step of taking one was a sentence
# someone had to remember. These subcommands are those sentences as code:
#
#   next-version   what the next version is, and why — from CHANGELOG.md alone
#   bump-label     what a pull request's labels declare the bump to be
#   declared-bump  what the `## Unreleased` section itself declares
#   write          the two files a release commit changes, changed
#   check          everything that must be true of a release before it is one
#
# Nothing here tags, pushes, or talks to GitHub. Deciding is separable from
# doing, and only the deciding half is worth testing.
set -euo pipefail

CHANGELOG=CHANGELOG.md
VERSION_FILE=Sources/SimmerCore/Version.swift

usage() {
  cat >&2 <<'USAGE'
usage:
  release.sh next-version [--bump major|minor|patch] [--changelog F] [--version-file F]
  release.sh bump-label            # pull request label names on stdin
  release.sh declared-bump [--changelog F]
  release.sh write VERSION [--date YYYY-MM-DD] [--changelog F] [--version-file F]
  release.sh check [--expect-version X.Y.Z] [--released "0.1.0 0.2.0"]
                   [--changelog F] [--version-file F]
USAGE
  exit 2
}

die() { echo "release.sh: $*" >&2; exit 1; }

# The one version string, read the same way the Makefile reads it.
current_version() {
  local v
  v="$(sed -n 's/.*string = "\(.*\)".*/\1/p' "$VERSION_FILE" | head -1)"
  [ -n "$v" ] || die "no version string in $VERSION_FILE"
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) die "$VERSION_FILE says '$v', which is not X.Y.Z" ;;
  esac
  printf '%s\n' "$v"
}

# The body of one `## ` section, without its heading. Used for `## Unreleased`
# when deciding a bump and for `## X.Y.Z — date` when asserting notes exist.
# Same shape as the Makefile's release-notes target, on purpose.
section_body() {
  local want="$1"
  awk -v want="$want" '
    /^## / {
      if (found) exit
      # Everything after "## ", up to a " — date" suffix if there is one.
      h = substr($0, 4)
      sub(/ — .*$/, "", h)
      if (h == want) { found = 1; next }
    }
    found { print }
  ' "$CHANGELOG"
}

blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

# ── the version rule ────────────────────────────────────────────────────────
#
# docs/RELEASING.md § What a version number means, and no more than it says.
#
# A minor is DECLARED, not inferred: writing an entry under one of the two
# headings that name a machine surface is the declaration. Prose under `###
# Added` is not read for hints — "adds a --json field" and "adds a menu row"
# are the same sentence to a machine, and guessing wrong in the permissive
# direction publishes a minor that was really a major.
#
# A major is never inferred at all. Removing a field, renaming one, or
# changing one's type reads exactly like adding one; only a person knows
# which, so a person says so with the `release: major` label.
#
# All three kinds are declarable the same way — `release: major`, `release:
# minor`, `release: patch` — because the reason a person overrules the rule is
# not always "the rule was too cautious". It is sometimes "we are shipping this
# as a patch anyway, and I know what that costs". A rule with no override is a
# rule that gets worked around outside the mechanism, where nothing records who
# decided or what the rule had said.
#
# There are two places to say it, and they are for two different moments:
#
#   `<!-- release: patch -->` under `## Unreleased`   — with the notes, in the
#       pull request that makes the change, reviewed by whoever reviews it.
#       This is the ordinary one. The release pull request then OPENS at the
#       right number, instead of opening wrong and being corrected, which is a
#       poor first thing for a mechanism to do in front of somebody.
#
#   `release: patch` as a label on the release pull request  — afterwards, when
#       the number is already written and somebody disagrees with it.
#
# The label wins, because it is the later decision and the one made looking at
# the release itself. Both are the same three words, deliberately: one
# vocabulary, and a person who has seen either has seen both.
#
# The declaration is CONSUMED when the section is renamed. It is an instruction
# about one release, so surviving into the published notes would be noise, and
# surviving into the next `## Unreleased` would be a decision nobody took
# silently repeating itself.
DECLARATION_PATTERN='^[[:space:]]*<!--[[:space:]]*release:[[:space:]]*([A-Za-z]+)[[:space:]]*-->[[:space:]]*$'
MACHINE_SURFACE_HEADINGS="Machine surface|The test seam"

bump_for_unreleased() {
  local body="$1"
  blank "$body" && { printf 'none\n'; return; }

  # A `### Machine surface` heading with nothing under it is somebody's
  # leftover scaffolding, not a contract change.
  local has_surface
  has_surface="$(printf '%s\n' "$body" | awk -v want="$MACHINE_SURFACE_HEADINGS" '
    BEGIN { split(want, w, "|"); for (i in w) heading[tolower(w[i])] = 1 }
    /^### / { inside = (tolower(substr($0, 5)) in heading); next }
    inside && $0 ~ /[^[:space:]]/ { print "yes"; exit }
  ')"
  [ "$has_surface" = yes ] && { printf 'minor\n'; return; }
  printf 'patch\n'
}

apply_bump() {
  local v="$1" kind="$2" major minor patch
  IFS=. read -r major minor patch <<<"$v"
  case "$kind" in
    major) printf '%d.0.0\n' "$((major + 1))" ;;
    minor) printf '%d.%d.0\n' "$major" "$((minor + 1))" ;;
    patch) printf '%d.%d.%d\n' "$major" "$minor" "$((patch + 1))" ;;
    *) die "unknown bump '$kind'" ;;
  esac
}

# What the `## Unreleased` section declares about its own release, if
# anything. Empty when it says nothing.
#
# `<!-- release: patch -->` rather than a visible line, for three reasons: it
# is an instruction to CI and not a note to whoever reads the release; a
# visible "released as a patch" under a heading called Unreleased is a claim
# about something that has not happened; and a pull request's diff of a `.md`
# file is raw markdown, so it is perfectly visible exactly where it is
# reviewed. The three words match the label's spelling because they are the
# same declaration in two places.
declared_bump() {
  local body kinds count
  body="$(section_body Unreleased)"
  kinds="$(printf '%s\n' "$body" | sed -n -E "s/$DECLARATION_PATTERN/\1/p")"
  [ -n "$kinds" ] || return 0

  count="$(printf '%s\n' "$kinds" | grep -c .)"
  # Two declarations is not a bump to choose between, for the same reason two
  # labels is not.
  [ "$count" -eq 1 ] ||
    die "## Unreleased declares more than one bump ($(printf '%s' "$kinds" | tr '\n' ' ')). Leave exactly one."

  case "$kinds" in
    major|minor|patch) printf '%s\n' "$kinds" ;;
    # A misspelling must not be ignored. Ignoring it means the release goes out
    # at whatever the rule said while somebody believes they declared
    # otherwise, which is the failure this whole mechanism exists to prevent.
    *) die "## Unreleased declares '<!-- release: $kinds -->', and a bump is major, minor or patch" ;;
  esac
}

cmd_declared_bump() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --changelog) CHANGELOG="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  declared_bump
}

cmd_next_version() {
  local declared=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bump) declared="$2"; shift 2 ;;
      --changelog) CHANGELOG="$2"; shift 2 ;;
      --version-file) VERSION_FILE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$declared" in
    ""|major|minor|patch) ;;
    *) die "--bump takes major, minor or patch, not '$declared'" ;;
  esac

  local current body rule kind in_file source
  current="$(current_version)"
  body="$(section_body Unreleased)"
  rule="$(bump_for_unreleased "$body")"
  in_file="$(declared_bump)"

  # Precedence, and the reason for it: the label is the LATER decision, taken
  # looking at the release pull request itself; the CHANGELOG declaration was
  # taken with the notes, before there was a release to look at. Both beat the
  # category rule, which is the only one of the three that guessed.
  kind="$rule"
  source=""
  if [ -n "$in_file" ]; then kind="$in_file"; source=changelog; fi
  if [ -n "$declared" ]; then kind="$declared"; source=label; fi

  # But only over something. Declaring a bump for an empty section is an
  # instruction about a release, not a reason to invent one.
  if [ "$rule" = none ]; then kind=none; source=""; fi

  printf 'current=%s\n' "$current"
  printf 'bump=%s\n' "$kind"
  # What the rule said underneath and who overruled it, so the caller can print
  # both. A number that overrules the CHANGELOG has to say so where somebody
  # reads it, or an override is indistinguishable from the rule agreeing.
  if [ "$kind" != "$rule" ]; then
    printf 'rule_bump=%s\n' "$rule"
    printf 'declared_by=%s\n' "$source"
  fi
  [ "$kind" = none ] || printf 'version=%s\n' "$(apply_bump "$current" "$kind")"
}

# ── what a pull request's labels declare ────────────────────────────────────
#
# Label names on stdin, the declared bump on stdout, nothing at all when none
# of them say anything.
#
# One reader, because two halves of CI ask this question — the job that WRITES
# the number and the check that RE-DERIVES it — and a second implementation is
# how they would come to disagree on the one pull request where it matters.
cmd_bump_label() {
  [ $# -eq 0 ] || usage
  local kinds count
  # `sed -E`, not `\|` alternation: that is a GNU extension, and BSD sed — the
  # one on the maintainer's Mac, where `make release-check` runs — matches it
  # as a literal. It would have worked on every ubuntu runner and silently
  # found no label at home.
  kinds="$(sed -n -E 's/^release: (major|minor|patch)$/\1/p' | sort -u)"
  [ -n "$kinds" ] || return 0

  count="$(printf '%s\n' "$kinds" | grep -c .)"
  # Two of them is not a bump to choose between, it is two people who have not
  # spoken to each other. Refusing is the only answer that does not silently
  # pick one of them and publish it.
  [ "$count" -eq 1 ] ||
    die "the release pull request carries more than one bump label ($(printf '%s' "$kinds" | tr '\n' ' ')). Leave exactly one."
  printf '%s\n' "$kinds"
}

# ── the release commit, written ─────────────────────────────────────────────
#
# Both files, always together. `StructureTests` asserts the compiled-in version
# has a CHANGELOG section, so writing one without the other is a red suite —
# which is the point, and is why this is one subcommand rather than two.
cmd_write() {
  local version="" date=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --date) date="$2"; shift 2 ;;
      --changelog) CHANGELOG="$2"; shift 2 ;;
      --version-file) VERSION_FILE="$2"; shift 2 ;;
      -*) usage ;;
      *) [ -z "$version" ] || usage; version="$1"; shift ;;
    esac
  done
  [ -n "$version" ] || usage
  [ -n "$date" ] || date="$(date -u +%F)"

  grep -q '^## Unreleased' "$CHANGELOG" || die "$CHANGELOG has no '## Unreleased' heading"
  grep -q "^## $version — " "$CHANGELOG" &&
    die "$CHANGELOG already has a '## $version' section"

  # Computed whole, then moved into place. A redirect onto the destination
  # truncates it the moment any stage fails, and a half-written CHANGELOG is a
  # release with half its notes. Same care `make skill` and the ledger take.
  local tmp
  tmp="$(mktemp)"
  # The declaration goes with the rename. It is an instruction about THIS
  # release: leaving it in the published section would put a directive to CI
  # in notes people read, and leaving it in the fresh `## Unreleased` would be
  # a decision nobody took quietly repeating itself at the next release.
  awk -v version="$version" -v date="$date" -v declaration="$DECLARATION_PATTERN" '
    !done && /^## Unreleased[[:space:]]*$/ {
      print "## Unreleased"
      print ""
      print "## " version " — " date
      done = 1
      inside = 1
      next
    }
    inside && /^## / { inside = 0 }
    # The declaration, and the blank line that followed it — otherwise
    # consuming it leaves a doubled blank under every release heading.
    inside && $0 ~ declaration { dropped = 1; next }
    dropped { dropped = 0; if ($0 ~ /^[[:space:]]*$/) next }
    { print }
  ' "$CHANGELOG" > "$tmp"
  mv "$tmp" "$CHANGELOG"

  tmp="$(mktemp)"
  sed "s/\(string = \)\"[^\"]*\"/\1\"$version\"/" "$VERSION_FILE" > "$tmp"
  mv "$tmp" "$VERSION_FILE"

  [ "$(current_version)" = "$version" ] ||
    die "$VERSION_FILE did not take the version — its shape must have changed"
  echo "wrote $version — $date into $CHANGELOG and $VERSION_FILE"
}

# ── what must be true before a version is released ──────────────────────────
#
# `make release-check` minus the parts only a laptop can ask (a clean tree, the
# branch, the suites — CI runs those as their own legs). Everything left is
# about the two files, which is what a pull request can be judged on.
cmd_check() {
  local expect="" released=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --expect-version) expect="$2"; shift 2 ;;
      --released) released="$2"; shift 2 ;;
      --changelog) CHANGELOG="$2"; shift 2 ;;
      --version-file) VERSION_FILE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  local version fail=0
  version="$(current_version)"
  problem() { echo "  ✗ $1" >&2; fail=1; }

  echo "Version.swift says $version"

  grep -q '^## Unreleased' "$CHANGELOG" ||
    problem "$CHANGELOG lost its '## Unreleased' heading — the next change has nowhere to land"

  # Already released: this branch does not move the version, and there is
  # nothing else to ask. Every ordinary pull request lands here.
  if printf ' %s ' "$released" | grep -q " $version "; then
    echo "$version is already released — this branch does not cut one"
    [ "$fail" = 0 ] || exit 1
    echo "ok"
    return
  fi

  echo "$version has no tag — judging this as a release"

  local heading body
  heading="$(grep -m1 "^## $version — " "$CHANGELOG" || true)"
  if [ -z "$heading" ]; then
    problem "$CHANGELOG has no '## $version — <date>' section"
  else
    case "${heading##*— }" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) problem "the $version heading's date is not YYYY-MM-DD: $heading" ;;
    esac
    body="$(section_body "$version")"
    blank "$body" && problem "the $version section in $CHANGELOG is empty — a release with nothing to say"
  fi

  # Unreleased has to sit ABOVE the new section, or the next change lands in
  # the release that already went out.
  local unreleased_at section_at
  unreleased_at="$(grep -n '^## Unreleased' "$CHANGELOG" | head -1 | cut -d: -f1)"
  section_at="$(grep -n "^## $version — " "$CHANGELOG" | head -1 | cut -d: -f1)"
  if [ -n "$unreleased_at" ] && [ -n "$section_at" ] && [ "$unreleased_at" -gt "$section_at" ]; then
    problem "'## Unreleased' is below the $version section — new notes would land inside a published release"
  fi

  # A declaration that survived the rename is a `write` that did not consume
  # it — which would put a directive to CI into the published release notes,
  # and repeat somebody's one-release decision at the next one.
  # `${body:-}` because a missing section leaves it unset, and `set -u` would
  # turn "no notes" into a crash instead of the refusal above.
  if printf '%s\n' "${body:-}" | grep -qE "$DECLARATION_PATTERN"; then
    problem "the $version section still carries a release declaration — it should have been consumed when the section was renamed"
  fi

  if [ -n "$expect" ] && [ "$expect" != "$version" ]; then
    problem "the version rule says this release is $expect, not $version (docs/RELEASING.md § What a version number means)"
  fi

  [ "$fail" = 0 ] || exit 1
  echo "ok"
}

[ $# -gt 0 ] || usage
subcommand="$1"; shift
case "$subcommand" in
  next-version) cmd_next_version "$@" ;;
  bump-label)   cmd_bump_label "$@" ;;
  declared-bump) cmd_declared_bump "$@" ;;
  write)        cmd_write "$@" ;;
  check)        cmd_check "$@" ;;
  *)            usage ;;
esac
