# Plan: drive LayoutEngine order moves from DecisionCore (sommelier-ejb.7)

**Status (ejb.7, Wiring 5 done).** The plan below is executed: every order move comes from `DecisionCore.step` (ejb.15), rows and status from the core (ejb.16), and
the replaced decision code is deleted (section 3). The file:line references are as of d64b567 and are history. `scripts/check-single-decider.sh` (run by `make test` and
`make verify-core`) fails if a second `actuator.move(` call site or any deleted symbol comes back. Kept, as planned: the scanner, membership planning (`Reconciler.plan`
is membership only), adoption, the actuator and `LiveActuator`'s refusals as a backstop, the D5 position timeout, and a membership-only fold memory (`LayoutEngine.foldMemory`,
the `effective` foldedParked union) so a folded item is never shown. Known gaps left for ejb.17 / follow-ups: relaunching an app no longer clears a give-up (the core has no
such event), and the "Done: X. Next: Y" announcement after a user edit is gone (the core does not report the deferred moves).

## 1. Adapter: today's Swift to Lean inputs

New pure files in SommelierCore: `CoreKeys` (ItemKey ↔ UInt32, interned, never reused, chevron never interned) and `ReadAdapter` (ObservedOrder + context → `Read`).

**Read fields**
- **kind:** a pass read comes from `observeOnce` (LayoutEngine.swift:2249-2282). A poll comes from `notePollScan`, called at EngineTriggers.swift:239. The actuator's post-move snapshot (`adopt`, :2309) is a pass read with `settled:false`, so it is evidence only.
- **settled:** `BarObservation.settled` (MenuBarObserver.swift:35). Also set false when the last two complete reads disagree on the pile, which replaces the veto in `fullBarOrderGate` (:3076).
- **level:** `snapshot.completeness` (MenuBarItem.swift `completeness`).
- **observed:** false when observation fails or the bar comes back empty.
- **stripOpen:** `obs.stripExpanded` (Reconciler.swift:105-106).
- **chevron:** `.fresh` if `overflowChevron != nil`. `.stale` if `chevronRecent || chevronPresent`; a recently verified chevron counts as stale, the conservative choice. `.absent` otherwise.
- **drawn:** `onBar` minus pile minus the chevron key, left to right.
- **pile:** `onBar ∩ systemOverflow`, only with a fresh chevron. A stale pile (inferred at :94-98) goes to `unread`, as A7 requires.
- **folded:** `[]`. The inferred `foldedParked` (:107) goes to `unread` (A2), pending the user's decision.
- **trusted:** drawn minus `uncorroborated ∪ staleOnBar` (:73-75, :78), minus `handDragUnverified`, minus `!caps.canMove`, minus unread. On a read that is not `.complete`, it also drops self-positioning keys; this replaces the (e2) gate at :2653.
- **nearFold:** `SystemOverflowRule.churnZone(recentReads)` (:1917) minus pile.
- **notFullProven:** send `false`. Every export judges `s.view r` (Truth.lean:2354), so this field is ignored.
- **unread (A6/A7 gap):**
  - Add `unreadOwners` (pid and bundle id) to `MenuBarSnapshot` and `BarObservation`. Fill it from `fallBack` (MenuBarScanner.swift:527, both the failed case :510 and the missed-budget case :514), the skip set (:453), and every queried app on the fast path (:432).
  - Collect the stale off-bar items that the filter at Reconciler.swift:71 drops into `ObservedOrder.staleOff`.
  - Parked keys with `placementUnknown` (:86), and with `controlCenterAllowed == nil` (the fall-through at :87), go to unread.
  - Map owners to record keys through `itemInfo` / `ArrangeSections.ownerBundleID`. Over-approximating here is sound.
- **Duplicate-free and disjoint:** `ObservedOrder` already dedups (:72). The adapter dedups again, removes pile keys from drawn, removes unread keys from trusted, and asserts `Nodup` (debug precondition).
- **record:** `layout.visible` minus the chevron and immovable keys (assumption 8), deduped.

**Events**
- **read:** see above.
- **userEdit(rec, moved):** from `setLayout(..., moved:)` (:602), only when the user placed it and `moved` is not empty. Engine-made record changes send `userEdit(rec, [])`: new items (:2622), upgrade adoption (`adoptBarOrder` :1151), hand-drag adoption (:1059), System Settings hides (:1641).
- **userRetry:** `userRetry()` (:1259).
- **retryKey(k):** `retry(key:)` (:1292).
- **moveResult:** see §2.
- **passBoundary:** at the start of a regular pass, at the branch at :2493-2499. Also when a user chain ends (:2427). Never at the start of the Re-apply pass (assumption 6).

