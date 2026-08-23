#!/bin/bash
# simmer's test suite. Hermetic: no sudo, no real power state touched, no claim
# left behind.
#
# That is possible because bin/simmer funnels its power operations and its clock
# through functions that SIMMER_FAKE_* can substitute. The alternative -- driving
# real `pmset` -- needs root, changes the machine under you, and cannot test the
# battery branch at all while the laptop is charging. SIMMER_FAKE_NOW does the
# same job for time: warn-once, the reminder interval and deadline crossings used
# to be reachable only by hand-writing timestamps and hoping.
#
# Deliberately no `pipefail`. Assertions are `cmd | grep -q ...`, and grep -q
# exits on the first match -- so cmd takes SIGPIPE (141), or exits 1 because it
# was *supposed* to refuse. Under pipefail both read as a failed assertion, and
# the suite reports nine failures against code that is entirely correct.
#
# This is the acceptance test for any implementation of CONTRACTS.md, not just
# for the bash one: point SIMMER_BIN at another binary and it must go green.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMMER="${SIMMER_BIN:-$HERE/bin/simmer}"
[ -x "$SIMMER" ] || { echo "no simmer at $SIMMER" >&2; exit 2; }
# Pin it for the integrations too. They resolve simmer through SIMMER_BIN, then
# PATH, then known install locations -- so without this the front-end assertions
# would silently exercise whichever simmer happens to be installed, and would
# find none at all on a clean CI runner.
export SIMMER_BIN="$SIMMER"

# Its own state directory, so a run cannot disturb the real ledger.
TMP="$(mktemp -d)"; export XDG_STATE_HOME="$TMP/state"
STATE="$XDG_STATE_HOME/simmer"; CLAIMS="$STATE/claims"; CAPFILE="$STATE/cap"
mkdir -p "$CLAIMS"
export SIMMER_FAKE_PMSET="$TMP/disablesleep"; echo 0 > "$SIMMER_FAKE_PMSET"
# No real banners while testing: the suite fires notify() dozens of times, and
# before this line every run sprayed the desktop with them.
export SIMMER_NOTIFY=none
export SIMMER_FAKE_THERMAL=0   # a genuinely warm Mac must not fail the suite
export SIMMER_FAKE_LOCKDELAY=0 # nor should the tester's lock-screen setting
# Point the bundle transport somewhere empty so its selection logic is testable.
export SIMMER_NOTIFIER_APP="$TMP/NoSuch.app"
export SIMMER_FAKE_BATTERY="80:0"          # 80%, on AC
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
t() { if eval "$2" >/dev/null 2>&1; then echo "  ✅ $1"; pass=$((pass+1)); else echo "  ❌ $1"; fail=$((fail+1)); fi; }

