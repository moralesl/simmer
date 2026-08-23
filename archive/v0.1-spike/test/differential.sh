#!/bin/bash
# Differential test: drive two simmer binaries through identical CLI scenarios in
# identical fake environments and diff the answers.
#
#   ./test/differential.sh <binary-a> <binary-b>
#   ./test/differential.sh                        # the reference vs this spike
#   ./test/differential.sh --strict <a> <b>       # compare two format=2 implementations
#
# The reference is the `v0.0-lease` tag -- the single-lease design, before the
# claims ledger (override with SIMMER_DIFF_REF). It has to be PINNED, not "the
# previous commit": the declared deltas below only differ from THAT design, so a
# moving reference would turn every one of them into a failure the day after it
# landed. At that ref the implementation lives at bin/simmer, which is why the
# path below is not archive-relative -- that is history, not the current layout.
#
# Why this exists. simmer is being reimplemented, and the safety mechanism that
# replaces incremental caution is "the new one answers what the old one answered".
# The unit suite proves each implementation is internally right; this proves they
# agree with each other. It is the only instrument that catches a message, an
# exit code, a field name or a state value drifting during a port -- the class of
# change nothing else notices, because every individual test still passes.
#
# What is compared, and what is not. CONTRACTS.md says human sentences may be
# reworded at any time and that --json / --machine are the contract, so:
#
#   * exit codes                  compared exactly. They are API.
#   * --machine / --json          compared exactly, after normalisation.
#   * human output                listed when it differs, never fatal.
#
# So a scenario declares which bar applies to it:
#
#   agree     every line must match. For scenarios that print only machine
#             output and exit codes.
#   contract  only contract-bearing lines must match (rc=, switch=, key=value,
#             JSON). Prose differences are printed as information -- guarantee 5
#             says human sentences may be reworded, and during a port they will
#             all be retyped, so making that fatal would make the harness
#             unrunnable exactly when it is most needed.
#   differ    must NOT match. These are the recorded deltas; a scenario here that
#             stops differing is as much a finding as one that starts.
#
# Against v1 the format=2-only fields (claim_count, cap, capped, claims[]) are
# stripped from both sides before comparing: CONTRACTS.md makes the machine
# output append-only, so their presence is conformance, not drift. Comparing two
# format=2 implementations (--strict, and the default once v1 is gone) keeps them.
#
# Normalisation removes everything that legitimately varies between two runs a
# second apart: epochs, wall-clock times, durations, pids, version strings. Both
# sides honour SIMMER_FAKE_NOW where they have it, but v1 does not, so the
# harness cannot rely on a pinned clock for the v1 comparison.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ "${1:-}" = --strict ]; then STRICT=1; shift; else STRICT=0; fi
A="${1:-}"; B="${2:-$HERE/bin/simmer}"
if [ -z "$A" ]; then
  REF="${SIMMER_DIFF_REF:-v0.0-lease}"
  if ! git -C "$HERE" show "$REF:bin/simmer" > "$WORK/ref" 2>/dev/null; then
    # Not an error worth failing a build over: a shallow clone legitimately has
    # no tags. Say what is missing and how to get it, and stop cleanly.
    echo "no reference to compare against: '$REF:bin/simmer' does not resolve."
    echo "In CI: fetch tags (fetch-depth: 0). Locally: git tag v0.0-lease <the pre-claims commit>."
    echo "Or pass two binaries explicitly, or set SIMMER_DIFF_REF."
    echo "(read from git at $REF, where the path was bin/simmer.)"
    exit 0
  fi
  chmod +x "$WORK/ref"; A="$WORK/ref"
  echo "reference: $REF"
fi
[ -x "$A" ] && [ -x "$B" ] || { echo "need two executables (got '$A' '$B')" >&2; exit 2; }

echo "A = $A"
echo "B = $B"
echo

