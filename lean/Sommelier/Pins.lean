import Sommelier.Safety
import Sommelier.Gates
import Sommelier.Honesty
import Sommelier.Truth
import Sommelier.Verified
import Sommelier.GestureProv

/-!
# Statement pins

One `example : <full statement> := @theorem` per headline theorem of `Safety.lean`.  If a theorem is weakened (a hypothesis
added, a conclusion dropped) the pin stops compiling, so a weakening cannot go unnoticed.  `scripts/check-lean-axioms.sh`
requires this file to build.  The statements here are the contract; do not edit one to make a build pass.
-/

namespace Sommelier

-- 4. one action per step
example : ∀ (s : State) (e : Event), (step s e).2.length ≤ 1 := @oneActionPerStep
example : ∀ (s : State) (e : Event), s.inFlight.isSome = true → (step s e).2 = [] := @noActionWhileInFlight

-- 3. no folded target
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 →
    a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.rel.target ∉ s.lastFreshPile) ∧
    a.rel.target ∉ (noteRead s r).lastFreshPile ∧
    (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.subject ∉ s.lastFreshPile) ∧
      a.subject ∉ (noteRead s r).lastFreshPile) := @noFoldedTarget
example : ∀ (s : State) (es : List Event) (a : Action), a ∈ (run s es).2 →
    ∃ pre r post, es = pre ++ .read r :: post ∧
      a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.rel.target ∉ (run s pre).1.lastFreshPile) ∧
      a.rel.target ∉ (noteRead (run s pre).1 r).lastFreshPile ∧
      (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.subject ∉ (run s pre).1.lastFreshPile) ∧
        a.subject ∉ (noteRead (run s pre).1 r).lastFreshPile) := @noFoldedTarget_run

-- 2. strip only for the user, and honest
example : ∀ (rec : List Key) (pre : List Event) (e : Event) (a : Action),
    a ∈ (step (run (State.init rec) pre).1 e).2 → a.strip = true → a.user = true ∧ UserPassOpen pre := @stripOnlyForUser
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    ∀ a ∈ (run (State.init rec) es).2, a.strip = false := @noStripWithoutUser
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 →
    a.strip = needsStrip s r a.subject a.rel := @strip_honest
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 →
    (a.strip = true ↔ (a.subject ∈ foldedAll s r ∨ a.subject ∈ r.nearFold ∨
      a.rel.target ∈ foldedAll s r ∨ a.rel.target ∈ r.nearFold)) := @strip_iff

-- user label
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.user = true →
    (a.subject ∈ s.foldRequest.toList ∨ a.subject ∈ s.owedKeys) ∨ (a.strip = true ∧ s.stripGrant = true) :=
  @userLabelHonest
example : ∀ (C : Nat) (s : State) (es : List Event), (∀ e ∈ es, isUserEvent e = false) → capOK C s es →
    postedEngine s es + s.moveCount ≤ max C (s.moveCount + pendEng s) := @seg_run

-- 4. one strip session per user event
example : ∀ (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event),
    isUserEvent ue = true → (∀ e ∈ ys, isUserEvent e = false) →
    stripCount (run (step (run (State.init rec) pre).1 ue).1 ys).2 ≤
      1 + unpostedStrip (step (run (State.init rec) pre).1 ue).1 ys := @oneStripSessionPerEdit

-- 5. hold release
example : ∀ (s : State) (e : Event), s.hold = true → (step s e).1.hold = false →
    isUserEvent e = true ∨ ((step s e).1.provenNotFull = true ∧ s.provenNotFull = false) := @holdRelease
example : ∀ (es : List Event) (s : State), s.hold = true → (∀ e ∈ es, isUserEvent e = false) →
    (run s es).1.hold = false →
    ∃ pre r post, es = pre ++ .read r :: post ∧
      (run s pre).1.provenNotFull = false ∧ (noteRead (run s pre).1 r).provenNotFull = true := @holdRelease_run

-- 6. proof
example : ∀ (rec : List Key) (es : List Event), (run (State.init rec) es).1.provenNotFull = true →
    ∃ pre r post, es = pre ++ .read r :: post ∧
      (run (State.init rec) pre).1.provenNotFull = false ∧
      (noteRead (run (State.init rec) pre).1 r).provenNotFull = true ∧
      2 ≤ ((readsOf pre).filter counted).length ∧ (∀ x ∈ ((readsOf pre).filter counted).reverse.take 2, qualifying x) ∧
      qualifying r ∧
      (r.kind = .pass → 3 ≤ ((readsOf pre).filter counted).length ∧
        ∀ x ∈ ((readsOf pre).filter counted).reverse.take 3, qualifying x) ∧
      ∀ r' ∈ readsOf post, r'.chevron = .absent := @proofNeedsThreeConsecutive

-- 7. owed expires
example : ∀ (rec : List Key) (pre : List Event) (e0 : Event), (e0 = .passBoundary ∨ e0 = .userRetry) →
    ∀ (ys : List Event), (∀ e ∈ ys, isUserEvent e = false) →
    (run (step (run (State.init rec) pre).1 e0).1 ys).1.owedKeys = [] ∧
    (run (step (run (State.init rec) pre).1 e0).1 ys).1.foldRequest = none := @owedExpires

-- 1. budget
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    postedEngine (State.init rec) es ≤ 20 := @budget_any
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    fullThroughout (State.init rec) es → postedEngine (State.init rec) es ≤ 3 := @budget_full
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    ((run (State.init rec) es).2.filter (fun a => !a.user)).length ≤
      postedEngine (State.init rec) es + (run (State.init rec) es).1.skipped.length +
        (if (run (State.init rec) es).1.inFlight.isSome then 1 else 0) := @engineActions_bound
example : ∀ (s : State) (es : List Event), (∀ e ∈ es, isUserEvent e = false) → postedEngine s es ≤ 20 := @budget_any_from
example : ∀ (s : State) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    fullThroughout s es → postedEngine s es ≤ 3 := @budget_full_from
example : ∀ (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event),
    isUserEvent ue = true → (∀ e ∈ ys, isUserEvent e = false) →
    postedEngine (step (run (State.init rec) pre).1 ue).1 ys ≤ 20 := @budget_between_user_events
example : ∀ (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event),
    isUserEvent ue = true → (∀ e ∈ ys, isUserEvent e = false) →
    fullThroughout (step (run (State.init rec) pre).1 ue).1 ys →
    postedEngine (step (run (State.init rec) pre).1 ue).1 ys ≤ 3 := @budget_full_between_user_events
example : ∀ (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event),
    isUserEvent ue = true → (∀ e ∈ ys, isUserEvent e = false) →
    ((run (step (run (State.init rec) pre).1 ue).1 ys).2.filter (fun a => !a.user)).length ≤
      postedEngine (step (run (State.init rec) pre).1 ue).1 ys +
      (run (step (run (State.init rec) pre).1 ue).1 ys).1.skipped.length +
      pendEng (run (step (run (State.init rec) pre).1 ue).1 ys).1 := @engineActions_between_user_events

/-! ## ejb.3: the gates gate, the user is answered, the rows and the status line are honest -/

-- the two definitions of "a user event" agree
example : ∀ e, userEv e = isUserEvent e := by intro e; cases e <;> rfl

