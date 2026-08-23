#!/bin/bash
# simmer installer. `make install` and `make check` front this; it also runs
# standalone, which is what makes a one-line remote install possible later.
#
# The one step that needs root -- the sudoers rule that lets the guard hand the
# switch back unattended -- is always OFFERED and never taken: the two-line rule
# is printed in full before anything is asked, so what runs as root is exactly
# what was read. How it asks depends on what is there to ask with:
#
#   a terminal on stdin   ->  the familiar sudo password prompt
#   no stdin, but a tty   ->  consent read from /dev/tty, then ONE native macOS
#                             authorisation dialog. This is the `curl | bash`
#                             case, where stdin is the script itself.
#   neither               ->  the command is printed for you to run
#
# SIMMER_ASSUME_NO=1 forces the last branch. That is for automation and tests --
# an installer that can block on an invisible dialog is an installer that hangs
# a CI job.
set -euo pipefail

# Under `curl … | bash` there is no BASH_SOURCE, so dirname yields "." and this
# silently became WHATEVER DIRECTORY THE USER HAPPENED TO BE IN -- after which
# swiftc would compile "$SIMMER_HOME/notifier/main.swift" from a path that is not
# simmer. A wrong answer is worse than no answer, so the guess is checked against
# files only this repo has, and a failure names the fix.
SIMMER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -z "$SIMMER_HOME" ] || [ ! -f "$SIMMER_HOME/bin/simmer" ] || [ ! -f "$SIMMER_HOME/notifier/main.swift" ]; then
  cat >&2 <<'NOREPO'
simmer: this installer needs the repository around it, and cannot find it.

That is what happens when it is piped straight from curl -- a piped script has
no path on disk, so it cannot locate the files it installs.

Use the bootstrap instead, which clones first and then runs this:
  curl -fsSL https://raw.githubusercontent.com/moralesl/simmer/main/bootstrap.sh | bash

Or clone it yourself:
  git clone https://github.com/moralesl/simmer && cd simmer && make install
NOREPO
  exit 2
fi
PREFIX="${PREFIX:-$HOME/.local/bin}"
LABEL=com.github.moralesl.simmer-guard
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
NOTIFIER_APP="$HOME/Applications/Simmer.app"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/simmer"

ok=0; bad=0
say()  { printf '  %s\n' "$*"; }
check() { if eval "$2" >/dev/null 2>&1; then echo "✅ $1"; ok=$((ok+1)); else echo "❌ $1"; bad=$((bad+1)); fi; }


# The notifier bundle: banners with simmer's own name and icon, no certificate,
# no Apple account. Built from source on this machine, ad-hoc signed, registered,
# and launched once so macOS shows its one-time permission banner (which carries
# the pot icon). Recipe and traps: ../../docs/PLATFORM-FACTS.md.
#
# Missing swiftc is fine and said out loud: notifications then post as Script
# Editor via osascript. Homebrew users always have the CLT, so in practice this
# only skips on machines that could not compile anything anyway.
build_notifier() {
  if ! command -v swiftc >/dev/null 2>&1; then
    say "no swift compiler -- notifications will post as Script Editor"
    say "(fix later with: xcode-select --install, then make install again)"
    return 0
  fi
  local first=0; [ -d "$NOTIFIER_APP" ] || first=1
  mkdir -p "$NOTIFIER_APP/Contents/MacOS" "$NOTIFIER_APP/Contents/Resources"
  swiftc -O -o "$NOTIFIER_APP/Contents/MacOS/simmer-notify" "$SIMMER_HOME/notifier/main.swift" || return 1
  cp "$SIMMER_HOME/notifier/Info.plist" "$NOTIFIER_APP/Contents/Info.plist"
  cp "$SIMMER_HOME/assets/icon.icns"    "$NOTIFIER_APP/Contents/Resources/AppIcon.icns"
  codesign --force --deep --sign - "$NOTIFIER_APP" >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$NOTIFIER_APP" >/dev/null 2>&1 || true
  say "notifier built at $NOTIFIER_APP"

  # Only pester for permission when it is genuinely undecided. The request
  # arrives as a banner with the pot icon; clicking Allow is the whole setup.
  if [ "$("$NOTIFIER_APP/Contents/MacOS/simmer-notify" --status 2>/dev/null)" = "notDetermined" ] || [ "$first" = 1 ]; then
    open -a "$NOTIFIER_APP" --args "Simmer" "one-time setup" "Click Allow so simmer can notify you." || true
    echo
    echo "  A notification permission banner should be on screen -- click Allow."
  fi
}

# bootout returns before the job is gone; a bootstrap straight after fails with
# "5: Input/output error" and the service quietly stays down.
reload_agent() {
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || true
  for _ in $(seq 20); do launchctl print "$domain/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
  launchctl bootstrap "$domain" "$AGENT"
}

