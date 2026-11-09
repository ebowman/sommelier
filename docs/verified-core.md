# Verified decision core (epic sommelier-ejb)

`lean/` holds the specification of the engine's decisions in Lean 4 (4.35.0, no Mathlib yet). `cd lean && lake build` checks it.
The model is `lean/Sommelier/Model.lean` (types), the decision function is `lean/Sommelier/Step.lean`
(`step : State -> Event -> State x List Action`, total, computable, axioms: `propext` only), `lean/Sommelier/Safety.lean` holds the safety theorems (ejb.2, below), `lean/Sommelier/Gates.lean` states what each gate DOES to the engine's output (ejb.3), `lean/Sommelier/Truth.lean` states and proves what a reading says about the REAL bar (the verdicts and T1 - T9, below), `lean/Sommelier/Status.lean` defines the status line and the rows as pure functions of `State` and `Read` over those verdicts, `lean/Sommelier/Honesty.lean` proves liveness and honesty about them (ejb.3), `lean/Sommelier/Eqns.lean` generates equation lemmas shared by `Safety.lean` and `Gates.lean` (so `Gates.lean` does not import `Safety.lean`, and a mutant that breaks a `Safety.lean` proof positionally cannot mask a `Gates.lean` theorem; `Honesty.lean` imports `Gates.lean` and `Status.lean`, not `Safety.lean`, so a mutant that breaks a `Gates.lean` proof stops `Honesty.lean` from building and masks every theorem in it), and `lean/Sommelier/Examples.lean` holds
`#eval` examples that are also `decide`-checked, including every counterexample a reviewer found. macOS is an adversary: the safety theorems
quantify over ALL event lists, and `Model.lean` alone never says what a read means; `Truth.lean` says it, from stated assumptions.

**Status.** The Swift app does NOT yet run this model. `step`, `statusLine` and `rowLine` are a specification written beside the app; the mapping in
this document is a reading of the Swift code, to be tested on a device at ejb.8. The theorems are proved about the model. The assumptions they rest on
(A1, A2, A3, A6, A7 and leftmost folding, see `Truth.lean`) are unproved facts about macOS and the adapter, believed from observation: if one is false
on a device, the theorems that use it say nothing about that device.

## Shape (deliberate)

- One decision per read: at most ONE drag leaves per `read` event; the world answers with `moveResult` and the next read decides again.
  EVERY action is one physical drag, for user and engine moves on every bar (retries are later passes). Decided.
- Only a `pass` read that is `settled` and not `incomplete` may plan. A `poll` read, an unsettled read and an `incomplete` read are evidence only
  (evidence rules below apply to all of them).
- A user's pass is the span from a user event to the next `passBoundary`. After `userEdit` (non-empty moved) and `retryKey` only owed keys move; `userRetry` (Re-apply) starts an UNRESTRICTED pass (the engine may move, with one strip grant).
- Owed user moves (the fold request first) are planned before the engine's, never both in one read.
- The planner is a stub (first inversion); `ejb.4` replaces it.

## Lean to rule