# Everything that can differ between two runs one second apart. Aggressive on
# purpose: a differential that reports the clock moving is a differential nobody
# runs twice.
normalise() {
  sed -E \
    -e 's/[0-9]{10}/EPOCH/g' \
    -e 's/[[:<:]][0-9]{1,2}:[0-9]{2}[[:>:]]/HH:MM/g' \
    -e 's/[0-9]+ h [0-9]+ min/DUR/g' \
    -e 's/[0-9]+ min/DUR/g' \
    -e 's/under 1 min/DUR/g' \
    -e 's/[[:<:]][0-9]+h[0-9]{2}[[:>:]]/SHORT/g' \
    -e 's/[[:<:]][0-9]+m[[:>:]]/SHORT/g' \
    -e 's/run:[0-9]+/run:PID/g' \
    -e 's/\[run [0-9]+\]/[run PID]/g' \
    -e 's/simmer [0-9]+\.[0-9]+\.[0-9]+[^ ]*/simmer VERSION/g' \
    -e 's/"version":"[^"]*"/"version":"VERSION"/g' \
    -e 's/(left|left_short|seconds_left|until|since|cap|set_at)=[^ ]*/\1=N/g' \
    -e 's/"(left|left_short|seconds_left|until|since|cap|set_at)":("[^"]*"|-?[0-9]+)/"\1":N/g' \
    -e 's/^-?[0-9]+$/N/'
}

# The fields format=2 added. Append-only is the contract, so against v1 these are
# conformance rather than drift -- but between two format=2 implementations they
# are part of the surface and must match.
STRIP_V2=1
[ "$STRICT" = 1 ] && STRIP_V2=0
drop_v2_fields() {
  [ "$STRIP_V2" = 1 ] || { cat; return; }
  sed -E \
    -e '/^(claim_count|cap)=/d' \
    -e 's/,"claim_count":[^,}]*//g' \
    -e 's/,"cap":[^,}]*//g' \
    -e 's/,"capped":(true|false)//g' \
    -e 's/,"claims":\[[^]]*\]//g' \
    -e 's/"claim_count":[^,}]*,//g'
}

# One scenario in one throwaway environment, against one binary.
run_one() { # <binary> <scenario-script>
  local bin="$1" script="$2" env; env="$(mktemp -d "$WORK/env.XXXXXX")"
  (
    export XDG_STATE_HOME="$env/state"
    export SIMMER_FAKE_PMSET="$env/sw"; mkdir -p "$env"; echo 0 > "$SIMMER_FAKE_PMSET"
    export SIMMER_NOTIFY=none SIMMER_FAKE_THERMAL=0 SIMMER_FAKE_LOCKDELAY=0
    export SIMMER_FAKE_BATTERY="80:0" SIMMER_NOTIFIER_APP="$env/NoSuch.app"
    export SIMMER_BIN="$bin"
    S="$bin"
    sw() { cat "$SIMMER_FAKE_PMSET"; }
    # shellcheck disable=SC1090
    . "$script"
  ) 2>&1
  local rc=$?
  rm -rf "$env"
  return $rc
}

# What the contract actually freezes: exit codes, the switch, key=value machine
# output, and JSON. Everything else on stdout is prose written for a person.
contract_lines() { grep -E '^(rc=|switch=|[a-z_]+=|\{|N$|[0-9])' || true; }

pass=0; differ=0; expected=0; prose=0
CASES="$WORK/cases"; mkdir -p "$CASES"
n=0

# A scenario is a shell fragment. It must print its own evidence: the harness
# only diffs what it prints, so `echo "rc=$?"` after anything whose exit code
# matters is the whole discipline here.
scenario() { # <name> <mode: agree|differ> <script text>
  n=$((n+1))
  local name="$1" mode="$2" body="$3"
  local f="$CASES/$n.sh"; printf '%s\n' "$body" > "$f"
  local oa ob ca cb
  oa="$(run_one "$A" "$f" | normalise | drop_v2_fields)"
  ob="$(run_one "$B" "$f" | normalise | drop_v2_fields)"
  if [ "$mode" = contract ]; then
    ca="$(printf '%s\n' "$oa" | contract_lines)"
    cb="$(printf '%s\n' "$ob" | contract_lines)"
    if [ "$ca" = "$cb" ]; then
      if [ "$oa" = "$ob" ]; then echo "  ✅ $name"
      else
        echo "  ✅ $name — contract identical, prose differs:"
        diff <(printf '%s\n' "$oa") <(printf '%s\n' "$ob") | grep -E '^[<>]' | sed 's/^/       /'
        prose=$((prose+1))
      fi
      pass=$((pass+1))
    else
      echo "  ❌ $name — CONTRACT differs"
      differ=$((differ+1))
      diff <(printf '%s\n' "$ca") <(printf '%s\n' "$cb") | sed 's/^/       /'
    fi
    return 0
  fi
  if [ "$oa" = "$ob" ]; then
    if [ "$mode" = differ ]; then
      echo "  ⚠️  $name — expected a difference, got none"
      differ=$((differ+1))
    else
      echo "  ✅ $name"; pass=$((pass+1))
    fi
  else
    if [ "$mode" = differ ]; then
      echo "  ➖ $name — differs, as documented"
      expected=$((expected+1))
    else
      echo "  ❌ $name"
      differ=$((differ+1))
      diff <(printf '%s\n' "$oa") <(printf '%s\n' "$ob") | sed 's/^/       /'
    fi
  fi
}

