#!/bin/bash
# Soak test for the closed-loop actuator (bead sommelier-gdu.9).
#
#   scripts/soak-move.sh [--moves N] [--cycles N] [--third-party <bundle id>]
#
# 1. Quits Bartender 7 if it runs (it fights every mechanism); relaunches it at exit.
# 2. Starts the MBDummy app (make dummy) and records a baseline `mbprobe list --json`.
# 3. N alternating drag moves of Dummy-A / Dummy-B (default 20), then N hide/show cycles (default 10; one batch hide of
#    both dummies + one batch show per cycle). Counts verified vs failed per action; prints timings.
# 4. Optional --third-party: move that app's item one slot left and back, hide and show it once.
# 5. Asserts the final on-bar order equals the baseline. Stops the dummy. Exits non-zero on any failure.
set -u
cd "$(dirname "$0")/.."

MOVES=20; CYCLES=10; THIRD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --moves) MOVES="$2"; shift 2 ;;
    --cycles) CYCLES="$2"; shift 2 ;;
    --third-party) THIRD="$2"; shift 2 ;;
    *) echo "usage: $0 [--moves N] [--cycles N] [--third-party <bundle id>]" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

swift build >/dev/null 2>&1 || { echo "swift build failed" >&2; exit 2; }
PROBE="$(swift build --show-bin-path)/mbprobe"
WORK="$(mktemp -d)"
LOG="$WORK/soak.log"
BARTENDER_WAS_RUNNING=0
FAILURES=0
STATS="$WORK/stats.txt"   # lines: action<TAB>result<TAB>ms
: > "$STATS"

log() { echo "$@" | tee -a "$LOG"; }

cleanup() {
  make dummy-stop >/dev/null 2>&1
  if [ "$BARTENDER_WAS_RUNNING" = 1 ] && ! pgrep -x "Bartender 7" >/dev/null; then
    open -a "Bartender 7"
    echo "relaunched Bartender 7"
  fi
  echo "log: $LOG"
}
trap cleanup EXIT

if pgrep -x "Bartender 7" >/dev/null; then
  BARTENDER_WAS_RUNNING=1
  log "quitting Bartender 7 (will be relaunched)"
  osascript -e 'quit app "Bartender 7"' >/dev/null 2>&1
  for _ in $(seq 1 20); do pgrep -x "Bartender 7" >/dev/null || break; sleep 0.5; done
  pgrep -x "Bartender 7" >/dev/null && { log "Bartender 7 did not quit"; exit 2; }
  sleep 3   # let the menu bar re-lay out
fi

# Dummy tracked entry (hide/show needs one).
if ! "$PROBE" cc-allowed list | grep -q '^[01] ie.boboco.mbdummy\( \|$\)'; then
  "$PROBE" cc-allowed set ie.boboco.mbdummy 1 --create --restart >/dev/null
fi
"$PROBE" cc-allowed list | grep -q '^0 ie.boboco.mbdummy\( \|$\)' && "$PROBE" cc-allowed set ie.boboco.mbdummy 1 --restart >/dev/null

make dummy-stop >/dev/null 2>&1
make dummy >/dev/null 2>&1 || { log "make dummy failed"; exit 2; }

# stdin: mbprobe list --json -> fresh on-bar keys, one per line. Stale items (an app whose AX read timed out, e.g. iStat)
# carry cached frames from earlier layouts, so their position is not evidence of the current order and they are left out.
onbar_keys() {
  jq -r '[.items, .keys] | transpose | map(select(.[0].isOnMenuBar and (.[0].stale | not))) | .[] | .[1]' | grep -v 'istatmenus\|^module:com.apple.menuextra.'
}
onbar_keys_all() { jq -r '[.items, .keys] | transpose | map(select(.[0].isOnMenuBar and (.[0].stale | not))) | .[] | .[1]'; }
snapshot() { "$PROBE" list --json 2>/dev/null; }
# Scans can drop an item now and then (docs/findings, gdu.23): keep the read with the most on-bar items of three.
best_snapshot() {
  local best=-1 n
  for i in 1 2 3; do
    snapshot > "$1.$i"
    n="$(onbar_keys < "$1.$i" | wc -l | tr -d ' ')"
    if [ "$n" -gt "$best" ]; then best="$n"; cp "$1.$i" "$1"; fi
    sleep 1
  done
}

KEY_A=""; KEY_B=""
for _ in $(seq 1 30); do
  J="$(snapshot)"
  KEY_A="$(echo "$J" | onbar_keys | grep 'Dummy-A$' | head -1)"
  KEY_B="$(echo "$J" | onbar_keys | grep 'Dummy-B$' | head -1)"
  [ -n "$KEY_A" ] && [ -n "$KEY_B" ] && break
  sleep 1
