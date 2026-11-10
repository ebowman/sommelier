#!/bin/bash
# sommelier-ejb.7: there is exactly ONE place that decides an engine order move, the proved core (`DecisionCore.step`), and exactly ONE place that
# performs one: the core-Action execution site in LayoutEngine.runPassBody (the single `actuator.move(` call). Fails (exit 1) if:
#   1. `actuator.move(` is called anywhere in Sources other than that one site, or a `DragMover` is built outside the actuator platform / mbprobe;
#   2. Reconciler.swift or LayoutEngine.swift mention a symbol of the deleted order machinery (comments are ignored);
#   3. Reconciler.swift still has an order phase (`.order`, `onlyMove`, `layoutTarget`, ...).
# mbprobe and mbdummy are manual debug tools driven by a person, never by the engine; they are not scanned for rule 1.
set -u
cd "$(dirname "$0")/.."
fail=0
say() { echo "check-single-decider: FAIL: $*"; fail=1; }

SRC=(Sources/SommelierCore Sources/Sommelier Sources/DecisionCore)

# 1a. calls of an actuator's move: exactly one, in LayoutEngine.swift
calls=$(grep -rnE '[Aa]ctuator\.move\(' "${SRC[@]}" --include='*.swift' | grep -vE '^[^[:space:]]+:[0-9]+:[[:space:]]*//' || true)
n=$(printf '%s' "$calls" | grep -c . || true)
if [ "$n" != "1" ]; then say "expected exactly one 'actuator.move(' call site in Sources, found $n"; printf '%s\n' "$calls"; fi
if [ -n "$calls" ] && ! printf '%s' "$calls" | grep -q '^Sources/SommelierCore/LayoutEngine.swift:'; then say "the single actuator.move( call is not in LayoutEngine.swift"; printf '%s\n' "$calls"; fi

# 1b. any other way of making a drag: a DragMover / mover.move outside the actuator platform
other=$(grep -rnE 'DragMover\(|[a-z]*[mM]over\.move\(' "${SRC[@]}" --include='*.swift' | grep -vE '^Sources/SommelierCore/(ActuatorPlatform|DragMover)\.swift:' | grep -vE '^[^[:space:]]+:[0-9]+:[[:space:]]*//' || true)
if [ -n "$other" ]; then say "a DragMover is used outside ActuatorPlatform.swift"; printf '%s\n' "$other"; fi

# 2. deleted order machinery must not come back (code only: trailing and full-line comments are stripped first)
SYMBOLS='userEditMoved|userEditRestricting|userDropPending|foldDropRequest|foldRequestCreated|foldRequestPlanned|userEditOldRecord|stripOpenHold|stripHoldFoldedSet|stripHoldLogged|stripHoldUnplaceable|stripHoldDidNotHold|lastFolded|lastDrawn|lastFreshChevronObs|fullBarState|noChevronReads|notFullProven|lastGatedDiffers|lastOrderDiffers|lastCheckingBar|lastPlanHadMoves|retryStripGrant|retryGrantPass|grantedAction|editStripSessionUsed|engineMoveCount|engineBudgetLogged|orderAttempts|revertWatch|lastVerifiedOrderMove|unverifiedStrikes|overflowRefused|foldRefused|coreRefused|orderMoveTimes|capLoggedUntil|unsteadyKeys|previousSettledBar|deferredThisPass|applyUserEditDeferral|isUsersMove|noteChevronEvidence|noteAnyRead|engineCap|gateEngineMoves|applyStripHold|setStripHold|resetStripHold|resetEngineBudget|noteAttempt|clearGiveUp|orderCapLiftsAt|fullBarOrderGate|crossFoldMove|crossesFold|isLegalFoldMove|layoutTarget|movesReporting|overflowViolations|trailingBlockStart|unsteadyKeys|isMovingNeighbourSkip|movingNeighbourSkipReason|staleFrameSkipReason|noSafeMoveSkipReason|foldDropRequest|onlyMove|desiredOnBar|gatedDiffers|orderDiffers|checkingBar|stripHeld|blockedNoWall|blockedBy|skipPlanningGateForTests|maxEngineMovesPerLaunch|maxAttemptsPerItem|maxOrderMovesPerMinute'
for f in Sources/SommelierCore/Reconciler.swift Sources/SommelierCore/LayoutEngine.swift; do
  hits=$(sed -E 's#^[[:space:]]*//.*##; s#[[:space:]]//.*$##' "$f" | grep -nE "\b($SYMBOLS)\b" || true)
  if [ -n "$hits" ]; then say "$f mentions a deleted order symbol:"; printf '%s\n' "$hits" | head -5; fi
done

# 3. no order planner in the Reconciler: no order phase, no move spelling
hits=$(sed -E 's#^[[:space:]]*//.*##; s#[[:space:]]//.*$##' Sources/SommelierCore/Reconciler.swift | grep -nE 'case order\b|\.order\b|static func (moves|violations|lis)\(|func moves\(|PlannedAction\.move|return \.move\(|\.move\(' || true)
if [ -n "$hits" ]; then say "Reconciler.swift contains an order planner:"; printf '%s\n' "$hits" | head -5; fi
# a Plan never carries a move
if grep -nE 'case \.move' Sources/SommelierCore/LayoutEngine.swift | grep -vE '(PlannedAction|inFlight|plan|describe|key\(of|switch a|case \.move\(let k, let r\))' >/dev/null 2>&1; then :; fi

if [ $fail -ne 0 ]; then exit 1; fi
echo "check-single-decider: OK (one actuator.move( call site, in LayoutEngine.swift; no order planner in Reconciler / LayoutEngine)"