# The privileged step, asked for the way macOS asks: one native authorisation
# dialog rather than a sudo prompt on a tty that may not exist. Verified to run
# as root from an unsigned, unnotarised context -- no certificate, no Apple
# account (../../docs/PLATFORM-FACTS.md, spike B).
#
# The file has been through `visudo -c` before this runs, and the shell string is
# a fixed command over two fixed paths with no user input anywhere in it.
install_sudoers_via_dialog() {
  local src="$SIMMER_HOME/.build/simmer.sudoers"
  if osascript -e "do shell script \"install -m 440 -o root -g wheel '$src' /etc/sudoers.d/simmer\" with administrator privileges" >/dev/null 2>&1; then
    if sudo -nl /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
      say "sudoers rule installed -- the guard can now release unattended"
    else
      say "rule written, but sudo does not honour it yet."
      say "check with: sudo -nl /usr/bin/pmset -a disablesleep 0"
    fi
  else
    echo "  not installed (cancelled, or the password was wrong). Run it later with:"
    echo "    sudo install -m 440 -o root -g wheel \\"
    echo "      \"$src\" /etc/sudoers.d/simmer"
  fi
}

cmd_install() {
  echo "Installing simmer from $SIMMER_HOME"
  mkdir -p "$PREFIX" "$STATE" "$HOME/Library/LaunchAgents"
  ln -sf "$SIMMER_HOME/bin/simmer" "$PREFIX/simmer"
  say "linked $PREFIX/simmer"

  sed -e "s|__SIMMER__|$SIMMER_HOME|g" -e "s|__HOME__|$HOME|g" \
      "$SIMMER_HOME/launchd/$LABEL.plist" > "$AGENT"
  reload_agent
  say "guard running as $LABEL"

  build_notifier

  # Generated rather than committed, because the committed template must not
  # carry a username: copying someone else's would grant them nothing and you
  # nothing either.
  mkdir -p "$SIMMER_HOME/.build"
  sed "s|__USER__|$(id -un)|g" "$SIMMER_HOME/sudoers.d/simmer" > "$SIMMER_HOME/.build/simmer.sudoers"

  # Check it BEFORE it goes anywhere near /etc/sudoers.d. A malformed file there
  # does not merely fail to grant pmset -- it can break sudo for everything,
  # which on a laptop with no other admin account is a genuinely bad afternoon.
  # visudo -c needs no root to check a file we own.
  if ! visudo -c -f "$SIMMER_HOME/.build/simmer.sudoers" >/dev/null 2>&1; then
    echo "❌ the generated sudo rule does not parse -- refusing to install it." >&2
    echo "   file: $SIMMER_HOME/.build/simmer.sudoers" >&2
    visudo -c -f "$SIMMER_HOME/.build/simmer.sudoers" 2>&1 | sed 's/^/   /' >&2
    return 1
  fi

  echo
  if sudo -nl /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
    say "sudoers rule already in place"
  elif [ -t 0 ]; then
    # Offered, never sneaked: the command is printed in full before the y/N so
    # what runs under sudo is exactly what was read. Declining leaves simmer
    # working interactively; only unattended release needs the rule.
    echo "One step needs your password. It installs this two-line sudo rule so the"
    echo "watchdog can hand the sleep switch back while nobody is at the keyboard:"
    echo
    sed 's/^/    /' "$SIMMER_HOME/.build/simmer.sudoers" | grep -v '^    #'
    echo
    printf "  Install it now with sudo? [y/N] "
    read -r answer
    case "$answer" in
      [yY]*)
        sudo install -m 440 -o root -g wheel "$SIMMER_HOME/.build/simmer.sudoers" /etc/sudoers.d/simmer &&
          say "sudoers rule installed" ||
          echo "  failed -- run it yourself later:
    sudo install -m 440 -o root -g wheel \"$SIMMER_HOME/.build/simmer.sudoers\" /etc/sudoers.d/simmer" ;;
      *)
        echo "  Skipped. Run it later with:"
        echo "    sudo install -m 440 -o root -g wheel \\"
        echo "      \"$SIMMER_HOME/.build/simmer.sudoers\" /etc/sudoers.d/simmer" ;;
    esac
  elif [ "${SIMMER_ASSUME_NO:-0}" != 1 ] && [ -e /dev/tty ]; then
    # No tty on stdin, but a terminal exists -- which is exactly the bootstrap
    # case, where stdin is the script itself. Reading the consent from /dev/tty
    # keeps the "offered, never sneaked" rule instead of falling back to a dead
    # end that a non-technical colleague cannot act on.
    echo "One step needs an administrator password. It installs this two-line sudo"
    echo "rule so the watchdog can hand the sleep switch back with nobody at the"
    echo "keyboard -- without it, simmer works but only while you are logged in:"
    echo
    sed 's/^/    /' "$SIMMER_HOME/.build/simmer.sudoers" | grep -v '^    #'
    echo
    printf "  Install it now? macOS will ask for your password. [y/N] "
    read -r answer < /dev/tty || answer=n
    case "$answer" in
      [yY]*) install_sudoers_via_dialog ;;
      *)
        echo "  Skipped. Run it later with:"
        echo "    sudo install -m 440 -o root -g wheel \\"
        echo "      \"$SIMMER_HOME/.build/simmer.sudoers\" /etc/sudoers.d/simmer" ;;
    esac
  else
    echo "One step needs root, so it is yours to run:"
    echo "  sudo install -m 440 -o root -g wheel \\"
    echo "    \"$SIMMER_HOME/.build/simmer.sudoers\" /etc/sudoers.d/simmer"
  fi
  echo
  echo "Optional, one-time:"
  [ -d /Applications/SwiftBar.app ] &&
    echo "  SwiftBar   ln -sf \"$SIMMER_HOME/integrations/swiftbar/simmer.10s.sh\" <your plugin folder>/"
  [ -d /Applications/Raycast.app ] &&
    echo "  Raycast    Settings → Extensions → Script Commands → Add Directories → $SIMMER_HOME/integrations/raycast"
  [ -d "/Applications/Alfred 5.app" ] &&
    echo "  Alfred     open \"$SIMMER_HOME/integrations/alfred/Simmer.alfredworkflow\"  (needs Powerpack)"
  echo
  echo "Then: simmer doctor"
}

