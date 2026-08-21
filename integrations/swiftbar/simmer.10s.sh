#!/bin/bash
# <xbar.title>simmer</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Luis Morales</xbar.author>
# <xbar.desc>Shows and controls the simmer lease: is this Mac being held awake, and for how much longer.</xbar.desc>
# <xbar.dependencies>bash</xbar.dependencies>
#
# The menu bar is the one channel that cannot be dropped. Notifications go
# through "Script Editor" and vanish silently if that is muted; a lease with no
# visible indicator is exactly the failure mode simmer exists to prevent. So this
# plugin is not decoration -- it is the honest answer to "is my Mac still awake
# right now", available without opening a terminal.
#
# Refresh every 10s comes from the filename. The countdown is therefore up to
# ten seconds stale, which is fine: the guard, not this plugin, enforces the
# deadline.
set -uo pipefail

# Where is simmer? A launcher runs with a minimal PATH, so `command -v` alone is
# not enough, and hardcoding one path is what made this unshareable in the first
# place. SIMMER_BIN wins if set; otherwise the usual install locations are tried.
simmer_bin() {
  if [ -n "${SIMMER_BIN:-}" ] && [ -x "$SIMMER_BIN" ]; then printf '%s' "$SIMMER_BIN"; return 0; fi
  local p
  p="$(command -v simmer 2>/dev/null)" && [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  for p in "$HOME/.local/bin/simmer" /usr/local/bin/simmer /opt/homebrew/bin/simmer \
           "$HOME/workspace/tools/simmer/bin/simmer"; do
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

SIMMER="$(simmer_bin)" || { echo "☕?"; echo "---"; echo "simmer not on PATH"; echo "Install: https://github.com/moralesl/simmer"; exit 0; }

# Parse the porcelain output field by field. No eval: a reason like
# `rm -rf /` is a string, not something to execute.
state=idle; left=0; left_short=""; reason=""; min_battery=""; battery=""
on_battery=0; sleep_disabled=0; until_epoch=0; since=0
while IFS='=' read -r key value; do
  case "$key" in
    state)          state="$value" ;;
    until)          until_epoch="$value" ;;
    left)           left="$value" ;;
    left_short)     left_short="$value" ;;
    reason)         reason="$value" ;;
    min_battery)    min_battery="$value" ;;
    battery)        battery="$value" ;;
    on_battery)     on_battery="$value" ;;
    sleep_disabled) sleep_disabled="$value" ;;
    since)          since="$value" ;;
  esac
done < <("$SIMMER" --porcelain 2>/dev/null)

act() { # <label> <simmer args...> -- a clickable menu entry
  local label="$1"; shift
  local line="$label | bash=\"$SIMMER\" terminal=false refresh=true"
  local i=1
  for arg in "$@"; do line="$line param${i}=\"$arg\""; i=$((i + 1)); done
  echo "$line"
}

power_line() {
  if [ "$on_battery" = 1 ]; then echo "Battery ${battery}% · on battery"
  else echo "Battery ${battery}% · on AC"; fi
}

case "$state" in
  active)
    # Under five minutes the countdown turns orange: the warning notification
    # may not have arrived, this always will.
    if [ "$left" -le 300 ]; then echo "☕ $left_short | sfimage=cup.and.saucer.fill color=orange"
    else                          echo "☕ $left_short | sfimage=cup.and.saucer.fill"; fi
    echo "---"
    echo "Simmering until $(date -r "$until_epoch" '+%H:%M') | sfimage=clock"
    [ -n "$reason" ] && echo "$reason | sfimage=text.quote"
    echo "$(power_line) · floor ${min_battery}% | sfimage=battery.50"
    [ "$sleep_disabled" = 0 ] && echo "⚠️ disablesleep is off — the lid will not hold | color=red"
    echo "---"
    act "Extend 15 minutes"  "+15m"
    act "Extend 1 hour"      "+1h"
    act "Extend 3 hours"     "+3h"
    echo "---"
    act "Release now" "down"
    ;;
  forever)
    echo "☕ ∞ | sfimage=cup.and.saucer.fill color=orange"
    echo "---"
    echo "Simmering with no deadline | sfimage=infinity"
    [ "$since" != 0 ] && echo "since $(date -r "$since" '+%H:%M') | sfimage=clock"
    [ -n "$reason" ] && echo "$reason | sfimage=text.quote"
    echo "$(power_line) · floor ${min_battery}% | sfimage=battery.50"
    echo "---"
    echo "Convert to a deadline"
    act "-- 1 hour from now"  "1h" "--owner" "menubar"
    act "-- 3 hours from now" "3h" "--owner" "menubar"
    echo "---"
    act "Release now" "down"
    ;;
  orphan)
    # disablesleep on, no lease. Loud on purpose: this is the state that
    # empties a battery in a bag, and the guard will fix it within 30 seconds
    # unless it is not running.
    echo "☕ ⚠️ | sfimage=exclamationmark.triangle.fill color=red"
    echo "---"
    echo "Sleep is disabled with no lease | color=red"
    echo "Nobody is scheduled to hand it back. Is the guard running?"
    echo "$(power_line) | sfimage=battery.50"
    echo "---"
    act "Revert now" "down"
    act "Turn it into a 1 hour lease" "1h" "--owner" "menubar"
    echo "Run simmer doctor | bash=\"$SIMMER\" param1=doctor terminal=true"
    ;;
  *)
    echo "⏾ | sfimage=moon.zzz"
    echo "---"
    echo "Sleep allowed | sfimage=moon.zzz"
    echo "$(power_line) | sfimage=battery.50"
    echo "---"
    echo "Stay awake for…"
    act "-- 30 minutes" "30m" "--owner" "menubar"
    act "-- 1 hour"     "1h" "--owner" "menubar"
    act "-- 2 hours"    "2h" "--owner" "menubar"
    act "-- 4 hours"    "4h" "--owner" "menubar"
    act "-- until further notice" "forever" "--owner" "menubar"
    ;;
esac

echo "---"
echo "Log | bash=\"$SIMMER\" param1=log param2=40 terminal=true"
echo "Refresh | refresh=true"