-- 1. each gate stops the engine (every action is the user's)
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → s.hold = true → a.user = true := @eng_no_hold
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → r.stripOpen = true → a.user = true := @eng_no_open
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → r.chevron = .stale → a.user = true := @eng_no_stale
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → s.restricted = true → a.user = true := @eng_no_restricted
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → fullBar s r = true → 3 ≤ s.moveCount →
    a.user = true := @eng_no_budget_full
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → fullBar s r = false → 20 ≤ s.moveCount →
    a.user = true := @eng_no_budget_notfull
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.user = false →
    a.subject ∉ s.givenUp := @plan_no_givenUp
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.user = false →
    a.subject ∉ s.skipped := @plan_no_skipped
-- 2. any chevron means full
example : ∀ (s : State) (r : Read), r.chevron ≠ .absent → fullBar s r = true := @fullBar_ignores_chevron
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → r.chevron ≠ .absent → a.user = false →
    s.moveCount < 3 := @chevron_engine_budget
-- 3. plans only on good reads
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 →
    r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ s.inFlight = none := @plan_on_good_read
-- 4. the folded memory
example : ∀ (s : State) (r : Read), r.chevron = .fresh → r.settled = true → r.level ≠ .incomplete → r.stripOpen = false →
    (noteRead s r).lastFreshPile = r.foldedSet := @pile_replace
example : ∀ (s : State) (r : Read), r.chevron = .fresh →
    (r.settled = false ∨ r.level = .incomplete ∨ r.stripOpen = true) → ∀ (k : Key),
    k ∈ (noteRead s r).lastFreshPile ↔ k ∈ s.lastFreshPile ∨ k ∈ r.foldedSet := @pile_fresh_add
example : ∀ (s : State) (r : Read), r.chevron = .stale → ∀ (k : Key),
    k ∈ (noteRead s r).lastFreshPile ↔ k ∈ s.lastFreshPile ∨ k ∈ r.foldedSet := @pile_stale_add
example : ∀ (s : State) (r : Read), s.provenNotFull = false → (noteRead s r).provenNotFull = true →
    (noteRead s r).lastFreshPile = [] := @proof_clears_pile
example : ∀ (s : State) (r : Read), s.provenNotFull = false → (noteRead s r).provenNotFull = true →
    (noteRead s r).hold = false := @proof_clears_hold
example : ∀ (s : State) (r : Read), r.chevron = .absent →
    ¬ (s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true) →
    (noteRead s r).lastFreshPile = s.lastFreshPile := @pile_absent_keeps
-- 5. failed drags, user events
example : ∀ (s : State) (a : Action), s.provenNotFull = false →
    (result s a .failed true).hold = true ∧ (result s a .failed true).holdFolded = s.lastFreshPile := @res_failed_holds
example : ∀ (s : State) (a : Action), s.provenNotFull = false → a.subject ∈ (result s a .failed true).givenUp :=
  @res_failed_gives_up
example : ∀ (s : State) (a : Action), s.provenNotFull = true → (result s a .failed true).hold = s.hold := @res_proven_no_hold
example : ∀ (s : State) (a : Action), s.provenNotFull = true →
    (result s a .failed true).strikes = a.subject :: s.strikes := @res_proven_strike
example : ∀ (s : State) (a : Action), s.provenNotFull = true →
    (a.subject ∈ (result s a .failed true).givenUp ↔
      a.subject ∈ s.givenUp ∨ 2 ≤ (s.strikes.filter (fun x => x == a.subject)).length) := @res_proven_giveup
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] →
    ((step s (.userEdit rec moved)).1.hold = true ↔
      s.hold = true ∧ ∀ k ∈ moved, k ∉ s.holdFolded ∧ k ∉ s.lastFreshPile) := @edit_hold
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → (step s (.userEdit rec moved)).1.moveCount = 0 :=
  @edit_budget_reset
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → (step s (.userEdit rec moved)).1.restricted = true :=
  @edit_restricts
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] →
    (step s (.userEdit rec moved)).1.givenUp = s.givenUp.filter (fun k => !moved.contains k) := @edit_givenUp
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] →
    (step s (.userEdit rec moved)).1.strikes = s.strikes.filter (fun k => !moved.contains k) := @edit_strikes
example : ∀ (s : State), (step s .userRetry).1.hold = false := @retry_clears_hold
example : ∀ (s : State), (step s .userRetry).1.givenUp = [] := @retry_clears_givenUp
example : ∀ (s : State), (step s .userRetry).1.moveCount = 0 := @retry_resets_budget
example : ∀ (s : State), (step s .userRetry).1.restricted = false := @retry_unrestricts
example : ∀ (s : State), (step s .userRetry).1.stripGrant = true := @retry_grants
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.hold = false := @rk_clears_hold
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.moveCount = 0 := @rk_resets_budget
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.givenUp = s.givenUp.erase k := @rk_givenUp
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.stripGrant = s.stripGrant := @rk_no_grant
-- 6. one attempt per drop
example : ∀ (rec : List Key) (es : List Event), (run (State.init rec) es).1.owedKeys.Nodup := @owed_nodup_init
example : ∀ {s : State} {r : Read} {a : Action}, s.owedKeys.Nodup → a ∈ (step s (.read r)).2 →
    a.subject ∉ (step s (.read r)).1.owedKeys ∧ (step s (.read r)).1.foldRequest ≠ some a.subject := @emit_consumes
example : ∀ (s : State) (a : Action) (o : Outcome) (p : Bool) (j : Key),
    j ∈ (result s a o p).owedKeys ↔ j ∈ s.owedKeys ∨ (j = a.subject ∧ Rearm s a o p) := @rearm_iff
example : ∀ (s : State) (a : Action), Rearm s a .busy false ↔
    (s.flightOwed = some s.gen ∧ a.subject ∉ s.skipped ∧ a.subject ∈ s.record) := by
  intro s a; simp [Rearm]
open Classical in
example : ∀ (s : State) (a : Action) (o : Outcome) (p : Bool), (result s a o p).foldRequest =
    if Rearm s a o p ∧ s.flightReq = true ∧ s.foldRequest = none then some a.subject else s.foldRequest := @rearm_request
-- 6b. where the user's key goes
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → anchorMove s r k =
      if ((seenOf s r k).all (fun a => (wantOf s r k).contains a) &&
          (wantOf s r k).all (fun a => (seenOf s r k).contains a)) = true then none
      else match prefixFor (wantOf s r k) (anchorsOf s r k) with
        | none => none
        | some i =>
          match ((anchorsOf s r k).take i).getLast? with
          | some p => some ⟨k, .after p, needsStrip s r k (.after p), true⟩
          | none => (anchorsOf s r k).head?.map (fun t => ⟨k, .before t, needsStrip s r k (.before t), true⟩) :=
  @anchorMove_spec
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → userMove s r k =
    (match anchorMove s r k with | some a => some a | none => fallbackMove s r k) := @userMove_drawn_spec
example : ∀ {want l : List Key} {i : Nat}, prefixFor want l = some i →
    i ≤ l.length ∧ SameKeys (l.take i) want ∧ ∀ j, j < i → ¬ SameKeys (l.take j) want := @prefixFor_spec
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r →
    SameKeys (seenOf s r k) (wantOf s r k) → anchorMove s r k = none := @anchorMove_right_place
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → ¬ SameKeys (seenOf s r k) (wantOf s r k) →
    (prefixFor (wantOf s r k) (anchorsOf s r k)).isSome = true → ∃ a, userMove s r k = some a := @userMove_moves
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ movable s r → anchorMove s r k = some a →
    ¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t)) :=
  @anchorMove_target
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ movable s r → userMove s r k = some a →
    (¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t))) ∨
    (anchorMove s r k = none ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧ k ∈ s.owedKeys ∧
      misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn) := @userMove_target
example : ∀ (l : List Key) (a : Action) (t : Key), a.rel = .before t → a.subject ≠ t → t ∈ l →
    ∃ pre post, applyMove l a = pre ++ a.subject :: t :: post := @applyMove_before
example : ∀ (l : List Key) (a : Action) (t : Key), a.rel = .after t → a.subject ≠ t → t ∈ l →
    ∃ pre post, applyMove l a = pre ++ t :: a.subject :: post := @applyMove_after
