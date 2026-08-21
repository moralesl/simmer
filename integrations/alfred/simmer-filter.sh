#!/bin/bash
# Alfred Script Filter for `simmer` -- current state plus the actions that make
# sense in that state.
#
# The workflow in Alfred is a thin shim that calls this file in the repo, rather
# than carrying a copy of it. That way editing the repo takes effect on the next
# keystroke, with no re-import: Alfred's own copy of a workflow script is a fork
# that silently drifts.
#
# Alfred filters nothing here (alfredfiltersresults=false). It cannot: the first
# item is generated *from* the query, so that typing `simmer 90m` offers exactly
# ninety minutes rather than the nearest preset.
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

SIMMER="$(simmer_bin)" || SIMMER=""
QUERY="${1:-}"

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

items=()
item() { # <title> <subtitle> <arg|""> <icon-name>
  local valid=true
  [ -z "$3" ] && valid=false
  items+=("$(printf '{"title":"%s","subtitle":"%s","arg":"%s","valid":%s,"icon":{"path":"%s"}}' \
    "$(esc "$1")" "$(esc "$2")" "$(esc "$3")" "$valid" "$4")")
}

# Alfred has no icon set of its own here; the system ones are always present and
# do not need shipping with the workflow.
ICON_ON=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns
ICON_OFF=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SleepFolderIcon.icns
ICON_WARN=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertCautionIcon.icns

if [ -z "$SIMMER" ] || [ ! -x "$SIMMER" ]; then
  item "simmer is not installed" "Install it from github.com/moralesl/simmer" "" "$ICON_WARN"
  printf '{"items":[%s]}\n' "$(IFS=,; echo "${items[*]}")"
  exit 0
fi

state=idle; left=0; left_short=""; reason=""; min_battery=""; battery=""
on_battery=0; sleep_disabled=1; until_epoch=0; since=0
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

power="battery ${battery}%$([ "$on_battery" = 1 ] && echo ", on battery" || echo ", on AC")"

# A typed duration wins the top slot: it is the only thing the presets cannot do.
duration_query=""
if [[ "$QUERY" =~ ^\+?[0-9]+[hms]?[a-z0-9]*$ ]] || [[ "$QUERY" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
  duration_query="$QUERY"
fi

case "$state" in
  active)
    item "Simmering until $(date -r "$until_epoch" '+%H:%M') · $left_short left" \
         "${reason:-no reason given} — $power, floor ${min_battery}%" "" "$ICON_ON"
    [ "$sleep_disabled" = 0 ] &&
      item "Warning: disablesleep is off" "The lid will not hold. Run simmer doctor." "" "$ICON_WARN"
    if [ -n "$duration_query" ]; then
      case "$duration_query" in
        *:*) item "Move the deadline to $duration_query" "Replaces the current lease" "--until $duration_query" "$ICON_ON" ;;
        +*)  item "Extend by ${duration_query#+}"         "Counted from now"            "$duration_query"        "$ICON_ON" ;;
        *)   item "Replace with $duration_query"          "Counted from now"            "$duration_query"        "$ICON_ON" ;;
      esac
    fi
    item "Release now"        "Allow sleep again immediately" "down"  "$ICON_OFF"
    item "Extend 15 minutes"  "Deadline moves to 15 minutes from now" "+15m" "$ICON_ON"
    item "Extend 1 hour"      "Deadline moves to 1 hour from now"     "+1h"  "$ICON_ON"
    item "Extend 3 hours"     "Deadline moves to 3 hours from now"    "+3h"  "$ICON_ON"
    ;;
  forever)
    item "Simmering with no deadline · since $(date -r "$since" '+%H:%M')" \
         "${reason:-no reason given} — $power, floor ${min_battery}%" "" "$ICON_ON"
    [ -n "$duration_query" ] &&
      item "Give it a deadline: $duration_query" "Turns the open-ended lease into a timebox" "${duration_query#+}" "$ICON_ON"
    item "Release now"     "Allow sleep again immediately" "down" "$ICON_OFF"
    item "Deadline in 1 hour"  "Turns the open-ended lease into a timebox" "1h" "$ICON_ON"
    item "Deadline in 3 hours" "Turns the open-ended lease into a timebox" "3h" "$ICON_ON"
    ;;
  orphan)
    item "Sleep is disabled with no lease" "Nobody is scheduled to hand it back — is the guard running?" "" "$ICON_WARN"
    item "Revert now"                "Allow sleep again immediately"  "down" "$ICON_OFF"
    item "Turn it into a 1 hour lease" "Keeps it awake, with a deadline" "1h" "$ICON_ON"
    ;;
  *)
    item "Sleep allowed" "$power — nothing is holding this Mac awake" "" "$ICON_OFF"
    if [ -n "$duration_query" ]; then
      case "$duration_query" in
        *:*) item "Stay awake until $duration_query" "Lid may close until then" "--until $duration_query" "$ICON_ON" ;;
        *)   item "Stay awake for ${duration_query#+}" "Lid may close until then" "${duration_query#+}" "$ICON_ON" ;;
      esac
    fi
    item "30 minutes" "Lid may close until then" "30m"     "$ICON_ON"
    item "1 hour"     "Lid may close until then" "1h"      "$ICON_ON"
    item "2 hours"    "Lid may close until then" "2h"      "$ICON_ON"
    item "4 hours"    "Lid may close until then" "4h"      "$ICON_ON"
    item "Until further notice" "No deadline — reminds every 30 minutes, releases on low battery" "forever" "$ICON_ON"
    ;;
esac

printf '{"items":[%s]}\n' "$(IFS=,; echo "${items[*]}")"
