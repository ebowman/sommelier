#!/bin/sh
# Fails unless every theorem in lean/Sommelier/{Eqns,Safety,Gates,Truth,Honesty}.lean (and the named headline theorems) depends only on
# propext, Classical.choice and Quot.sound, and lean/Sommelier/Pins.lean (the full statements) builds: no sorryAx, no native_decide (Lean.ofReduceBool), no new axioms.
set -eu
cd "$(dirname "$0")/../lean"
lake build Sommelier.Safety Sommelier.Gates Sommelier.Truth Sommelier.Honesty Sommelier.Pins >/dev/null || { echo "FAIL: Safety.lean, Gates.lean, Truth.lean, Honesty.lean or Pins.lean does not build (a weakened statement breaks a pin)"; exit 1; }
FILES="Sommelier/Eqns.lean Sommelier/Safety.lean Sommelier/Gates.lean Sommelier/Truth.lean Sommelier/Honesty.lean Sommelier/Status.lean Sommelier/Step.lean Sommelier/Pins.lean Sommelier/Examples.lean Sommelier/Fuzz.lean Sommelier.lean"
for f in $FILES; do
  for bad in sorry native_decide 'axiom '; do
    if grep -n "^[^-]*\b$bad" $f | grep -v '^[0-9]*:\s*--' >/dev/null 2>&1; then
      echo "FAIL: $f mentions '$bad'"; grep -n "$bad" $f | head -3; exit 1
    fi
  done
done
HEADLINE="oneActionPerStep noActionWhileInFlight noFoldedTarget noFoldedTarget_run holdRelease holdRelease_run proofNeedsThreeConsecutive
stripOnlyForUser noStripWithoutUser oneStripSessionPerEdit owedExpires budget_any budget_full engineActions_bound budget_any_from
budget_full_from budget_between_user_events budget_full_between_user_events engineActions_between_user_events strip_honest
strip_iff userLabelHonest seg_run eng_no_hold eng_no_open eng_no_stale eng_no_restricted eng_no_budget_full eng_no_budget_notfull
plan_no_givenUp plan_no_skipped fullBar_ignores_chevron chevron_engine_budget plan_on_good_read pile_replace pile_fresh_add
pile_stale_add proof_clears_pile proof_clears_hold pile_absent_keeps res_failed_holds res_failed_gives_up res_proven_no_hold
res_proven_strike res_proven_giveup edit_hold edit_budget_reset edit_restricts edit_givenUp retry_clears_hold retry_clears_givenUp
retry_resets_budget retry_unrestricts retry_grants rk_clears_hold rk_resets_budget rk_givenUp emit_consumes rearm_iff
rearm_request prefixFor_spec userMove_moves userMove_target applyMove_before applyMove_after userMove_folded
edit_request_origin edit_requests_pull rk_request rk_requests_pull emit_flightReq edit_flightReq edit_empty_flightReq rk_flightReq
edit_owed edit_empty_owed edit_request_in_record rk_owed plan_in_record subjects_in_record postedFull_init quiescence
userAlwaysAnswered_drawn userAlwaysAnswered_none userAlwaysAnswered_pull userRetry_leaves userRetry_opens_gate notStuck
row_notStuck plan_spec userMove_drawn_spec request_first noNeedlessDrag_plan noNeedlessDrag_user noNeedlessDrag drop_expires
status_matches_bridge status_except_bridge status_differs_bridge status_checking_bridge status_matches_conv status_except_conv
status_differs_conv status_checking_conv notStuck_conv status_matches_true status_differs_true status_except_true
status_checking_true stopped_true barFull_true status_plain_iff row_tick_bridge row_behind_bridge row_notWherePut_bridge
row_notOnBar_bridge row_cannotTell_bridge row_free_of_memory row_waiting_true row_waiting_conv row_notStuck_conv row_tick_true
row_behind_true row_notWherePut_true drop_truth user_drop_answered user_can_leave verdict_matches_iff verdict_differs_iff
verdict_except_iff verdict_cannotTell_iff rowVerdict_inOrder_iff rowVerdict_outOfPlace_iff rowVerdict_behind_iff
rowVerdict_behindOutOfTurn_iff rowVerdict_notOnBar_iff rowVerdict_cannotTell_iff differs_names_cause no_needless_move_engine
no_needless_move_user no_folded_target_truth no_move_on_cannotTell macOS_fold_preserves status_judges_view decideMove_gated owed_unanswered_reason fold_crossed_only_by_drop row_good_read_verdict
usable_pass usable_settled usable_not_incomplete usable_observed usable_strip_closed usable_not_stale usable_absent_proven
provenNotFull_pile_empty drop_answered_reachable foldedDrawn_chevronless in_place_row unanswered_row pileInv_step pileInv_run
gate_facts fresh_drawn_not_folded decide_head mem_foldedAll noteRead_pile_usable
anchorMove_spec anchorMove_right_place anchorMove_moves anchorMove_target fallbackMove_basic fallbackRel_target misplaced_fallbackRel
fallbackMove_none_cases fallbackMove_exists legal_mem_cands argmin_spec fallback_reduces_inversions fallback_best right_everywhere_no_move noMoveHelps_true userRetry_answers plain_is_no_move drop_no_gap_note bar_open_record applyMove_filter fallback_improves_bar noMoveHelps_bar cantJudge_iff exists_drag applyMove_split filter_ins wholeBar_cases invCount_ignores_unmovable userPick_exists userPick_none userPick_head1 userMove_phases userMove_none_reason rowNote_true rowNote_reason queue_move_decides try_again_core try_again_answers
drain_potential potential_le drops_drain drop_mutual_inversion drop_no_gap drop_keys_around_say_so drain_bound_attained
wholeBar_unlisted wholeBar_iff_free penalty_wholeBar worstCount_wholeBar fallback_best_whole cantJudge_iff cantJudge_free move_bound move_cmp_left move_cmp_right
bar_movable_facts invs_split fallback_improves_bar noMoveHelps_bar"
ALL=$(cat Sommelier/Eqns.lean Sommelier/Safety.lean Sommelier/Gates.lean Sommelier/Truth.lean Sommelier/Honesty.lean | grep -E '^theorem [^ ]+' | sed -E 's/^theorem ([^ ]+).*/\1/' | sort -u)
for h in $HEADLINE; do
  echo "$ALL" | grep -qx "$h" || { echo "FAIL: headline theorem $h is missing from Eqns/Safety/Gates/Truth/Honesty.lean"; exit 1; }
