#!/bin/bash
# One command that runs every check on the proved decision core, in order, failing fast (sommelier-ejb.6).
# MUTANTS=full additionally runs the full mutant run (about 45 minutes). Exit codes are captured per step, never through a pipeline.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
SUMMARY=()
T0=$SECONDS

# step <name> <command...>: run in $ROOT, print one line "name OK|FAIL Ns", stop the script on failure.
step() {
  local name=$1; shift
  local t=$SECONDS rc
  echo "==> $name"
  ( cd "$ROOT" && "$@" )
  rc=$?
  local dt=$((SECONDS - t))
  if [ $rc -eq 0 ]; then
    SUMMARY+=("$(printf '%-26s OK   %5ds' "$name" "$dt")")
    echo "${SUMMARY[${#SUMMARY[@]}-1]}"
  else
    SUMMARY+=("$(printf '%-26s FAIL %5ds (rc=%d)' "$name" "$dt" "$rc")")
    echo "${SUMMARY[${#SUMMARY[@]}-1]}"
    echo
    echo "verify-core summary:"
    printf '  %s\n' "${SUMMARY[@]}"
    echo "verify-core: FAIL at step '$name' after $((SECONDS - T0))s"
    exit 1
  fi
}

swift_decision_tests() {
  # SwiftPM caches the evaluated Package.swift; the stamp makes it re-evaluate when the core changes (same guard as the Makefile).
  SOMMELIER_LEANCORE_STAMP=$(cat build/LeanCore/stamp 2>/dev/null || echo none)
  export SOMMELIER_LEANCORE_STAMP
  swift test --filter DecisionCoreTests
}

step "lake build"          bash -c 'cd lean && lake build'
step "check-lean-axioms"   scripts/check-lean-axioms.sh
step "lake exe fuzz"       bash -c 'cd lean && lake exe fuzz'
step "lake exe oracle"     bash -c 'cd lean && lake exe oracle'
FASTFUZZ_CASES="${FASTFUZZ_CASES:-$( [ "${MUTANTS:-}" = full ] && echo 10000 || echo 1000 )}"
step "lake exe fastfuzz ($FASTFUZZ_CASES cases)" bash -c "cd lean && lake exe fastfuzz $FASTFUZZ_CASES"
step "build-lean-core"     scripts/build-lean-core.sh
step "DecisionCoreTests"   swift_decision_tests
step "mutants --check"     python3 lean/scripts/mutants.py --check
if [ "${MUTANTS:-}" = "full" ]; then
  # mutants.py exits nonzero on any survivor or invalid mutant
  step "mutants (full)"    python3 lean/scripts/mutants.py
fi

echo
echo "verify-core summary:"
printf '  %s\n' "${SUMMARY[@]}"
echo "verify-core: OK, ${#SUMMARY[@]} steps in $((SECONDS - T0))s"
