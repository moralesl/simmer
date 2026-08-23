#!/bin/bash
# One-paste install for simmer, for people who should not have to know what a
# checkout is:
#
#   curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash
#
# A script piped from curl has no path on disk (BASH_SOURCE is unset and
# `dirname ""` is "."), so this script never reads files relative to itself:
# it clones the repository and works from the clone. LEARNINGS.md, paid for.
#
# Quarantine is why this works at all: macOS attaches it to browser-style
# downloads only, never to `git clone` or `curl`, so the locally built,
# ad-hoc-signed bundle runs with no Gatekeeper warning.
set -euo pipefail

REPO="${SIMMER_REPO:-https://github.com/moralesl/simmer}"
# A stable path: ~/.local/bin/simmer symlinks into it and the launchd guard
# names it. Machinery, not a project someone works in.
DIR="${SIMMER_DIR:-$HOME/.local/share/simmer}"
SUDOERS=/etc/sudoers.d/simmer

die() { printf 'simmer: %s\n' "$*" >&2; exit 1; }
step() { printf '\n▸ %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "simmer is macOS only — it exists to work around macOS lid behaviour."

# `command -v git` is NOT the check: on a Mac with no developer tools,
# /usr/bin/git EXISTS — a stub that pops Apple's installer dialog and exits
# non-zero. Same for swiftc. Run the thing and look at its exit code.
if ! git --version >/dev/null 2>&1 || ! swiftc --version >/dev/null 2>&1; then
  cat >&2 <<'NOCLT'
simmer: the Command Line Tools are not (fully) installed yet, and simmer is
compiled here on your machine — that is what makes it run with no warnings,
no certificate and no Apple account.

Run this, click through the installer that appears (a few minutes), then
paste the simmer line again:

  xcode-select --install
NOCLT
  exit 1
fi

step "fetching simmer into $DIR"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only --quiet || die "could not update $DIR — it has local changes. Move it aside and retry."
  echo "  updated the existing checkout"
else
  [ -e "$DIR" ] && die "$DIR exists but is not a git checkout. Move it aside and retry."
  mkdir -p "$(dirname "$DIR")"
  git clone --quiet "$REPO" "$DIR" || die "clone failed — check the network, or the URL $REPO"
  echo "  cloned"
fi

step "building and installing (a minute or two)"
# NOTES=0: this script performs the two remaining steps itself right below,
# so make must not tell the reader to do them.
make -C "$DIR" install NOTES=0

# ── the one privileged step ─────────────────────────────────────────────────
# Only root can flip `pmset -a disablesleep`, and the guard must be able to
# flip it BACK while nobody is at the keyboard. Scope: exactly that, nothing
# else. The check is for simmer's OWN file AND the capability — an installer
# that checks only the capability silently adopts a stranger's grant, reports
# rules it never wrote, and lies during uninstall (LEARNINGS.md).
RULE="# simmer — flip the sleep switch without a password; nothing else.
$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"

have_capability() { sudo -nl /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; }

step "the sleep switch needs one administrator password"
if [ -f "$SUDOERS" ] && have_capability; then
  echo "  already in place ($SUDOERS) — nothing to do"
else
  if [ ! -f "$SUDOERS" ] && have_capability; then
    cat <<'FOREIGN'
  Note: something OTHER than simmer already grants this capability.
  Find it with:  sudo grep -rn disablesleep /etc/sudoers.d/
  simmer installs its own rule anyway, so removing simmer later removes
  exactly what simmer added — and only that.
FOREIGN
  fi
  echo "  This exact rule, and nothing else, goes to $SUDOERS:"
  echo
  printf '%s\n' "$RULE" | sed 's/^/    /'
  echo
  echo "  macOS will now ask for your password in a normal dialog."
  # The rule file is written UNPRIVILEGED, then the privileged step only
  # validates and installs it — validated with visudo BEFORE it lands,
  # because a malformed file in /etc/sudoers.d can break sudo entirely
  # (LEARNINGS.md). mktemp paths carry no spaces, so the quoting stays sane.
  tmp="$(mktemp /private/tmp/simmer-sudoers.XXXXXX)"
  printf '%s\n' "$RULE" > "$tmp"
  if ! osascript -e "do shell script \"/usr/sbin/visudo -c -f $tmp >/dev/null && /usr/bin/install -m 0440 -o root -g wheel $tmp $SUDOERS && /bin/rm -f $tmp\" with administrator privileges" \
      >/dev/null 2>&1; then
    rm -f "$tmp"
    cat <<BYHAND
  The dialog was cancelled (or failed). simmer works interactively without the
  rule, but the background guard cannot hand the switch back unattended.
  Install it later by pasting (the rule is exactly the two lines shown above):

    printf '%s\n' '$RULE' | sudo tee $SUDOERS >/dev/null && sudo chmod 0440 $SUDOERS && sudo visudo -c
BYHAND
  fi
fi

# ── the notification identity ───────────────────────────────────────────────
# Launched via LaunchServices so macOS shows the permission request as a
# banner carrying simmer's own pot icon (PLATFORM-FACTS.md). This launch IS
# the onboarding: the banner is on screen when the next paragraph says Allow.
step "launching Simmer"
open "$HOME/Applications/Simmer.app"

cat <<EOF

▸ One thing left, and it is a click

  A notification banner with simmer's pot icon should appear now (or a
  permission request from "Simmer"). Click **Allow**. That is macOS asking
  once, the same as any app, and it is the whole notification setup.

  Nothing appeared? Notifications are optional — the menu bar and the CLI
  always tell the truth. \`simmer notify-test\` shows which channels work.

▸ Try it

  simmer 2h -r "big build"    stay awake two hours, lid may close
  simmer                      how much longer, and who else is holding it
  simmer down                 hand your own claim back
  simmer doctor               is everything wired up?

  \$HOME/.local/bin must be on PATH. If \`simmer\` is not found, add:
    export PATH="\$HOME/.local/bin:\$PATH"

  The checkout lives at $DIR
  Update later with:  curl -fsSL ${REPO}/raw/main/bootstrap.sh | bash
EOF
