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
# Scope: the soak asserts the order of THIRD-PARTY items and the dummies' states; system items (module:*, status:com.apple.*) are
#    macOS-ordered and excluded from every comparison (phases and final), as are heuristic keys and iStat items.
# Self-tests (also: --selftest runs them alone and exits 0): the volatile-key filter, and the respawn attribution, which counts only app-log
#    lines stamped at or after the soak's start (an own-fallback line from an earlier run can never excuse a foreign respawn).
# Safety: the app is never stopped while the engine acts. Every stop (restart between phases, exit handler) first waits, up to 60 s,
#    for the app log to show the latest pass reaching `plan: phase=converged` after the last request, with no new actuator output for
#    2 s; on timeout it says so and leaves the app RUNNING instead of killing a batch or drag. The idle check is repeated after that quiet
#    period: if a new `pass started` line appeared after the last converged plan, it waits for that pass's plan too (same 60 s bound).
#    Only the Sommelier this script launched is ever stopped, and by pid (never by name); a Sommelier that was already running makes the
#    script exit 2 before it touches Bartender or any dummy.
#    The baseline is captured BEFORE the app starts and compared in full (exact equality of the non-dummy key list).
# Respawn rule: a MenuBarAgent pid change the app log attributes to Sommelier's own fallback (`agent restarted by Sommelier (expected)` or
#    `falling back to respawn`) makes that phase INCONCLUSIVE ("own fallback respawn (slow reads)"); a change with no such line is a FAIL
#    ("foreign respawn"). More than 3 inconclusive phases fail the soak.
# 5. Asserts the final on-bar order of the non-dummy items equals the baseline and the dummies match the layout; counts
#    MenuBarAgent respawns (pid before/after) and fails if > 0 unless --allow-respawn. Prints a summary table; exits non-zero on
#    any assertion failure. The dummy's Control Center entry must exist (`mbprobe cc-allowed list`); this script never respawns
#    the agent to create it.
set -u
cd "$(dirname "$0")/.."

N=10; TOGGLES=10; ALLOW_RESPAWN=0; SELFTEST_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --relaunches) N="$2"; shift 2 ;;
    --toggles) TOGGLES="$2"; shift 2 ;;
    --allow-respawn) ALLOW_RESPAWN=1; shift ;;
    --selftest) SELFTEST_ONLY=1; shift ;;
    *) echo "usage: $0 [--relaunches N] [--toggles N] [--allow-respawn] [--selftest]" >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# One -e per pattern: macOS grep honours `$` only at the end of the whole pattern, so a `$` inside an alternation never matched.
# System items are macOS-ordered (it re-bases them on every agent respawn) and Sommelier does not manage them: `module:*` and `status:com.apple.*`.
volatile_filter() { grep -Ev -e '^heuristic:' -e 'istatmenus' -e '^module:' -e '^status:com\.apple\.' ; }

# own_fallback_count <since> <files...>: lines of the app log(s) at or after the timestamp <since> ("YYYY-MM-DD HH:MM:SS.mmm", the
# NSLog prefix) that attribute an agent respawn to Sommelier's own fallback. Lines from before the soak started never count.
own_fallback_count() {
  local since="$1"; shift
  cat "$@" 2>/dev/null | awk -v since="$since" 'substr($0, 1, 23) >= since && (index($0, "agent restarted by Sommelier (expected)") || index($0, "falling back to respawn")) { n++ } END { print n + 0 }'
}
# respawn_verdict <since> <seen> <files...>: prints "own <n>" when the logs hold more own-fallback lines (n) than already attributed
# to earlier phases (<seen>), else "foreign <n>".
respawn_verdict() {
  local since="$1" seen="$2" n; shift 2
  n="$(own_fallback_count "$since" "$@")"
  if [ "$n" -gt "$seen" ]; then echo "own $n"; else echo "foreign $n"; fi
}