-- 7. pull-out only on request or for an owed (dropped) key
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ foldedAll s r → userMove s r k = some a →
    (s.foldRequest = some k ∨ k ∈ s.owedKeys) ∧ r.chevron = .fresh ∧ applyMove r.drawn a ≠ r.drawn ∧
    ∃ p, a.rel = .after p ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      a.subject = k ∧ a.strip = true ∧ a.user = true := @userMove_folded
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (p : Key),
    (step s (.userEdit rec moved)).1.foldRequest = some p →
    (p ∈ moved ∧ p ∈ rec ∧ p ∈ s.lastFreshPile ∧ ∃ x ∈ rec.takeWhile (fun x => x != p), x ∈ s.lastDrawn) ∨
    (s.foldRequest = some p ∧ p ∉ moved ∧ p ∈ rec) := @edit_request_origin
example : ∀ (s : State) (rec moved : List Key) (q : Key), q ∈ rec → q ∈ moved → q ∈ s.lastFreshPile →
    (∃ x ∈ rec.takeWhile (fun x => x != q), x ∈ s.lastDrawn) →
    (step s (.userEdit rec moved)).1.foldRequest ≠ none := @edit_requests_pull
example : ∀ (s : State) (k p : Key), (step s (.retryKey k)).1.foldRequest = some p →
    (p = k ∧ k ∈ s.record ∧ k ∈ s.lastFreshPile ∧ ∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) ∨
    s.foldRequest = some p := @rk_request
example : ∀ (s : State) (k : Key), k ∈ s.record → k ∈ s.lastFreshPile →
    (∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) →
    (step s (.retryKey k)).1.foldRequest = some k := @rk_requests_pull
example : ∀ (s : State) (a : Action), (emit s a).flightReq = true ↔ s.foldRequest = some a.subject := @emit_flightReq
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (a : Action), s.inFlight = some a →
    a.subject ∈ moved → (step s (.userEdit rec moved)).1.flightReq = false := @edit_flightReq
example : ∀ (s : State) (rec : List Key), rec ≠ s.record → (step s (.userEdit rec [])).1.flightReq = false :=
  @edit_empty_flightReq
example : ∀ (s : State) (k : Key) (a : Action), s.inFlight = some a → a.subject = k →
    (step s (.retryKey k)).1.flightReq = false := @rk_flightReq
-- 9. subjects are in the record
example : ∀ {s : State} {r : Read} {b : Action}, planOrderMoves s r = some b →
    b.subject ∈ s.record ∧ b.rel.target ∈ s.record := @plan_spec
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (j : Key),
    j ∈ (step s (.userEdit rec moved)).1.owedKeys ↔ j ∈ rec ∧ (j ∈ s.owedKeys ∨ j ∈ moved) := @edit_owed
example : ∀ (s : State) (rec : List Key) (j : Key),
    j ∈ (step s (.userEdit rec [])).1.owedKeys ↔ j ∈ rec ∧ j ∈ s.owedKeys := @edit_empty_owed
example : ∀ (s : State) (rec moved : List Key) (p : Key), (step s (.userEdit rec moved)).1.foldRequest = some p →
    p ∈ rec := @edit_request_in_record
example : ∀ (s : State) (k j : Key), j ∈ (step s (.retryKey k)).1.owedKeys ↔ j ∈ s.record ∧ (j = k ∨ j ∈ s.owedKeys) :=
  @rk_owed
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.user = false →
    a.subject ∈ s.record ∧ a.rel.target ∈ s.record := @plan_in_record
example : ∀ (rec : List Key) (es : List Event) (a : Action), a ∈ (run (State.init rec) es).2 →
    ∃ pre r post, es = pre ++ .read r :: post ∧ a.subject ∈ (run (State.init rec) pre).1.record := @subjects_in_record
example : ∀ (s : State) (r : Read), r.kind = .pass → r.settled = true → r.level ≠ .incomplete →
    (noteRead s r).lastDrawn = r.drawn := @lastDrawn_set
example : ∀ (s : State) (r : Read), (r.kind = .poll ∨ r.settled = false ∨ r.level = .incomplete) →
    (noteRead s r).lastDrawn = s.lastDrawn := @lastDrawn_kept
-- posted engine drags decided on a full read: at most 3, no hypothesis about the other reads
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, userEv e = false) → postedFull (State.init rec) false es ≤ 3 :=
  @postedFull_init
-- 1. quiescence
example : ∀ (s : State) (es : List Event), (∀ e ∈ es, userEv e = false) →
    (20 ≤ s.moveCount ∨
      (3 ≤ s.moveCount ∧ ∀ pre r post, es = pre ++ .read r :: post → fullBar (run s pre).1 r = true) ∨
      (s.hold = true ∧ ∀ pre r post, es = pre ++ .read r :: post → ¬ Gain (run s pre).1 r)) →
    (∀ a ∈ (run s es).2, a.user = true) ∧ (Idle s → (run s es).2 = []) := @quiescence
example : ∀ (s : State) (r : Read), Gain s r ↔ (s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true) :=
  fun _ _ => Iff.rfl
