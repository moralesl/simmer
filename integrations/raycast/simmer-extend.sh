#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Simmer longer
# @raycast.mode compact
# @raycast.packageName Simmer
# @raycast.icon simmer.png
# @raycast.description Move the deadline, counted from now
# @raycast.argument1 { "type": "text", "placeholder": "15m", "optional": true }
set -uo pipefail
exec "$SIMMER" "+${1:-15m}"