## 2. Output side

- One `Action` becomes one `actuator.move(k, .before/.after(t))`, the single call site at :2988. Before it the engine calls:
  - `setSingleDrag(true)` (assumption 5);
  - `setEngineInitiated(!a.user)`, kept as the strip-open refusal backstop (LiveActuator.swift:364);
  - a new `setStripAllowed(a.strip)`: `performMove` refuses when `stripNeed != nil && !allowed` (:369-374). This is assumption 7.
- Strip sessions stay entirely inside `stripMove` (LiveActuator ~563). Only `strip` gates them.
- **Outcome mapping.** `posted` is always `lastMoveTouchedMouse` (:334); the chevron click counts as a touch.
  - `.verified` → `verified`
  - `.userBusy` → `busy`
  - `isOverflowRefusal`, `unsupportedItem`, `notFound`, or the new strip refusal → `refused`
  - everything else, including `isStripHoldFailure` → `failed`
- Every emitted action gets exactly one `moveResult`. This includes actions vetoed after the step (`awaitQuiet` blocked, layout superseded, paused); those send `busy, posted:false`.
- Swift-only vetoes that are known before the step must not decide anything. They downgrade the read to evidence: `settled:false` is the only permitted edit to a `Read`. The vetoes are: pause, conflict, sleep, not ready, a membership batch this pass (assumption 4), pending adoption, hand-drag adoption, transient reveal, reveal pass.

## 3. Dead code and what stays

**Delete, in LayoutEngine:**
- The user-edit chain state: `userEditMoved`, `userEditRestricting`, `userDropPending`, `foldDropRequest`, `foldRequestCreated`/`Planned`, `userEditPassOwed` (reduced to two pass-scheduling flags for `passBoundary`).
- The strip hold: `stripOpenHold`, `stripHoldFoldedSet`, `stripHold*`, `lastFolded`, `lastDrawn`.
- The not-full proof: `lastFreshChevronObs`, `fullBarState`, `noChevronReads`, `notFullProven`.
- The display flags: `lastGatedDiffers`, `lastOrderDiffers`, `lastCheckingBar`, `lastPlanHadMoves`.
- Grants and budget: `retryStripGrant`, `retryGrantPass`, `grantedAction`, `editStripSessionUsed`, `engineMoveCount`, `engineBudgetLogged`.
- Attempt tracking: `cannotPlace`, `orderAttempts`, `revertWatch`, `lastVerifiedOrderMove`, `unverifiedStrikes`, order `strikes`, `overflowRefused`, `foldRefused`, `orderMoveTimes` and the per-minute cap, `unsteadyKeys`, `previousSettledBar`, `deferredThisPass`.
- Functions: `applyUserEditDeferral`, `isUsersMove`, `fullBar`, `noteChevronEvidence`, `noteAnyRead`, `engineCap`, `gateEngineMoves`, `applyStripHold`, `set/resetStripHold`, `noteAttempt`, `fullBarOrderGate`, and the order half of `makePlan` (:1727-1814).

**Delete, in Reconciler:** the order phase of `plan` (:354-545). That means the `held`, `unsteady`, `foldDropRequest`, `fullBar` and `onlyMove` parameters, plus `crossFoldMove`, `layoutTarget`, `moves`, `movesReporting`, `violations` and the order skip reasons.