cmd_check() {
  echo "install"
  echo "==================="
  # Only what belongs to installing: whether this checkout is the thing that is
  # actually installed. Everything about the running system -- guard, sudo rule,
  # notifier, state -- is `simmer doctor`, called below rather than repeated
  # here. Two health reports covering the same ground is two reports that drift.
  check "linked into $PREFIX"     "[ -L '$PREFIX/simmer' ]"
  check "link points at this repo" "[ \"\$(readlink '$PREFIX/simmer')\" = '$SIMMER_HOME/bin/simmer' ]"
  check "$PREFIX is on PATH"      "case \":\$PATH:\" in *:$PREFIX:*) true ;; *) false ;; esac"
  check "guard agent installed"   "[ -f '$AGENT' ]"
  check "guard agent up to date"  "diff -q <(sed -e 's|__SIMMER__|$SIMMER_HOME|g' -e 's|__HOME__|$HOME|g' '$SIMMER_HOME/launchd/$LABEL.plist') '$AGENT'"
  echo
  "$SIMMER_HOME/bin/simmer" doctor || bad=$((bad+1))
  echo "==================="
  [ "$bad" -eq 0 ] && echo "All good 🎉" || echo "$bad problem(s) -- see above"
  return "$bad"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT" "$PREFIX/simmer"
  rm -rf "$NOTIFIER_APP"
  echo "Removed the guard and the launcher symlink."
  echo "Left alone on purpose: /etc/sudoers.d/simmer (needs root) and $STATE (your log)."
  echo "  sudo rm /etc/sudoers.d/simmer"
}

# Regenerating every icon consumer from the one SVG: the .icns (for anyone who
# wants it), a PNG for the README, and a PNG for Raycast. One source, so they
# cannot disagree -- which is the point, since they sit next to each other.
#
# Chrome is preferred purely for the alpha channel: QuickLook composites the SVG
# onto white, so the rounded corners come out opaque and the icon shows a white
# box on a dark page. Chrome renders with a transparent background. If Chrome is
# absent we still produce icons, just with white corners, and say so.
cmd_icon() {
  local t chrome png
  t="$(mktemp -d)"
  chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  png="$t/icon.png"

  if [ -x "$chrome" ]; then
    cp "$SIMMER_HOME/assets/icon.svg" "$t/i.svg"
    "$chrome" --headless --disable-gpu --default-background-color=00000000 \
              --window-size=1024,1024 --hide-scrollbars \
              --screenshot="$png" "$t/i.svg" >/dev/null 2>&1
  fi
  if [ ! -f "$png" ]; then
    qlmanage -t -s 1024 -o "$t" "$SIMMER_HOME/assets/icon.svg" >/dev/null 2>&1
    mv "$t/icon.svg.png" "$png" 2>/dev/null || true
    echo "  note: rendered without Chrome, so the corners are opaque white."
  fi
  [ -f "$png" ] || { echo "could not rasterise assets/icon.svg" >&2; return 1; }

  mkdir -p "$t/i.iconset"
  local sz dbl
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$png" --out "$t/i.iconset/icon_${sz}x${sz}.png" >/dev/null
    dbl=$((sz * 2))
    sips -z "$dbl" "$dbl" "$png" --out "$t/i.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  iconutil -c icns "$t/i.iconset" -o "$SIMMER_HOME/assets/icon.icns"
  sips -Z 256 "$png" --out "$SIMMER_HOME/assets/icon-256.png" >/dev/null
  # Raycast wants the image beside the script that names it.
  sips -Z 512 "$png" --out "$SIMMER_HOME/integrations/raycast/simmer.png" >/dev/null
  say "assets/icon.icns, assets/icon-256.png, integrations/raycast/simmer.png"
}

case "${1:-install}" in
  install)   cmd_install ;;
  check)     cmd_check ;;
  uninstall) cmd_uninstall ;;
  icon)      cmd_icon ;;
  *) echo "usage: install.sh [install|check|uninstall|icon]" >&2; exit 2 ;;
esac
