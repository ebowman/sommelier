import Sommelier.Safety

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
    a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ a.rel.target ∉ s.lastFreshPile ∧
    a.rel.target ∉ (noteRead s r).lastFreshPile ∧
    (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ a.subject ∉ s.lastFreshPile ∧
      a.subject ∉ (noteRead s r).lastFreshPile) := @noFoldedTarget
example : ∀ (s : State) (es : List Event) (a : Action), a ∈ (run s es).2 →
    ∃ pre r post, es = pre ++ .read r :: post ∧
      a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ a.rel.target ∉ (run s pre).1.lastFreshPile ∧
      a.rel.target ∉ (noteRead (run s pre).1 r).lastFreshPile ∧
      (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ a.subject ∉ (run s pre).1.lastFreshPile ∧
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
      2 ≤ (readsOf pre).length ∧ (∀ x ∈ (readsOf pre).reverse.take 2, qualifying x) ∧ qualifying r ∧
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

end Sommelier