example : ∀ (s : State), Idle s ↔ (s.inFlight = none ∧ s.owedKeys = [] ∧ s.foldRequest = none) := fun _ => Iff.rfl
-- 2. the user is always answered (restated: no hypothesis that merely assumes the drop is answerable)
example : ∀ (s : State) (rec : List Key) (k : Key) (r : Read),
    s.inFlight = none → (step s (.userEdit rec [k])).1.gate r = true → k ∈ rec →
    ((step s (.userEdit rec [k])).1.foldRequest.toList ++ (step s (.userEdit rec [k])).1.owedKeys).head? = some k →
    k ∈ r.drawn → k ∈ r.trusted → k ∉ foldedAll (step s (.userEdit rec [k])).1 r →
    ¬ SameKeys (seenOf (step s (.userEdit rec [k])).1 r k) (wantOf (step s (.userEdit rec [k])).1 r k) →
    (prefixFor (wantOf (step s (.userEdit rec [k])).1 r k) (anchorsOf (step s (.userEdit rec [k])).1 r k)).isSome = true →
    ∃ a, (step (step s (.userEdit rec [k])).1 (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true ∧
      userMove (step s (.userEdit rec [k])).1 r k = some a := @userAlwaysAnswered_drawn
example : ∀ (s : State) (rec : List Key) (k : Key) (r : Read),
    s.inFlight = none → s.owedKeys = [] → s.foldRequest = none → k ∈ rec →
    userMove (step s (.userEdit rec [k])).1 r k = none →
    (step (step s (.userEdit rec [k])).1 (.read r)).2 = [] := @userAlwaysAnswered_none
example : ∀ (s : State) (rec : List Key) (k : Key) (r : Read),
    s.inFlight = none → (step s (.userEdit rec [k])).1.gate r = true → k ∈ rec →
    ((step s (.userEdit rec [k])).1.foldRequest.toList ++ (step s (.userEdit rec [k])).1.owedKeys).head? = some k →
    r.chevron = .fresh → k ∈ r.foldedSet → k ∉ r.drawn →
    (∃ x ∈ movable (step s (.userEdit rec [k])).1 r, x ∈ (step s (.userEdit rec [k])).1.record.takeWhile (fun y => y != k)) →
    ∃ a, (step (step s (.userEdit rec [k])).1 (.read r)).2 = [a] ∧ a.strip = true ∧ a.user = true ∧ a.subject = k ∧
      userMove (step s (.userEdit rec [k])).1 r k = some a := @userAlwaysAnswered_pull
-- 2c. the reachable drop, the invariant, the row of an unanswered drop
example : ∀ (rec : List Key) (es : List Event), (run (State.init rec) es).1.provenNotFull = true →
    (run (State.init rec) es).1.lastFreshPile = [] := @provenNotFull_pile_empty
example : ∀ (rec0 : List Key) (es : List Event) (rec : List Key) (k : Key) (r : Read),
    (run (State.init rec0) es).1.inFlight = none →
    (step (run (State.init rec0) es).1 (.userEdit rec [k])).1.gate r = true → k ∈ rec →
    ((step (run (State.init rec0) es).1 (.userEdit rec [k])).1.foldRequest.toList ++
      (step (run (State.init rec0) es).1 (.userEdit rec [k])).1.owedKeys).head? = some k →
    k ∈ r.drawn → k ∈ r.trusted → k ∉ r.foldedSet →
    ¬ SameKeys (seenOf (step (run (State.init rec0) es).1 (.userEdit rec [k])).1 r k)
      (wantOf (step (run (State.init rec0) es).1 (.userEdit rec [k])).1 r k) →
    (prefixFor (wantOf (step (run (State.init rec0) es).1 (.userEdit rec [k])).1 r k)
      (anchorsOf (step (run (State.init rec0) es).1 (.userEdit rec [k])).1 r k)).isSome = true →
    ∃ a, (step (step (run (State.init rec0) es).1 (.userEdit rec [k])).1 (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true :=
  @drop_answered_reachable
example : ∀ {s : State} {r : Read} {k : Key}, s.inFlight = none → s.gate r = true → r.chevron = .absent → k ∈ r.foldedSet →
    userMove s r k = none ∧ rowLine s r k = (rowVerdict s.record (s.view r) k).line ∧ rowLine s r k ≠ .behind :=
  @foldedDrawn_chevronless
example : ∀ {s : State} {r : Read} {k : Key}, s.gate r = true → k ∈ movable s r → SameKeys (seenOf s r k) (wantOf s r k) →
    rowVerdict s.record (s.view r) k = .inOrder ∨
    ∃ x, x ≠ k ∧ x ∈ s.record ∧ x ∈ r.drawn ∧ x ∈ r.trusted ∧ (x ∈ s.owedKeys ∨ x ∈ foldedAll s r) := @in_place_row
example : ∀ {s : State} {r : Read} {k : Key}, s.inFlight = none → s.gate r = true → k ∈ s.owedKeys →
    (∀ a ∈ (step s (.read r)).2, a.subject ≠ k) →
    rowLine s r k = (rowVerdict s.record (s.view r) k).line ∨
    (rowLine s r k = .waiting ∧ ∃ a, userMove s r k = some a) := @unanswered_row
-- 2a. only a user's drop crosses the fold
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.subject ∈ r.foldedSet →
    a.user = true ∧ (s.foldRequest = some a.subject ∨ a.subject ∈ s.owedKeys) ∧ r.chevron = .fresh := @fold_crossed_only_by_drop
-- 2b. an owed key that gets no move has a named reason
example : ∀ (s : State) (r : Read) (k : Key), s.inFlight = none → s.gate r = true → k ∈ s.owedKeys →
    (∀ a ∈ (step s (.read r)).2, a.subject ≠ k) →
    (k ∈ movable s r ∧ misplaced s r k = false) ∨
    (k ∈ movable s r ∧ misplaced s r k = true ∧ (k ∉ s.record ∨ wholeBar s r = false ∨ NoReducingDrag s r k)) ∨
    (k ∉ foldedAll s r ∧ ¬ (k ∈ r.drawn ∧ k ∈ r.trusted)) ∨
    (k ∈ foldedAll s r ∧ ¬ (r.chevron = .fresh ∧ k ∈ r.foldedSet)) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = none) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧ ∃ p,
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn) ∨
    (∃ a, userMove s r k = some a ∧ a.strip = true ∧ s.editSessionUsed = true) ∨
    (∃ j a, j ∈ s.foldRequest.toList ++ s.owedKeys ∧ j ≠ k ∧ (step s (.read r)).2 = [a] ∧ a.subject = j ∧ a.user = true) :=
  @owed_unanswered_reason
-- 2c. a drop that gets no move says so, and "Try again" never silently does nothing; the drain
example : ∀ {s : State} {r : Read} {k : Key} {w : RowNote}, rowNote s r k = some w →
    rowLine s r k = .notWherePut ∧ owedNow s k = true ∧ s.gate r = true ∧ userMove s r k = none ∧ movingKey s r k = false ∧
    (rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn) := @rowNote_true
example : ∀ {s : State} {r : Read} {k : Key} {w : RowNote}, k ∈ s.owedKeys → rowNote s r k = some w →
    (rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn) ∧ userMove s r k = none ∧
    ((k ∈ movable s r ∧ misplaced s r k = false) ∨
    (k ∈ movable s r ∧ misplaced s r k = true ∧ (k ∉ s.record ∨ wholeBar s r = false ∨ NoReducingDrag s r k)) ∨
    (k ∉ foldedAll s r ∧ ¬ (k ∈ r.drawn ∧ k ∈ r.trusted)) ∨
    (k ∈ foldedAll s r ∧ ¬ (r.chevron = .fresh ∧ k ∈ r.foldedSet)) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = none) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧ ∃ p,
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn)) := @rowNote_reason
example : ∀ (s : State) (r : Read) (k : Key), s.inFlight = none → k ∈ s.record → s.gate r = true → rowLine s r k = .notWherePut →
    (∃ a, (step (step s (.retryKey k)).1 (.read r)).2 = [a] ∧ a.user = true) ∨
    (rowLine (step s (.retryKey k)).1 r k = .notWherePut ∧ (rowNote (step s (.retryKey k)).1 r k).isSome = true ∧
      userMove (step s (.retryKey k)).1 r k = none) := @try_again_answers
example : ∀ (s : State), s.inFlight = none → s.stripGrant = false → ∀ (es : List Event),
    (∀ e ∈ es, (∃ r, e = .read r) ∨ (∃ k o p, e = .moveResult k o p)) →
    ((run s es).2.filter (fun a => a.user)).length ≤ 2 * (s.owedKeys.length + reqExtra s) := @drops_drain
-- 2d. the fallback for a misplaced owed key (ejb.10)
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, fallbackMove s r k = some a →
    a.user = true ∧ a.subject = k ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    a.strip = needsStrip s r a.subject a.rel ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ worstCount s r k a.rel < invCount s r r.drawn ∧
    misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn ∧
    invCount s r (applyMove r.drawn a) < invCount s r r.drawn ∧
    ∀ rel ∈ fallbackCands s r k, worstCount s r k a.rel ≤ worstCount s r k rel :=
  @fallbackMove_basic
example : ∀ {s : State} {r : Read} {k : Key}, misplaced s r k = true → ∃ rel, fallbackRel s r k = some rel := @misplaced_fallbackRel
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, fallbackMove s r k = some a →
    invCount s r (applyMove r.drawn a) < invCount s r r.drawn := @fallback_reduces_inversions
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, fallbackMove s r k = some a →
    ∀ rel : Rel, rel.target ∈ movable s r → rel.target ∈ s.record → rel.target ≠ k →
      worstCount s r k a.rel ≤ worstCount s r k rel := @fallback_best
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, wholeBar s r = true → fallbackMove s r k = some a →
    ∀ rel : Rel, rel.target ∈ movable s r → rel.target ∈ s.record → rel.target ≠ k →
      invCount s r (applyMove r.drawn a) ≤ invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) := @fallback_best_whole
-- the free keys and the whole-bar condition (ejb.11)
example : ∀ (s : State) (r : Read), wholeBar s r = true ↔ freeKeys s r = [] := wholeBar_iff_free
example : ∀ (s : State) (r : Read) (u : List Key),
    (∀ x ∈ u, r.drawn.contains x = false ∧ r.pile.contains x = false ∧ r.folded.contains x = false ∧ r.unread.contains x = false) →
    wholeBar { s with record := s.record ++ u } r = wholeBar s r := wholeBar_unlisted