echo "must agree — the contract-shared surface"

scenario "duration parsing" contract '
for d in 90 90m 1h 1h30m 45min 2h15 30s 2H 5x7 abc 1h2x; do
  $S budget --need "$d" >/dev/null 2>&1; echo "$d -> $?"
done'

scenario "help and version" agree '
$S --version; echo "rc=$?"
$S --help | wc -l | tr -d " "'

scenario "budget with nothing claimed" contract '
$S budget; echo "rc=$?"
$S budget --need 20m; echo "rc=$?"
$S budget --seconds; echo "rc=$?"
$S budget --json; echo "rc=$?"
$S status --machine
$S status --json
$S'

scenario "orphan: switch on, nothing claimed" contract '
echo 1 > "$SIMMER_FAKE_PMSET"
$S; echo "rc=$?"
$S status --machine
$S budget --json; echo "rc=$?"'

scenario "take, status, budget, extend, down" contract '
$S 2h -r "the reason" --owner terminal; echo "rc=$?"
echo "switch=$(sw)"
$S; echo "rc=$?"
$S status --machine
$S status --json
$S budget; echo "rc=$?"
$S budget --need 10m; echo "rc=$?"
$S budget --need 5h; echo "rc=$?"
$S budget --seconds
$S budget --json
$S +30m --owner terminal; echo "rc=$?"
$S status --machine
$S down --owner terminal; echo "rc=$?"
echo "switch=$(sw)"'

scenario "forever" contract '
$S forever -r nightly --owner terminal; echo "rc=$?"
$S status --machine
$S status --json
$S budget --seconds
$S budget --need 99h; echo "rc=$?"
$S +10m --owner terminal 2>&1; echo "rc=$?"
$S down --owner terminal; echo "rc=$?"'

scenario "--until and --min-battery" contract '
$S --until 23:00 -r evening --owner terminal >/dev/null; echo "rc=$?"
$S status --machine | grep -E "^(state|min_battery)="
$S down --owner terminal >/dev/null
$S 1h --min-battery 45 --owner terminal >/dev/null; echo "rc=$?"
$S status --machine | grep "^min_battery="
$S down --owner terminal >/dev/null
$S 1h --min-battery banana --owner terminal 2>&1; echo "rc=$?"
$S --until 99:99 --owner terminal 2>&1; echo "rc=$?"
$S --owner terminal 2>&1; echo "rc=$?"
$S nonsense --owner terminal 2>&1; echo "rc=$?"
$S 1h --bogus-flag --owner terminal 2>&1; echo "rc=$?"'

scenario "the battery floor refuses" contract '
SIMMER_FAKE_BATTERY=10:1 $S 30m --min-battery 20 --owner terminal 2>&1; echo "rc=$?"
echo "switch=$(sw)"'

scenario "guard: deadline passes" agree '
$S 30s -r short --owner terminal >/dev/null
echo "switch=$(sw)"
sleep 1
$S guard; echo "rc=$?"
echo "still=$(sw)"
$S status --machine | grep "^state="'

scenario "guard: battery below the floor" agree '
$S 1h -r x --owner terminal >/dev/null
SIMMER_FAKE_BATTERY=12:1 $S guard; echo "rc=$?"
echo "switch=$(sw)"
$S status --machine | grep "^state="'

scenario "guard: charging ignores the floor" agree '
$S 1h -r x --owner terminal >/dev/null
SIMMER_FAKE_BATTERY=12:0 $S guard; echo "rc=$?"
echo "switch=$(sw)"
$S status --machine | grep "^state="'

scenario "guard: thermal pressure" agree '
$S 1h -r x --owner terminal >/dev/null
SIMMER_FAKE_THERMAL=2 $S guard; echo "rc=$?"
echo "switch=$(sw)"'

