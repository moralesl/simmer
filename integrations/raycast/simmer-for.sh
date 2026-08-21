#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer for…
# @raycast.mode compact
# @raycast.packageName Simmer
# @raycast.icon ☕
# @raycast.description Hold this Mac awake for a bounded time, lid closed
# @raycast.argument1 { "type": "text", "placeholder": "60m / 2h / 23:00 / forever" }
# @raycast.argument2 { "type": "text", "placeholder": "reason (optional)", "optional": true }
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

SIMMER="$(simmer_bin)" || { echo "simmer not installed"; exit 1; }
ARG="${1:-}"; REASON="${2:-Raycast}"

# A wall-clock time needs --until; everything else is a duration or `forever`.
case "$ARG" in
  *:*) exec "$SIMMER" --until "$ARG" -r "$REASON" --owner raycast ;;
  "")  exec "$SIMMER" ;;
  *)   exec "$SIMMER" "$ARG" -r "$REASON" --owner raycast ;;
esac
