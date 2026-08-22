#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer status
# @raycast.mode inline
# @raycast.refreshTime 10s
# @raycast.packageName Simmer
# @raycast.icon simmer.png
# @raycast.description Is this Mac being held awake, and for how much longer
#
# A shim on purpose: the core renders every surface (simmer render raycast).
set -u

# Find simmer. A launcher runs with a minimal PATH, so `command -v` alone is not
# enough; SIMMER_BIN wins if set.
SIMMER="${SIMMER_BIN:-$(command -v simmer 2>/dev/null || true)}"
if [ ! -x "${SIMMER:-}" ]; then
  for p in "$HOME/.local/bin/simmer" /usr/local/bin/simmer /opt/homebrew/bin/simmer \
           "$HOME/workspace/tools/simmer/bin/simmer"; do
    [ -x "$p" ] && SIMMER="$p" && break
  done
fi
[ -x "${SIMMER:-}" ] || { echo "simmer not installed -- github.com/moralesl/simmer"; exit 0; }
exec "$SIMMER" render raycast