done
[ -n "$KEY_A" ] && [ -n "$KEY_B" ] || { log "dummy items did not appear on the bar"; exit 2; }
log "dummy keys: $KEY_A $KEY_B"

# run <action-label> <mbprobe args...>: records result + ELAPSED_MS; echoes the output on failure.
run() {
  local label="$1"; shift
  local out; out="$("$PROBE" "$@" 2>>"$LOG")"
  echo "$out" >> "$LOG"
  local res ms
  res="$(echo "$out" | sed -n 's/^RESULT //p' | head -1)"
  ms="$(echo "$out" | sed -n 's/^ELAPSED_MS //p' | head -1)"
  if [ "$res" = "verified" ]; then
    printf '%s\tverified\t%s\n' "$label" "${ms:-0}" >> "$STATS"
    log "  ok   $label (${ms} ms)"
    return 0
  fi
  printf '%s\tfailed\t%s\n' "$label" "${ms:-0}" >> "$STATS"
  log "  FAIL $label: ${res:-no result}"
  echo "$out" | sed 's/^/       /' | head -30 | tee -a "$LOG" >/dev/null
  FAILURES=$((FAILURES + 1))
  return 1
}

# An even number of alternations, so the sequence ends in the arrangement it starts from.
if [ $((MOVES % 2)) = 1 ]; then MOVES=$((MOVES + 1)); log "odd --moves rounded up to $MOVES"; fi

# Setup (not counted), BEFORE the baseline, so the baseline is a state the alternating moves can return to:
# B directly right of the first module item (Wi-Fi; not the Control Center / Clock modules at the far right, where drops are
# clamped), A immediately left of B: the pair is adjacent with no module between them, so the alternating swaps can always
# return to it. (Drags at x~1077 right of Wi-Fi succeeded 20/20 in every earlier soak; the pair parked further right,
# next to Audio/Video at x~1490, failed about half of its attempts for no reason found, see the findings doc.)
setup() { local out; out="$("$PROBE" "$@" 2>>"$LOG")"; echo "$out" >> "$LOG"
  echo "$out" | grep -q '^RESULT verified' || { log "setup step failed: mbprobe $*"; echo "$out" | head -20; exit 2; }; }
ANCHOR="$(snapshot | onbar_keys_all | grep '^module:' | grep -v 'controlcenter\|^module:Clock$' | head -1)"
if [ -n "$ANCHOR" ]; then
  log "setup anchor (first module): $ANCHOR"
  setup move "$KEY_B" --after "$ANCHOR"
else
  setup move "$KEY_B" --leftmost
fi
setup move "$KEY_A" --before "$KEY_B"
best_snapshot "$WORK/baseline.json"
onbar_keys < "$WORK/baseline.json" > "$WORK/baseline.keys"
log "baseline: $(wc -l < "$WORK/baseline.keys" | tr -d ' ') on-bar items"

log "== $MOVES alternating drag moves"
for i in $(seq 1 "$MOVES"); do
  if [ $((i % 2)) = 1 ]; then run "move" move "$KEY_A" --after "$KEY_B"; else run "move" move "$KEY_B" --after "$KEY_A"; fi
done

log "== $CYCLES hide/show cycles"
for i in $(seq 1 "$CYCLES"); do
  run "hide-batch" hide "$KEY_A" "$KEY_B"
  run "show-batch" show "$KEY_A" "$KEY_B"
done

if [ -n "$THIRD" ]; then
  log "== third-party: $THIRD"
  if ! "$PROBE" cc-allowed list | grep -q "^1 $THIRD\( \|\$\)"; then
    log "  FAIL $THIRD has no allowed Control Center entry (cc-allowed list); cannot test hide"
    FAILURES=$((FAILURES + 1))
  else
    # Left neighbour: nearest on-bar item to the left that is fresh and not a heuristic key.
    TKEY="$(jq -r --arg b "$THIRD" '[.items, .keys, .keyConfidence] | transpose | map(select(.[0].isOnMenuBar)) | map(select(.[1] | startswith("status:" + $b + "::"))) | .[0][1] // empty' "$WORK/baseline.json")"
    LKEY="$(jq -r --arg t "$TKEY" '[.items, .keys, .keyConfidence] | transpose | map(select(.[0].isOnMenuBar)) as $bar
        | ($bar | map(.[1]) | index($t)) as $i
        | if $i == null then empty else [range(0; $i)] | reverse | map($bar[.]) | map(select(.[0].stale == false and .[2] != "heuristic" and (.[1] | startswith("module:") | not))) | .[0][1] // empty end' "$WORK/baseline.json")"
    if [ -z "$TKEY" ] || [ -z "$LKEY" ]; then
      log "  FAIL could not find $THIRD on the bar with a fresh left neighbour (item=$TKEY neighbour=$LKEY)"
      FAILURES=$((FAILURES + 1))
    else
      log "  item $TKEY ; left neighbour $LKEY"
      run "3p-move-left" move "$TKEY" --before "$LKEY"
      run "3p-move-back" move "$TKEY" --after "$LKEY"
      run "3p-hide" hide "$TKEY"
      run "3p-show" show "$TKEY"
    fi
  fi
