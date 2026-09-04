#!/bin/bash
# One-paste install for simmer, for people who should not have to know what a
# checkout is:
#
#   curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
#
# A script piped from curl has no path on disk (BASH_SOURCE is unset and
# `dirname ""` is "."), so this script never reads files relative to itself:
# it clones the repository and works from the clone. PLATFORM-FACTS.md, paid for.
#
# Everything lives inside main(), called on the last line. A `curl | bash` that
# is truncated mid-flight — a dropped connection, a proxy cutting the response —
# then executes NOTHING instead of half an installer, because bash cannot call
# a function it has not finished reading.
#
# Quarantine is why this works at all: macOS attaches it to browser-style
# downloads only, never to `git clone` or `curl`, so the locally built,
# ad-hoc-signed bundle runs with no Gatekeeper warning.
set -euo pipefail

REPO="${SIMMER_REPO:-https://github.com/moralesl/simmer}"
# Which commit-ish to install. Empty means "work it out": the newest release
# tag, and `main` only when there are none. Defaulting to `main` meant a
# first-time visitor got whatever landed an hour ago, and pinning the version
# in the README instead would go stale the first time one is cut.
# SIMMER_REF=v1.0.0 still overrides, and SIMMER_REF=main is how you ask for the
# development branch on purpose.
REF="${SIMMER_REF:-}"
# A stable path: ~/.local/bin/simmer symlinks into it and the launchd guard
# names it. Machinery, not a project someone works in.
DIR="${SIMMER_DIR:-$HOME/.local/share/simmer}"
# One file per USER, not one per machine. The shared file held a single
# `<user> ALL=(root) NOPASSWD: …` line, so a second admin running this same
# one-paste install overwrote the first admin's — and their guard then failed
# `sudo -n pmset` on every tick, forever, lid closed, machine held awake.
#
# `#includedir` ignores any filename containing a dot, so a username with one
# cannot have a file here; that falls back to the shared name, which is the
# only thing sudo will read for them.
# A headless install: everything except opening the app. For a machine with no
# session to open a window in — CI, or an install over SSH — where `open` either
# fails or launches into nothing. The notification permission is a click by
# design (PLATFORM-FACTS.md), so this is the one step nothing can stand in for,
# and the script says so rather than pretending the install is complete.
NO_LAUNCH="${SIMMER_NO_LAUNCH:-}"
SUDOERS_USER=$(id -un)
case "$SUDOERS_USER" in
  *[!A-Za-z0-9_-]*) SUDOERS=/etc/sudoers.d/simmer ;;
  *)                SUDOERS=/etc/sudoers.d/simmer-$SUDOERS_USER ;;
esac
SUDOERS_LEGACY=/etc/sudoers.d/simmer

die() { printf 'simmer: %s\n' "$*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

require_macos() {
  [ "$(uname -s)" = Darwin ] ||
    die "simmer is macOS only — it exists to work around macOS lid behaviour."

  # Package.swift declares .macOS(.v14) and Info.plist LSMinimumSystemVersion
  # 14.0, so an older Mac was going to fail — the only question was whether it
  # failed in one sentence here or in a wall of compiler output four minutes in.
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "${major:-0}" -ge 14 ] ||
    die "simmer needs macOS 14 or newer; this is $(sw_vers -productVersion)."
}

# `command -v git` is NOT the check: on a Mac with no developer tools,
# /usr/bin/git EXISTS — a stub that pops Apple's installer dialog and exits
# non-zero. Same for swiftc. Run the thing and look at its exit code.
require_toolchain() {
  if git --version >/dev/null 2>&1 && swiftc --version >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<'NOCLT'
simmer: the Command Line Tools are not (fully) installed yet, and simmer is
compiled here on your machine — that is what makes it run with no warnings,
no certificate and no Apple account.

Run this, click through the installer that appears (a few minutes), then
paste the simmer line again:

  xcode-select --install
NOCLT
  exit 1
}

