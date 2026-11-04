#!/bin/bash
# Soak test for the engine's event handling (bead sommelier-gdu.21). Exercises the APP's engine (not mbprobe apply).
#
#   scripts/soak-events.sh [--relaunches N] [--toggles N] [--allow-respawn]
#
# 1. Quits Bartender 7 if it runs (relaunched at exit). Starts MBDummy and writes a SCRATCH layout (init-from-current;
#    the user's real hidden items go to "always hidden" so a reveal never touches them). The real layout.json is never read
#    or written: the app runs with SOMMELIER_LAYOUT_FILE=<scratch>.
# 2. Phase V: dummies VISIBLE in the layout. N/2 times: `make dummy-stop`, wait 3 s, `make dummy`, then poll `mbprobe list --json`
#    until the on-bar order (dummies included) equals the baseline (30 s timeout).
# 3. Phase H: the app restarts on a layout with the dummies HIDDEN. N/2 relaunch cycles: converged = dummies not on the bar and
#    every other item in its baseline order.
# 4. Phase R: M reveal toggles (show hidden section / hide it) through SOMMELIER_DEBUG_REVEAL_FILE (Sommelier's own item can sit
#    in Apple's overflow where it cannot be clicked, so the left click is replaced by the debug file; same engine call as the
#    click in "inline" mode): dummies must appear on the bar, then disappear again.
# Safety: the app is never stopped while the engine acts. Every stop (restart between phases, exit handler) first waits, up to 60 s,
#    for the app log to show the latest pass reaching `plan: phase=converged` after the last request, with no new actuator output for
#    2 s; on timeout it says so and leaves the app RUNNING instead of killing a batch or drag.
#    The baseline is captured BEFORE the app starts and compared in full (exact equality of the non-dummy key list).
# 5. Asserts the final on-bar order of the non-dummy items equals the baseline and the dummies match the layout; counts
#    MenuBarAgent respawns (pid before/after) and fails if > 0 unless --allow-respawn. Prints a summary table; exits non-zero on
#    any assertion failure. The dummy's Control Center entry must exist (`mbprobe cc-allowed list`); this script never respawns
#    the agent to create it.
set -u
cd "$(dirname "$0")/.."

N=10; TOGGLES=10; ALLOW_RESPAWN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --relaunches) N="$2"; shift 2 ;;
    --toggles) TOGGLES="$2"; shift 2 ;;
    --allow-respawn) ALLOW_RESPAWN=1; shift ;;
    *) echo "usage: $0 [--relaunches N] [--toggles N] [--allow-respawn]" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

make app >/dev/null 2>&1 || { echo "make app failed" >&2; exit 2; }
PROBE="$(swift build --show-bin-path)/mbprobe"
WORK="$(mktemp -d)"
LAYOUT="$WORK/layout.json"
REVEAL="$WORK/reveal"
LOG="$WORK/soak.log"
STATS="$WORK/stats.txt"   # phase<TAB>ok|fail<TAB>seconds
: > "$STATS"
FAILURES=0
BARTENDER_WAS_RUNNING=0
APP_LOG="$PWD/build/sommelier.log"

log() { echo "$@" | tee -a "$LOG"; }

LAST_PS=0
ps_count() { grep -c 'pass started' "$APP_LOG" 2>/dev/null || true; }
# request_reveal show|hide: records how many passes had started, so idleness is judged on a pass started AFTER the request.
request_reveal() { LAST_PS="$(ps_count)"; echo "$1" > "$REVEAL"; }

# wait_idle [timeout s]: 0 when the latest pass has reached `plan: phase=converged` (no later `pass started`), at least one pass started
# after the last request, and nothing new was logged by the actuator for 2 s. 1 on timeout (nothing is killed then).
wait_idle() {
  local limit="${1:-60}" t0 plan_line ps_line a1 a2
  t0="$(date +%s)"
  while :; do
    pgrep -x Sommelier >/dev/null || return 0
    plan_line="$(grep -n 'plan: phase=' "$APP_LOG" | tail -1)"
    ps_line="$(grep -n 'pass started' "$APP_LOG" | tail -1 | cut -d: -f1)"
    if [ "$(ps_count)" -gt "$LAST_PS" ] && echo "$plan_line" | grep -q 'plan: phase=converged' && [ "${plan_line%%:*}" -gt "${ps_line:-0}" ]; then
      a1="$(grep -c 'actuator:' "$APP_LOG")"; sleep 2; a2="$(grep -c 'actuator:' "$APP_LOG")"
      [ "$a1" = "$a2" ] && [ "$(grep -n 'plan: phase=' "$APP_LOG" | tail -1)" = "$plan_line" ] && return 0
    fi
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && return 1
    sleep 1
  done
}