**Keep:**
- the scanner, observer, membership planning and batches, new items, adoption (upgrade, hand drag, System Settings), the actuator;
- LiveActuator's refusals as a backstop;
- the position timeout (D5);
- a membership-only fold memory (today's `effective` foldedParked union), so a folded item is never "shown".

## 4. Rows and status

- **Where it is computed:** after each read step, in the actor, from the pair the next step judges: (state before the read, read). After other events, from (current state, last read). Publish `coreStatus`, `coreRows[ItemKey]` and `coreNotes` in EngineState.
- **Single renderer:** `CoreStatusText.render(status, context)` is used by both `ArrangeSections.statusLine` (ArrangeModel.swift:657) and `StatusLine.text(state:)` (:22). This settles D10.
- **Status wording:**
  - `moving` → "Moving X…"
  - `matchesExcept` → "Menu bar matches except N unread"
  - `differs(.stopped)` → `stoppedText`
  - `differs(.barFull)` → `barFullText` with the pile count
  - `differs(.needsReapply(k))` → "Re-apply to move <name of k>: the move needs the « strip" (ejb.20; the row of k carries the same signal as a note)
  - `differs(.plain)` → "No move to make right now"
  - `checking` → `checkingMenuBar`
- **D7 leaders:** lastError, permission, conflict, paused, pause reason, adoption pending, hand-drag and System Settings notices, failed membership.
- **D7 trailers:** pinnedDown, pollPaused, unsettledNotice.
- **Deleted text:** `userEditDeferredText` goes, because it came from a second plan.
- **Rule:** the string "Menu bar matches" is produced only by `.matches` / `.matchesExcept` with no leader and `lastError == nil`. A test enumerates every Status against every context.
- **Rows (D9):** the Lean row first. Swift may refine wording only within the same ok-class:
  - ok = tick, behind, notOnBar
  - not ok = moving, waiting, notWherePut, cannotTell

  A timed-out row (D5) may only downgrade.
- **Row notes:** `noMoveHelps`, `cantJudge` and `noMoveHere` need a `rowNote` export, which does not exist yet: Ffi.lean exports only init, step, status, shown_verdict, row_line, row_verdict and describe_event.

## 5. Threading

- `LayoutEngine` is already an actor, so it is the single serial owner of `DecisionState`. All core calls run there, never in `publish` closures on the main actor.
- Rows cost 2.7-4.2 ms per read and should be computed once per step.
- A `DecisionError` is logged and stops actuation (`lastError`). It never defaults to "matches".

## 6. Risks

- **Engine planner is a stub.** Lean `planOrderMoves` moves the first inversion only (Step.lean:84), and allows one move per pass. With the 3/20 budget, a badly ordered bar ends in "stopped" where today's minimal-move planner finished.
- **Membership, reveal and the full-bar fold are outside the model.** Keep them before the step, as evidence-only downgrades. They never create a move.
- **Self-positioning items and iStat:** handled only through `trusted` and `unread`. Expect `cantJudge` rows.
- **Time-based timeouts:** only downgrade text.
- **Proof takes effect one pass later (port item 2):** schedule a bounded follow-up pass when the status is `checking` on a settled chevronless complete read.
- **Free-key worst case:** time it with unread keys.

## 7. Beads, in dependency order

1. **Adapter, no wiring.** `CoreKeys`, `ReadAdapter`, the `unreadOwners` and `staleOff` supply, `setStripAllowed`, the outcome mapper. *Done:* property tests for A7 (Nodup, drawn∩pile=∅, unread∩trusted=∅), table tests per field, `swift test` passes. Reviewable offline.
2. **Lean `rowNote` export.** `rowNoteTok` with its round-trip and bad-input theorems in `check-lean-axioms`, shim, Codec, differential fixture. *Done:* `make verify-core` and `swift test` pass. Offline.
3. **Wire the order path** (needs 1). Events, dispatch, `moveResult` on every path, evidence downgrades, `passBoundary`. Gdu126/129/131/134/136/144 suites and the random adversary updated only for API, with a reason per test. *Done:* `swift test` passes; a test proves every emitted action gets exactly one `moveResult`. Offline.
4. **Rows and status** (needs 2 and 3). Renderer, D7 contexts, note texts. *Done:* the "matches" property test and the D9 class test. Offline.
5. **Delete §3.** *Done:* `swift test` passes; `scripts/check-single-decider.sh` greps for one `actuator.move(` call site and none of the removed identifiers; report the LayoutEngine lines and vars removed. Offline.

**Live checks for the orchestrator afterwards** (36-key record, 25 on bar, chevron, iStat):
1. Launch shows "Checking" until a fresh chevron; at most 3 engine drags.
2. A drawn drop gets one drag and a tick.
3. A drop right of the fold gets one strip pull-out.
4. iStat at the exceptSelfPositioning level: no iStat drag.
5. An app whose read fails gets "matches except", never a plain "matches" with a stale chevron.
6. Re-apply makes one granted move plus at most 3.
7. A3 soak: longest chevronless run on the full bar.
8. Step and row timings from the log.
9. Menu text equals Arrange text.

### Critical Files for Implementation
- /Users/ebowman/src/sommelier/Sources/SommelierCore/LayoutEngine.swift
- /Users/ebowman/src/sommelier/Sources/SommelierCore/Reconciler.swift
- /Users/ebowman/src/sommelier/Sources/SommelierCore/MenuBarScanner.swift
- /Users/ebowman/src/sommelier/Sources/SommelierCore/ArrangeModel.swift
- /Users/ebowman/src/sommelier/Sources/SommelierCore/LiveActuator.swift