# The real floor, and the one nothing said out loud: `swift-tools-version: 6.0`
# in Package.swift means Swift 6, which means Xcode or Command Line Tools 16 or
# newer. macOS 14 is necessary and not sufficient — a Mac on 14 with CLT 15
# passes every check above and then dies on:
#
#   error: 'simmer': package 'simmer' is using Swift tools version 6.0.0 but
#          the installed version is 5.10.0
#
# which tells the reader nothing about what to do. This is that same fact, said
# before four minutes of cloning and building. CI hit it too: the macos-14 leg
# defaults to Xcode 15.4 and had been red at manifest load.
require_swift6() {
  local full major
  # Report the whole version, compare on the major. "Swift 5" in the message
  # when `swiftc` says 5.10 reads like the check itself is broken.
  full="$(swiftc --version 2>&1 | sed -n 's/.*Swift version \([0-9][0-9.]*\).*/\1/p' | head -1)"
  major="${full%%.*}"
  [ "${major:-0}" -ge 6 ] && return 0
  cat >&2 <<NOSWIFT
simmer: simmer needs Swift 6, and this machine has Swift ${full:-(unreadable)}.

Swift 6 ships with Xcode 16 / Command Line Tools 16 and newer. Update the
Command Line Tools, then paste the simmer line again:

  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install

If you have several Xcodes installed, pointing the toolchain at a current one
is enough:

  sudo xcode-select -s /Applications/Xcode.app
NOSWIFT
  exit 1
}

# The newest `v*` tag on the remote, or empty. Resolved here rather than at the
# top of the file because it needs a working git, and require_toolchain has run
# by now — on a Mac with no developer tools /usr/bin/git is a stub that pops
# Apple's installer and exits non-zero.
resolve_ref() {
  [ -n "$REF" ] && return 0
  # Newest `v*` tag by version sort. Every tag on this repository is a
  # release of THIS implementation — the bash spike that once held v0.x
  # tags lives in the maintainer's archive, not in this history.
  REF="$(git ls-remote --tags --refs --sort=-v:refname "$REPO" 'v*' 2>/dev/null |
         head -1 | sed 's|.*/||')"
  if [ -n "$REF" ]; then
    echo "  newest release: $REF  (SIMMER_REF=main for the development branch)"
  else
    # No release yet. Say so, rather than silently installing a branch.
    REF=main
    echo "  no release tagged yet — installing from main"
  fi
}

fetch() {
  step "fetching simmer into $DIR"
  resolve_ref
  echo "  ref: $REF"
  if [ -d "$DIR/.git" ]; then
    git -C "$DIR" fetch --quiet origin ||
      die "could not fetch in $DIR — check the network, or the URL $REPO"
    git -C "$DIR" checkout --quiet "$REF" 2>/dev/null ||
      die "no such ref: $REF"
    # A branch needs fast-forwarding; a tag is already exactly what it says.
    git -C "$DIR" merge --ff-only --quiet "origin/$REF" 2>/dev/null || true
    echo "  updated the existing checkout"
  else
    [ -e "$DIR" ] && die "$DIR exists but is not a git checkout. Move it aside and retry."
    mkdir -p "$(dirname "$DIR")"
    git clone --quiet --branch "$REF" "$REPO" "$DIR" ||
      die "clone failed — check the network, the URL $REPO, or the ref $REF"
    echo "  cloned"
  fi
}

build_and_install() {
  step "building and installing (a minute or two)"
  # NOTES=0: this script performs the remaining steps itself right below,
  # so make must not tell the reader to do them.
  make -C "$DIR" install NOTES=0
}

# ── the one privileged step ─────────────────────────────────────────────────
# Only root can flip `pmset -a disablesleep`, and the guard must be able to
# flip it BACK while nobody is at the keyboard. Scope: exactly that, nothing
# else. The check is for simmer's OWN file AND the capability — an installer
# that checks only the capability silently adopts a stranger's grant, reports
# rules it never wrote, and lies during uninstall (PLATFORM-FACTS.md).
#
# The rule text below must stay identical to SudoRule.swift, which is the
# single source the app and `simmer doctor` render from. CI asserts they agree.
sudo_rule() {
  printf '%s\n' \
    "# simmer — flip the sleep switch without a password; nothing else." \
    "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
}

# `sudo -nl <command>` answers whether the command is PERMITTED, not whether it
# is permitted WITHOUT a password — so through the stock `(ALL) ALL` entry it
# exits 0 on every admin Mac, with or without simmer's rule. It reported a
# grant on machines that granted nothing, and a second admin then got no rule
# installed at all. The listing form needs no password on macOS and names the
# entries that actually carry NOPASSWD; SudoRule.grants parses the same text.
have_capability() {
  sudo -nl 2>/dev/null | grep -qE 'NOPASSWD:.*/usr/bin/pmset -a disablesleep 0'
}