# stop_app: stops Sommelier only when the engine is idle; otherwise reports and leaves it running (returns 1).
stop_app() {
  if ! wait_idle 60; then
    echo "ERROR: Sommelier's engine was not idle after 60 s (last plan: $(grep 'plan: phase=' "$APP_LOG" | tail -1 | cut -c1-120)); NOT killing it mid-pass. Stop it by hand: pkill -x Sommelier"
    return 1
  fi
  pkill -x Sommelier >/dev/null 2>&1
  return 0
}

cleanup() {
  stop_app || FAILURES=$((FAILURES + 1))
  make dummy-stop >/dev/null 2>&1
  if [ "$BARTENDER_WAS_RUNNING" = 1 ] && ! pgrep -x "Bartender 7" >/dev/null; then
    open -a "Bartender 7"; echo "relaunched Bartender 7"
  fi
  echo "log: $LOG  scratch layout: $LAYOUT  app log: $APP_LOG"
}
trap cleanup EXIT

if pgrep -x "Bartender 7" >/dev/null; then
  BARTENDER_WAS_RUNNING=1
  log "quitting Bartender 7 (will be relaunched)"
  osascript -e 'tell application "Bartender 7" to quit' >/dev/null 2>&1
  for _ in $(seq 1 20); do pgrep -x "Bartender 7" >/dev/null || break; sleep 0.5; done
  pgrep -x "Bartender 7" >/dev/null && { log "Bartender 7 did not quit"; exit 2; }
  sleep 3
fi
pgrep -x Sommelier >/dev/null && { echo "Sommelier is already running; stop it first (and let it finish)" >&2; exit 2; }

"$PROBE" cc-allowed list | grep -q '^1 ie.boboco.mbdummy\( \|$\)' \
  || { log "no ALLOWED Control Center entry for ie.boboco.mbdummy (mbprobe cc-allowed list); create it once with 'mbprobe cc-allowed set ie.boboco.mbdummy 1 --create --restart' (respawns the agent)"; exit 2; }

agent_pid() { pgrep -x MenuBarAgent | head -1; }
AGENT_BEFORE="$(agent_pid)"

# Fresh, on-bar keys in bar order from `mbprobe list --json` on stdin. Heuristic keys (chevron, unnamed items), iStat items
# (they reposition themselves) and AX-identifier system modules (Focus) and the Wi-Fi module (which flickers in and out of the read, see AgreedScanObserver.defaultVolatileKeys) are not compared.
onbar() { jq -r '[.items, .keys] | transpose | map(select(.[0].isOnMenuBar and (.[0].stale | not))) | .[] | .[1]' | grep -v '^heuristic:\|istatmenus\|^module:com.apple.menuextra.\|^module:WiFi$\|^module:FocusModes$'; }
snapshot() { "$PROBE" list --json 2>/dev/null; }
is_dummy() { grep -q '^status:MBDummy::'; }
# Order of the keys of $1 that also occur in $2 (common keys, order of $1).
common_in() { grep -Fxf "$2" "$1"; }

start_app() {   # start_app <layout file>
  if pgrep -x Sommelier >/dev/null; then
    stop_app || { log "FAIL cannot stop the running app safely"; FAILURES=$((FAILURES + 1)); exit 1; }
    sleep 1
  fi
  : > "$APP_LOG"; LAST_PS=0
  SOMMELIER_LAYOUT_FILE="$1" SOMMELIER_DEBUG_REVEAL_FILE="$REVEAL" "$PWD/build/Sommelier.app/Contents/MacOS/Sommelier" > "$APP_LOG" 2>&1 &
  disown
  sleep 2
  pgrep -x Sommelier >/dev/null || { log "Sommelier did not start"; exit 2; }
  wait_idle 90 || log "note: first passes not converged after 90 s"
}

# Starts the dummy app and waits until it runs and the agent has had time to host (or, when hidden, not host) its items, so that a
# "hidden" check cannot pass merely because the dummy has not appeared yet.
start_dummies() {
  make dummy >/dev/null 2>&1 || { log "make dummy failed"; exit 2; }
  for _ in $(seq 1 20); do pgrep -x MBDummy >/dev/null && break; sleep 0.5; done
  pgrep -x MBDummy >/dev/null || { log "MBDummy did not start"; exit 2; }
  sleep 4
}