selftest() {
  local t; t="$(mktemp -d)"
  # (1) the volatile-key filter: system items out, third-party items and the dummies in.
  [ -z "$(printf 'module:WiFi\nmodule:AudioVideoModule\nmodule:Clock\nstatus:com.apple.TextInputMenuAgent::Item-0\n' | volatile_filter)" ] \
    && [ "$(printf 'status:MBDummy::Dummy-A\nstatus:com.corsair.ControlCenter::Item-0\nstatus:ie.boboco.vpnswitch::Item-0\n' | volatile_filter | wc -l | tr -d ' ')" = 3 ] \
    || { echo "self-test failed: the volatile-key filter does not behave" >&2; rm -rf "$t"; return 1; }
  # (2) an own-fallback line from BEFORE the soak started must not excuse a respawn; the same line after the start does.
  printf '2026-11-04 19:30:00.000 Sommelier[1:2] [Sommelier] engine: actuator: live verify failed; falling back to respawn\n' > "$t/old.log"
  printf '2026-11-04 20:05:00.000 Sommelier[1:2] [Sommelier] engine: actuator: live verify failed; falling back to respawn\n' > "$t/new.log"
  [ "$(respawn_verdict '2026-11-04 20:00:00.000' 0 "$t/old.log")" = "foreign 0" ] \
    && [ "$(respawn_verdict '2026-11-04 20:00:00.000' 0 "$t/new.log")" = "own 1" ] \
    && [ "$(respawn_verdict '2026-11-04 20:00:00.000' 1 "$t/new.log")" = "foreign 1" ] \
    || { echo "self-test failed: respawn attribution (stale or leaked own-fallback lines)" >&2; rm -rf "$t"; return 1; }
  rm -rf "$t"
}
selftest || exit 2
if [ "$SELFTEST_ONLY" = 1 ]; then echo "self-tests passed"; exit 0; fi
SOAK_START="$(date '+%Y-%m-%d %H:%M:%S.000')"

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
INCONCLUSIVE=0
APP_STARTED=0
SOM_PID=""   # pid of the Sommelier THIS script started; the only one it ever stops
app_alive() { [ -n "$SOM_PID" ] && kill -0 "$SOM_PID" 2>/dev/null; }
# unsettled_reason: prints why the latest observation in the app log was not a settled, complete read (nothing when it was, or when
# the latest event is a plan). Used to tell "engine idle, but the bar could not be read reliably" from a real failure.
unsettled_reason() {
  local last
  last="$(grep -E 'observe scan [0-9]+:|observation unsettled|plan: phase=' "$APP_LOG" 2>/dev/null | tail -1)"
  case "$last" in
    *"plan: phase="*) return 0 ;;
    *"observation unsettled"*) echo "latest observation unsettled"; return 0 ;;
    *"hostedComplete=false"*) echo "latest read incomplete (hostedComplete=false)"; return 0 ;;
    *onBarStale=[1-9]*) echo "latest read has stale on-bar items"; return 0 ;;
    *"agree=false"*) echo "latest scans did not agree"; return 0 ;;
  esac
  return 0
}
ps_count() { grep -c 'pass started' "$APP_LOG" 2>/dev/null || true; }
# request_reveal show|hide: records how many passes had started, so idleness is judged on a pass started AFTER the request.
request_reveal() { LAST_PS="$(ps_count)"; echo "$1" > "$REVEAL"; }

# wait_idle [timeout s]: 0 when the latest pass has reached `plan: phase=converged` (no later `pass started`), at least one pass started
# after the last request, and nothing new was logged by the actuator for 2 s. 1 on timeout (nothing is killed then).
wait_idle() {
  local limit="${1:-60}" t0 plan_line ps_line a1 a2
  t0="$(date +%s)"
  while :; do
    app_alive || return 0
    plan_line="$(grep -n 'plan: phase=' "$APP_LOG" | tail -1)"
    ps_line="$(grep -n 'pass started' "$APP_LOG" | tail -1 | cut -d: -f1)"
    if [ "$(ps_count)" -gt "$LAST_PS" ] && echo "$plan_line" | grep -q 'plan: phase=converged' && [ "${plan_line%%:*}" -gt "${ps_line:-0}" ]; then
      a1="$(grep -c 'actuator:' "$APP_LOG")"; sleep 2; a2="$(grep -c 'actuator:' "$APP_LOG")"
      # Quiet for 2 s AND still the same last plan AND no pass started after it meanwhile (else wait for that pass's plan, same bound).
      ps_line="$(grep -n 'pass started' "$APP_LOG" | tail -1 | cut -d: -f1)"
      [ "$a1" = "$a2" ] && [ "$(grep -n 'plan: phase=' "$APP_LOG" | tail -1)" = "$plan_line" ] && [ "${plan_line%%:*}" -gt "${ps_line:-0}" ] && return 0
    fi
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && return 1
    sleep 1
  done
}

