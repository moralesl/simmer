#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer for…
# @raycast.mode compact
# @raycast.packageName Simmer
# @raycast.icon simmer.png
# @raycast.description Hold this Mac awake for a bounded time, lid closed
# @raycast.argument1 { "type": "text", "placeholder": "60m / 2h / 23:00 / forever" }
# @raycast.argument2 { "type": "text", "placeholder": "reason (optional)", "optional": true }
set -uo pipefail

# Find simmer. A launcher runs with a minimal PATH, so `command -v` alone is not
# enough; SIMMER_BIN wins if set. Short on purpose -- this is duplicated in every
# integration, and the long version is how two of them ended up referencing
# $SIMMER without ever setting it.
SIMMER="${SIMMER_BIN:-$(command -v simmer 2>/dev/null || true)}"
if [ ! -x "${SIMMER:-}" ]; then
  for p in "$HOME/.local/bin/simmer" /usr/local/bin/simmer /opt/homebrew/bin/simmer \
           "$HOME/workspace/tools/simmer/bin/simmer"; do
    [ -x "$p" ] && SIMMER="$p" && break
  done
fi
[ -x "${SIMMER:-}" ] || { echo "simmer not installed -- github.com/moralesl/simmer"; exit 0; }

ARG="${1:-}"; REASON="${2:-Raycast}"

# A wall-clock time needs --until; everything else is a duration or `forever`.
case "$ARG" in
  *:*) exec "$SIMMER" --until "$ARG" -r "$REASON" --owner raycast ;;
  "")  exec "$SIMMER" ;;
  *)   exec "$SIMMER" "$ARG" -r "$REASON" --owner raycast ;;
esac