example : ∀ {s : State} {r : Read} {k : Key}, rowNote s r k = some .cantJudge → freeKeys s r ≠ [] := @cantJudge_free
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → misplaced s r k = false → userMove s r k = none := @right_everywhere_no_move
example : ∀ {s : State} {r : Read} {k : Key}, rowNote s r k = some .noMoveHelps →
    s.gate r = true ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ wholeBar s r = true ∧ misplaced s r k = true ∧ NoReducingDrag s r k ∧
    userPick s r = none ∧ userMove s r k = none ∧ rowLine s r k = .notWherePut := @noMoveHelps_true
example : ∀ {s : State} {r : Read} {k : Key}, rowNote s r k = some .cantJudge ↔
    (rowLine s r k = .notWherePut ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ wholeBar s r = false ∧ misplaced s r k = true ∧
      fallbackMove s r k = none ∧ decideMove s r = none) := @cantJudge_iff
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, s.gate r = true → fallbackMove s r k = some a →
    ∀ b : Bar, Possible (s.view r) b → recInv s.record (applyMove b.open_ a) < recInv s.record b.open_ := @fallback_improves_bar
example : ∀ {s : State} {r : Read} {k : Key}, rowNote s r k = some .noMoveHelps →
    ∀ b : Bar, Possible (s.view r) b → ∀ i : Nat,
      ¬ recInv s.record (ins k (b.open_.filter (fun x => x != k)) i) < recInv s.record b.open_ := @noMoveHelps_bar
example : ∀ (s : State) (r : Read), s.inFlight = none → s.gate r = true → shownVerdict (step s .userRetry).1 r = .differs →
    (∃ a, (step (step s .userRetry).1 (.read r)).2 = [a]) ∨
    (statusLine (step s .userRetry).1 r = .differs .plain ∧ decideMove (step s .userRetry).1 r = none ∧
      (step (step s .userRetry).1 (.read r)).2 = []) := @userRetry_answers
example : ∀ {s : State} {r : Read} {x : Key}, (x ∉ movable s r ∨ x ∉ s.record) → ∀ l : List Key,
    invCount s r (l.filter (fun y => y != x)) = invCount s r l := @invCount_ignores_unmovable
example : ∀ {s : State} {r : Read}, statusLine s r = .differs .plain →
    s.inFlight = none ∧ decideMove s r = none ∧ shownVerdict s r = .differs := @plain_is_no_move
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [1, 2], .read (dropRead [2, 1, 3])]).2 = [⟨1, .before 2, false, true⟩] :=
  drop_mutual_inversion.1
example : (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [3], .read (dropRead [2, 3, 4, 1])]).2 = [⟨3, .after 1, false, true⟩] :=
  drop_no_gap.2.2.1
example : ∀ (s : State), (step s .userRetry).1.hold = false := @retry_clears_hold
example : ∀ (s : State), (step s .userRetry).1.givenUp = [] := @retry_clears_givenUp
example : ∀ (s : State), (step s .userRetry).1.moveCount = 0 := @retry_resets_budget
example : ∀ (s : State), (step s .userRetry).1.restricted = false := @retry_unrestricts
example : ∀ (s : State), (step s .userRetry).1.stripGrant = true := @retry_grants
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.hold = false := @rk_clears_hold
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.moveCount = 0 := @rk_resets_budget
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.givenUp = s.givenUp.erase k := @rk_givenUp
example : ∀ (s : State) (k : Key), (step s (.retryKey k)).1.stripGrant = s.stripGrant := @rk_no_grant
-- 6. one attempt per drop
example : ∀ (rec : List Key) (es : List Event), (run (State.init rec) es).1.owedKeys.Nodup := @owed_nodup_init
example : ∀ {s : State} {r : Read} {a : Action}, s.owedKeys.Nodup → a ∈ (step s (.read r)).2 →
    a.subject ∉ (step s (.read r)).1.owedKeys ∧ (step s (.read r)).1.foldRequest ≠ some a.subject := @emit_consumes
example : ∀ (s : State) (a : Action) (o : Outcome) (p : Bool) (j : Key),
    j ∈ (result s a o p).owedKeys ↔ j ∈ s.owedKeys ∨ (j = a.subject ∧ Rearm s a o p) := @rearm_iff
example : ∀ (s : State) (a : Action), Rearm s a .busy false ↔
    (s.flightOwed = some s.gen ∧ a.subject ∉ s.skipped ∧ a.subject ∈ s.record) := by
  intro s a; simp [Rearm]
open Classical in
example : ∀ (s : State) (a : Action) (o : Outcome) (p : Bool), (result s a o p).foldRequest =
    if Rearm s a o p ∧ s.flightReq = true ∧ s.foldRequest = none then some a.subject else s.foldRequest := @rearm_request
-- 6b. where the user's key goes
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → anchorMove s r k =
      if ((seenOf s r k).all (fun a => (wantOf s r k).contains a) &&
          (wantOf s r k).all (fun a => (seenOf s r k).contains a)) = true then none
      else match prefixFor (wantOf s r k) (anchorsOf s r k) with
        | none => none
        | some i =>
          match ((anchorsOf s r k).take i).getLast? with
          | some p => some ⟨k, .after p, needsStrip s r k (.after p), true⟩
          | none => (anchorsOf s r k).head?.map (fun t => ⟨k, .before t, needsStrip s r k (.before t), true⟩) :=
  @anchorMove_spec
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → userMove s r k =
    (match anchorMove s r k with | some a => some a | none => fallbackMove s r k) := @userMove_drawn_spec
example : ∀ {want l : List Key} {i : Nat}, prefixFor want l = some i →
    i ≤ l.length ∧ SameKeys (l.take i) want ∧ ∀ j, j < i → ¬ SameKeys (l.take j) want := @prefixFor_spec
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r →
    SameKeys (seenOf s r k) (wantOf s r k) → anchorMove s r k = none := @anchorMove_right_place
example : ∀ {s : State} {r : Read} {k : Key}, k ∈ movable s r → ¬ SameKeys (seenOf s r k) (wantOf s r k) →
    (prefixFor (wantOf s r k) (anchorsOf s r k)).isSome = true → ∃ a, userMove s r k = some a := @userMove_moves
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ movable s r → anchorMove s r k = some a →
    ¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t)) :=
  @anchorMove_target
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ movable s r → userMove s r k = some a →
    (¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t))) ∨
    (anchorMove s r k = none ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧ k ∈ s.owedKeys ∧
      misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn) := @userMove_target
example : ∀ (l : List Key) (a : Action) (t : Key), a.rel = .before t → a.subject ≠ t → t ∈ l →
    ∃ pre post, applyMove l a = pre ++ a.subject :: t :: post := @applyMove_before
example : ∀ (l : List Key) (a : Action) (t : Key), a.rel = .after t → a.subject ≠ t → t ∈ l →
    ∃ pre post, applyMove l a = pre ++ t :: a.subject :: post := @applyMove_after
-- 7. pull-out only on request or for an owed (dropped) key
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, k ∈ foldedAll s r → userMove s r k = some a →
    (s.foldRequest = some k ∨ k ∈ s.owedKeys) ∧ r.chevron = .fresh ∧ applyMove r.drawn a ≠ r.drawn ∧
    ∃ p, a.rel = .after p ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      a.subject = k ∧ a.strip = true ∧ a.user = true := @userMove_folded
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (p : Key),
    (step s (.userEdit rec moved)).1.foldRequest = some p →
    (p ∈ moved ∧ p ∈ rec ∧ p ∈ s.lastFreshPile ∧ ∃ x ∈ rec.takeWhile (fun x => x != p), x ∈ s.lastDrawn) ∨
    (s.foldRequest = some p ∧ p ∉ moved ∧ p ∈ rec) := @edit_request_origin