# stop_app: stops the Sommelier this script started (by pid, never by name) only when its engine is idle; otherwise reports and leaves it
# running (returns 1). Nothing to stop (or a pre-existing Sommelier of the user's) -> returns 0 without touching anything.
stop_app() {
  app_alive || return 0
  if ! wait_idle 60; then
    echo "ERROR: Sommelier's engine was not idle after 60 s (last plan: $(grep 'plan: phase=' "$APP_LOG" | tail -1 | cut -c1-120)); NOT killing it mid-pass. Stop it by hand: kill $SOM_PID"
    return 1
  fi
  kill "$SOM_PID" >/dev/null 2>&1
  SOM_PID=""
  return 0
}

# A Sommelier that is already running is the user's: refuse BEFORE the exit handler exists or Bartender is touched, so this early exit quits
# nothing (the handler's `make dummy-stop` quits every MBDummy by bundle id).
pgrep -x Sommelier >/dev/null && { echo "Sommelier is already running; stop it first (and let it finish)" >&2; exit 2; }

cleanup() {
  local rc=$?
  if ! stop_app; then echo "WARNING: Sommelier was left running (engine not idle)"; [ "$rc" = 0 ] && rc=1; fi
  make dummy-stop >/dev/null 2>&1
  if [ "$BARTENDER_WAS_RUNNING" = 1 ] && ! pgrep -x "Bartender 7" >/dev/null; then
    open -a "Bartender 7"; echo "relaunched Bartender 7"
  fi
  echo "log: $LOG  scratch layout: $LAYOUT  app log: $APP_LOG"
  exit "$rc"
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

"$PROBE" cc-allowed list | grep -q '^1 ie.boboco.mbdummy\( \|$\)' \
  || { log "no ALLOWED Control Center entry for ie.boboco.mbdummy (mbprobe cc-allowed list); create it once with 'mbprobe cc-allowed set ie.boboco.mbdummy 1 --create --restart' (respawns the agent)"; exit 2; }

agent_pid() { pgrep -x MenuBarAgent | head -1; }
AGENT_BEFORE="$(agent_pid)"
LAST_AGENT="$AGENT_BEFORE"; ATTR_SEEN=0; RESPAWN_NOTES=""
# check_respawn <phase>: a MenuBarAgent pid change in the phase. Attributed to Sommelier's own fallback when the app log
# (lines from after this soak started) gained an `agent restarted by Sommelier (expected)` or `falling back to respawn` line: INCONCLUSIVE, "own fallback respawn (slow
# reads)". Without such a line it is a FAIL ("foreign respawn"). --allow-respawn only prints a note.
check_respawn() {
  local cur n verdict
  cur="$(agent_pid)"
  verdict="$(respawn_verdict "$SOAK_START" "$ATTR_SEEN" "$WORK/applog.all" "$APP_LOG")"
  n="${verdict#* }"
  # Fallback lines of a phase WITHOUT a pid change are consumed here too, so they cannot excuse a later phase's respawn.
  if [ "$cur" = "$LAST_AGENT" ]; then ATTR_SEEN="$n"; return 0; fi
  if [ "$ALLOW_RESPAWN" = 1 ]; then log "  note [$1] MenuBarAgent respawned ($LAST_AGENT -> $cur); allowed"; RESPAWN_NOTES="$RESPAWN_NOTES
  $1: $LAST_AGENT -> $cur (allowed)"
  elif [ "${verdict%% *}" = own ]; then
    printf '%s\tinconclusive\t0\n' "$1" >> "$STATS"; INCONCLUSIVE=$((INCONCLUSIVE + 1))
    log "  INCONCLUSIVE [$1] MenuBarAgent respawned ($LAST_AGENT -> $cur): own fallback respawn (slow reads)"
    RESPAWN_NOTES="$RESPAWN_NOTES
  $1: $LAST_AGENT -> $cur, attributed to Sommelier's own fallback respawn (slow reads)"
  else
    printf '%s\tfail\t0\n' "$1" >> "$STATS"; FAILURES=$((FAILURES + 1))
    log "  FAIL [$1] MenuBarAgent respawned ($LAST_AGENT -> $cur): foreign respawn (no own-fallback line in the app log)"
    RESPAWN_NOTES="$RESPAWN_NOTES
  $1: $LAST_AGENT -> $cur, FOREIGN respawn"
  fi
  ATTR_SEEN="$n"; LAST_AGENT="$cur"
}

# Fresh, on-bar keys in bar order from `mbprobe list --json` on stdin. Heuristic keys (chevron, unnamed items), iStat items
# (they reposition themselves) and AX-identifier system modules (Focus) and the Wi-Fi module (which flickers in and out of the read, see AgreedScanObserver.defaultVolatileKeys) are not compared.
onbar() { jq -r '[.items, .keys] | transpose | map(select(.[0].isOnMenuBar and (.[0].stale | not))) | .[] | .[1]' | volatile_filter; }
snapshot() { "$PROBE" list --json 2>/dev/null; }
is_dummy() { grep -q '^status:MBDummy::'; }
# Order of the keys of $1 that also occur in $2 (common keys, order of $1).
common_in() { grep -Fxf "$2" "$1"; }

start_app() {   # start_app <layout file>
  if app_alive; then
    stop_app || { log "FAIL cannot stop the running app safely"; FAILURES=$((FAILURES + 1)); exit 1; }
    sleep 1
  fi
  # Log lines of earlier app runs of THIS soak stay available for the attribution (the pre-soak build/sommelier.log is discarded).
  [ "$APP_STARTED" = 1 ] && cat "$APP_LOG" >> "$WORK/applog.all" 2>/dev/null
  APP_STARTED=1
  : > "$APP_LOG"; LAST_PS=0
  SOMMELIER_LAYOUT_FILE="$1" SOMMELIER_DEBUG_REVEAL_FILE="$REVEAL" "$PWD/build/Sommelier.app/Contents/MacOS/Sommelier" > "$APP_LOG" 2>&1 &
  SOM_PID=$!
  disown
  sleep 2
  app_alive || { log "Sommelier did not start"; exit 2; }
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
  else
    local why; why="$(unsettled_reason)"
    if [ -n "$why" ]; then
      printf '%s\tinconclusive\t%s\n' "$1" "$3" >> "$STATS"; INCONCLUSIVE=$((INCONCLUSIVE + 1))
      log "  INCONCLUSIVE $2: not converged after ${3}s; $why"
    else
      printf '%s\tfail\t%s\n' "$1" "$3" >> "$STATS"; log "  FAIL $2: not converged after ${3}s"; FAILURES=$((FAILURES + 1))
    fi
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

# The scans may not agree right away on a busy bar: retry the (read-only) layout capture a few times.
for try in 1 2 3 4 5; do
  "$PROBE" layout init-from-current --file "$LAYOUT" --force > "$WORK/init.out" 2>&1 && break
  [ "$try" = 5 ] && { log "init-from-current failed 5 times"; cat "$WORK/init.out"; exit 2; }
  sleep 5
done
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
  s="$(wait_for visible 90)"; rc=$?; record V "relaunch $i" "$s" "$rc"
done

check_respawn V

# --- phase H -------------------------------------------------------------------------------------------------------------
log "== phase H: app restarted on a layout with the dummies HIDDEN, $NH relaunches"
jq --arg a "$KEY_A" --arg b "$KEY_B" '.visible -= [$a, $b] | .hidden = [$a, $b] + .hidden' "$WORK/layout.visible.json" > "$LAYOUT"
start_app "$LAYOUT"
s="$(wait_for hidden 90)"; rc=$?; record H "dummies hidden by the engine" "$s" "$rc"
for i in $(seq 1 "$NH"); do
  make dummy-stop >/dev/null 2>&1; sleep 3; start_dummies
  s="$(wait_for hidden 90)"; rc=$?; record H "relaunch $i" "$s" "$rc"
done

check_respawn H

# --- phase R -------------------------------------------------------------------------------------------------------------
log "== phase R: $TOGGLES reveal toggles (show/hide the hidden section)"
for i in $(seq 1 "$TOGGLES"); do
  request_reveal show
  t0="$(date +%s)"; ok=1
  for _ in $(seq 1 90); do snapshot | onbar > "$WORK/cur.keys"; [ "$(grep -c '^status:MBDummy::' "$WORK/cur.keys")" = 2 ] && { ok=0; break; }; sleep 1; done
  record R "reveal $i: dummies shown" "$(( $(date +%s) - t0 ))" "$ok"
  request_reveal hide
  s="$(wait_for hidden 90)"; rc=$?; record R "reveal $i: hidden again" "$s" "$rc"
done

check_respawn R

# --- final assertions ----------------------------------------------------------------------------------------------------
log "== final check"
s="$(wait_for hidden 90)"; rc=$?
if [ "$rc" = 0 ]; then log "  ok   non-dummy order equals the baseline; dummies hidden as in the layout"; printf 'final\tok\t%s\n' "$s" >> "$STATS"
else log "  FAIL final order differs from the baseline"; printf 'final\tfail\t%s\n' "$s" >> "$STATS"; FAILURES=$((FAILURES + 1)); diff "$WORK/c1" "$WORK/c2" | head -20 | tee -a "$LOG"; fi
AGENT_AFTER="$(agent_pid)"
check_respawn final
# Leave the dummies shown in the store (allowed) so the next run needs no write.
request_reveal show
wait_idle 60 || log "note: engine not idle 60 s after the last request"

echo
printf '%-8s %8s %6s %6s %13s %10s\n' phase attempts ok fail inconclusive max_s
for ph in V H R final; do
  n="$(awk -F'\t' -v p="$ph" '$1==p' "$STATS" | wc -l | tr -d ' ')"; [ "$n" = 0 ] && continue
  o="$(awk -F'\t' -v p="$ph" '$1==p && $2=="ok"' "$STATS" | wc -l | tr -d ' ')"
  mx="$(awk -F'\t' -v p="$ph" '$1==p {print $3}' "$STATS" | sort -n | tail -1)"
  inc="$(awk -F'\t' -v p="$ph" '$1==p && $2=="inconclusive"' "$STATS" | wc -l | tr -d ' ')"
  printf '%-8s %8s %6s %6s %13s %10s\n' "$ph" "$n" "$o" "$((n - o - inc))" "$inc" "$mx"
done
echo
echo "MenuBarAgent pid: $AGENT_BEFORE -> $AGENT_AFTER ($([ "$AGENT_BEFORE" = "$AGENT_AFTER" ] && echo 'no respawn' || echo 'RESPAWNED'))$RESPAWN_NOTES"
echo "engine failures logged: $(grep -c 'marked failed until\|stopped after' "$APP_LOG")"
if [ "$INCONCLUSIVE" -gt 3 ]; then echo "too many inconclusive phases ($INCONCLUSIVE > 3): the bar could not be read reliably"; FAILURES=$((FAILURES + 1)); fi
if [ "$FAILURES" = 0 ]; then echo "SOAK PASS (0 failures, $INCONCLUSIVE inconclusive)"; else echo "SOAK FAIL ($FAILURES failures)"; fi
[ "$FAILURES" = 0 ]