scenario "guard: heals an orphan switch" agree '
echo 1 > "$SIMMER_FAKE_PMSET"
$S guard; echo "rc=$?"
echo "switch=$(sw)"'

scenario "guard: restores the switch inside a claim" agree '
$S 1h -r x --owner terminal >/dev/null
echo 0 > "$SIMMER_FAKE_PMSET"
$S guard; echo "rc=$?"
echo "switch=$(sw)"'

scenario "run: exit codes pass through" contract '
$S run -- true >/dev/null 2>&1; echo "true=$?"
$S run -- false >/dev/null 2>&1; echo "false=$?"
$S run -- sh -c "exit 7" >/dev/null 2>&1; echo "seven=$?"
$S run true 2>&1; echo "no-dashdash=$?"
$S run 2>&1; echo "nothing=$?"
echo "switch=$(sw)"'

scenario "run: --max does not kill the command" agree '
SIMMER_RUN_CHUNK=30s SIMMER_RUN_INTERVAL=1s $S run --max 2s -- sleep 3 >/dev/null 2>&1
echo "rc=$?"
echo "switch=$(sw)"'

scenario "renderers, one claim" contract '
$S 2h -r render --owner terminal >/dev/null
$S render raycast
$S render swiftbar | head -6
$S render alfred "" | head -c 200; echo
$S down --owner terminal >/dev/null'

scenario "renderers, idle and orphan" contract '
$S render raycast
$S render swiftbar | head -2
echo 1 > "$SIMMER_FAKE_PMSET"
$S render raycast
$S render swiftbar | head -2
$S render bogus 2>&1; echo "rc=$?"'

scenario "renderers, forever" contract '
$S forever -r nightly --owner terminal >/dev/null
$S render raycast
$S render swiftbar | head -2
$S down --owner terminal >/dev/null'

scenario "json escaping" agree '
$S 60s -r "he said \"hi\" via C:\\temp\\ done" --owner terminal >/dev/null
$S status --json | python3 -c "import json,sys;print(repr(json.load(sys.stdin)[\"reason\"]))"
$S down --owner terminal >/dev/null'

echo
echo "must differ — D1's documented deltas"

scenario "a second owner is refused (v1) / gets a claim (v2)" differ '
$S 1h -r human --owner menubar >/dev/null
$S 1h -r bot --owner agent 2>&1; echo "rc=$?"
$S status --machine | grep -E "^(state|owner)="'

scenario "--force" differ '
$S 1h -r human --owner menubar >/dev/null
$S 1h -r bot --owner agent --force 2>&1; echo "rc=$?"'

scenario "down releases only your own" differ '
$S 2h -r human --owner terminal >/dev/null
$S 1h -r bot --owner agent >/dev/null
$S down --owner agent 2>&1; echo "rc=$?"
echo "switch=$(sw)"'

scenario "a non-owner cannot release" differ '
$S 2h -r human --owner terminal >/dev/null
$S down --owner agent 2>&1; echo "rc=$?"
echo "switch=$(sw)"'

scenario "the cap does not exist in v1" differ '
$S cap 23:00 --owner terminal 2>&1; echo "rc=$?"'

scenario "--require-ac does not exist in v1" differ '
$S 1h --require-ac --owner terminal 2>&1; echo "rc=$?"'

scenario "SIMMER_FAKE_NOW is not honoured by v1" differ '
SIMMER_FAKE_NOW=1800000000 $S 1h --owner terminal >/dev/null
u=$($S status --json | python3 -c "import json,sys;print(json.load(sys.stdin)[\"until\"])")
[ "$u" = 1800003600 ] && echo "clock=pinned" || echo "clock=real"'

scenario "two concurrent runs" differ '
$S run -- sleep 2 >/dev/null 2>&1 &
r1=$!
$S run -- sleep 2 >/dev/null 2>&1 &
r2=$!
sleep 0.8
$S status --machine | grep -E "^state="
c=$($S status --json | python3 -c "import json,sys;print(len(json.load(sys.stdin).get(\"claims\",[])))")
echo "concurrent=$c"
wait $r1 $r2 2>/dev/null
echo "switch=$(sw)"'

echo
echo "$pass agree ($prose with reworded prose) · $expected differ as documented · $differ unexpected"
exit "$differ"
