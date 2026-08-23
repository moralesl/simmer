#!/bin/bash
# simmer's test suite. Hermetic: no sudo, no real power state touched, no lease
# left behind.
#
# That is possible because bin/simmer funnels its four power operations through
# functions that SIMMER_FAKE_PMSET and SIMMER_FAKE_BATTERY can substitute. The
# alternative -- driving real `pmset` -- needs root, changes the machine under
# you, and cannot test the battery branch at all while the laptop is charging.
# Deliberately no `pipefail`. Assertions are `cmd | grep -q ...`, and grep -q
# exits on the first match -- so cmd takes SIGPIPE (141), or exits 1 because it
# was *supposed* to refuse. Under pipefail both read as a failed assertion, and
# the suite reports nine failures against code that is entirely correct.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMMER="${SIMMER_BIN:-$HERE/bin/simmer}"
[ -x "$SIMMER" ] || { echo "no simmer at $SIMMER" >&2; exit 2; }
# Pin it for the integrations too. They resolve simmer through SIMMER_BIN, then
# PATH, then known install locations -- so without this the front-end assertions
# would silently exercise whichever simmer happens to be installed, and would
# find none at all on a clean CI runner.
export SIMMER_BIN="$SIMMER"

# Its own state directory, so a run cannot disturb the real lease.
TMP="$(mktemp -d)"; export XDG_STATE_HOME="$TMP/state"
STATE="$XDG_STATE_HOME/simmer"; LEASE="$STATE/lease"
mkdir -p "$STATE"
export SIMMER_FAKE_PMSET="$TMP/disablesleep"; echo 0 > "$SIMMER_FAKE_PMSET"
# No real banners while testing: the suite fires notify() dozens of times, and
# before this line every run sprayed the desktop with them.
export SIMMER_NOTIFY=none
export SIMMER_FAKE_THERMAL=0   # a genuinely warm Mac must not fail the suite
# Point the bundle transport somewhere empty so its selection logic is testable.
export SIMMER_NOTIFIER_APP="$TMP/NoSuch.app"
export SIMMER_FAKE_BATTERY="80:0"          # 80%, on AC
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
t() { if eval "$2" >/dev/null 2>&1; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1"; fail=$((fail+1)); fi; }
lease() { # <until> <started> <reason> <floor> <warned> <reminded> [owner]
  printf 'format=1\nuntil=%s\nstarted=%s\nreason=%s\nmin_battery=%s\ncaffeinate=0\nwarned=%s\nreminded=%s\nowner=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:-test}" > "$LEASE"
}
switch() { cat "$SIMMER_FAKE_PMSET"; }
NOW=$(date +%s)

echo "duration parsing (via budget, which parses without taking anything)"
for d in 90 90m 1h 1h30m 45min 2h15 30s 2H; do
  t "accepts $d" "! $SIMMER budget --need $d 2>&1 | grep -q 'did not understand'"
done
for d in 5x7 abc 1h2x; do
  t "rejects $d" "$SIMMER budget --need $d 2>&1 | grep -q 'did not understand'"
done

echo "taking and returning a lease"
t "take sets the switch"        "$SIMMER 30m -r take --owner test >/dev/null && [ \"\$(switch)\" = 1 ]"
t "status shows the reason"     "$SIMMER | grep -q take"
t "down clears the switch"      "$SIMMER down >/dev/null && [ \"\$(switch)\" = 0 ]"
t "refuses below the floor"     "SIMMER_FAKE_BATTERY=10:1 $SIMMER 30m --min-battery 20 2>&1 | grep -q 'floor'"
t "and did not set the switch"  "[ \"\$(switch)\" = 0 ]"

echo "the guard's decision tree"
echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW-60)) $((NOW-3660)) expired 10 0 $((NOW-60)); "$SIMMER" guard >/dev/null 2>&1
t "deadline passed releases"    "[ ! -f '$LEASE' ] && [ \"\$(switch)\" = 0 ]"
t "and says why"                "tail -3 '$STATE/simmer.log' | grep -q 'time is up'"

echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW+3600)) "$NOW" batt 20 0 "$NOW"
SIMMER_FAKE_BATTERY="12:1" "$SIMMER" guard >/dev/null 2>&1
t "battery below floor releases" "[ ! -f '$LEASE' ] && [ \"\$(switch)\" = 0 ]"

echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW+3600)) "$NOW" charging 20 0 "$NOW"
SIMMER_FAKE_BATTERY="12:0" "$SIMMER" guard >/dev/null 2>&1
t "but not while charging"      "[ -f '$LEASE' ]"

echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW+240)) "$NOW" warn 10 0 "$NOW"; "$SIMMER" guard >/dev/null 2>&1
t "warns inside the window"     "grep -q '^warned=1' '$LEASE'"
"$SIMMER" guard >/dev/null 2>&1
t "warns exactly once"          "[ \"\$(grep -c '^warned=1' '$LEASE')\" = 1 ]"

echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW+3600)) "$NOW" hot 10 1 "$NOW"
SIMMER_FAKE_THERMAL=2 "$SIMMER" guard >/dev/null 2>&1
t "thermal pressure releases"   "[ ! -f '$LEASE' ] && [ \"\$(switch)\" = 0 ] && tail -2 '$STATE/simmer.log' | grep -q thermal"

echo 1 > "$SIMMER_FAKE_PMSET"
lease $((NOW+3600)) "$NOW" cool 10 1 "$NOW"
SIMMER_FAKE_THERMAL=0 "$SIMMER" guard >/dev/null 2>&1
t "but nominal heat does not"   "[ -f '$LEASE' ]"
rm -f "$LEASE"

