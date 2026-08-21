#!/bin/bash
# simmer installer. `make install` and `make check` front this; it also runs
# standalone, which is what makes a one-line remote install possible later.
#
# Nothing here asks for a password. The one step that needs root -- the sudoers
# rule that lets the guard hand the switch back unattended -- is printed for you
# to run. An installer that sudos is an installer nobody can audit in a hurry.
set -euo pipefail

SIMMER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local/bin}"
LABEL=com.github.moralesl.simmer-guard
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$HOME/Applications/Simmer.app"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/simmer"

ok=0; bad=0
say()  { printf '  %s\n' "$*"; }
check() { if eval "$2" >/dev/null 2>&1; then echo "✅ $1"; ok=$((ok+1)); else echo "❌ $1"; bad=$((bad+1)); fi; }

# The notification's name and icon come from the bundle that posts it, and from
# nothing else. That is the whole reason this app exists: a 20-line AppleScript
# applet so banners say "Simmer" with simmer's own logo, instead of arriving as
# Script Editor with a quill.
build_app() {
  mkdir -p "$HOME/Applications"
  rm -rf "$APP"
  osacompile -o "$APP" "$SIMMER_HOME/assets/notifier.applescript"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.github.moralesl.simmer" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.github.moralesl.simmer" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Simmer" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Simmer" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$APP/Contents/Info.plist" 2>/dev/null || true
  cp "$SIMMER_HOME/assets/icon.icns" "$APP/Contents/Resources/applet.icns"
  # A version, so LaunchServices sees a *different* bundle than the one whose
  # icon it cached. Without this a rebuilt app keeps showing the old graphic in
  # notifications no matter what is in Resources.
  local v; v="$(cd "$SIMMER_HOME" && git rev-list --count HEAD 2>/dev/null || echo 1)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.$v" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0.$v" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $v" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $v" "$APP/Contents/Info.plist"
  # Ad-hoc signature: the bundle changed after osacompile signed it, and macOS
  # will refuse to launch a bundle whose signature no longer matches.
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  touch "$APP"
  # Tell LaunchServices and Notification Center to look again. Both cache icons
  # per bundle id, which is why a corrected icon otherwise never shows up.
  local ls_reg=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [ -x "$ls_reg" ] && "$ls_reg" -f "$APP" >/dev/null 2>&1 || true
  killall NotificationCenter >/dev/null 2>&1 || true
}

# bootout returns before the job is gone; a bootstrap straight after fails with
# "5: Input/output error" and the service quietly stays down.
reload_agent() {
  local domain="gui/$(id -u)"
  launchctl bootout "$domain/$LABEL" 2>/dev/null || true
  for _ in $(seq 20); do launchctl print "$domain/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
  launchctl bootstrap "$domain" "$AGENT"
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

  build_app
  say "notifier built at $APP"

  # Generated rather than committed, because the committed template must not
  # carry a username: copying someone else's would grant them nothing and you
  # nothing either.
  mkdir -p "$SIMMER_HOME/.build"
  sed "s|__USER__|$(id -un)|g" "$SIMMER_HOME/sudoers.d/simmer" > "$SIMMER_HOME/.build/simmer.sudoers"

  echo
  echo "One step needs root, so it is yours to run:"
  echo "  sudo install -m 440 -o root -g wheel \\"
  echo "    \"$SIMMER_HOME/.build/simmer.sudoers\" /etc/sudoers.d/simmer"
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
  rm -rf "$APP"
  echo "Removed the guard, the launcher symlink and the notifier."
  echo "Left alone on purpose: /etc/sudoers.d/simmer (needs root) and $STATE (your log)."
  echo "  sudo rm /etc/sudoers.d/simmer"
}

# Regenerating every icon consumer from the one SVG: the .icns for the notifier
# app, a PNG for the README, and a PNG for Raycast. One source, so they cannot
# disagree -- which is the whole point, since they sit next to each other.
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
