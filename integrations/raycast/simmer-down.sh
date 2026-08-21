#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer down
# @raycast.mode compact
# @raycast.packageName Simmer
# @raycast.icon simmer.png
# @raycast.description Allow sleep again immediately
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
exec "$SIMMER" down