cf() { printf '%s/%s' "$CLAIMS" "$1"; }          # a claim's file
claim() { # <owner> <until> <started> <reason> <floor> <warned> <reminded> [require_ac]
  printf 'format=2\nid=%s\nowner=%s\nuntil=%s\nstarted=%s\nreason=%s\nmin_battery=%s\ncaffeinate=0\nrequire_ac=%s\nwarned=%s\nprewarned=0\nreminded=%s\n' \
    "$1" "$1" "$2" "$3" "$4" "$5" "${8:-0}" "$6" "$7" > "$(cf "$1")"
}
clear_all() { rm -f "$CLAIMS"/* "$CAPFILE"; }
switch() { cat "$SIMMER_FAKE_PMSET"; }
NOW=$(date +%s)

echo "duration parsing (via budget, which parses without claiming anything)"
for d in 90 90m 1h 1h30m 45min 2h15 30s 2H; do
  t "accepts $d" "! $SIMMER budget --need $d 2>&1 | grep -q 'did not understand'"
done
for d in 5x7 abc 1h2x; do
  t "rejects $d" "$SIMMER budget --need $d 2>&1 | grep -q 'did not understand'"
done

echo "taking and returning a claim"
t "take sets the switch"        "$SIMMER 30m -r take --owner test >/dev/null && [ \"\$(switch)\" = 1 ]"
t "status shows the reason"     "$SIMMER | grep -q take"
t "down clears the switch"      "$SIMMER down --owner test >/dev/null && [ \"\$(switch)\" = 0 ]"
t "refuses below the floor"     "SIMMER_FAKE_BATTERY=10:1 $SIMMER 30m --min-battery 20 2>&1 | grep -q 'floor'"
t "and did not set the switch"  "[ \"\$(switch)\" = 0 ]"
t "--require-ac refuses on battery" "SIMMER_FAKE_BATTERY=90:1 $SIMMER 30m --require-ac 2>&1 | grep -q 'on battery'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "the clock is substitutable (SIMMER_FAKE_NOW)"
FN=1800000000
t "take lands on the fake clock" "SIMMER_FAKE_NOW=$FN $SIMMER 1h --owner fn >/dev/null && [ \"\$(grep '^until=' '$(cf fn)' | cut -d= -f2)\" = $((FN+3600)) ]"
t "budget counts from it"        "[ \"\$(SIMMER_FAKE_NOW=$FN $SIMMER budget --seconds)\" = 3600 ]"
t "the log is stamped from it"   "SIMMER_FAKE_NOW=$FN $SIMMER +5m --owner fn >/dev/null && tail -1 '$STATE/simmer.log' | grep -q '^2027-01-15'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "claims are counted, not owned"
t "two owners, two claims"      "$SIMMER 2h -r human --owner terminal >/dev/null && $SIMMER 30m -r bot --owner agent >/dev/null && [ \"\$(ls '$CLAIMS' | wc -l | tr -d ' ')\" = 2 ]"
t "the aggregate is the latest"  "[ \"\$($SIMMER --machine | grep '^left=' | cut -d= -f2)\" -gt 7000 ]"
t "claim_count is published"     "$SIMMER --machine | grep -q '^claim_count=2'"
t "status lists both"            "$SIMMER | grep -q 'agent · bot' && $SIMMER | grep -q 'terminal · human'"
t "taking again replaces my own" "$SIMMER 45m -r bot2 --owner agent >/dev/null && [ \"\$(ls '$CLAIMS' | wc -l | tr -d ' ')\" = 2 ]"
t "and did not touch the other"  "grep -q '^reason=human' '$(cf terminal)'"
t "extend moves only my claim"   "u=\$(grep '^until=' '$(cf terminal)' | cut -d= -f2); $SIMMER +10m --owner agent >/dev/null; [ \"\$(grep '^until=' '$(cf terminal)' | cut -d= -f2)\" = \"\$u\" ]"
t "extend needs a claim of mine" "! $SIMMER +10m --owner nobody 2>/dev/null"
# Extending a dated claim while somebody holds an open-ended one: the aggregate
# is `forever`, so anything formatting its deadline as a time prints 1970.
t "extend under a forever claim"  "clear_all; $SIMMER forever -r n --owner agent >/dev/null; $SIMMER 1h -r m --owner terminal >/dev/null; $SIMMER +30m --owner terminal | grep -q 'until further notice'"
t "and never formats epoch zero"  "! $SIMMER +30m --owner terminal | grep -q '01:00'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "two owners again for what follows" "$SIMMER 2h -r human --owner terminal >/dev/null && $SIMMER 45m -r bot2 --owner agent >/dev/null"
t "--force is a documented no-op" "$SIMMER 20m --owner agent --force 2>&1 | grep -q 'no longer does anything'"
t "releasing mine leaves theirs" "$SIMMER down --owner agent >/dev/null && [ -f '$(cf terminal)' ] && [ ! -f '$(cf agent)' ]"
t "and the switch stays on"      "[ \"\$(switch)\" = 1 ]"
t "the last one out flips it"    "$SIMMER down --owner terminal >/dev/null && [ \"\$(switch)\" = 0 ]"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "human primacy"
claim terminal $((NOW+7200)) "$NOW" human 20 0 "$NOW"
claim agent    $((NOW+1800)) "$NOW" bot   20 0 "$NOW"
echo 1 > "$SIMMER_FAKE_PMSET"
t "an agent cannot down --all"   "! $SIMMER down --all --owner agent 2>/dev/null"
t "and is told whose they are"   "$SIMMER down --all --owner agent 2>&1 | grep -q 'only a person'"
t "nothing was released"         "[ \"\$(ls '$CLAIMS' | wc -l | tr -d ' ')\" = 2 ]"
t "an agent holding none is refused" "! $SIMMER down --owner stranger 2>/dev/null"
t "a human may release anything" "$SIMMER down --all --owner terminal >/dev/null && [ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ]"
t "and the switch came back"     "[ \"\$(switch)\" = 0 ]"
claim agent $((NOW+1800)) "$NOW" bot 20 0 "$NOW"; echo 1 > "$SIMMER_FAKE_PMSET"
t "a human holding none clears all" "$SIMMER down --owner terminal >/dev/null && [ \"\$(switch)\" = 0 ]"
t "and says whose it was"           "claim agent $((NOW+1800)) $NOW bot 20 0 $NOW; $SIMMER down --owner terminal | grep -q agent"
t "SIMMER_HUMAN grants authority"   "claim agent $((NOW+1800)) $NOW bot 20 0 $NOW; SIMMER_HUMAN=1 $SIMMER down --all --owner ci >/dev/null"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "orphan: reverting is always allowed, by anyone"
echo 1 > "$SIMMER_FAKE_PMSET"
t "an agent may revert an orphan" "$SIMMER down --owner agent >/dev/null && [ \"\$(switch)\" = 0 ]"
t "down on an empty ledger is quiet" "$SIMMER down --owner agent | grep -q 'nothing to release'"

echo "the cap -- the one ceiling only a human sets"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "an agent cannot set it"      "! $SIMMER cap 23:00 --owner agent 2>/dev/null"
t "an agent cannot lift it"     "$SIMMER cap 2h --owner terminal >/dev/null; ! $SIMMER cap off --owner agent 2>/dev/null"
t "a human can"                 "$SIMMER cap off --owner terminal >/dev/null && [ ! -f '$CAPFILE' ]"
t "it clips a future claim"     "$SIMMER cap 1h --owner terminal >/dev/null; $SIMMER 6h -r long --owner agent >/dev/null; [ \"\$($SIMMER budget --seconds)\" -le 3600 ]"
t "and says it did"             "$SIMMER 6h -r long --owner agent | grep -q 'clipped by the cap'"
t "it clips a claim already held" "$SIMMER cap off --owner terminal >/dev/null; $SIMMER 6h -r long --owner agent >/dev/null; $SIMMER cap 30m --owner terminal | grep -q 'clipped 1 claim'"
t "budget marks it as the cap"  "$SIMMER budget --json | jq -e '.capped==true'"
t "budget names the cap in prose" "$SIMMER budget | grep -q 'cap a human set'"
t "cap is in --machine"         "$SIMMER --machine | grep -qE '^cap=[0-9]{10}'"
t "status says nothing past it" "$SIMMER | grep -q 'nothing past'"
t "forever under a cap is active" "clear_all; $SIMMER cap 1h --owner terminal >/dev/null; $SIMMER forever --owner agent >/dev/null; $SIMMER --machine | grep -q '^state=active'"
t "extend cannot exceed it"     "! $SIMMER +9h --owner agent 2>/dev/null"
t "a passed cap refuses a claim" "clear_all; $SIMMER cap 1m --owner terminal >/dev/null; ! SIMMER_FAKE_NOW=\$(( \$(date +%s) + 300 )) $SIMMER 30m --owner agent 2>/dev/null"
t "and says who can lift it"     "SIMMER_FAKE_NOW=\$(( \$(date +%s) + 300 )) $SIMMER 30m --owner agent 2>&1 | grep -q 'cap off'"
t "cap with no argument reports" "$SIMMER cap | grep -qE 'cap|nothing past'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "the guard's decision tree"
echo 1 > "$SIMMER_FAKE_PMSET"
claim expired $((NOW-60)) $((NOW-3660)) expired 10 0 $((NOW-60)); "$SIMMER" guard >/dev/null 2>&1
t "deadline passed releases"    "[ ! -f '$(cf expired)' ] && [ \"\$(switch)\" = 0 ]"
t "and says why"                "tail -3 '$STATE/simmer.log' | grep -q 'time is up'"

echo 1 > "$SIMMER_FAKE_PMSET"
claim batt $((NOW+3600)) "$NOW" batt 20 0 "$NOW"
SIMMER_FAKE_BATTERY="12:1" "$SIMMER" guard >/dev/null 2>&1
t "battery below floor releases" "[ ! -f '$(cf batt)' ] && [ \"\$(switch)\" = 0 ]"

echo 1 > "$SIMMER_FAKE_PMSET"
claim charging $((NOW+3600)) "$NOW" charging 20 0 "$NOW"
SIMMER_FAKE_BATTERY="12:0" "$SIMMER" guard >/dev/null 2>&1
t "but not while charging"      "[ -f '$(cf charging)' ]"

# Per-claim floors: an actor asking for a high floor gets it without dragging
# everyone else's time down with it.
claim picky $((NOW+3600)) "$NOW" picky 60 0 "$NOW"
SIMMER_FAKE_BATTERY="55:1" "$SIMMER" guard >/dev/null 2>&1
t "a claim retires on ITS floor" "[ ! -f '$(cf picky)' ] && [ -f '$(cf charging)' ]"
t "and the switch stays on"      "[ \"\$(switch)\" = 1 ]"
clear_all

echo 1 > "$SIMMER_FAKE_PMSET"
claim ac $((NOW+3600)) "$NOW" overnight 20 0 "$NOW" 1
SIMMER_FAKE_BATTERY="95:0" "$SIMMER" guard >/dev/null 2>&1
t "--require-ac survives on AC"  "[ -f '$(cf ac)' ]"
SIMMER_FAKE_BATTERY="95:1" "$SIMMER" guard >/dev/null 2>&1
t "and ends when the cable goes" "[ ! -f '$(cf ac)' ] && [ \"\$(switch)\" = 0 ]"
t "logging the reason"           "tail -3 '$STATE/simmer.log' | grep -q 'require-ac'"

echo 1 > "$SIMMER_FAKE_PMSET"
claim pre $((NOW+3600)) "$NOW" work 20 0 "$NOW"
SIMMER_FAKE_BATTERY="28:1" "$SIMMER" guard >/dev/null 2>&1
t "warns approaching the floor"  "grep -q '^prewarned=1' '$(cf pre)'"
SIMMER_FAKE_BATTERY="26:1" "$SIMMER" guard >/dev/null 2>&1
t "exactly once"                 "[ \"\$(grep -c 'pre-floor' '$STATE/simmer.log')\" = 1 ]"
t "the claim is still live"      "[ -f '$(cf pre)' ]"
SIMMER_FAKE_BATTERY="90:0" "$SIMMER" guard >/dev/null 2>&1
t "re-arms once plugged back in" "grep -q '^prewarned=0' '$(cf pre)'"
clear_all

echo 1 > "$SIMMER_FAKE_PMSET"
claim warn $((NOW+240)) "$NOW" warn 10 0 "$NOW"; "$SIMMER" guard >/dev/null 2>&1
t "warns inside the window"     "grep -q '^warned=1' '$(cf warn)'"
"$SIMMER" guard >/dev/null 2>&1
t "warns exactly once"          "[ \"\$(grep -c '^warned=1' '$(cf warn)')\" = 1 ]"

# The warning belongs to the AGGREGATE deadline, so it sits on whichever claim
# defines it -- and a shorter claim newly exposed gets its own warning rather
# than inheriting a spent one.
clear_all; echo 1 > "$SIMMER_FAKE_PMSET"
claim short $((NOW+120)) "$NOW" short 10 0 "$NOW"
claim long  $((NOW+240)) "$NOW" long  10 0 "$NOW"
"$SIMMER" guard >/dev/null 2>&1
t "only the defining claim warns" "grep -q '^warned=1' '$(cf long)' && grep -q '^warned=0' '$(cf short)'"
"$SIMMER" down --owner long >/dev/null 2>&1
"$SIMMER" guard >/dev/null 2>&1
t "a newly exposed deadline warns" "grep -q '^warned=1' '$(cf short)'"
clear_all

echo 1 > "$SIMMER_FAKE_PMSET"
claim hot $((NOW+3600)) "$NOW" hot 10 1 "$NOW"
claim hot2 $((NOW+7200)) "$NOW" hot2 10 1 "$NOW"
SIMMER_FAKE_THERMAL=2 "$SIMMER" guard >/dev/null 2>&1
t "thermal pressure ends ALL"   "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(switch)\" = 0 ] && tail -4 '$STATE/simmer.log' | grep -q thermal"

echo 1 > "$SIMMER_FAKE_PMSET"
claim cool $((NOW+3600)) "$NOW" cool 10 1 "$NOW"
SIMMER_FAKE_THERMAL=0 "$SIMMER" guard >/dev/null 2>&1
t "but nominal heat does not"   "[ -f '$(cf cool)' ]"
clear_all

echo 1 > "$SIMMER_FAKE_PMSET"
claim fvr 0 $((NOW-7200)) forever 10 0 $((NOW-3600)); SIMMER_FAKE_THERMAL=0 "$SIMMER" guard >/dev/null 2>&1
t "open-ended claim reminds"    "[ \"\$(grep '^reminded=' '$(cf fvr)' | cut -d= -f2)\" -gt $((NOW-60)) ]"
"$SIMMER" guard >/dev/null 2>&1
t "and not again straight away" "[ \"\$(grep '^reminded=' '$(cf fvr)' | cut -d= -f2)\" -lt $((NOW+60)) ]"
t "machine reports forever"     "$SIMMER --machine | grep -q 'state=forever'"
clear_all

echo 1 > "$SIMMER_FAKE_PMSET"
"$SIMMER" guard >/dev/null 2>&1
t "heals a switch with no claim" "[ \"\$(switch)\" = 0 ]"
t "and logs that it did"         "tail -2 '$STATE/simmer.log' | grep -q 'nothing claiming it'"

echo "restores the switch inside a live claim"
claim restore $((NOW+3600)) "$NOW" restore 10 1 "$NOW"; echo 0 > "$SIMMER_FAKE_PMSET"
"$SIMMER" guard >/dev/null 2>&1
t "switch put back"             "[ \"\$(switch)\" = 1 ]"
clear_all

echo "migration from a format=1 lease"
printf 'format=1\nuntil=%s\nstarted=%s\nreason=old\nmin_battery=25\ncaffeinate=0\nwarned=0\nreminded=%s\nowner=menubar\n' \
  $((NOW+3600)) "$NOW" "$NOW" > "$STATE/lease"
echo 1 > "$SIMMER_FAKE_PMSET"
t "the lease becomes a claim"   "$SIMMER --machine | grep -q '^claim_count=1' && [ -f '$(cf menubar)' ]"
t "the old file is gone"        "[ ! -f '$STATE/lease' ]"
t "its floor survived"          "$SIMMER --machine | grep -q '^min_battery=25'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "budget, the agent-facing contract"
claim b $((NOW+1500)) "$NOW" budget 10 1 "$NOW"
t "exit 0 when it fits"         "$SIMMER budget --need 10m >/dev/null"
t "exit 1 when it does not"     "$SIMMER budget --need 5h >/dev/null; [ \$? = 1 ]"
claim b 0 "$NOW" forever 10 0 "$NOW"
t "no deadline fits anything"   "$SIMMER budget --need 99h >/dev/null"
claim b $((NOW+1500)) "$NOW" budget 10 1 "$NOW"
t "--seconds is a bare number"  "[ \"\$($SIMMER budget --seconds)\" -gt 1400 ]"
claim b 0 "$NOW" forever 10 0 "$NOW"
t "--seconds is -1 for forever" "[ \"\$($SIMMER budget --seconds)\" = -1 ]"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "exit 3 with nothing claimed" "$SIMMER budget >/dev/null; [ \$? = 3 ]"
t "--seconds stays silent then" "[ -z \"\$($SIMMER budget --seconds 2>/dev/null)\" ]"
# budget's answer cannot depend on who asks, but callers pass --owner to
# everything else, so dying on it here would be a papercut with no upside.
t "budget tolerates --owner"    "$SIMMER budget --owner agent >/dev/null; [ \$? = 3 ]"
# The aggregate is what an agent is really asking about: whose claim provides
# the time does not change how long the work has.
claim mine  $((NOW+600))  "$NOW" mine  20 1 "$NOW"
claim other $((NOW+5400)) "$NOW" other 20 1 "$NOW"
t "budget answers over the aggregate" "$SIMMER budget --need 60m >/dev/null"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "json output, the same answers for jq"
claim agent $((NOW+1500)) "$NOW" json 20 1 "$NOW"; echo 1 > "$SIMMER_FAKE_PMSET"
t "status --json parses (python3)"  "$SIMMER status --json | python3 -m json.tool"
t "status --json parses (jq)"       "$SIMMER status --json | jq -e ."
t "numbers are numbers"             "$SIMMER status --json | jq -e '(.left|type)==\"number\" and (.battery|type)==\"number\"'"
t "owner and version are in it"     "$SIMMER status --json | jq -e '.owner==\"agent\" and .version'"
t "--machine now carries owner"     "$SIMMER --machine | grep -q '^owner=agent'"
t "the claims array is there"       "$SIMMER status --json | jq -e '(.claims|length)==1 and .claims[0].owner==\"agent\"'"
t "and marks who is a human"        "$SIMMER status --json | jq -e '.claims[0].human==false'"
claim terminal $((NOW+9000)) "$NOW" hers 20 1 "$NOW"
t "two claims, two array entries"   "$SIMMER status --json | jq -e '(.claims|length)==2 and .claim_count==2'"
t "the human one is marked"         "$SIMMER status --json | jq -e '[.claims[]|select(.human)]|length==1'"
t "idle json has an empty array"    "clear_all; echo 0 > '$SIMMER_FAKE_PMSET'; $SIMMER status --json | jq -e '.state==\"idle\" and (.claims|length)==0'"
t "orphan json still says orphan"   "echo 1 > '$SIMMER_FAKE_PMSET'; $SIMMER status --json | jq -e '.state==\"orphan\"'"
echo 0 > "$SIMMER_FAKE_PMSET"

# The escaping that matters: a reason holding a double quote and a backslash,
# taken through the real cmd_take, must come back byte-identical from the JSON.
tricky='he said "hi" via C:\temp\ done'
"$SIMMER" 60s -r "$tricky" --owner test >/dev/null 2>&1
got="$("$SIMMER" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["reason"])')"
t "reason survives quote+backslash" "[ \"\$got\" = \"\$tricky\" ]"
got2="$("$SIMMER" status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["claims"][0]["reason"])')"
t "and so does the array copy"      "[ \"\$got2\" = \"\$tricky\" ]"
"$SIMMER" down --owner test >/dev/null 2>&1

claim agent $((NOW+1500)) "$NOW" json 20 1 "$NOW"; echo 1 > "$SIMMER_FAKE_PMSET"
t "budget --json: active and fits"  "$SIMMER budget --json --need 10m | jq -e '.state==\"active\" and .fits==true and .need_seconds==600'"
t "budget --json: does not fit"     "$SIMMER budget --json --need 5h | jq -e '.fits==false'"
t "and still exits 1"               "$SIMMER budget --json --need 5h >/dev/null; [ \$? = 1 ]"
t "no --need means fits null"       "$SIMMER budget --json | jq -e '.fits==null and (.seconds_left|type)==\"number\"'"
claim agent 0 "$NOW" forever 20 0 "$NOW"
t "budget --json: forever"          "$SIMMER budget --json | jq -e '.state==\"forever\" and .seconds_left==-1'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "budget --json: idle"             "$SIMMER budget --json | jq -e '.state==\"idle\" and .seconds_left==null'"
t "and still exits 3"               "$SIMMER budget --json >/dev/null; [ \$? = 3 ]"
echo 1 > "$SIMMER_FAKE_PMSET"
t "budget --json: orphan"           "$SIMMER budget --json | jq -e '.state==\"orphan\"'"
echo 0 > "$SIMMER_FAKE_PMSET"
t "help mentions --json"            "$SIMMER --help | grep -q -- '--json'"

echo "run -- a claim scoped to a process lifetime"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "exit 0 passes through"        "$SIMMER run -- true >/dev/null"
t "exit 1 passes through"        "$SIMMER run -- false >/dev/null; [ \$? = 1 ]"
t "any code passes through"      "$SIMMER run -- sh -c 'exit 7' >/dev/null; [ \$? = 7 ]"
t "and nothing is left behind"   "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(switch)\" = 0 ]"
t "refuses a command without --" "$SIMMER run true 2>&1 | grep -q usage"
t "help documents run"           "$SIMMER --help | grep -q 'simmer run'"

# While the command runs: claim held, owner = run:<pid>. The pid IS the identity
# now, which is why two concurrent runs can no longer collide.
"$SIMMER" run -- sleep 2 >/dev/null 2>&1 & runner=$!
sleep 0.7
t "claim held while it runs"     "[ \"\$(switch)\" = 1 ] && ls '$CLAIMS' | grep -q '^run:'"
t "reason is the command"        "grep -q '^reason=sleep' '$CLAIMS'/run:*"
wait "$runner"
t "released the moment it exits" "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(switch)\" = 0 ]"

# D1 in one assertion: what needed --force in the single-lease model is now
# simply two claims that cannot see each other.
"$SIMMER" run -- sleep 2 >/dev/null 2>&1 & r1=$!
"$SIMMER" run -- sleep 2 >/dev/null 2>&1 & r2=$!
sleep 0.7
t "two concurrent runs coexist"  "[ \"\$(ls '$CLAIMS' | wc -l | tr -d ' ')\" = 2 ]"
wait "$r1" "$r2"
t "both clean up after"          "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(switch)\" = 0 ]"

# A run finishing must not take a human's claim with it. In v1 this was the
# --force hazard; here it is arithmetic.
"$SIMMER" 2h -r mine --owner terminal >/dev/null 2>&1
"$SIMMER" run -- true >/dev/null 2>&1
t "a run exiting leaves the human's" "[ -f '$(cf terminal)' ] && [ \"\$(switch)\" = 1 ]"
"$SIMMER" down --owner terminal >/dev/null 2>&1

# Renewal, shrunk to test scale: chunk 3s, renew every 1s. A 3s command must
# get its deadline pushed at least once while it runs.
SIMMER_RUN_CHUNK=3s SIMMER_RUN_INTERVAL=1s "$SIMMER" run -- sleep 3 >/dev/null 2>&1 & runner=$!
sleep 0.7
u1="$(grep '^until=' "$CLAIMS"/run:* | cut -d= -f2)"
sleep 1.5
u2="$(grep '^until=' "$CLAIMS"/run:* | cut -d= -f2)"
wait "$runner"
t "renewer extends the deadline" "[ -n '$u1' ] && [ '$u2' -gt '$u1' ]"
t "and still cleans up after"    "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(switch)\" = 0 ]"

# The guard retiring a run's claim must stop the renewer, or a renewal would
# resurrect a claim the guard deliberately ended.
SIMMER_RUN_CHUNK=30s SIMMER_RUN_INTERVAL=1s "$SIMMER" run -- sleep 2 >/dev/null 2>&1 & runner=$!
sleep 0.5
rm -f "$CLAIMS"/run:*
sleep 1.5
t "renewer does not resurrect"   "[ \"\$(ls '$CLAIMS' 2>/dev/null | wc -l | tr -d ' ')\" = 0 ]"
wait "$runner"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

# --max: a hard cap on total awake time. The first chunk is already capped,
# and running out of budget must not kill the command.
RSTART=$(date +%s)
SIMMER_RUN_CHUNK=30s SIMMER_RUN_INTERVAL=1s "$SIMMER" run --max 2s -- sleep 3 >/dev/null 2>&1 & runner=$!
sleep 0.5
umax="$(grep '^until=' "$CLAIMS"/run:* | cut -d= -f2)"
wait "$runner"; maxrc=$?
t "--max caps the first chunk"   "[ -n '$umax' ] && [ '$umax' -le $((RSTART+3)) ]"
t "the command is not killed"    "[ $maxrc = 0 ]"
t "budget exhaustion is logged"  "grep -q 'budget exhausted' '$STATE/simmer.log'"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

# run goes through cmd_take, so the cap applies to it unchanged.
t "run respects the cap"         "$SIMMER cap 1m --owner terminal >/dev/null; $SIMMER run -- true >/dev/null && [ \"\$(switch)\" = 0 ]"
t "a passed cap refuses a run"   "! SIMMER_FAKE_NOW=\$(( \$(date +%s) + 300 )) $SIMMER run -- true 2>/dev/null"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

echo "surfaces render in every state"
claim render 0 $((NOW-600)) render 10 0 "$NOW"
t "swiftbar, open-ended"        "$HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -q '^∞ |'"
t "raycast inline, open-ended"  "$HERE/integrations/raycast/simmer-status.sh | grep -q 'no deadline'"
t "alfred filter emits JSON"    "$HERE/integrations/alfred/simmer-filter.sh '' | python3 -m json.tool"
claim second $((NOW+600)) "$NOW" second 10 0 "$NOW"
t "swiftbar lists the claims"   "$HERE/integrations/swiftbar/simmer.10s.sh | grep -q '2 claims'"
t "raycast counts them"         "$HERE/integrations/raycast/simmer-status.sh | grep -q '2 claims'"
t "swiftbar offers release all" "$HERE/integrations/swiftbar/simmer.10s.sh | grep -q 'Release everything'"
"$SIMMER" cap 4h --owner terminal >/dev/null
t "swiftbar shows the cap"      "$HERE/integrations/swiftbar/simmer.10s.sh | grep -q 'Nothing past'"
t "alfred shows the cap"        "$HERE/integrations/alfred/simmer-filter.sh '' | jq -e '[.items[]|select(.title|test(\"Nothing past\"))]|length==1'"
t "alfred json still parses"    "$HERE/integrations/alfred/simmer-filter.sh '+15m' | python3 -m json.tool"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"
t "swiftbar offers a cap when idle" "$HERE/integrations/swiftbar/simmer.10s.sh | grep -q 'Nothing past…'"
t "swiftbar, idle"              "$HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -q 'sfimage=moon.zzz'"
t "menu bar title has one icon"  "! $HERE/integrations/swiftbar/simmer.10s.sh | head -1 | grep -qE '☕|⏾'"
t "status readable when idle"   "$SIMMER | grep -q 'sleep allowed'"
t "help documents down --all"   "$SIMMER --help | grep -q 'simmer down' && $SIMMER --help | grep -q -- 'down --all'"
t "help documents the cap"      "$SIMMER --help | grep -q 'simmer cap'"
t "help documents --require-ac" "$SIMMER --help | grep -q -- '--require-ac'"
t "help says --force is gone"    "$SIMMER --help | grep -q 'no --force any more'"
t "--version prints"            "$SIMMER --version | grep -q simmer"
t "warns about a lazy lock delay" "SIMMER_FAKE_LOCKDELAY=300 $SIMMER 30m --owner t | grep -q 'UNLOCKED 300s'"
t "silent when lock is immediate" "! $SIMMER 30m --owner t | grep -q UNLOCKED"
t "60s grace stays silent"        "! SIMMER_FAKE_LOCKDELAY=60 $SIMMER 30m --owner t | grep -q UNLOCKED"
t "notify-test runs"            "SIMMER_NOTIFY=auto $SIMMER notify-test >/dev/null 2>&1"
if command -v swiftc >/dev/null 2>&1; then
  t "notifier source compiles"  "swiftc -O -o '$TMP/nb' '$HERE/notifier/main.swift'"
else
  echo "  ⏭  notifier source compiles — no swiftc on this machine"
fi
t "notifier plist parses"       "plutil -lint '$HERE/notifier/Info.plist'"
t "SIMMER_NOTIFY=none is quiet" "SIMMER_NOTIFY=none $SIMMER 5m --owner t >/dev/null"
clear_all; echo 0 > "$SIMMER_FAKE_PMSET"

# Execute every front-end, not just two of them. Two Raycast commands shipped
# broken -- `$SIMMER: unbound variable` -- because nothing ever ran them.
#
# The assertion is "no shell-level failure", not "exit 0": `simmer +15m` with no
# claim exits 1 and is right to. What must never happen is an unbound variable or
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

# Every command reachable from a launcher gets `-r <reason> --owner <name>`
# appended by the Alfred action, whether it has any use for a reason or not.
echo "launcher-shaped invocations"
t "cap via the alfred action"    "$SIMMER cap 2h -r Alfred --owner alfred >/dev/null"
t "cap off via the alfred action" "$SIMMER cap off -r Alfred --owner alfred >/dev/null"
t "down --all via the alfred action" "$SIMMER 1h -r x --owner agent >/dev/null; $SIMMER down --all -r Alfred --owner alfred >/dev/null"
t "raycast down works as a human" "$SIMMER 1h -r x --owner agent >/dev/null; $HERE/integrations/raycast/simmer-down.sh >/dev/null && [ \"\$(switch)\" = 0 ]"

echo
echo "$pass passed, $fail failed"
exit "$fail"