done
TMP=$(mktemp "${TMPDIR:-/tmp}/axioms.XXXXXX")
mv "$TMP" "$TMP.lean"; TMP="$TMP.lean"
trap 'rm -f "$TMP"' EXIT
{ echo "import Sommelier.Pins"; for t in $ALL; do echo "#print axioms Sommelier.$t"; done; } > "$TMP"
OUT=$(lake env lean "$TMP" 2>&1) || { echo "$OUT"; echo "FAIL: lean error"; exit 1; }
N=$(echo "$ALL" | wc -l | tr -d ' ')
CNT=$(echo "$OUT" | grep -c "depends on axioms\|does not depend on any axioms" || true)
[ "$CNT" = "$N" ] || { echo "$OUT" | head -20; echo "FAIL: expected $N axiom reports, got $CNT"; exit 1; }
BAD=$(echo "$OUT" | grep "depends on axioms" | sed -E 's/.*\[(.*)\]/\1/' | tr ',' '\n' | sed 's/^ *//' | grep -v -x -e propext -e Classical.choice -e Quot.sound || true)
if [ -n "$BAD" ]; then echo "$OUT" | grep -E "$(echo "$BAD" | head -1)" | head -5; echo "FAIL: unexpected axioms: $BAD"; exit 1; fi
echo "OK: $N theorems, axioms limited to propext, Classical.choice, Quot.sound"
echo "$OUT" | grep "depends on axioms" | sed -E 's/.*\[(.*)\]/\1/' | sort | uniq -c
