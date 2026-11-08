#!/bin/sh
# Fails unless every theorem in lean/Sommelier/Safety.lean (and the named headline theorems) depends only on
# propext, Classical.choice and Quot.sound, and lean/Sommelier/Pins.lean (the full statements) builds: no sorryAx, no native_decide (Lean.ofReduceBool), no new axioms.
set -eu
cd "$(dirname "$0")/../lean"
lake build Sommelier.Safety Sommelier.Pins >/dev/null || { echo "FAIL: Safety.lean or Pins.lean does not build (a weakened statement breaks a pin)"; exit 1; }
for bad in sorry native_decide 'axiom '; do
  if grep -n "^[^-]*\b$bad" Sommelier/Safety.lean | grep -v '^[0-9]*:\s*--' >/dev/null 2>&1; then
    echo "FAIL: Safety.lean mentions '$bad'"; grep -n "$bad" Sommelier/Safety.lean | head -3; exit 1
  fi
done
HEADLINE="oneActionPerStep noActionWhileInFlight noFoldedTarget noFoldedTarget_run holdRelease holdRelease_run
proofNeedsThreeConsecutive stripOnlyForUser noStripWithoutUser oneStripSessionPerEdit owedExpires
budget_any budget_full engineActions_bound budget_any_from budget_full_from budget_between_user_events
budget_full_between_user_events engineActions_between_user_events strip_honest strip_iff userLabelHonest seg_run"
ALL=$(grep -E '^theorem [A-Za-z0-9_.]+' Sommelier/Safety.lean | sed -E 's/^theorem ([A-Za-z0-9_.]+).*/\1/' | sort -u)
for h in $HEADLINE; do
  echo "$ALL" | grep -qx "$h" || { echo "FAIL: headline theorem $h is missing from Safety.lean"; exit 1; }
done
TMP=$(mktemp "${TMPDIR:-/tmp}/axioms.XXXXXX")
mv "$TMP" "$TMP.lean"; TMP="$TMP.lean"
trap 'rm -f "$TMP"' EXIT
{ echo "import Sommelier.Safety"; for t in $ALL; do echo "#print axioms Sommelier.$t"; done; } > "$TMP"
OUT=$(lake env lean "$TMP" 2>&1) || { echo "$OUT"; echo "FAIL: lean error"; exit 1; }
N=$(echo "$ALL" | wc -l | tr -d ' ')
CNT=$(echo "$OUT" | grep -c "depends on axioms\|does not depend on any axioms" || true)
[ "$CNT" = "$N" ] || { echo "$OUT" | head -20; echo "FAIL: expected $N axiom reports, got $CNT"; exit 1; }
BAD=$(echo "$OUT" | grep "depends on axioms" | sed -E 's/.*\[(.*)\]/\1/' | tr ',' '\n' | sed 's/^ *//' | grep -v -x -e propext -e Classical.choice -e Quot.sound || true)
if [ -n "$BAD" ]; then echo "$OUT" | grep -E "$(echo "$BAD" | head -1)" | head -5; echo "FAIL: unexpected axioms: $BAD"; exit 1; fi
echo "OK: $N theorems, axioms limited to propext, Classical.choice, Quot.sound"
echo "$OUT" | grep "depends on axioms" | sed -E 's/.*\[(.*)\]/\1/' | sort | uniq -c
