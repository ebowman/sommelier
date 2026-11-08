# Verified decision core (epic sommelier-ejb)

`lean/` holds the specification of the engine's decisions in Lean 4 (4.35.0, no Mathlib yet). `cd lean && lake build` checks it.
The model is `lean/Sommelier/Model.lean` (types), the decision function is `lean/Sommelier/Step.lean`
(`step : State -> Event -> State x List Action`, total, computable, axioms: `propext` only), and `lean/Sommelier/Examples.lean` holds
`#eval` examples that are also `decide`-checked, including every counterexample a reviewer found. macOS is an adversary: theorems (later
beads) quantify over ALL event lists, so the model never says what a read means.

## Shape (deliberate)

- One decision per read: at most ONE drag leaves per `read` event; the world answers with `moveResult` and the next read decides again.
  EVERY action is one physical drag, for user and engine moves on every bar (retries are later passes). Decided.
- Only a `pass` read that is `settled` and not `incomplete` may plan. A `poll` read, an unsettled read and an `incomplete` read are evidence only
  (evidence rules below apply to all of them).
- A user's pass is the span from a user event to the next `passBoundary`. In it only owed keys move.
- Owed user moves (the fold request first) are planned before the engine's, never both in one read.
- The planner is a stub (first inversion); `ejb.4` replaces it.

## Lean to rule