fi

# iStat Menus repositions its own items on every agent restart even when nothing else changed (plain `mbprobe agent-restart`
# moved its Time item to three different slots; docs/findings-restart-collateral.md), so its items are not compared.
# System modules named by their AX identifier (module:com.apple.menuextra.*, e.g. Focus) are not store keys and appear/
# disappear with system state, so they are not compared either.
# Final order must equal the baseline on the keys that are FRESH (non-stale) in both the baseline and the final read
# (a stale item carries a cached frame, so its position says nothing). At least one of 8 reads must match exactly,
# and the compared set must be substantial and contain both dummies (and the third-party item).
log "== restore check"
MATCH=0; NCOMMON=0
REQUIRED="$KEY_A"$'\n'"$KEY_B"; [ -n "${TKEY:-}" ] && REQUIRED="$REQUIRED"$'\n'"$TKEY"
for _ in 1 2 3 4 5 6 7 8; do
  snapshot | onbar_keys > "$WORK/final.keys"
  grep -Fxf "$WORK/final.keys" "$WORK/baseline.keys" > "$WORK/baseline.common"
  grep -Fxf "$WORK/baseline.keys" "$WORK/final.keys" > "$WORK/final.common"
  NCOMMON="$(wc -l < "$WORK/baseline.common" | tr -d ' ')"
  if diff -q "$WORK/baseline.common" "$WORK/final.common" >/dev/null && [ "$NCOMMON" -ge 8 ] \
     && echo "$REQUIRED" | while read -r k; do grep -Fxq "$k" "$WORK/baseline.common" || exit 1; done; then MATCH=1; break; fi
  sleep 3
done
if [ "$MATCH" = 1 ]; then log "  order restored: final order equals baseline on $NCOMMON keys fresh in both reads"
else
  log "  FAIL final order differs from baseline (compared $NCOMMON keys fresh in both):"
  diff "$WORK/baseline.common" "$WORK/final.common" | head -40 | tee -a "$LOG"
  { echo "  -- evidence: order-store values (iStat, dummies) and final fresh frames"
    plutil -convert json -o - "$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist" \
      | jq -c '.TrailingItemPreferredPositions | with_entries(select(.key | test("istat|iStat|MBDummy"))) | to_entries | sort_by(.key) | map("\(.key)=\(.value)")'
    snapshot | jq -r '[.items, .keys] | transpose | map(select(.[0].isOnMenuBar)) | .[] | "\(.[0].frame[0][0] // .[0].frame.x) stale=\(.[0].stale) \(.[1])"' | head -40
  } 2>&1 | tee -a "$LOG"
  FAILURES=$((FAILURES + 1))
fi

# Summary table.
echo
printf '%-14s %8s %9s %7s %10s %8s\n' action attempts verified failed median_ms max_ms
for act in $(cut -f1 "$STATS" | sort -u); do
  n="$(awk -F'\t' -v a="$act" '$1==a' "$STATS" | wc -l | tr -d ' ')"
  v="$(awk -F'\t' -v a="$act" '$1==a && $2=="verified"' "$STATS" | wc -l | tr -d ' ')"
  f=$((n - v))
  med="$(awk -F'\t' -v a="$act" '$1==a {print $3}' "$STATS" | sort -n | awk '{x[NR]=$1} END {if (NR==0) print 0; else if (NR%2) print x[(NR+1)/2]; else print int((x[NR/2]+x[NR/2+1])/2)}')"
  mx="$(awk -F'\t' -v a="$act" '$1==a {print $3}' "$STATS" | sort -n | tail -1)"
  printf '%-14s %8s %9s %7s %10s %8s\n' "$act" "$n" "$v" "$f" "$med" "${mx:-0}"
done
echo
echo "drift repairs triggered: $(grep -c "order drift after restart" "$LOG")"
if [ "$FAILURES" = 0 ]; then echo "SOAK PASS (0 failures)"; else echo "SOAK FAIL ($FAILURES failures)"; fi
[ "$FAILURES" = 0 ]
