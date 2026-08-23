#!/bin/bash
# One-paste install for simmer, for people who should not have to know what a
# checkout is:
#
#   curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
#
# Why this file exists separately from install.sh. A script piped from curl has
# no path on disk, so install.sh cannot find the files it installs -- it now
# detects that and says so instead of silently reading whatever directory you
# happened to be standing in. This script is the missing first half: it gets the
# repository onto the disk, then hands over.
#
# Quarantine is the reason this works at all. macOS attaches the quarantine
# attribute to *browser-style downloads*, not to `git clone` or `curl`, so a
# locally built, ad-hoc-signed bundle fetched this way runs with no Gatekeeper
# warning at all. A .dmg or a zip pulled from a browser would hit "unidentified
# developer" -- which is precisely why simmer is never distributed that way.
set -euo pipefail

REPO="${SIMMER_REPO:-https://github.com/moralesl/simmer}"
# A stable path, because ~/.local/bin/simmer is a symlink into it and the
# launchd guard names it too -- move the checkout later and both break. Not the
# home directory root: this is machinery, not a project someone works in.
DIR="${SIMMER_DIR:-$HOME/.local/share/simmer}"

die() { printf 'simmer: %s\n' "$*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "simmer is macOS only -- it exists to work around macOS lid behaviour."

# The Command Line Tools give us git AND swiftc. swiftc is what compiles the
# notifier, which is what makes banners carry simmer's own name and icon instead
# of arriving as "Script Editor". Missing it is survivable; missing git is not.
#
# `command -v git` is NOT the check, and this is the trap the whole paragraph
# exists for: on a Mac with no developer tools, /usr/bin/git still EXISTS. It is
# a stub that pops Apple's "install the command line developer tools" dialog and
# exits non-zero. So `command -v` says yes on exactly the machines where git does
# not work -- a non-technical colleague's most likely starting state. Run it and
# see, rather than asking whether the name resolves.
if ! git --version >/dev/null 2>&1; then
  cat >&2 <<'NOGIT'
simmer: git does not work here yet, so there is nothing to clone with.

On a fresh Mac that means Apple's Command Line Tools are not installed. The file
/usr/bin/git exists anyway -- it is a placeholder that only offers the installer.

Run this, click through the installer that appears, then paste the simmer line
again:

  xcode-select --install
NOGIT
  exit 1
fi

# CLT present but swiftc missing is unusual -- a partial install, or a full Xcode
# whose developer directory was switched away. Survivable, so it is a note.
if ! swiftc --version >/dev/null 2>&1; then
  step "no Swift compiler found"
  cat <<'NOSWIFT'
  simmer will still install and work. What you lose is its own notification
  identity: banners will arrive as "Script Editor" rather than as Simmer with
  the pot icon, because that bundle is compiled here on your machine.

  To get it, run `xcode-select --install` and then this installer again.
NOSWIFT
fi

step "fetching simmer into $DIR"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only --quiet || die "could not update $DIR -- it has local changes. Move it aside and retry."
  echo "  updated an existing checkout"
else
  [ -e "$DIR" ] && die "$DIR exists but is not a git checkout. Move it aside and retry."
  mkdir -p "$(dirname "$DIR")"
  git clone --quiet "$REPO" "$DIR" || die "clone failed -- check the network, or the URL $REPO"
  echo "  cloned"
fi

# Someone who already had simmer from a different checkout would end up with a
# symlink pointing at the old one and no clue why edits do nothing. Say it now.
existing="$(command -v simmer 2>/dev/null || true)"
if [ -n "$existing" ] && [ -L "$existing" ]; then
  target="$(readlink "$existing")"
  case "$target" in
    "$DIR"/*) : ;;
    *) step "note: an existing simmer points at $target"
       echo "  This install will repoint it at $DIR." ;;
  esac
fi

step "installing"
# install.sh asks for the administrator password through a native macOS dialog
# when there is no terminal on stdin -- which is exactly this case, since stdin
# here is the script itself. It asks first, and shows the two-line sudo rule
# before asking.
"$DIR/install.sh" install

cat <<EOF

▸ One thing left, and it is a click

  A notification banner carrying simmer's own pot icon should have appeared, or
  will shortly. Click **Allow** on it. That is macOS asking permission once, the
  same as any app, and it is the whole notification setup.

  Nothing appeared? Notifications are optional -- the menu bar and the CLI always
  tell the truth. \`simmer notify-test\` fires one through every channel so you
  can see which your Mac shows.

▸ Try it

  simmer 2h -r "big build"    stay awake two hours, lid may close
  simmer                      how much longer, and who else is holding it
  simmer down                 hand your own claim back
  simmer doctor               is everything wired up?

  \`\$HOME/.local/bin\` must be on your PATH. If \`simmer\` is not found, add:
    export PATH="\$HOME/.local/bin:\$PATH"

  The checkout lives at $DIR -- \`git -C $DIR pull && make -C $DIR install\` updates it.
EOF