example : ∀ (s : State) (rec moved : List Key) (q : Key), q ∈ rec → q ∈ moved → q ∈ s.lastFreshPile →
    (∃ x ∈ rec.takeWhile (fun x => x != q), x ∈ s.lastDrawn) →
    (step s (.userEdit rec moved)).1.foldRequest ≠ none := @edit_requests_pull
example : ∀ (s : State) (k p : Key), (step s (.retryKey k)).1.foldRequest = some p →
    (p = k ∧ k ∈ s.record ∧ k ∈ s.lastFreshPile ∧ ∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) ∨
    s.foldRequest = some p := @rk_request
example : ∀ (s : State) (k : Key), k ∈ s.record → k ∈ s.lastFreshPile →
    (∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) →
    (step s (.retryKey k)).1.foldRequest = some k := @rk_requests_pull
example : ∀ (s : State) (a : Action), (emit s a).flightReq = true ↔ s.foldRequest = some a.subject := @emit_flightReq
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (a : Action), s.inFlight = some a →
    a.subject ∈ moved → (step s (.userEdit rec moved)).1.flightReq = false := @edit_flightReq
example : ∀ (s : State) (rec : List Key), rec ≠ s.record → (step s (.userEdit rec [])).1.flightReq = false :=
  @edit_empty_flightReq
example : ∀ (s : State) (k : Key) (a : Action), s.inFlight = some a → a.subject = k →
    (step s (.retryKey k)).1.flightReq = false := @rk_flightReq
-- 9. subjects are in the record
example : ∀ {s : State} {r : Read} {b : Action}, planOrderMoves s r = some b →
    b.subject ∈ s.record ∧ b.rel.target ∈ s.record := @plan_spec
example : ∀ (s : State) (rec moved : List Key), moved ≠ [] → ∀ (j : Key),
    j ∈ (step s (.userEdit rec moved)).1.owedKeys ↔ j ∈ rec ∧ (j ∈ s.owedKeys ∨ j ∈ moved) := @edit_owed
example : ∀ (s : State) (rec : List Key) (j : Key),
    j ∈ (step s (.userEdit rec [])).1.owedKeys ↔ j ∈ rec ∧ j ∈ s.owedKeys := @edit_empty_owed
example : ∀ (s : State) (rec moved : List Key) (p : Key), (step s (.userEdit rec moved)).1.foldRequest = some p →
    p ∈ rec := @edit_request_in_record
example : ∀ (s : State) (k j : Key), j ∈ (step s (.retryKey k)).1.owedKeys ↔ j ∈ s.record ∧ (j = k ∨ j ∈ s.owedKeys) :=
  @rk_owed
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → a.user = false →
    a.subject ∈ s.record ∧ a.rel.target ∈ s.record := @plan_in_record
example : ∀ (rec : List Key) (es : List Event) (a : Action), a ∈ (run (State.init rec) es).2 →
    ∃ pre r post, es = pre ++ .read r :: post ∧ a.subject ∈ (run (State.init rec) pre).1.record := @subjects_in_record
example : ∀ (s : State) (r : Read), r.kind = .pass → r.settled = true → r.level ≠ .incomplete →
    (noteRead s r).lastDrawn = r.drawn := @lastDrawn_set
example : ∀ (s : State) (r : Read), (r.kind = .poll ∨ r.settled = false ∨ r.level = .incomplete) →
    (noteRead s r).lastDrawn = s.lastDrawn := @lastDrawn_kept
-- posted engine drags decided on a full read: at most 3, no hypothesis about the other reads
example : ∀ (rec : List Key) (es : List Event), (∀ e ∈ es, userEv e = false) → postedFull (State.init rec) false es ≤ 3 :=
  @postedFull_init
-- 1. quiescence
example : ∀ (s : State) (es : List Event), (∀ e ∈ es, userEv e = false) →
    (20 ≤ s.moveCount ∨
      (3 ≤ s.moveCount ∧ ∀ pre r post, es = pre ++ .read r :: post → fullBar (run s pre).1 r = true) ∨
      (s.hold = true ∧ ∀ pre r post, es = pre ++ .read r :: post → ¬ Gain (run s pre).1 r)) →
    (∀ a ∈ (run s es).2, a.user = true) ∧ (Idle s → (run s es).2 = []) := @quiescence
example : ∀ (s : State) (r : Read), Gain s r ↔ (s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true) :=
  fun _ _ => Iff.rfl