| Lean | Swift / rule |
|---|---|
| `fullBar s r` = `!provenNotFull or chevron present` | `LayoutEngine.fullBar`: full from launch, any chevron makes it full |
| `noteRead`, `provenNotFull`, `noChevronReads` | `noteChevronEvidence`, `notePollScan`, `noteAnyRead`: 3 consecutive chevronless reads at level `complete`/`exceptSelfPositioning` prove the bar not full; `incomplete` resets the count; any chevron revokes. `noChevronReads` may REACH 3 without effect (Swift's `notFullProven`): a PASS read that is the third only arms the proof, the next settled chevronless pass read flips `provenNotFull` (= `!fullBarState`) and clears hold and pile, and a chevron or an `incomplete` read in between cancels it (:1856, :2262); a quiet POLL that reaches 3 flips at once (architecture.md rule 2, :1876-1883). An unsettled complete chevronless pass read neither counts nor resets. `decideMove` runs on the pre-read state, so the flipping pass still decides under the old state (more conservative than Swift, which plans that pass flipped). |
| `hold`, `holdFolded` | `stripOpenHold`, `stripHoldFoldedSet`. Set by a failed POSTED drag while the bar is not proven not-full (user's or engine's); `holdFolded` is the folded set at that moment (read only by `userEdit`, never reset: it matters only while `hold` is set). Released by `userRetry`, `retryKey`, a `userEdit` whose moved keys meet `holdFolded` or the current last fresh pile, and the proof. A drawn-only edit keeps it. |
| `moveCount`, `cap`, `capFull`=3, `capNotFull`=20 | `engineMoveCount`, `engineCap`. Counted at the result of a POSTED engine drag, so it never decreases between user events; reset by `userEdit` (non-empty moved), `userRetry`, `retryKey`. 3 means 3 real drags. |
| `owedKeys` | `userDropPending`: every moved key of every edit still in the record (union across edits, no duplicates, no filter on what was drawn). Erased when its move is emitted; emptied by `passBoundary` and `userRetry`. |
| `foldRequest` | `foldDropRequest`: owed keys and the request are always filtered by the CURRENT record (at every `userEdit`, even with empty `moved`, at `retryKey` and at re-arm). At most one folded key (first in record order of an edit) with a drawn key before it in the record, folded AT EDIT TIME (member of `lastFreshPile`). A priority hint only: the licence for a pull-out is that the key is OWED (or the request) and the read lists it folded (`userMove`); the request is not needed for the answer. A later edit that asks for another pull-out REPLACES the request (T3: the earlier key stays owed but is no longer pulled out). `flightReq` marks that the in-flight drag was the request: a `busy` result re-arms the request only if `flightReq` is still set AND no later request exists (T4: a pull of 5 in flight, an edit asks for 6, busy on 5: 6 is kept); a later edit that moves the in-flight key clears `flightReq` (T5: the edit put 5 before every drawn key, busy, 9 becomes drawn: 5 is not pulled out after 9). |
| `restricted` | `userEditRestricting`: only owed keys move. `userRetry` is unrestricted. |
| `stripGrant` | `retryStripGrant`/`grantedAction`: set by `userRetry` ONLY (after `retryKey` the pass is restricted, so the engine could never use a grant), consumed by the first engine move that needs the strip (emitted as the user's, `user := true`, not counted), cleared by `passBoundary`. |
| `editSessionUsed` | `editStripSessionUsed`: any emitted `strip := true` sets it; a user (or granted) move that needs the strip is withheld once set, and while the strip is open. A drag with no mouse event returns the session. |
| `needsStrip`, `Action.strip` | `gateEngineMoves.needsStrip`: subject or target in `foldedAll` (on a usable fresh-chevron read exactly this read's pile and folded keys, which supersede the memory; on any other read this read's pile and folded keys plus `lastFreshPile`) or `Read.nearFold` (the churn zone, supplied by the adapter). |
| `movable` | gdu.144 rule 3: drawn, trusted, not in `foldedAll`: the only keys a planned move names. |
| `lastFreshPile` | `lastFreshChevronObs` pile: REPLACED only by a settled, non-`incomplete`, strip-closed read with a fresh chevron; any other chevron read (stale, unsettled, incomplete, strip open) adds to it (a SETTLED, closed, readable fresh poll replaces it, like a pass read); kept through chevronless reads until the proof. |
| `givenUp`, `strikes` | `cannotPlace`/`orderAttempts`/`revertWatch`/strikes. On a bar not proven not-full the first failed posted drag gives a key up; once proven not-full, 3 failed posted drags. Cleared by user events: `userEdit` clears only the MOVED keys' entries, `userRetry` all, `retryKey` that key. There is no `appsChanged` release (dropped: only user events clear given-up keys). |
| `skipped` | a key whose drag was refused/busy/failed without a mouse event: no engine move of it until a user event (so a refused key cannot loop). |
| `inFlight`, `gen`, `flightOwed` | the serial actuator call; only its `moveResult` clears it. `gen` is bumped by `passBoundary` and `userRetry`; `flightOwed` records at emit time whether the drag's subject was owed by the CURRENT chain (never true for a granted move), which is the only case a user `busy` without a mouse event is re-armed. |
| `planOrderMoves` | `Reconciler.plan` order phase (stub). An engine move that needs the strip is withheld (not emitted, not counted) unless `stripGrant`. |
| `userMove` | `plan(onlyMove:)` + `foldDropRequest`. Exact rule for a drawn owed key `k`: ANCHORS are the movable keys that are in the record, are not `k` and are not still owed (so a key already SERVED is an anchor, and may be a target; a drawn key absent from the record never forces a drag). `k` is RIGHT when the set of anchors before it on the bar equals the set of anchors before it in the record: then no move. Otherwise take the first gap, in DRAWN order of the anchors, whose preceding anchors are exactly that set; the move is `after` the last anchor of the gap, or `before` the first anchor if the gap is empty. If no gap satisfies the test (the anchors are themselves out of record order) there is no move, and if the drag would leave the drawn list unchanged (`applyMove`) there is no move; a no-op never spends the owed attempt or sets a hold. Anchors never move in a restricted pass. A folded key is pulled out only if it is the fold request OR owed, the chevron is fresh and THIS read lists the key as folded (`r.foldedSet`; the pile memory alone never licenses a drag), `after` the rightmost movable key that precedes it in the record. So a drop that macOS folded after the edit (never a fold request) is pulled out on the first good reading. A folded key the user did not drop never gets one. On a usable fresh-chevron read the folded set is the read's own and supersedes the memory (`foldedAll`): a key the memory still lists but this read shows drawn is judged as drawn, for the planner too (it may now plan a key that stale memory used to hide, on the same read the memory is replaced). |
| `engineAllowed` | `gateEngineMoves`: not restricted, no hold, chevron not stale, strip not open, budget left. |

The gdu.144 text "in restricted passes a target-is-moved move needs the pair to have flipped" is replaced by the exact rule above:
a moved key is a valid target once served, and a drawn key is placed by the set test above. The earlier sentence "an already-ordered pair is never moved" is NOT claimed: the guarantee is only that a moved key ends with the right set of anchors before it, anchors stay put, and a no-op drag is never made.

## Assumptions outside the proof (the adapter / actuator must provide)

1. The actuator honours `strip := false`: such a drag never opens the « strip.
2. The actuator answers EVERY action with exactly one `moveResult` (the core never clears `inFlight` otherwise). Theorems about user
   responsiveness take `inFlight = none` as a premise. A result for a drag dispatched before a user event still applies when it arrives
   (a late failed result can re-set the hold after Re-apply; pressing Re-apply again clears it).
3. The adapter sends `passBoundary` at the start of each regular pass and at the end of every user chain, however it ends.
4. The adapter withholds reads during membership (hide/show) batches. Membership actions are outside the core.
5. `posted` is truthful (it comes from `lastMoveTouchedMouse`), and every action runs with `setSingleDrag(true)`.
6. The Re-apply pass does not start with `passBoundary` (that would clear `stripGrant`, which only `userRetry` sets); the adapter sends `passBoundary` for the NEXT regular pass.
   If Swift cannot guarantee this, the grant must be re-derived from `userRetry` by ordering the events in the adapter.
7. ejb.7 needs a separate strip-permission flag in the actuator: `setEngineInitiated(true)` also refuses with the strip open, so it cannot
   express "strip := false" alone.
8. Immovable keys: the adapter leaves them out of `trusted` and out of the `record` it passes; the core has no such concept.
9. Scope of the guarantees: "the engine does not move on its own" is about ORDER drags only. Membership (hide/show) is outside the core and
   proves nothing here.
10. `Read.nearFold` (the churn zone), `trusted`, `kind`, `settled` are supplied by the scanner; they are adversarial inputs.
11. The status line and the rows are modelled as `Status.lean` over the verdicts of `Truth.lean` (below); their TEXT (names, counts, the paused/adoption/order-cap/hand-drag
    contexts, the "Done: X. Next: Y" line, the hand-drag `unreadAfterHandDrag` state and the 60 s position timeout) stays in the Swift adapter. The adapter
    must keep every immovable or uncorroborated key out of `Read.trusted`: order claims are made only about trusted drawn keys (`Read.pinOpen`) and the record.
12. The adapter sends `userEdit` with non-empty `moved`, `userRetry` and `retryKey` ONLY for real user actions. Every budget and strip
    theorem treats these three as the only events that reset the budget or open a user pass.
13. `chevron`, `level`, `pile`, `folded`, `drawn`, `trusted`, `nearFold`, `settled` are scanner inputs (adversarial). "Full bar" means full
    ACCORDING TO THE READS (`fullBar`); the theorems do not know whether the bar really is full.
14. One `State` lives for the app's lifetime. A relaunch is `State.init` again and restarts the budget (3 or 20 automatic moves).

## Open questions, each decided (safer reading chosen)

1. Refused drags. Decided: a drag with `posted = false` is never budget (refund by construction) and EVERY such result, including a
   "verified" one, puts the key in `skipped` (so nothing loops); only a user's `busy` that the CURRENT chain owed is re-armed, once; every other
   user result without a mouse event is consumed.
2. Several failures per key. Decided: on a bar not proven not-full the first failed posted drag gives the key up; once proven, 3 strikes.
3. Hold at launch before any chevron is seen. Decided: a failed posted drag holds whenever the bar is not proven not-full (assumed full counts).
4. `provenNotFull` is revoked only by a chevron (an `incomplete` chevronless read after the proof does not revoke it, as in Swift). So the
   theorem "provenNotFull implies the last three reads were chevronless" is FALSE as written; the true statement is "since the proof no
   read showed a chevron, and three qualifying chevronless reads preceded it". Decided: model unchanged; the true theorem is proved (`proofNeedsThreeConsecutive`).
5. Unsettled complete chevronless reads. Decided: an unsettled complete PASS read neither counts nor resets (Swift ends it before `noteChevronEvidence`); a POLL counts toward the proof whether it is strip-open, unsettled or `exceptSelfPositioning` (Swift `notePollScan`, :1871-1883); `incomplete` resets. The ejb.8 soak must count exactly these reads (A3).
6. Planning on `incomplete` reads. Decided: an incomplete read never plans, and it cannot replace the fresh pile. NOT the Swift behaviour:
   Swift sets `lastFreshChevronObs` whenever a chevron is in the read (`LayoutEngine` ~1691 and ~2596, no level guard) and plans on whatever
   the read holds. Flagged for ejb.5: the adapter must pass incomplete reads as `incomplete`.
7. A user pull-out on a stale chevron. Decided: it waits; the fold request survives until `passBoundary` and is then gone.
8. `userEdit` with empty `moved` changes only the record (as Swift `!movedKeys.isEmpty`).
9. A `moveResult` that does not match `inFlight` is ignored.
10. The bead's `s3_pauseResume` was not found in the repository; `resume` and `resumeUnserved` are reconstructed from the gdu.144 text.
11. The stub planner moves the first out-of-place key before the key in its slot; minimal only by accident.
12. A late failed result after a user event can re-set the hold (assumption 2). Decided: accepted, the user retries again.
13. With the strip open only user moves with `strip := false` proceed (a pull-out waits).
14. `appsChanged`. Decided: dropped; only user events clear given-up keys.
15. Pile union. Decided: only a settled, readable, strip-closed fresh-chevron read replaces `lastFreshPile`; every other read adds to it, so an
    unsettled or strip-open scan can never un-fold a key.

16. `lastDrawn` is set only by reads that may plan (settled pass reads at a non-`incomplete` level), so a partial poll cannot hide the drawn
    keys a drop is judged against. A busy result re-arms the fold request only if the dragged key WAS the request (`flightReq`).

## Decision: Re-apply and the budget promise

Re-apply (`userRetry`) is something the user did, so it resets the budget and grants ONE strip session (`stripGrant`, emitted as a `user := true`,
unbudgeted move). On a full bar one Re-apply may therefore perform 1 granted move plus up to 3 budgeted moves. The product promise reads:
"at most 3 automatic moves between things you do, and pressing Re-apply may also make the one move next to the fold it grants." The model is
NOT changed for this; the theorems count budgeted (`user = false`) drags only.

## Safety theorems (ejb.2, `lean/Sommelier/Safety.lean`)

All quantify over every event list (`run`), so macOS may do anything. "User event" = `isUserEvent` (non-empty `userEdit`, `userRetry`,
`retryKey`; an edit that moved nothing is not one). Method: per-step lemmas by case analysis on `Event`, invariants (`Inv` with a ghost bit
"a user pass is open", `NU` for runs without a user event, `Expired`, `CountInv`) proved preserved by `step`, lifted by induction on the list.
`scripts/check-lean-axioms.sh` fails unless every theorem uses only `propext`, `Classical.choice`, `Quot.sound`.

| Theorem | Statement |
|---|---|
| `budget_any_from`, `budget_full_from`, `budget_between_user_events`, `budget_full_between_user_events`, `engineActions_between_user_events` | from ANY state (no reachability), over any list with no user event: `postedEngine <= 20`, and `<= 3` if `fullThroughout`; instantiated at the state just after a user event this is the promise "between one user event and the next". Invariant: `moveCount + pendEng <= max C (moveCount_0 + pendEng_0)` (`pendEng` = 1 only for an ENGINE drag in flight); it is false for a model where a strip grant bypasses the budget (mutant `engine_grant_bypasses_budget`). The engine-action count has the same segment form with `pendEng` |
| `budget_any`, `budget_full`, `engineActions_bound` | from `init`, no user event: `postedEngine <= 20`; if `fullBar s_i r` holds at every read (`fullThroughout`): `<= 3`; engine actions `<= postedEngine + skipped.length + (1 if a drag is in flight)` |
| `userLabelHonest` | a `user := true` action is an owed key or the fold request, or a granted strip move (`strip` and `stripGrant`); a grant cannot relabel an ordinary engine move |
| `strip_honest`, `strip_iff` | an emitted action's `strip` flag equals `needsStrip s r subject rel`, and is true exactly when the subject or target is in `foldedAll` or `nearFold` (mutants `needsStrip := false`, `needsStrip_no_near/_subject/_target` die to the theorems) |
| `stripOnlyForUser`, `noStripWithoutUser` | an action with `strip = true` at step `pre.length` is `user = true` and `UserPassOpen pre` (some user event in `pre` with no `passBoundary` after it); with no user event in the run, no action allows the strip |
| `noFoldedTarget`, `noFoldedTarget_run` | per read and for any action of a run: target not in `r.pile`, `r.folded`, the post-read `lastFreshPile`, nor in the pre-read `lastFreshPile` unless the read is a usable fresh-chevron read (which supersedes the memory: a key the memory still lists but the read shows drawn may be a target); an engine (`user = false`) subject likewise. Holds from ANY state. (Pin change of the corrective pass: the pre-read memory clause gained the exception, needed by the drop rule.) |
| `oneActionPerStep`, `noActionWhileInFlight` | at most one action per event; none while a drag is in flight |
| `oneStripSessionPerEdit` | after a user event and before the next, strip actions emitted `<= 1 +` strip drags answered "no mouse event posted" (those return the session). Stated without Nat subtraction; the fuzz form (`n - 1`, clamped) is stronger and also passes |
| `holdRelease`, `holdRelease_run` | a set hold is cleared only by a user event or by the step that gains the proof (`provenNotFull` false to true) |
| `proofNeedsThreeConsecutive` | `provenNotFull` at the end of a run from `init` implies a read `r` after `pre` that gained it. In the history of ALL reads except the complete, chevronless, observed, unsettled pass reads (these neither count nor reset; an unsettled read with a chevron or `incomplete` stays in it): the last two reads of `pre` and `r` are `absent` and not `incomplete`, and if `r` is a pass read the last THREE reads of `pre` are (non-read events may interleave); every read after `r` has no chevron |
| `owedExpires` | after `passBoundary` or `userRetry` (from a reachable state), `owedKeys = []` and `foldRequest = none` for every following list with no user event, including a late `busy` result |

Findings of the proof pass:
- No restated theorem was false. The earlier loose statements were already corrected by the restatement (budget counted at the result;
  proof needs three qualifying reads, not "the last three reads"; strip only inside an open user pass).
- Model fix from the ejb.1 final review, applied first: a later non-empty edit that moves the in-flight key clears `flightReq`, and a
  `busy` re-arm sets the fold request only if there is none (T4, T5 and T3 are `example`s; mutants `rearm_overwrites_request`,
  `edit_keeps_flightReq`).
- Fixed in the corrective pass (T6, T7): `retryKey k` clears `flightReq` when `k` is in flight (its pull is recomputed), and an empty-moved edit that
  changes the record clears it too; otherwise a `busy` result could re-arm a pull-out that no longer applies.
- `lean/Sommelier/Pins.lean` restates a SELECTION of the headline theorems as `example : <full statement> := @theorem` (171 examples); it does NOT restate every headline: 49 are unpinned, among them every status and row bridge (`status_*_bridge`, `row_*_bridge`) and `drop_truth`. `scripts/check-lean-axioms.sh` requires every HEADLINE name to exist as a theorem and be axiom-clean, whether or not it is pinned
  to build, so weakening a statement (not just its proof) breaks the build.
- The invariant that made `oneStripSessionPerEdit` provable: a strip grant with `restricted = false` implies the session is unused (`Inv.grant_used`).

## Liveness, gates and honesty (ejb.3: `Gates.lean`, `Truth.lean`, `Status.lean`, `Honesty.lean`)

Same method as ejb.2 (per-step lemmas lifted over `run`), but the statements say what a gate DOES to the engine's output, so removing the gate makes
the statement false. `Gates.lean` imports only `Step` (through `Eqns`); `Honesty.lean` imports `Gates.lean` and `Status.lean` (so `Truth.lean`); neither imports `Safety.lean`. Honesty is NOT independent of Gates: a broken `Gates.lean` proof stops `Honesty.lean` from building, so a kill credited to `Gates.lean` says nothing about `Honesty.lean` (the mutation script builds `Honesty.lean` only when `Gates.lean` builds, and requires a separate `HONESTY_MUST_KILL` set to fail there). Every statement is pinned in `Pins.lean`;
`scripts/check-lean-axioms.sh` lists the headline names and checks axioms for all 433 theorems of `Eqns`, `Safety`, `Gates`, `Truth`, `Honesty` (and requires `Pins.lean`, the full statements, to build).

| Theorem | Statement |
|---|---|
| `eng_no_hold`, `eng_no_open`, `eng_no_stale`, `eng_no_restricted`, `eng_no_budget_full`, `eng_no_budget_notfull`, `eng_budget_exact` | for a read where the hold is set / the strip is open / the chevron is stale / the pass is restricted / the budget (3 when `fullBar`, else 20) is spent, EVERY action of `step s (read r)` has `user = true` (no engine move). `eng_budget_exact`: an engine move implies `moveCount < 3` on a full read, `< 20` otherwise. |
| `plan_no_givenUp`, `plan_no_skipped`, `plan_in_record` | an engine move's subject is never given up or skipped, and its subject and target are keys of the record |
| `fullBar_ignores_chevron`, `chevron_engine_budget` | any chevron in a read means full; an engine move on a chevron read needs `moveCount < 3` |
| `plan_on_good_read` | an action implies a `pass` read, `settled`, level not `incomplete`, nothing in flight |
| `pile_replace`, `pile_fresh_add`, `pile_stale_add`, `proof_clears_pile`, `proof_clears_hold`, `pile_absent_keeps`, `lastDrawn_set`, `lastDrawn_kept` | exactly which reads REPLACE `lastFreshPile` (settled, readable, strip-closed, fresh chevron), which only ADD to it (every other fresh read, every stale read), that the proof clears pile and hold, and that other chevronless reads keep the pile; `lastDrawn` is set by plannable reads only |
| `res_failed_holds`, `res_failed_gives_up`, `res_failed_no_strike`, `res_proven_no_hold`, `res_proven_strike`, `res_proven_giveup`, `res_other_keeps` | a failed POSTED drag on a bar not proven not-full holds (with `holdFolded` = the pile) and gives its key up; on a proven bar it takes a strike and gives the key up exactly at the third; unposted or non-failed results change neither |
| `edit_hold`, `edit_budget_reset`, `edit_restricts`, `edit_new_session`, `edit_clears_skipped`, `edit_strikes`, `edit_givenUp`, `retry_*`, `rk_*` | a non-empty edit releases the hold exactly when a moved key meets `holdFolded` or the pile, resets the budget, restricts the engine, forgives exactly the moved keys; Re-apply clears hold, given-up keys, strikes, skips, owed drops, the restriction and the budget and grants one session; `retryKey` forgives its key, restricts, and never grants |
| `owed_nodup_init`, `emit_consumes`, `rearm_iff`, `rearm_request` | owed keys are listed once; a move that leaves removes its subject from `owedKeys` and the request (ONE attempt per drop); a busy-without-mouse result re-arms a key only if the CURRENT chain owed it, it is not already skipped, it is in the record (`Rearm`), and the request only if there is none |
| `prefixFor_spec`, `userMove_drawn_spec`, `userMove_right_place`, `userMove_moves`, `userMove_target`, `applyMove_before`, `applyMove_after` | the drop rule: a drawn key whose preceding anchors already equal the record's (as sets) gets NO move; otherwise, if the anchors admit a gap, exactly one move, to just after the last anchor of the smallest matching prefix (or before the first anchor); `applyMove` puts the subject next to its target on the stated side |
| `userMove_folded`, `edit_request_origin`, `edit_requests_pull`, `rk_request`, `rk_requests_pull`, `emit_flightReq`, `edit_flightReq`, `edit_empty_flightReq`, `rk_flightReq` | a pull-out is planned only for the fold request or an owed key, on a fresh chevron that lists it as folded, after the rightmost movable key before it in the record, and only if it changes the drawn list; the request is asked for only for a moved key that is folded now with a drawn key before it (and such a key does ask), or kept from before; `flightReq` is set exactly when the leaving drag was the request and cleared by every later event that moves or reorders it |
| `edit_owed`, `edit_empty_owed`, `edit_request_in_record`, `rk_owed`, `plan_spec`, `subjects_in_record` | owed keys, the request and every action subject are keys of the record (`SubjInRec` is preserved by every event) |
| `postedFull_init` | from `init`, with no user event, at most 3 engine drags that were DECIDED on a full read are posted, with no hypothesis about the other reads |
| `quiescence` | no user event in `es`, and any of (a) `moveCount >= 20`, (b) `moveCount >= 3` and `fullBar` at every read, (c) a hold that no read of `es` lifts by gaining the proof: every action of the run has `user = true`; if also nothing is in flight, owed or requested, there is no action at all |
| `userAlwaysAnswered_drawn`, `_none`, `_pull`, `user_drop_answered` | after the user drops `k` (`edited s rec k`) from ANY state with nothing in flight and `k` first in the queue (the fold request, then the owed keys), whatever the hold, budget, given-up keys, fold request or pile memory, on a read where the GATE is true (`State.gate`: usable and consistent; D2). Drawn case: `k` trusted drawn, not counted as folded, out of place among its anchors, with a gap: exactly one action, a move of `k`, `user = true`. Folded case: this read lists `k` as folded under a fresh chevron, `k` not drawn, a movable key precedes it in the record: exactly one action, the pull-out of `k` (`strip`, `user`). (`userAllowed` holds by itself after an edit: the edit opens a new session and a true gate says the strip is closed.) `_none`: no move of `k` exists and nothing else is owed: nothing leaves. Narrowly: when the stated hypotheses hold (see "Where a drop gets no move"), a gate-true read emits exactly the move of `k`; otherwise `owed_unanswered_reason` names why not |
| `provenNotFull_pile_empty`, `drop_answered_reachable` | for every state reachable from `init` (`run`): a bar proven not full has no pile memory (preserved by every event: a chevron read revokes the proof, the proof clears the memory). With it the drawn case of `user_drop_answered` needs NO `k ∉ foldedAll` hypothesis: for reachable `s`, gate true, `k` first in the queue, `k` trusted drawn and not in `r.foldedSet`, out of place among its anchors with a gap: exactly one action, a user move of `k` |
| `foldedDrawn_chevronless` | a key listed folded AND drawn on a chevronless read is an adapter contradiction (A2 pins the folded list only under a fresh chevron): it counts as folded, no move of it leaves, its row is its `rowVerdict` (the trusted drawn position), never `waiting`, never `behind`; a tick is the truthful `row_tick_true` |
| `in_place_row`, `unanswered_row` | the converse tied to the row. A movable owed key right among its anchors has row `inOrder`, or a named key is the reason: another OWED key, or a key counted as folded (chevronless contradiction or stale memory); untrusted and unread keys can never be the reason (the row reads only the pinned open keys), which is stronger than "owed, untrusted, unread or folded". Every owed key with no move emitted on a gate-true read has row = its `rowVerdict`, or `waiting` with a move of it existing and blocked: an unanswered drop never sits behind a row that says more than the reading says |
| `fold_crossed_only_by_drop` | from ANY state and read: a move whose subject this read lists as folded is the user's (`user = true`), on a fresh chevron, and its subject is the fold request or an owed (dropped) key. The engine never names a folded key; a folded key the user did not drop never gets a pull-out |
| `owed_unanswered_reason` | the converse, from ANY state with nothing in flight, on a gate-true read: an owed `k` with no move emitted for it is (1) already right among its anchors, (2) movable but its anchors admit no gap, (3) not a trusted drawn key and not folded (not on the bar, or not read), (4) counted folded but not licensed by this read (no fresh chevron listing it), (5) licensed but no movable key precedes it, (6) licensed but the pull-out would change nothing, (7) a move exists but needs the strip and this edit's session is used (an open strip is excluded by the gate), or (8) another queued key's move left instead. The "right among its anchors" test is the engine's own (`userMove`), not `rowVerdict`: the row may still say "not where you put it" while another owed key is pinned |
| `userRetry_leaves`, `userRetry_opens_gate` | from any state Re-apply leaves no hold, given-up key, strike, skip, spent budget or restriction, and then the engine gate is open on any read that is not stale and has a closed strip |
| `drop_expires` (Safety.lean) | from a reachable state, after `passBoundary` and with no user event: nothing is owed or requested, even if a late `busy` result arrives, and no action of the run is the user's (`user = false`): the owed attempt is not made again |
| `user_can_leave` | from ANY state: after Re-apply the hold, the given-up keys, the strikes, the skipped keys, the budget and the restriction are clear; and an edit is always accepted (the record is the new one, nothing leaves, and with moved keys the budget is fresh, those keys are no longer given up or struck and are owed) |
| `request_first` | a pending fold request whose pull-out move exists and is allowed, with the gate true, is the move the next read decides, whatever else is owed |
| `noNeedlessDrag_plan`, `noNeedlessDrag_user`, `noNeedlessDrag` | with a duplicate-free record and drawn list, every move the planner proposes or a user move names changes the drawn list (`applyMove r.drawn a ≠ r.drawn`). Without `Nodup` it is FALSE (record `[1,1,2]`): an adapter obligation (duplicate-free `record` and `drawn`) |

### What a reading says: `Truth.lean` (T1 - T9, no drop memory)

Verdicts are computed from the record and ONE reading (`verdict`, `rowVerdict`); `shownVerdict s r = verdict s.record (s.view r)` is what the window judges (`status_judges_view`).
`s.view r` is the read with the engine's own proof of "not full" in the field, as of BEFORE the read (`view_of_agree`). `State.unmet`, `State.served`, `placed`, `goodRead`,
`ownKeys` and the discharge logic are GONE: a lost drop is no longer remembered, the window says what the latest reading shows (`outOfPlace` / `behindOutOfTurn` for the
key: "not where you put it"; "Try again" is offered). The moves were compared with the pre-deletion step function on 60000 random traces (1.8 million events): same actions, same state in every other field.

| Theorem | Statement |
|---|---|
| `verdict_matches_iff`, `verdict_differs_iff`, `verdict_except_iff`, `verdict_cannotTell_iff` (T1 - T4) | `matches`: the read is usable and EVERY bar the reading allows (`Possible`) matches the record; `differs`: some bar is allowed and none matches; `matchesExcept U`: `ValidU` (the exact set of unplaceable keys that matter); `cannotTell`: none of these |
| `rowVerdict_inOrder_iff`, `_outOfPlace_iff`, `_behind_iff`, `_behindOutOfTurn_iff`, `_notOnBar_iff`, `_cannotTell_iff`, `differs_names_cause`, `rowVerdict_swap_elsewhere` (T5) | what each row mark claims about every allowed bar; a `differs` verdict always names a row that is out of place or behind out of turn |
| `no_needless_move_engine`, `no_needless_move_user` (T6) | an engine move is made only when the shown verdict is `differs`; a user move of an open key is out of its place on every allowed bar |
| `no_folded_target_truth` (T7) | a move's target is never behind the « on any allowed bar; its subject is open, or a pull-out of a key this read lists as folded and that is behind on every allowed bar |
| `macOS_fold_preserves` (T8) | if macOS folds the leftmost open key of a matching bar, it still matches (needs leftmost folding) |
| `no_move_on_cannotTell` (T9) | no move of any kind, the user's drop included, accompanies a `cannotTell` verdict. NOT "exactly when" |
| `decideMove_gated`, `view_of_agree` | a decision implies a usable, consistent view; `view` is the identity when the adapter feeds the engine's proof |

### Status and rows (`Status.lean`, `Honesty.lean`)

`statusLine s r`: `moving` when a drag is in flight or the read decides one (and only then: `notStuck`, `notStuck_conv`), else the verdict of the read: `matches`, `matchesExcept U`,
`differs why` (why: `stopped` = the budget is spent, else `barFull` = a hold, else `plain`), `checking` = cannot tell. `rowLine s r k`: `moving` (the key is in flight or decided), `waiting`
(owed or requested, and the read is not good or a move of the key exists and is blocked; NOT on a good read where the drop needs no move), else `tick` / `behind` / `notWherePut` / `notOnBar` / `cannotTell` from `rowVerdict` alone.

| Theorem | Statement |
|---|---|
| `status_matches_bridge`, `status_except_bridge`, `status_differs_bridge`, `status_checking_bridge` | each form of the status implies the matching `shownVerdict` |
| `status_matches_conv`, `status_except_conv`, `status_differs_conv`, `status_checking_conv` | with nothing pending, `shownVerdict = v` gives the status of `v`'s form |
| `status_matches_true`, `status_differs_true`, `status_except_true`, `status_checking_true` | the bridge composed with T1 - T4: what each status claims about every allowed bar |
| `notStuck`, `notStuck_conv`, `row_notStuck`, `row_notStuck_conv` | Moving (status or row) if and only if a drag is in flight or decided (for the row: of that key) |
| `stopped_true`, `barFull_true`, `status_plain_iff` | `stopped`: the bar differs, nothing is pending, the budget is spent, and (`quiescence`) no engine move follows without a user event while every further read is full (or 20 are spent); `barFull`: differs, a hold is set, no engine move follows unless a read gains the proof; `plain`: neither |
| `row_tick_bridge`, `row_behind_bridge`, `row_notWherePut_bridge`, `row_notOnBar_bridge`, `row_cannotTell_bridge`, `row_free_of_memory` | a tick is `inOrder`, a « is `behindChevron`, "not where you put it" is `outOfPlace` or `behindOutOfTurn`; with nothing moving and nothing owed the row IS its `rowVerdict`: no row is derived from memory |
| `row_waiting_true`, `row_waiting_conv`, `row_good_read_verdict` | `waiting` is exactly: owed or requested, no drag of the key leaving, and either the gate is false or a move of the key exists (`userMove`) and is blocked. On a gate-true read where the key's drop needs no move the row is its `rowVerdict`, never `waiting` |
| `row_tick_true`, `row_behind_true`, `row_notWherePut_true` | what each mark claims about every allowed bar (T5 through the bridge) |
| `drop_truth` | after `userEdit rec [k]` and any events, on a final read whose status is "matches": on EVERY allowed bar `k` is not on the bar, or it is and the bar matches the record (bridge and T1; no ghost) |

### Trust boundary and port items

The proofs assume (see "Truth statements" below): `Bar.WF`, leftmost folding (T8 only), A1 - A7 and the A3 soak (adapter assumptions: A2 the folded list under a fresh chevron, A3 the three-read proof of "not full"), and that the adapter delivers `passBoundary` and `moveResult`. Nothing else is trusted: the old drop memory is gone.
Port items (the Swift must change; the model is the spec):
1. Replace `statusLine` / `rowState` by the verdict forms above, fed from `shownVerdict` / `rowVerdict`. `Read.notFullProven` is fed from `!fullBarState`, not Swift's `notFullProven`.
2. The pass on which the proof takes effect is one pass LATER than Swift (the fourth chevronless pass read, the model judges a read by the state before it): the port needs a follow-up pass or Moving strands.
3. `stopped` needs nothing pending and a spent budget; Swift also shows it for a held strip move (`gatedDiffers`, LayoutEngine.swift:1982): in the model that is a plain `differs` (no reason is claimed).
4. Every move, the user's drop included, waits for a USABLE reading (D2): a stale chevron, an open strip, an unsettled, incomplete or unobserved read, a poll, or a chevronless read before the proof gives "Checking" and no move.
5. Feed `Read.unread` (apps whose read failed or was skipped, stale off-bar items, parked items with a nil Control Center flag) and subtract the pile keys from `drawn` (A6, A7).

Known limits (stated, not proved away): "matches except U" is not final placement (a tick next to an unread key); "Try again" needs a USABLE read to do anything, so with a stale
chevron it waits (row `waiting`), then the attempt expires at the pass boundary and, while the chevron is still stale, the row reads "can't tell" (`cannotTell`; status "Checking the menu bar"): an unusable read has no `rowVerdict` beyond that. "Not where you put it" appears only once a USABLE read shows the key out of place; a key remembered as folded but absent from the read gets no pull-out;
T9 is one-way and is about the whole read, not a row; `heldStrip` has no reason text; the truth theorems are only as good as A1 - A7 (A3 needs the soak). The positional claims
`drop_expires`, `stopped_true` and `barFull_true` are about the ENGINE: Re-apply (a user event) is outside them.

## Live items for ejb.8 (device tests the model cannot settle)

1. How often does the chevron read arrive STALE (carried: a fresh read failed or missed its budget, `MenuBarItem.stale`; `ScanState.recentlyVerifiedMaxScans = 2` bounds only the display flag
   `recentlyVerified`, not `stale`) on an OVERFULL bar, over a 30 minute idle session and during a drag session? The docs say only that the chevron "flaps between scans"
   (docs/testing.md live item 4, docs/architecture.md:402); no figure exists. With D-E a persistently stale chevron presents as a permanent "Checking the menu bar…" and never as a check or
   "Menu bar matches" (a drop on a stale chevron: the row is `waiting` while the drop is owed, and "can't tell" once the attempt expires at the pass boundary; the status is "Checking the menu bar" throughout). Measure the fraction of passes and of seconds with a stale chevron and the longest run; if the longest run is long, the status needs a
   timeout text (the Swift `timedOut` path, D5).
2. A drop that macOS later folds: the row reads « (`behindChevron`) when nothing before it is open, "not where you put it" (`behindOutOfTurn`) when something before it is.
3. A drop whose attempt expires on an unusable read (stale chevron, unproven chevronless bar): the row says "can't tell" (`cannotTell`), the status "Checking the menu bar"; "Try again" is offered; check the wording on a device. ("Not where you put it" needs a usable read.)
4. An app that quits after a drop: the row reads "not on the bar" (`notOnBar`); unread keys read "can't tell".

## Truth statements (ejb.3, `lean/Sommelier/Truth.lean`: T1 - T9 proved, imported by `Sommelier.lean`)

What a reading says about the REAL bar. `verdict rec r` (matches / matches except U / differs / can't tell) and `rowVerdict` are computed from the record and ONE reading; the
theorems T1-T9 tie them, and the engine's moves, to "every bar macOS could honestly have drawn". The assumptions about macOS, in plain language (a reading is USABLE only if it is a
settled, observed pass read of a readable tree, strip closed, with a fresh chevron or the proof that there is none; nothing is believed from an unusable read):

- A1. On a usable read, the trusted drawn keys really are open on the bar, in the order the read shows them.
- A2. On a usable read with a FRESH chevron, the keys the read puts in the pile or folds really are behind the chevron. (Keys that Swift merely INFERS to be folded, `foldedParked`, are
  not measured, so they must go to `unread`; how `foldedParked` is treated is an open question with the user and is not decided here.)
- A3. On a usable read with no chevron, nothing is folded. The reason: 3 complete chevronless readings in a row, pass or quiet poll, are taken to prove the bar is not full (an unsettled complete pass read neither
  counts nor resets, as in Swift; an incomplete read or a chevron resets). This is an ASSUMPTION; it needs a soak of the longest chevronless run a FULL bar produces, counting those same reads (passes and polls). The counted polls include strip-open, unsettled and `exceptSelfPositioning` polls, matching Swift `notePollScan` (LayoutEngine.swift:1871-1883); the soak must be run at ejb.8 and has not been. If one run ever reaches three, the count is too short.
- A4. A `Key` names the same menu bar item in the record, in the reading and on the bar.
- A5. A reading describes one instant of the bar; no statement relates two readings (T6/T7/T9 relate a reading to the one move decided on it).
- A6. On a usable read, every key on the bar, open or behind, is drawn, in the pile, folded or `unread`. A key listed nowhere (an app that is not running) is not on the bar. An `unread` key may be anywhere.
- A7. (Shape of the lists.) `rec` has no duplicates, `unread` is disjoint from the trusted drawn keys, `drawn` excludes the pile keys, and a stale pile goes to `unread` (Truth.lean A7).
- `Bar.WF` (no duplicate key; nothing both open and behind) is assumed of every real bar.
- Leftmost folding: that macOS folds the leftmost open key (`Bar.IsFold`) is an assumption, needed only by `macOS_fold_preserves` (T8).

**Trust boundary, in full:** `Bar.WF`, leftmost folding (T8 only), A1, A2, A3, A4, A5, A6, A7 and the A3 soak. None is checked by the proofs.

`Read.notFullProven` must be fed from `!fullBarState`, not from Swift's `notFullProven` (LayoutEngine.swift:1849-1889): Swift's variable turns true during the third chevronless pass read while
`fullBarState` is still true (:1857-1858, :1810: that read still plans full and shows "Checking"), and it is cancelled by a chevron or an `incomplete` read before the next pass (:1856, :2262). The model's `provenNotFull` is `!fullBarState`: it turns true on the
FOURTH settled chevronless pass read (or at once on a quiet poll that is the third), and `State.view` uses the proof as of BEFORE a read, so that fourth read still says "can't tell" and moves nothing; the fifth is the first judged proven. Swift plans the flipping pass flipped, so the model is one pass more conservative there. Gating and the status judge the same view on the same read.

**The Swift supply for A6 (bounded change; today nothing in Swift can supply `unread`).** (1) Add the unread owners to the snapshot and to `ObservedOrder`: apps whose read failed or timed out
(MenuBarScanner.swift:510, :514), the apps the scan skips (the skip set, :453) and the fast path that never scans them (:432). (2) Collect the stale off-bar items that Reconciler.swift:71 drops.
(3) Derive `unread` from each RECORD key's owner (`ownerKey` is usually but not always the bundle id; over-approximating, i.e. listing a key whose owner is merely suspect, is sound: it can only
lower a verdict toward "except" or "can't tell"). (4) Parked items with a nil Control Center flag (Reconciler.swift:87) go to `unread`.

**Port obligation.** `Status.lean` is built on `shownVerdict` / `rowVerdict` (bridge theorems above); the Swift rebuild replaces `statusLine` and `rowState` with them. T9 (`no_move_on_cannotTell`) says no move is made when the shown verdict is "can't tell" (the converse, and rows, do not follow).

**Limits.** (a) A tick with "except" is not final placement: with the bar [1,3,2] and 2 unread, row 3 is a tick with "matches except 2"; the UI must not imply that 3 is finally placed. (b) "Try again"
needs a USABLE read to do anything: a drop (and a retry) waits for the gate (D2), so with a stale chevron or an unproven chevronless bar it stays pending (row `waiting`), then expires at the pass boundary and the row reads "can't tell".
(c) A key remembered as folded (pile memory) but absent from the current read gets no pull-out on that read; its row says "not on the bar" (listed nowhere) or "can't tell" (unread).
(d) A1, A2, A3 (and its soak), A4, A5, A6, A7, `Bar.WF` and leftmost folding are ASSUMPTIONS, not checked by the proofs (see the trust boundary above). (e) T9 says a move is never made when the shown verdict of the read is "can't tell"; it is NOT "exactly when", and it is not about rows: a move can coexist with a "can't tell" row for another key.

## Fuzz harness

`cd lean && lake exe fuzz [mixed] [noUser] [seed]` (default 20000 mixed traces of 30 events, 5000 traces with no user event, seed 1) runs
seeded random traces against computable forms of the ejb.2/ejb.3 statements: oneActionPerStep, noActionWhileInFlight, noFoldedTarget,
noFoldedEngineSubject, holdRelease, proofNeedsThreeConsecutive (`proof_three_consecutive`, `proof_not_late`), chevronRevokes, owedExpires, owedStaysExpired, userRetryClears,
quiescence_true, userAlwaysAnswered (with the gate), budget_any, budget_full, stripNone.

The honest-bar property (second set of 20000 traces): at each read a REAL bar `b` is drawn first (open keys in some order, keys behind the chevron; aligned with the record or not, sometimes
with a swapped pair) and the reading is derived from it by the assumptions of `Truth.lean` (trusted drawn keys open in the shown order, pile and folded keys behind a fresh chevron, no chevron only
when nothing is behind, every bar key drawn, in the pile, folded or unread, junk and unread keys added). `generator_honest` checks that `Possible (s.view r) b` really holds. Then, for the state before the read:
`claim_matches` (status "matches" implies `barMatches`), `claim_differs` (not), `claim_except` (`barMatchesExcept U`), `row_tick_open`, `row_behind_behind`, `row_notOnBar_off`,
`engine_move_bar_differs` (an engine move implies the bar differs), `move_target_open`, `move_subject_open_or_pullout`, `move_not_on_cannotTell`. Both sides are counted (`bar_matches_seen`,
`bar_differs_seen`, `status_*_seen`, `engine_move_seen`, `user_move_seen`) and the run fails if any claim was never exercised. Default run, seed 1 (one fresh `lake exe fuzz`, exit 0, 25000 traces, 1350000 events): `claim_matches` 35095, `claim_differs` 23696, `claim_except` 73376, `engine_move_bar_differs` 20548, bars matching 201407 and differing 130548, `userAlwaysAnswered` 4276, `userAlwaysAnswered_pull` 25682, `owed_unanswered_reason` 46682, 0 failures. Exit code 1 and the first counterexample trace on any failure.
Use it to try a statement before proving it.

## Where a drop gets no move

What the theorems allow today, stated plainly. `user_drop_answered` and `drop_answered_reachable` promise a move only under their hypotheses (the key is trusted and drawn, or listed folded under a fresh chevron; it is out of place among its anchors; a gap or a movable predecessor exists; `k` is first in the queue). They do NOT promise that every dropped key is eventually placed. Three traces where a drop gets no move:

- (a) Vacuous tick. Record [1,3], the user drops 3, the read draws [3,1] with only 3 trusted. Key 1 is not pinned, so 3 has no anchor to be out of order against: no move, row 3 ticks, status "matches except 1". The tick is true about what the reading fixes (`row_tick_true`), not about key 1.
- (b) Mutual inversion. Record [1,2,3], the user drops [1,2] (both owed), the bar draws [2,1,3]. Owed keys are not anchors of each other, so no move leaves on any good read; both rows read "not where you put it"; "Try again" does nothing on a good read, because the same test runs again.
- (c) No gap. Record [1,2,4,3], bar [2,3,4,1]: the anchors of the dropped key are out of record order, so no gap satisfies the rule; "Try again" does nothing, even after a pass boundary.

(b) and (c) are being reconsidered. Liveness also rests on the adapter delivering `passBoundary` and `moveResult`; there is no drain theorem that an owed key is eventually served or expired without them.

## Mutation testing

`scripts/lean-mutants.sh` (= `python3 lean/scripts/mutants.py`; one build of every module per mutant, about 45 minutes with 8 jobs on a loaded machine; `--check` only validates the patches)
applies each of 214 single edits to `Step.lean`/`Model.lean`/`Safety.lean`/`Status.lean`/`Truth.lean`. A mutant is killed when a theorem or pin stops compiling, an example fails, or the fuzz
harness reports a failure. Modules are built SEPARATELY and the failing declarations named: `Safety.lean` and `Gates.lean` import only `Step` + `Eqns`; `Truth.lean` imports `Step` only;
`Honesty.lean` imports `Gates.lean` and `Status.lean` (so `Truth.lean`), so a mutant that breaks a `Gates.lean` or `Truth.lean` proof stops `Honesty.lean` from building and is credited to
that module (it says nothing about `Honesty.lean`; the script builds `Honesty.lean` only when both build). The fuzz harness runs only when `Truth.lean` builds. The sets: `PROOF_MUST_KILL`
(a `Gates`/`Truth`/`Honesty` theorem must fail), `TRUTH_MUST_KILL` (a `Truth.lean` declaration must fail), `HONESTY_MUST_KILL` (an `Honesty.lean` declaration must fail with `Gates.lean` and
`Truth.lean` intact: the status and row mutants) and `PROOF_MUST_KILL_ANY` (ejb.2 ones that any theorem or pin may catch, and the proof-count mutants). The script exits non-zero on any survivor
without a documented reason, any BADPATCH/NOCOMPILE mutant, or any must-kill mutant that its theorems miss.

Last full run: 214 mutants, 214 killed, 0 survivors, 0 invalid, exit 0 (the older ejb.3 pass B figure was 207; the counts below are from that older run). The full 214 run predates the additive theorems later added to `Honesty.lean` and `Pins.lean` (`provenNotFull_pile_empty`, `drop_answered_reachable`, `foldedDrawn_chevronless`, `in_place_row`, `unanswered_row`, `fold_crossed_only_by_drop`); no model change (`Step`, `Status`, `Truth`) since, only `mutants.py --check` was re-run. 194 fail a `Gates.lean`/`Truth.lean`/`Honesty.lean` theorem, 13 only a `Safety.lean` theorem or a pin
(bookkeeping whose theorem is an ejb.2 one: `stale_no_revoke`, `stale_no_count_reset`, `fresh_no_revoke`, `userAllowed_no_session`, `emit_no_session`, `emit_grant_survives`,
`res_no_session_return`, `res_no_skip`, `retry_no_gen`, `pb_grant_survives`, `pb_restricted_survives`, `pb_no_gen`, `postedEngine_skips_case`); none is noticed only by an example or the fuzz.
By the DECLARATION that fails: 125 fail a named headline theorem (`HEADLINE` of `scripts/check-lean-axioms.sh`), 82 only a helper or specification lemma, a pin or a Safety theorem. A helper that
fails invalidates the headline proofs that consume it, but the count cannot tell a falsified property from a positional proof break; 114 kills are also noticed semantically (a failing example or a fuzz
counterexample against the random honest bar), and the 93 others die only to a broken proof, because the fuzz harness does not run when `Truth.lean` fails to build. The 57 new mutants (the verdict and
`usable`: each Honest conjunct's use, each `usable` clause (stale, unsettled, proof, strip, poll, incomplete, unobserved), the pile, `unread`, a padded `U`, a global row check, `behindOutOfTurn`; the status and rows:
matches on "except" and on "cannot tell", Moving with nothing pending, `stopped` without a spent budget; the gate removed from `decideMove`; the pull-out from memory; the proof counting unsettled reads) are all
in the must-kill sets: 32 die to a `Truth.lean` declaration alone, 19 (the status and rows) to an `Honesty.lean` declaration with `Gates.lean` and `Truth.lean` intact, 6 to `Truth.lean` and also `Safety.lean` or `Gates.lean`.