# wait_for <mode> <timeout s>: mode "visible" = the full on-bar key list (dummies included) equals the baseline exactly; mode "hidden" =
# no dummy on the bar and the full non-dummy list equals the baseline's exactly.
wait_for() {
  local mode="$1" limit="$2" t0 now
  t0="$(date +%s)"
  while :; do
    snapshot | onbar > "$WORK/cur.keys"
    if [ "$mode" = visible ]; then
      cp "$WORK/cur.keys" "$WORK/c1"; cp "$WORK/base.all" "$WORK/c2"
      if diff -q "$WORK/c1" "$WORK/c2" >/dev/null; then
        echo $(( $(date +%s) - t0 )); return 0
      fi
    else
      grep -v '^status:MBDummy::' "$WORK/cur.keys" > "$WORK/cur.others"
      cp "$WORK/cur.others" "$WORK/c1"; cp "$WORK/base.others" "$WORK/c2"
      if ! grep -q '^status:MBDummy::' "$WORK/cur.keys" && diff -q "$WORK/c1" "$WORK/c2" >/dev/null; then
        echo $(( $(date +%s) - t0 )); return 0
      fi
    fi
    now="$(date +%s)"; [ $((now - t0)) -ge "$limit" ] && { echo $((now - t0)); return 1; }
    sleep 1
  done
}

record() {   # record <phase> <label> <seconds> <rc>
  if [ "$4" = 0 ]; then printf '%s\tok\t%s\n' "$1" "$3" >> "$STATS"; log "  ok   $2 (${3}s)"
  else printf '%s\tfail\t%s\n' "$1" "$3" >> "$STATS"; log "  FAIL $2: not converged after ${3}s"; FAILURES=$((FAILURES + 1))
    { echo "  -- on bar now:"; sed 's/^/     /' "$WORK/cur.keys"; echo "  -- baseline:"; sed 's/^/     /' "$WORK/base.all"; } >> "$LOG"
  fi
}

# --- setup: dummies on the bar, scratch layout, baseline -----------------------------------------------------------------
make dummy-stop >/dev/null 2>&1
start_dummies
for _ in $(seq 1 30); do snapshot | onbar | is_dummy && break; sleep 1; done
sleep 3
# Baseline BEFORE the app starts: two consecutive identical reads of the on-bar key list (dummies visible, nothing managing the bar).
PREV=""
for _ in $(seq 1 12); do
  snapshot | onbar > "$WORK/b.try"
  if [ -n "$PREV" ] && diff -q "$PREV" "$WORK/b.try" >/dev/null; then cp "$WORK/b.try" "$WORK/base.all"; break; fi
  cp "$WORK/b.try" "$WORK/prev.keys"; PREV="$WORK/prev.keys"; sleep 1
done
[ -s "$WORK/base.all" ] || { log "no stable baseline read"; exit 2; }
grep -v '^status:MBDummy::' "$WORK/base.all" > "$WORK/base.others"
log "baseline (before the app starts): $(wc -l < "$WORK/base.all" | tr -d ' ') on-bar items ($(wc -l < "$WORK/base.others" | tr -d ' ') non-dummy)"
grep -q '^status:MBDummy::' "$WORK/base.all" || { log "baseline has no dummy on the bar"; exit 2; }

"$PROBE" layout init-from-current --file "$LAYOUT" --force > "$WORK/init.out" 2>&1 || { log "init-from-current failed"; cat "$WORK/init.out"; exit 2; }
# The dummies stay where init-from-current saw them (their start position on the bar), so a relaunch never moves them across the bar.
# The user's real hidden items go to "always hidden": revealing the hidden section must only ever show the dummies.
for key in $(jq -r '.hidden[]' "$LAYOUT"); do
  "$PROBE" layout move "$key" always --file "$LAYOUT" >/dev/null 2>&1
done
KEY_A="$(jq -r '.visible[]' "$LAYOUT" | grep 'Dummy-A$')"; KEY_B="$(jq -r '.visible[]' "$LAYOUT" | grep 'Dummy-B$')"
[ -n "$KEY_A" ] && [ -n "$KEY_B" ] || { log "dummies are not in the scratch layout's visible section"; exit 2; }
cp "$LAYOUT" "$WORK/layout.visible.json"
log "scratch layout: $(jq '.visible|length' "$LAYOUT") visible, $(jq '.hidden|length' "$LAYOUT") hidden, $(jq '.alwaysHidden|length' "$LAYOUT") always hidden; dummies $KEY_A $KEY_B"