echo 1 > "$SIMMER_FAKE_PMSET"
lease 0 $((NOW-7200)) forever 10 0 $((NOW-3600)); SIMMER_FAKE_THERMAL=0 "$SIMMER" guard >/dev/null 2>&1
t "open-ended lease reminds"    "[ \"\$(grep '^reminded=' '$LEASE' | cut -d= -f2)\" -gt $((NOW-60)) ]"
t "porcelain reports forever"   "$SIMMER --machine | grep -q 'state=forever'"

rm -f "$LEASE"; echo 1 > "$SIMMER_FAKE_PMSET"
"$SIMMER" guard >/dev/null 2>&1
t "heals a switch with no lease" "[ \"\$(switch)\" = 0 ]"
t "and logs that it did"         "tail -2 '$STATE/simmer.log' | grep -q 'no lease'"

echo "restores the switch inside a live lease"
lease $((NOW+3600)) "$NOW" restore 10 1 "$NOW"; echo 0 > "$SIMMER_FAKE_PMSET"
"$SIMMER" guard >/dev/null 2>&1
t "switch put back"             "[ \"\$(switch)\" = 1 ]"

echo "budget, the agent-facing contract"
lease $((NOW+1500)) "$NOW" budget 10 1 "$NOW"
t "exit 0 when it fits"         "$SIMMER budget --need 10m >/dev/null"
t "exit 1 when it does not"     "$SIMMER budget --need 5h >/dev/null; [ \$? = 1 ]"
lease 0 "$NOW" forever 10 0 "$NOW"
t "no deadline fits anything"   "$SIMMER budget --need 99h >/dev/null"
lease $((NOW+1500)) "$NOW" budget 10 1 "$NOW"
t "--seconds is a bare number"  "[ \"\$($SIMMER budget --seconds)\" -gt 1400 ]"
lease 0 "$NOW" forever 10 0 "$NOW"
t "--seconds is -1 for forever" "[ \"\$($SIMMER budget --seconds)\" = -1 ]"
rm -f "$LEASE"; echo 0 > "$SIMMER_FAKE_PMSET"
t "exit 3 with no lease at all" "$SIMMER budget >/dev/null; [ \$? = 3 ]"
t "--seconds stays silent then" "[ -z \"\$($SIMMER budget --seconds 2>/dev/null)\" ]"

echo "ownership"
lease $((NOW+1200)) "$NOW" human 10 1 "$NOW" menubar; echo 1 > "$SIMMER_FAKE_PMSET"
t "refuses a different owner"   "! $SIMMER 1h --owner agent 2>/dev/null"
t "names who holds it"          "$SIMMER 1h --owner agent 2>&1 | grep -q menubar"
t "--force overrides"           "$SIMMER 1h --owner agent --force >/dev/null"
t "same owner is silent"        "$SIMMER 2h --owner agent >/dev/null"
t "extend needs no ownership"   "$SIMMER +25m >/dev/null"

echo "surfaces render in every state"
lease 0 $((NOW-600)) render 10 0 "$NOW"
t "swiftbar, open-ended"        "$HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -q '^∞ |'"
t "raycast inline, open-ended"  "$HERE/integrations/raycast/simmer-status.sh | grep -q 'no deadline'"
t "alfred filter emits JSON"    "$HERE/integrations/alfred/simmer-filter.sh '' | python3 -m json.tool"
rm -f "$LEASE"; echo 0 > "$SIMMER_FAKE_PMSET"
t "swiftbar, idle"              "$HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -q 'sfimage=moon.zzz'"
t "menu bar title has one icon"  "! $HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -qE '☕|⏾'"
t "status readable when idle"   "$SIMMER | grep -q 'sleep allowed'"
t "help documents down/force"   "$SIMMER --help | grep -q 'simmer down' && $SIMMER --help | grep -q -- '--force'"
t "--version prints"            "$SIMMER --version | grep -q simmer"
t "notify-test runs"            "SIMMER_NOTIFY=auto $SIMMER notify-test >/dev/null 2>&1"
if command -v swiftc >/dev/null 2>&1; then
  t "notifier source compiles"  "swiftc -O -o '$TMP/nb' '$HERE/notifier/main.swift'"
else
  echo "  ⏭  notifier source compiles — no swiftc on this machine"
fi
t "notifier plist parses"       "plutil -lint '$HERE/notifier/Info.plist'"
t "SIMMER_NOTIFY=none is quiet" "SIMMER_NOTIFY=none $SIMMER 5m --owner t --force >/dev/null"

# Execute every front-end, not just two of them. Two Raycast commands shipped
# broken -- `$SIMMER: unbound variable` -- because nothing ever ran them.
#
# The assertion is "no shell-level failure", not "exit 0": `simmer +15m` with no
# lease exits 1 and is right to. What must never happen is an unbound variable or
# a missing command, which is the class of bug that shipped.
runs_clean() { # <script> [args...]
  local err; err="$("$@" 2>&1 >/dev/null)"
  ! printf '%s' "$err" | grep -qE 'unbound variable|command not found|No such file|syntax error'
}
echo "every integration actually executes"
for f in "$HERE"/integrations/raycast/*.sh; do
  t "runs $(basename "$f")"      "bash -n '$f' && runs_clean '$f'"
done
t "runs the swiftbar plugin"     "runs_clean '$HERE/integrations/swiftbar/simmer.10s.sh'"
t "runs the alfred filter"       "runs_clean '$HERE/integrations/alfred/simmer-filter.sh' ''"

echo
echo "$pass passed, $fail failed"
exit "$fail"
