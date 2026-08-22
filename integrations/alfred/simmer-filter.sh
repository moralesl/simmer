#!/bin/bash
# Alfred Script Filter shim: the core renders the JSON (simmer render alfred).
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
exec "$SIMMER" render alfred "${1:-}"