echo hide > "$REVEAL"
start_app "$LAYOUT"

# --- phase V -------------------------------------------------------------------------------------------------------------
NV=$(( (N + 1) / 2 )); NH=$(( N / 2 ))
log "== phase V: $NV relaunches of the dummy app, dummies VISIBLE in the layout"
for i in $(seq 1 "$NV"); do
  make dummy-stop >/dev/null 2>&1; sleep 3; start_dummies
  s="$(wait_for visible 30)"; rc=$?; record V "relaunch $i" "$s" "$rc"
done

# --- phase H -------------------------------------------------------------------------------------------------------------
log "== phase H: app restarted on a layout with the dummies HIDDEN, $NH relaunches"
jq --arg a "$KEY_A" --arg b "$KEY_B" '.visible -= [$a, $b] | .hidden = [$a, $b] + .hidden' "$WORK/layout.visible.json" > "$LAYOUT"
start_app "$LAYOUT"
s="$(wait_for hidden 60)"; rc=$?; record H "dummies hidden by the engine" "$s" "$rc"
for i in $(seq 1 "$NH"); do
  make dummy-stop >/dev/null 2>&1; sleep 3; start_dummies
  s="$(wait_for hidden 30)"; rc=$?; record H "relaunch $i" "$s" "$rc"
done

# --- phase R -------------------------------------------------------------------------------------------------------------
log "== phase R: $TOGGLES reveal toggles (show/hide the hidden section)"
for i in $(seq 1 "$TOGGLES"); do
  request_reveal show
  t0="$(date +%s)"; ok=1
  for _ in $(seq 1 40); do snapshot | onbar > "$WORK/cur.keys"; [ "$(grep -c '^status:MBDummy::' "$WORK/cur.keys")" = 2 ] && { ok=0; break; }; sleep 1; done
  record R "reveal $i: dummies shown" "$(( $(date +%s) - t0 ))" "$ok"
  request_reveal hide
  s="$(wait_for hidden 40)"; rc=$?; record R "reveal $i: hidden again" "$s" "$rc"
done

# --- final assertions ----------------------------------------------------------------------------------------------------
log "== final check"
s="$(wait_for hidden 30)"; rc=$?
if [ "$rc" = 0 ]; then log "  ok   non-dummy order equals the baseline; dummies hidden as in the layout"; printf 'final\tok\t%s\n' "$s" >> "$STATS"
else log "  FAIL final order differs from the baseline"; printf 'final\tfail\t%s\n' "$s" >> "$STATS"; FAILURES=$((FAILURES + 1)); diff "$WORK/c1" "$WORK/c2" | head -20 | tee -a "$LOG"; fi
AGENT_AFTER="$(agent_pid)"
if [ "$AGENT_BEFORE" != "$AGENT_AFTER" ]; then
  if [ "$ALLOW_RESPAWN" = 1 ]; then log "  note MenuBarAgent respawned ($AGENT_BEFORE -> $AGENT_AFTER); allowed"
  else log "  FAIL MenuBarAgent respawned ($AGENT_BEFORE -> $AGENT_AFTER)"; FAILURES=$((FAILURES + 1)); fi
fi
# Leave the dummies shown in the store (allowed) so the next run needs no write.
request_reveal show
wait_idle 60 || log "note: engine not idle 60 s after the last request"

echo
printf '%-8s %8s %6s %6s %10s\n' phase attempts ok fail max_s
for ph in V H R final; do
  n="$(awk -F'\t' -v p="$ph" '$1==p' "$STATS" | wc -l | tr -d ' ')"; [ "$n" = 0 ] && continue
  o="$(awk -F'\t' -v p="$ph" '$1==p && $2=="ok"' "$STATS" | wc -l | tr -d ' ')"
  mx="$(awk -F'\t' -v p="$ph" '$1==p {print $3}' "$STATS" | sort -n | tail -1)"
  printf '%-8s %8s %6s %6s %10s\n' "$ph" "$n" "$o" "$((n - o))" "$mx"
done
echo
echo "MenuBarAgent pid: $AGENT_BEFORE -> $AGENT_AFTER ($([ "$AGENT_BEFORE" = "$AGENT_AFTER" ] && echo 'no respawn' || echo 'RESPAWNED'))"
echo "engine failures logged: $(grep -c 'marked failed until\|stopped after' "$APP_LOG")"
if [ "$FAILURES" = 0 ]; then echo "SOAK PASS (0 failures)"; else echo "SOAK FAIL ($FAILURES failures)"; fi
[ "$FAILURES" = 0 ]
