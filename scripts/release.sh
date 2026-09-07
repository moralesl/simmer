#!/usr/bin/env bash
#
# The release rules, in one place, so CI and a laptop cannot disagree about
# them.
#
# A tag is the highest-consequence thing this repository can produce
# (docs/RELEASING.md), and until now every step of taking one was a sentence
# someone had to remember. These three subcommands are those sentences as code:
#
#   next-version   what the next version is, and why — from CHANGELOG.md alone
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
  release.sh next-version [--major] [--changelog F] [--version-file F]
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

cmd_next_version() {
  local want_major=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --major) want_major=yes; shift ;;
      --changelog) CHANGELOG="$2"; shift 2 ;;
      --version-file) VERSION_FILE="$2"; shift 2 ;;
      *) usage ;;
    esac
  done

  local current body kind
  current="$(current_version)"
  body="$(section_body Unreleased)"
  kind="$(bump_for_unreleased "$body")"

  # The label decides against a rule that cannot see removals, so it wins —
  # but only over something. A major of an empty section is still nothing.
  [ "$want_major" = yes ] && [ "$kind" != none ] && kind=major

  printf 'current=%s\n' "$current"
  printf 'bump=%s\n' "$kind"
  [ "$kind" = none ] || printf 'version=%s\n' "$(apply_bump "$current" "$kind")"
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
  awk -v version="$version" -v date="$date" '
    !done && /^## Unreleased[[:space:]]*$/ {
      print "## Unreleased"
      print ""
      print "## " version " — " date
      done = 1
      next
    }
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
  write)        cmd_write "$@" ;;
  check)        cmd_check "$@" ;;
  *)            usage ;;
esac