example : ∀ (s : State), Idle s ↔ (s.inFlight = none ∧ s.owedKeys = [] ∧ s.foldRequest = none) := fun _ => Iff.rfl
-- 2. the user is always answered
example : ∀ (s : State) (rec : List Key) (k : Key) (r : Read),
    s.inFlight = none → (step s (.userEdit rec [k])).1.gate r = true → k ∈ rec →
    ((step s (.userEdit rec [k])).1.foldRequest.toList ++ (step s (.userEdit rec [k])).1.owedKeys).head? = some k →
    ((k ∈ r.drawn → k ∈ r.trusted → k ∉ foldedAll (step s (.userEdit rec [k])).1 r →
      ¬ SameKeys (seenOf (step s (.userEdit rec [k])).1 r k) (wantOf (step s (.userEdit rec [k])).1 r k) →
      (prefixFor (wantOf (step s (.userEdit rec [k])).1 r k) (anchorsOf (step s (.userEdit rec [k])).1 r k)).isSome = true →
      ∃ a, (step (step s (.userEdit rec [k])).1 (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true) ∧
    (r.chevron = .fresh → k ∈ r.foldedSet → k ∉ r.drawn →
      (∃ x ∈ movable (step s (.userEdit rec [k])).1 r, x ∈ (step s (.userEdit rec [k])).1.record.takeWhile (fun y => y != k)) →
      ∃ a, (step (step s (.userEdit rec [k])).1 (.read r)).2 = [a] ∧ a.subject = k ∧ a.strip = true ∧ a.user = true)) :=
  @user_drop_answered
example : ∀ (rec : List Key) (pre : List Event) (ys : List Event), (∀ e ∈ ys, isUserEvent e = false) →
    (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).1.owedKeys = [] ∧
    (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).1.foldRequest = none ∧
    ∀ a ∈ (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).2, a.user = false := @drop_expires
example : ∀ (s : State),
    ((step s .userRetry).1.hold = false ∧ (step s .userRetry).1.givenUp = [] ∧ (step s .userRetry).1.moveCount = 0 ∧
      (step s .userRetry).1.strikes = [] ∧ (step s .userRetry).1.skipped = [] ∧ (step s .userRetry).1.restricted = false) ∧
    ∀ (rec moved : List Key), (step s (.userEdit rec moved)).1.record = rec ∧ (step s (.userEdit rec moved)).2 = [] ∧
      (moved.isEmpty = false →
        (step s (.userEdit rec moved)).1.moveCount = 0 ∧ (step s (.userEdit rec moved)).1.skipped = [] ∧
        (∀ j ∈ moved, j ∉ (step s (.userEdit rec moved)).1.givenUp ∧ j ∉ (step s (.userEdit rec moved)).1.strikes) ∧
        (∀ j ∈ moved, j ∈ rec → j ∈ (step s (.userEdit rec moved)).1.owedKeys)) := @user_can_leave
-- 5. the truth statements of Truth.lean (pass B: T6, T7, T9 proved)
example : ∀ (s s' : State) (r : Read) (a : Action), s.record.Nodup → step s (.read r) = (s', [a]) → a.user = false →
    shownVerdict s r = .differs := @no_needless_move_engine
example : ∀ (s s' : State) (r : Read) (a : Action), s.record.Nodup → step s (.read r) = (s', [a]) → a.user = true →
    a.subject ∉ foldedAll s r → ∀ b, Possible (s.view r) b → RowMisplaced (s.view r) s.record b a.subject :=
  @no_needless_move_user
example : ∀ (s s' : State) (r : Read) (a : Action), step s (.read r) = (s', [a]) →
    ∀ b, Possible (s.view r) b →
      a.rel.target ∉ b.behind ∧ (a.subject ∉ foldedAll s r → a.subject ∈ b.open_) ∧
      (a.subject ∈ foldedAll s r → a.subject ∈ r.foldedSet ∧ a.subject ∈ b.behind) := @no_folded_target_truth
example : ∀ (s s' : State) (r : Read) (a : Action), step s (.read r) = (s', [a]) → shownVerdict s r ≠ .cannotTell :=
  @no_move_on_cannotTell
-- 6. the fold request first
example : ∀ {s : State} {r : Read} {q : Key} {a : Action}, s.foldRequest = some q → r.kind = .pass → r.settled = true →
    r.level ≠ .incomplete → s.inFlight = none → s.gate r = true → userMove1 s r q = some a → userAllowed s r a = true →
    decideMove s r = some a := @request_first
-- 7. no needless drag (the planner and the user's own moves change the bar)
example : ∀ {s : State} {r : Read} {b : Action}, planOrderMoves s r = some b → s.record.Nodup → r.drawn.Nodup →
    applyMove r.drawn b ≠ r.drawn := @noNeedlessDrag_plan
example : ∀ {s : State} {r : Read} {k : Key} {a : Action}, userMove s r k = some a → r.drawn.Nodup →
    applyMove r.drawn a ≠ r.drawn := @noNeedlessDrag_user
example : ∀ {s : State} {r : Read} {a : Action}, a ∈ (step s (.read r)).2 → s.record.Nodup → r.drawn.Nodup →
    applyMove r.drawn a ≠ r.drawn := @noNeedlessDrag

-- 6. T1-T5, T8 (pass A)
example : ∀ (rec : List Key) (r : Read), rec.Nodup →
    (verdict rec r = .matches ↔ r.usable ∧ (∃ b, Possible r b) ∧ ∀ b, Possible r b → barMatches rec b) := @verdict_matches_iff
example : ∀ (rec : List Key) (r : Read), rec.Nodup →
    (verdict rec r = .differs ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → ¬ barMatches rec b) := @verdict_differs_iff
example : ∀ (rec : List Key) (r : Read) (U : List Key), rec.Nodup →
    (verdict rec r = .matchesExcept U ↔ (∃ b, Possible r b) ∧ ValidU rec r U) := @verdict_except_iff
example : ∀ (rec : List Key) (r : Read), rec.Nodup →
    (verdict rec r = .cannotTell ↔ ¬ r.usable ∨ ¬ (∃ b, Possible r b) ∨
      ((∃ b, Possible r b) ∧ ¬ AllMatch rec r ∧ ¬ AllDiffer rec r ∧ ¬ ∃ U, ValidU rec r U)) := @verdict_cannotTell_iff
example : ∀ (rec : List Key) (r : Read) (k : Key), rec.Nodup → k ∈ rec →
    (rowVerdict rec r k = .inOrder ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → RowPlaced r rec b k) := @rowVerdict_inOrder_iff
example : ∀ (rec : List Key) (r : Read) (k : Key), rec.Nodup → k ∈ rec →
    (rowVerdict rec r k = .outOfPlace ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → RowMisplaced r rec b k) :=
  @rowVerdict_outOfPlace_iff
example : ∀ (rec : List Key) (r : Read) (k : Key), rec.Nodup → k ∈ rec →
    (rowVerdict rec r k = .behindChevron ↔
      (∃ b, Possible r b) ∧ (∀ b, Possible r b → k ∈ b.behind) ∧ ¬ (∀ b, Possible r b → OutOfTurn rec b k)) :=
  @rowVerdict_behind_iff
example : ∀ (rec : List Key) (r : Read) (k : Key), rec.Nodup → k ∈ rec →
    (rowVerdict rec r k = .behindOutOfTurn ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → OutOfTurn rec b k) :=
  @rowVerdict_behindOutOfTurn_iff
example : ∀ (rec : List Key) (r : Read) (k : Key), rec.Nodup → k ∈ rec →
    (rowVerdict rec r k = .notOnBar ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → k ∉ b.open_ ∧ k ∉ b.behind) :=
  @rowVerdict_notOnBar_iff
example : ∀ (rec : List Key) (r : Read), rec.Nodup → verdict rec r = .differs →
    ∃ k ∈ rec, rowVerdict rec r k = .outOfPlace ∨ rowVerdict rec r k = .behindOutOfTurn := @differs_names_cause
example : ∀ (rec : List Key) (b b' : Bar), rec.Nodup → b.WF → barMatches rec b → b.IsFold b' → barMatches rec b' :=
  @macOS_fold_preserves
example : ∀ (s : State) (r : Read),
    shownVerdict s r = verdict s.record (s.view r) ∧
    (r.notFullProven = s.provenNotFull → shownVerdict s r = verdict s.record r) := @status_judges_view
example : ∀ (s : State) (r : Read) (a : Action), decideMove s r = some a →
    (s.view r).usable ∧ (s.view r).consistent = true := @decideMove_gated

-- ejb.17: a verified move the next read contradicts is a strike; the engine never repeats it more than three times
example : ∀ (rec : List Key) (k : Key) (es : List Event), (∀ e ∈ es, vFree e = true) → AllVerified k es →
    AtReads (StillMisplacedAtGate k) (State.init rec) es → verDrags k (State.init rec) es ≤ 3 := @verified_revert_bounded
example : ∀ (k : Key) (s : State) (es : List Event), VInv s → (∀ e ∈ es, vFree e = true) → AllVerified k es →
    AtReads (StillMisplacedAtGate k) s es → verDrags k s es ≤ 3 - strikeCount s k := @verified_revert_bounded_from
example : ∀ (s : State) (a : Action), a.user = false → (result s a .verified true).verified = some a.subject := @res_verified_marks
example : ∀ {s : State} {r : Read} {k : Key}, s.verified = some k → s.inFlight = none → s.gate r = true →
    verFailed s r k = true →
    (judge s r).strikes = k :: s.strikes ∧ (judge s r).verified = none ∧ (judge s r).hold = s.hold := @judge_contradicted_strikes
example : ∀ {s : State} {r : Read} {k : Key}, s.verified = some k → s.inFlight = none → s.gate r = true →
    verFailed s r k = true → 2 ≤ strikeCount s k → k ∈ (judge s r).givenUp := @judge_contradicted_giveup
example : ∀ {s : State} {r : Read} {k : Key}, s.verified = some k → s.inFlight = none → s.gate r = true →
    verFailed s r k = false → (judge s r).verified = none ∧ (judge s r).strikes = s.strikes ∧ (judge s r).givenUp = s.givenUp ∧
      (judge s r).hold = s.hold := @judge_confirmed_clears

-- ejb.26: any record change clears the mark; the read after an edit takes no strike; the verdict looks at the key and its anchor alone
example : ∀ (s : State) (rec moved : List Key), (step s (.userEdit rec moved)).1.verified = none := @edit_clears_verified
example : ∀ (s : State) (rec moved : List Key) (r : Read),
    (step (step s (.userEdit rec moved)).1 (.read r)).1.strikes = (step s (.userEdit rec moved)).1.strikes ∧
    (step (step s (.userEdit rec moved)).1 (.read r)).1.givenUp = (step s (.userEdit rec moved)).1.givenUp := @edit_read_no_strike
example : ∀ (s : State) (a : Action), a.user = false → ∀ (rec moved : List Key) (r : Read),
    strikeCount (step (step (result s a .verified true) (.userEdit rec moved)).1 (.read r)).1 a.subject ≤ strikeCount s a.subject ∧
    (a.subject ∈ (step (step (result s a .verified true) (.userEdit rec moved)).1 (.read r)).1.givenUp → a.subject ∈ s.givenUp) := @verified_drag_edit_read_no_strike
example : ∀ (s : State) (r r' : Read) (k y : Key) (rel : Rel), y ≠ k → y ≠ rel.target →
    (movable s r).erase y = (movable s r').erase y → revertedFromAnchor s r k rel = revertedFromAnchor s r' k rel := @crossing_move_keeps_verdict
example : ∀ {s : State} {r : Read} {k : Key}, s.verified = some k → revertedFromAnchor s r k s.verRel = false →
    (judge s r).strikes = s.strikes ∧ (judge s r).givenUp = s.givenUp := @judge_landed_no_strike

/-! ejb.20: "needs Re-apply" (an engine move withheld for the strip) -/
example : ∀ {s : State} {r : Read} {k : Key}, statusLine s r = .differs (.needsReapply k) ↔
    shownVerdict s r = .differs ∧ ∃ a, enginePlan s r = some a ∧ a.strip = true ∧ s.stripGrant = false ∧ a.subject = k := @needsReapply_iff
example : ∀ {s : State} {r : Read} {k : Key}, statusLine s r = .differs (.needsReapply k) →
    shownVerdict s r = .differs ∧ pending s r = false ∧ decideMove s r = none ∧ s.hold = false ∧ budgetSpent s r = false ∧
    withheldStrip s r = some k := @needsReapply_true
example : ∀ {s : State} {r : Read} {k : Key}, rowReapply s r k = true →
    rowLine s r k = .notWherePut ∧ statusLine s r = .differs (.needsReapply k) := @rowReapply_true
example : ∀ (s : State) (r : Read) (k : Key), statusLine (step s .userRetry).1 r ≠ .differs (.needsReapply k) := needsReapply_after_retry
example : ∀ {s : State} {r : Read} {a : Action}, enginePlan s r = some a →
    (a.strip = false → decideMove s r = some a) ∧
    (a.strip = true → s.stripGrant = true → decideMove s r = some { a with user := true }) ∧
    (a.strip = true → s.stripGrant = false → decideMove s r = none) := @enginePlan_decides

/-! ejb.32: gestures.  A drop is an input; the core computes the new layout and the keys the user moved (Gesture.lean, GestureProv.lean). -/
-- G1 same-section drop
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k = some s →
    ((moveKey unit sys L k s idx).keys s).filter (fun x => x != k) = (L.keys s).filter (fun x => x != k) := @same_order
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.Nodup → L.sectionOf k = some s → ∀ {t : Section}, t ≠ s → (moveKey unit sys L k s idx).keys t = L.keys t := @same_other
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.Nodup → L.sectionOf k = some s → (moveKey unit sys L k s idx).allKeys.Perm L.allKeys := @same_perm
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.Nodup → L.sectionOf k = some s → ∀ {x : Key}, x ≠ k → ∀ (t : Section),
    x ∈ (moveKey unit sys L k s idx).keys t ↔ x ∈ L.keys t := @same_section
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k = some s → ((moveKey unit sys L k s idx).keys s).idxOf k =
      insIdx sys ((L.keys s).filter (fun x => x != k)) s idx := @same_idx
-- G1/G2 a drop reports exactly the dropped key as moved
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} (k : Key) (s : Section) (idx : Option Nat),
    applyGesture unit sys L (.drop k s idx) = (moveKey unit sys L k s idx, [k]) := @drop_moved
-- G2 cross-section drop
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s → ∀ {x : Key}, (x = k ∨ x ∈ L.allKeys) → unit x = unit k →
    x ∈ (moveKey unit sys L k s idx).keys s := @cross_unit_in
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s → ∀ {x : Key}, x ∈ L.allKeys → unit x ≠ unit k → ∀ (t : Section),
    x ∈ (moveKey unit sys L k s idx).keys t ↔ x ∈ L.keys t := @cross_section
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s → ∀ (t : Section),
    ((moveKey unit sys L k s idx).keys t).filter (fun x => unit x != unit k) = (L.keys t).filter (fun x => unit x != unit k) := @cross_order
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s →
    ((moveKey unit sys L k s idx).keys s).filter (fun x => unit x == unit k) = groupOf unit L k := @cross_group
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s → ∀ {t : Section}, t ≠ s →
    ((moveKey unit sys L k s idx).keys t).filter (fun x => unit x == unit k) = [] := @cross_group_ne
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat},
    L.sectionOf k ≠ some s → ((moveKey unit sys L k s idx).keys s).idxOf k =
      insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx := @cross_idx
-- G3 no gesture loses or duplicates a key
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3}, L.Nodup → ∀ (g : Gesture),
    (applyGesture unit sys L g).1.Nodup := @gesture_nodup
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3}, L.Nodup → ∀ (g : Gesture) {x : Key},
    x ∈ (applyGesture unit sys L g).1.allKeys ↔ x ∈ L.allKeys ∨ x ∈ g.dropped := @gesture_mem
-- G4 hide what does not fit
example : ∀ {unit : Key → Nat} {sys : Key → Bool} {L : Layout3}, L.Nodup → UnitNormal unit L → ∀ (ks : List Key),
    (∀ x ∈ L.allKeys, (∀ k ∈ ks, unit x ≠ unit k) → ∀ t, (x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.keys t ↔ x ∈ L.keys t)) ∧
    (∀ t, ((applyGesture unit sys L (.hideNotFitting ks)).1.keys t).filter (fun x => ks.all (fun k => unit x != unit k)) =
      (L.keys t).filter (fun x => ks.all (fun k => unit x != unit k))) ∧
    (∀ x ∈ L.hidden, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.hidden) ∧
    (∀ x ∈ L.alwaysHidden, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.alwaysHidden) ∧
    (∀ x ∈ L.visible, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.visible ∨ x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.hidden) ∧
    (applyGesture unit sys L (.hideNotFitting ks)).2.Nodup ∧
    (∀ m ∈ (applyGesture unit sys L (.hideNotFitting ks)).2, m ∈ L.allKeys) := @hide_spec
-- G5 provenance: composed with step
example : ∀ (s : State) (rec moved : List Key) (es : List Event), (∀ e ∈ es, isUserEvent e = false) →
    ∀ a ∈ (run (step s (.userEdit rec moved)).1 es).2, a.user = true →
      a.subject ∈ moved ∨ a.subject ∈ s.owedKeys ∨ s.foldRequest = some a.subject ∨ (∃ f, s.inFlight = some f ∧ f.subject = a.subject) ∨
      (a.strip = true ∧ s.stripGrant = true) := @userEdit_provenance
example : ∀ (unit : Key → Nat) (sys mov : Key → Bool) (s : State) (L : Layout3) (g : Gesture) (es : List Event),
    (∀ e ∈ es, isUserEvent e = false) →
    ∀ a ∈ (run (step s (.userEdit (coreRecord mov (applyGesture unit sys L g).1) (applyGesture unit sys L g).2)).1 es).2, a.user = true →
      a.subject ∈ (applyGesture unit sys L g).2 ∨ a.subject ∈ s.owedKeys ∨ s.foldRequest = some a.subject ∨
      (∃ f, s.inFlight = some f ∧ f.subject = a.subject) ∨ (a.strip = true ∧ s.stripGrant = true) := @gesture_provenance
example : ∀ (unit : Key → Nat) (sys mov : Key → Bool) (s : State) (L : Layout3) (k : Key) (t : Section) (idx : Option Nat) (es : List Event),
    (∀ e ∈ es, isUserEvent e = false) → s.owedKeys = [] → s.foldRequest = none → s.inFlight = none → s.stripGrant = false →
    ∀ a ∈ (run (step s (.userEdit (coreRecord mov (moveKey unit sys L k t idx)) [k])).1 es).2, a.user = true → a.subject = k := by
  intro unit sys mov s L k t idx es hes h1 h2 h3 h4
  exact drop_provenance_idle unit sys mov s L k t idx es hes h1 h2 h3 h4

end Sommelier
