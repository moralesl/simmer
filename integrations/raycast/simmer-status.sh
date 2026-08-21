#!/bin/bash
# Live simmer state, rendered straight into Raycast's root search.
#
# @raycast.schemaVersion 1
# @raycast.title Simmer status
# @raycast.mode inline
# @raycast.refreshTime 10s
# @raycast.packageName Simmer
# @raycast.icon ☕
# @raycast.description Is this Mac being held awake, and for how much longer
#
# inline mode is the whole reason this is a Raycast command rather than an
# Alfred workflow: the answer appears without selecting anything, so "is my Mac
# still awake" costs a keystroke rather than a decision.
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

SIMMER="$(simmer_bin)" || { echo "simmer not installed — github.com/moralesl/simmer"; exit 0; }

state=idle; left_short=""; reason=""; battery=""; min_battery=""; on_battery=0; until_epoch=0
while IFS='=' read -r k v; do
  case "$k" in
    state) state="$v" ;; left_short) left_short="$v" ;; reason) reason="$v" ;;
    battery) battery="$v" ;; min_battery) min_battery="$v" ;;
    on_battery) on_battery="$v" ;; until) until_epoch="$v" ;;
  esac
done < <("$SIMMER" --porcelain 2>/dev/null)

power="${battery}%$([ "$on_battery" = 1 ] && echo " batt" || echo " AC")"
case "$state" in
  active)  echo "☕ ${left_short} left · until $(date -r "$until_epoch" '+%H:%M') · ${reason:-no reason} · $power" ;;
  forever) echo "☕ no deadline · ${reason:-no reason} · $power · floor ${min_battery}%" ;;
  orphan)  echo "⚠️ sleep disabled with no lease — run: simmer down" ;;
  *)       echo "⏾ sleep allowed · $power" ;;
esac