install_sudo_rule() {
  step "the sleep switch needs one administrator password"
  if [ -f "$SUDOERS" ] && have_capability; then
    echo "  already in place ($SUDOERS) — nothing to do"
    return 0
  fi
  # An install from before the rule went per-user: the line is in the shared
  # file, it works, and it is this user's own. Without this the next branch
  # would report it as a stranger's grant and install a second, redundant
  # rule — the "adopted somebody else's rule" failure, inverted.
  if [ -f "$SUDOERS_LEGACY" ] && have_capability; then
    echo "  already in place ($SUDOERS_LEGACY, from an earlier version) — nothing to do"
    echo "  Newer installs use one file per user; yours keeps working as it is."
    return 0
  fi
  if [ ! -f "$SUDOERS" ] && [ ! -f "$SUDOERS_LEGACY" ] && have_capability; then
    cat <<'FOREIGN'
  Note: something OTHER than simmer already grants this capability.
  Find it with:  sudo grep -rn disablesleep /etc/sudoers.d/
  simmer installs its own rule anyway, so removing simmer later removes
  exactly what simmer added — and only that.
FOREIGN
  fi
  echo "  This exact rule, and nothing else, goes to $SUDOERS:"
  echo
  sudo_rule | sed 's/^/    /'
  echo
  echo "  sudo will ask for your password (in this terminal), once."

  # Written UNPRIVILEGED, then validated with visudo BEFORE it lands: a
  # malformed file in /etc/sudoers.d can break sudo entirely (PLATFORM-FACTS.md).
  # mktemp paths carry no spaces, so the quoting stays sane.
  local tmp
  tmp="$(mktemp /private/tmp/simmer-sudoers.XXXXXX)"
  sudo_rule > "$tmp"
  if sudo /usr/sbin/visudo -c -f "$tmp" >/dev/null &&
     sudo /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"; then
    rm -f "$tmp"
    echo "  installed $SUDOERS"
    return 0
  fi
  rm -f "$tmp"
  cat <<BYHAND
  Not installed (cancelled, or sudo refused). simmer works interactively
  without the rule, but the background guard cannot hand the switch back
  unattended. \`simmer doctor\` prints the command to install it later.
BYHAND
}

# ── the notification identity ───────────────────────────────────────────────
# Launched via LaunchServices so macOS shows the permission request as a
# banner carrying simmer's own pot icon (PLATFORM-FACTS.md). This launch IS
# the onboarding: the banner is on screen when the next paragraph says Allow.
launch_app() {
  if [ -n "$NO_LAUNCH" ]; then
    step "not launching Simmer (SIMMER_NO_LAUNCH)"
    echo "  Everything else is installed. The menu bar and the notification"
    echo "  permission need a login session: run \`open -a Simmer\` in one."
    return 0
  fi
  step "launching Simmer"
  open "$HOME/Applications/Simmer.app"
}

epilogue() {
  if [ -n "$NO_LAUNCH" ]; then
    cat <<EOF

▸ One thing left, and it needs a session

  \`open -a Simmer\` where someone is logged in, then click **Allow** on the
  notification banner. Until then the CLI and the guard work as documented and
  there are no banners — honestly, and \`simmer notify-test\` says so.
EOF
  else
    cat <<EOF

▸ One thing left, and it is a click

  A notification banner with simmer's pot icon should appear now (or a
  permission request from "Simmer"). Click **Allow**. That is macOS asking
  once, the same as any app, and it is the whole notification setup.

  Nothing appeared? Notifications are optional — the menu bar and the CLI
  always tell the truth. \`simmer notify-test\` shows whether they can arrive.
EOF
  fi
  cat <<EOF

▸ Try it

  simmer 2h -r "big build"    stay awake two hours, lid may close
  simmer                      how much longer, and who else is holding it
  simmer down                 hand your own claim back
  simmer doctor               is everything wired up?

  \$HOME/.local/bin must be on PATH. If \`simmer\` is not found, add:
    export PATH="\$HOME/.local/bin:\$PATH"

  The checkout lives at $DIR
  Is it current?      simmer update      (it prints the command for THIS install)
  Remove it with:     simmer uninstall
EOF
}

main() {
  require_macos
  require_toolchain
  require_swift6
  fetch
  build_and_install
  install_sudo_rule
  launch_app
  epilogue
}

main "$@"
