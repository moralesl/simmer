#!/bin/bash
# <xbar.title>simmer</xbar.title>
# <xbar.version>v1.1</xbar.version>
# <xbar.author>Luis Morales</xbar.author>
# <xbar.desc>Menu bar countdown and controls for the simmer lease.</xbar.desc>
# <xbar.dependencies>bash</xbar.dependencies>
#
# A shim on purpose: the core renders every surface (simmer render swiftbar), so
# this file carries only SwiftBar's metadata and the resolver. The refresh
# cadence comes from the filename.
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
exec "$SIMMER" render swiftbar
