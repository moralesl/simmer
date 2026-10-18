#!/bin/bash
# The whole experiment in one sitting: a control run (no AppliesOnLidClose,
# expect: sleeps) and then the root run (with it, the question), each with the
# lid closed for a minute and a half, then both summaries and the system's own
# sleep/wake log for the window. Paste the summaries into PLATFORM-FACTS.md.
#
#   ./measure.sh            # asks for your password once, for the root run
#
# Nothing here changes the machine: an assertion is released when its process
# exits. Refuses to start while simmer holds a claim or the switch is on,
# because then the lid would stay awake for simmer's reason and the run would
# measure nothing.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
hold="${HOLD:-150}"
out="${OUT:-$here/results-$(date +%Y%m%d-%H%M)}"

[ -x "$here/lid-assertion" ] || "$here/build.sh"

echo "▸ preconditions"
if command -v simmer >/dev/null; then
  status="$(simmer status --machine 2>/dev/null || true)"
  if ! printf '%s\n' "$status" | grep -q '^claim_count=0$' ||
     ! printf '%s\n' "$status" | grep -q '^sleep_disabled=0$'; then
    echo "  simmer holds a claim or the switch is on — the lid would stay awake for"
    echo "  simmer's reason, not the assertion's. 'simmer down --all' first (yours to run)."
    exit 1
  fi
  echo "  simmer: idle, switch off"
fi
if system_profiler SPDisplaysDataType 2>/dev/null | grep -q 'Connection Type: External'; then
  echo "  an external display is connected — closed lid would be clamshell mode, which"
  echo "  stays awake regardless. Unplug it and run again."
  exit 1
fi
echo "  displays: built-in only"
pmset -g batt | head -1 | sed 's/^/  /'
mkdir -p "$out"
started="$(date '+%Y-%m-%d %H:%M:%S')"

phase() {
  local name="$1"; shift
  echo
  echo "▸ $name"
  echo "  When the sampling lines start: CLOSE THE LID. Leave it closed ~90 s, then open it."
  echo "  The run ends by itself after ${hold}s of wall time."
  read -r -p "  Press Enter to start… "
  "$@" --hold "$hold" --log "$out/$name.log" | tee "$out/$name.out"
}

phase control "$here/lid-assertion" --control
echo
echo "  (sudo asks for your password now, once)"
sudo -v
phase root sudo "$here/lid-assertion"

echo
echo "▸ the system's own sleep/wake log since $started"
pmset -g log | awk -v s="$started" '$0 >= s' | grep -E 'Sleep  |Wake  |DarkWake' | sed 's/^/  /' || true

echo
echo "▸ summaries (paste these into docs/PLATFORM-FACTS.md with today's date)"
grep -A2 '^summary' "$out/control.out" "$out/root.out" | sed 's/^/  /'
echo
echo "  logs: $out"
