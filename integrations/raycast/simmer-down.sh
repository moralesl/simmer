#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer down
# @raycast.mode compact
# @raycast.packageName Simmer
# @raycast.icon ⏾
# @raycast.description Allow sleep again immediately
set -uo pipefail
exec "$SIMMER" down