| Lean | Swift / rule |
|---|---|
| `fullBar s r` = `!provenNotFull or chevron present` | `LayoutEngine.fullBar`: full from launch, any chevron makes it full |
| `noteRead`, `provenNotFull`, `noChevronReads` | `noteChevronEvidence`, `notePollScan`, `noteAnyRead`: 3 consecutive chevronless reads at level `complete`/`exceptSelfPositioning` prove the bar not full; `incomplete` resets the count; any chevron revokes. Pass reads, polls, settled or not, are one rule (as `notePollScan`). The proof applies from the NEXT read (`decideMove` runs on the pre-read state). |
| `hold`, `holdFolded` | `stripOpenHold`, `stripHoldFoldedSet`. Set by a failed POSTED drag while the bar is not proven not-full (user's or engine's); `holdFolded` is the folded set at that moment (read only by `userEdit`, never reset: it matters only while `hold` is set). Released by `userRetry`, `retryKey`, a `userEdit` whose moved keys meet `holdFolded` or the current last fresh pile, and the proof. A drawn-only edit keeps it. |
| `moveCount`, `cap`, `capFull`=3, `capNotFull`=20 | `engineMoveCount`, `engineCap`. Counted at the result of a POSTED engine drag, so it never decreases between user events; reset by `userEdit` (non-empty moved), `userRetry`, `retryKey`. 3 means 3 real drags. |
| `owedKeys` | `userDropPending`: every moved key of every edit still in the record (union across edits, no duplicates, no filter on what was drawn). Erased when its move is emitted; emptied by `passBoundary`. |
| `foldRequest` | `foldDropRequest`: owed keys and the request are always filtered by the CURRENT record (at every `userEdit`, even with empty `moved`, at `retryKey` and at re-arm). At most one folded key (first in record order of an edit) with a drawn key before it in the record, folded AT EDIT TIME (member of `lastFreshPile`). The only key a pull-out is planned for. |
| `restricted` | `userEditRestricting`: only owed keys move. `userRetry` is unrestricted. |
| `stripGrant` | `retryStripGrant`/`grantedAction`: set by `userRetry` ONLY (after `retryKey` the pass is restricted, so the engine could never use a grant), consumed by the first engine move that needs the strip (emitted as the user's, `user := true`, not counted), cleared by `passBoundary`. |
| `editSessionUsed` | `editStripSessionUsed`: any emitted `strip := true` sets it; a user (or granted) move that needs the strip is withheld once set, and while the strip is open. A drag with no mouse event returns the session. |
| `needsStrip`, `Action.strip` | `gateEngineMoves.needsStrip`: subject or target in `foldedAll` (this read's pile and folded keys and `lastFreshPile`) or `Read.nearFold` (the churn zone, supplied by the adapter). |
| `movable` | gdu.144 rule 3: drawn, trusted, not in `foldedAll`: the only keys a planned move names. |
| `lastFreshPile` | `lastFreshChevronObs` pile: REPLACED only by a settled, non-`incomplete`, strip-closed read with a fresh chevron; any other chevron read (stale, unsettled, incomplete, strip open) adds to it (a SETTLED, closed, readable fresh poll replaces it, like a pass read); kept through chevronless reads until the proof. |
| `givenUp`, `strikes` | `cannotPlace`/`orderAttempts`/`revertWatch`/strikes. On a bar not proven not-full the first failed posted drag gives a key up; once proven not-full, 3 failed posted drags. Cleared by user events: `userEdit` clears only the MOVED keys' entries, `userRetry` all, `retryKey` that key. There is no `appsChanged` release (dropped: only user events clear given-up keys). |
| `skipped` | a key whose drag was refused/busy/failed without a mouse event: no engine move of it until a user event (so a refused key cannot loop). |
| `inFlight`, `gen`, `flightOwed` | the serial actuator call; only its `moveResult` clears it. `gen` is bumped by `passBoundary` and `userRetry`; `flightOwed` records at emit time whether the drag's subject was owed by the CURRENT chain (never true for a granted move), which is the only case a user `busy` without a mouse event is re-armed. |
| `planOrderMoves` | `Reconciler.plan` order phase (stub). An engine move that needs the strip is withheld (not emitted, not counted) unless `stripGrant`. |
| `userMove` | `plan(onlyMove:)` + `foldDropRequest`. Exact rule for a drawn owed key `k`: ANCHORS are the movable keys that are in the record, are not `k` and are not still owed (so a key already SERVED is an anchor, and may be a target; a drawn key absent from the record never forces a drag). `k` is RIGHT when the set of anchors before it on the bar equals the set of anchors before it in the record: then no move. Otherwise take the first gap, in DRAWN order of the anchors, whose preceding anchors are exactly that set; the move is `after` the last anchor of the gap, or `before` the first anchor if the gap is empty. If no gap satisfies the test (the anchors are themselves out of record order) there is no move, and if the drag would leave the drawn list unchanged (`applyMove`) there is no move; a no-op never spends the owed attempt or sets a hold. Anchors never move in a restricted pass. A folded key is pulled out only if it is the fold request, on a fresh chevron, `after` the rightmost drawn key that precedes it in the record. |
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
11. No row text, status line or warning is modelled here (bead `ejb.3`).

## Open questions, each decided (safer reading chosen)

1. Refused drags. Decided: a drag with `posted = false` is never budget (refund by construction) and EVERY such result, including a
   "verified" one, puts the key in `skipped` (so nothing loops); only a user's `busy` that the CURRENT chain owed is re-armed, once; every other
   user result without a mouse event is consumed.
2. Several failures per key. Decided: on a bar not proven not-full the first failed posted drag gives the key up; once proven, 3 strikes.
3. Hold at launch before any chevron is seen. Decided: a failed posted drag holds whenever the bar is not proven not-full (assumed full counts).
4. `provenNotFull` is revoked only by a chevron (an `incomplete` chevronless read after the proof does not revoke it, as in Swift). So the
   ejb.2 theorem "provenNotFull implies the last three reads were chevronless" is FALSE as written; the true statement is "since the proof no
   read showed a chevron, and three qualifying chevronless reads preceded it". Decided: model unchanged; state the true theorem.
5. Unsettled complete chevronless reads. Decided: they count toward the proof like polls (Swift `notePollScan` counts them), `incomplete` resets.
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

## Fuzz harness

`cd lean && lake exe fuzz [mixed] [noUser] [seed]` (default 20000 mixed traces of 30 events, 5000 traces with no user event, seed 1) runs
seeded random traces against computable forms of the ejb.2/ejb.3 statements: oneActionPerStep, noActionWhileInFlight, noFoldedTarget,
noFoldedEngineSubject, holdRelease, proofGained, chevronRevokes, owedExpires, owedStaysExpired, userRetryClears, quiescence_true,
userAlwaysAnswered, budget_any, budget_full, stripNone. Exit code 1 and the first counterexample trace on any failure. Use it to try a
statement before proving it.
16. `lastDrawn` is set only by reads that may plan (settled pass reads at a non-`incomplete` level), so a partial poll cannot hide the drawn
    keys a drop is judged against. A busy result re-arms the fold request only if the dragged key WAS the request (`flightReq`).

## Mutation testing

`scripts/lean-mutants.sh` (= `python3 lean/scripts/mutants.py`; slow, one full build per mutant, `--check` only validates the patches)
applies each of 141 single edits to `Step.lean`/`Model.lean`; a mutant is killed when an `example` stops compiling or the fuzz harness
reports a failure. Rules found to be dead were deleted rather than tested (the `retryKey` strip grant, the `!editSessionUsed` test in the
grant check, resetting `holdFolded`, and the no-op filter on a drawn user move, which the gap rule already makes unreachable: `noop_user` in the fuzz harness checks it). Last run: 141 mutants, 141 killed, 0 survivors (about 3.5 minutes on 10 jobs).
