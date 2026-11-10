import Sommelier.Eqns

/-!
# Sommelier decision core: safety theorems over ALL event lists

Everything here quantifies over every `Event` list (macOS is an adversary: a read means nothing).
Method: per-step lemmas about `step` by case analysis on `Event`, invariants (`Inv`, `NU`) proved
preserved by `step`, then lifted to `run` by induction on the event list.  Core tactics only (`simp`, `grind`).
The seven theorems are listed in `scripts/check-lean-axioms.sh`, which rejects anything beyond
`propext`, `Classical.choice`, `Quot.sound`.  See docs/verified-core.md.
-/

set_option linter.unusedSimpArgs false

namespace Sommelier

/-! ### Helper facts about `noteRead`, `movable`, the planners -/


theorem noteRead_frame (s : State) (r : Read) :
    (noteRead s r).record = s.record ∧ (noteRead s r).moveCount = s.moveCount ∧
    (noteRead s r).owedKeys = s.owedKeys ∧ (noteRead s r).foldRequest = s.foldRequest ∧
    (noteRead s r).stripGrant = s.stripGrant ∧ (noteRead s r).restricted = s.restricted ∧
    (noteRead s r).editSessionUsed = s.editSessionUsed ∧ (noteRead s r).skipped = s.skipped ∧
    (noteRead s r).gen = s.gen ∧ (noteRead s r).flightOwed = s.flightOwed ∧
    (noteRead s r).flightReq = s.flightReq ∧ (noteRead s r).inFlight = s.inFlight ∧
    (noteRead s r).givenUp = s.givenUp ∧ (noteRead s r).holdFolded = s.holdFolded := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> (unfold noteRead; grind)

theorem noteRead_pile (s : State) (r : Read) (k : Key)
    (h : k ∈ (noteRead s r).lastFreshPile) : k ∈ s.lastFreshPile ∨ k ∈ r.foldedSet := by
  unfold noteRead at h
  grind

/-- A usable fresh-chevron read replaces the pile by its own folded set. -/
theorem noteRead_pile_usable (s : State) (r : Read) (h : r.usable ∧ r.chevron = .fresh) :
    (noteRead s r).lastFreshPile = r.foldedSet := by
  obtain ⟨⟨_, h2, h3, _, h5, _⟩, h6⟩ := h
  unfold noteRead
  grind

theorem noteRead_hold (s : State) (r : Read) (h1 : s.hold = true) (h2 : (noteRead s r).hold = false) :
    s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true := by
  unfold noteRead at *
  grind


theorem firstInversion_mem : ∀ (l1 l2 : List Key) (w h : Key), firstInversion l1 l2 = some (w, h) → w ∈ l1 ∧ h ∈ l2
  | w :: ws, h :: hs, a, b, hh => by
    unfold firstInversion at hh
    by_cases e : (w == h) = true
    · simp only [e, ite_true] at hh
      have := firstInversion_mem ws hs a b hh
      simp [this]
    · simp only [e] at hh
      simp at hh
      simp [hh]
  | [], _, _, _, hh => by simp [firstInversion] at hh
  | _ :: _, [], _, _, hh => by simp [firstInversion] at hh

theorem movable_not_folded {s : State} {r : Read} {k : Key} (h : k ∈ movable s r) :
    k ∉ foldedAll s r := by
  unfold movable at h
  simp [List.mem_filter] at h
  simpa using h.2.2

theorem movable_mem_drawn {s : State} {r : Read} {k : Key} (h : k ∈ movable s r) : k ∈ r.drawn := by
  unfold movable at h; exact (List.mem_filter.1 h).1

theorem planOrderMoves_spec {s : State} {r : Read} {a : Action} (h : planOrderMoves s r = some a) :
    a.user = false ∧ a.subject ∈ movable s r ∧ a.rel.target ∈ movable s r ∧
    s.skipped.contains a.subject = false ∧ s.givenUp.contains a.subject = false := by
  simp only [planOrderMoves] at h
  split at h
  · rename_i w hh hmatch
    split at h
    · simp at h
    · rename_i hn
      have := firstInversion_mem _ _ _ _ hmatch
      simp at h
      subst h
      simp at hn
      simp [List.mem_filter] at this
      simp [Rel.target] at *
      grind
  · simp at h

theorem userMove_spec {s : State} {r : Read} {k : Key} {a : Action} (h : userMove s r k = some a) :
    a.user = true ∧ a.subject = k ∧ a.rel.target ∈ movable s r := by
  simp only [userMove] at h
  split at h
  · split at h
    · cases hg : List.getLast? (List.filter (fun x => (List.takeWhile (fun x => x != k) s.record).contains x) (movable s r)) with
      | none => simp only [hg, Option.map, Option.filter] at h; cases h
      | some p =>
        have hp := List.mem_of_getLast? hg
        simp only [hg, Option.map, Option.filter] at h
        split at h
        · simp at h; subst h; simp [Rel.target]; exact (List.mem_filter.1 hp).1
        · simp at h
    · simp at h
  · split at h
    · split at h
      · rename_i a' ha'
        simp only [Option.some.injEq] at h; subst h
        have := anchorMove_basic ha'
        exact ⟨this.1, this.2.1, this.2.2.1⟩
      · have := fallbackMove_basic h
        exact ⟨this.1, this.2.1, this.2.2.1⟩
    · simp at h

theorem decideMove_spec {s : State} {r : Read} {a : Action} (h : decideMove s r = some a) :
    s.inFlight = none ∧
    ((∃ k, (k ∈ s.foldRequest.toList ∨ k ∈ s.owedKeys) ∧ userMove s r k = some a ∧ userAllowed s r a = true) ∨
     (engineAllowed s r = true ∧ ∃ b, planOrderMoves s r = some b ∧
        ((b.strip = false ∧ a = b) ∨ (b.strip = true ∧ s.stripGrant = true ∧ a = { b with user := true })))) := by
  replace h := decide_judge h
  simp only [decideMove0] at h
  split at h
  · simp at h
  · rename_i hc
    refine ⟨?_, ?_⟩
    · cases hi : s.inFlight with
      | none => rfl
      | some x => simp [hi] at hc
    · split at h
      · rename_i b hb
        obtain ⟨k, hk, hk2⟩ := userPick_exists hb
        simp at h; subst h
        left
        refine ⟨k, ?_, ?_⟩
        · simpa using hk
        · cases hu : userMove s r k with
          | none => simp [hu] at hk2
          | some u => simp [hu, Option.filter] at hk2; grind
      · split at h
        · simp at h
        · rename_i hea
          right
          split at h
          · rename_i b hb
            split at h
            · rename_i hs
              split at h
              · simp at h; subst h
                exact ⟨by simpa using hea, b, hb, Or.inr ⟨hs, by simpa using ‹s.stripGrant = true›, rfl⟩⟩
              · simp at h
            · rename_i hs
              simp at h; subst h
              exact ⟨by simpa using hea, b, hb, Or.inl ⟨by simpa using hs, rfl⟩⟩
          · simp at h



/-! ### Definitions used by the statements -/

/-- A user event: a non-empty `userEdit`, `userRetry`, `retryKey` (an edit that moved nothing is not one). -/
def isUserEvent : Event → Bool
  | .userEdit _ m => !m.isEmpty
  | .userRetry | .retryKey _ => true
  | _ => false

/-- 1 iff this event is the result of a POSTED drag of the engine (not the user) that is in flight. -/
def postedStep (s : State) (e : Event) : Nat :=
  match e, s.inFlight with
  | .moveResult k _ true, some a => if a.subject == k && !a.user then 1 else 0
  | _, _ => 0

/-- Engine drags actually posted while running `es` from `s`. -/
def postedEngine (s : State) : List Event → Nat
  | [] => 0
  | e :: es => postedStep s e + postedEngine (step s e).1 es

/-- `fullBar s_i r` holds at every read of the run. -/
def fullThroughout (s : State) : List Event → Prop
  | [] => True
  | e :: es => (match e with | .read r => fullBar s r = true | _ => True) ∧ fullThroughout (step s e).1 es

/-- The reads of an event list, in order. -/
def readsOf : List Event → List Read
  | [] => []
  | .read r :: es => r :: readsOf es
  | _ :: es => readsOf es

/-- A read that counts toward the proof that the bar is not full. -/
def qualifying (r : Read) : Prop := r.chevron = .absent ∧ r.level ≠ .incomplete

/-- ONLY a complete, chevronless, observed, unsettled pass read is skipped: it neither counts toward the proof nor resets the count
(Swift: it ends the pass before `noteChevronEvidence`, and `observeOnce` resets only on a chevron or an `incomplete` level, :2259-2263).
Every other read stays in the history of Theorem 6, so an unsettled read with a chevron or an `incomplete` one is in the sequence as what
it is: a read that resets. -/
def counted (r : Read) : Bool :=
  !(r.kind == .pass && !r.settled && r.chevron == .absent && r.level != .incomplete && r.observed)

/-- The counted reads of one event. -/
def cnt (r : Read) : List Read := if counted r then [r] else []

/-! ### run -/

theorem run_cons (s : State) (e : Event) (es : List Event) :
    run s (e :: es) = ((run (step s e).1 es).1, (step s e).2 ++ (run (step s e).1 es).2) := by
  simp [run]

theorem run_nil (s : State) : run s [] = (s, []) := rfl

theorem run_append (s : State) (xs ys : List Event) :
    run s (xs ++ ys) = ((run (run s xs).1 ys).1, (run s xs).2 ++ (run (run s xs).1 ys).2) := by
  induction xs generalizing s with
  | nil => simp [run_nil]
  | cons e xs ih => simp [run_cons, ih]

/-- Every action of a run comes from a read step at some split point. -/
theorem run_action_split (s : State) (es : List Event) (a : Action) (h : a ∈ (run s es).2) :
    ∃ pre e post, es = pre ++ e :: post ∧ a ∈ (step (run s pre).1 e).2 := by
  induction es generalizing s with
  | nil => simp [run_nil] at h
  | cons e es ih =>
    rw [run_cons] at h
    simp only [List.mem_append] at h
    rcases h with h | h
    · exact ⟨[], e, es, rfl, by simpa [run_nil] using h⟩
    · obtain ⟨pre, e', post, h1, h2⟩ := ih _ h
      exact ⟨e :: pre, e', post, by simp [h1], by simpa [run_cons] using h2⟩

/-! ### Per-step facts -/

theorem step_read (s : State) (r : Read) :
    step s (.read r) = match decideMove s r with
      | none => (noteRead (judge s r) r, [])
      | some a => (emit (noteRead (judge s r) r) a, [a]) := rfl

theorem step_acts {s : State} {e : Event} {a : Action} (h : a ∈ (step s e).2) :
    ∃ r, e = .read r ∧ decideMove s r = some a ∧ step s e = (emit (noteRead (judge s r) r) a, [a]) := by
  cases e with
  | read r =>
    refine ⟨r, rfl, ?_⟩
    rw [step_read] at h ⊢
    cases hd : decideMove s r with
    | none => simp [hd] at h
    | some b => simp [hd] at h; subst h; simp
  | userEdit rec moved => simp only [step] at h; split at h <;> simp at h
  | userRetry => simp [step] at h
  | retryKey k => simp [step] at h
  | moveResult k o p =>
    simp only [step] at h
    split at h
    · split at h <;> simp at h
    · simp at h
  | passBoundary => simp [step] at h

/-- Theorem 4 (first half): at most one drag per event, and none while a drag is in flight. -/
theorem oneActionPerStep (s : State) (e : Event) : (step s e).2.length ≤ 1 := by
  cases hh : (step s e).2 with
  | nil => simp
  | cons a t =>
    obtain ⟨r, _, _, h⟩ := step_acts (s := s) (e := e) (a := a) (by simp [hh])
    rw [h] at hh; simp at hh; simp [← hh]

theorem noActionWhileInFlight (s : State) (e : Event) (h : s.inFlight.isSome = true) : (step s e).2 = [] := by
  cases hh : (step s e).2 with
  | nil => rfl
  | cons a t =>
    obtain ⟨r, _, hd, _⟩ := step_acts (s := s) (e := e) (a := a) (by simp [hh])
    have := (decideMove_spec hd).1
    simp [this] at h

theorem decide_target {s : State} {r : Read} {a : Action} (h : decideMove s r = some a) :
    a.rel.target ∈ movable s r ∧ (a.user = false → a.subject ∈ movable s r) := by
  rcases (decideMove_spec h).2 with ⟨k, _, hk, _⟩ | ⟨_, b, hb, hh⟩
  · have := userMove_spec hk
    exact ⟨this.2.2, fun hu => by simp [this.1] at hu⟩
  · have := planOrderMoves_spec hb
    rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
    · exact ⟨this.2.2.1, fun _ => this.2.1⟩
    · exact ⟨this.2.2.1, fun hu => by simp at hu⟩

/-- Theorem 3 (noFoldedTarget), one read: no move's target is in the read's pile or folded set, or in the
last fresh pile before or after the read; and no ENGINE move's subject is in any of them. -/
theorem noFoldedTarget {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) :
    a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.rel.target ∉ s.lastFreshPile) ∧
    a.rel.target ∉ (noteRead s r).lastFreshPile ∧
    (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.subject ∉ s.lastFreshPile) ∧
      a.subject ∉ (noteRead s r).lastFreshPile) := by
  obtain ⟨r', he, hd, _⟩ := step_acts h
  cases he
  have ⟨ht, hs⟩ := decide_target hd
  have fh : ∀ x, x ∉ foldedAll s r → x ∉ r.pile ∧ x ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → x ∉ s.lastFreshPile) ∧
      x ∉ (noteRead s r).lastFreshPile := by
    intro x hx
    rw [mem_foldedAll] at hx
    simp only [Read.foldedSet, List.mem_append, not_or] at hx
    refine ⟨hx.1.1, hx.1.2, fun hn m => hx.2 ⟨hn, m⟩, fun hm => ?_⟩
    by_cases hn : r.usable ∧ r.chevron = .fresh
    · rw [noteRead_pile_usable s r hn] at hm
      simp only [Read.foldedSet, List.mem_append] at hm
      grind
    · rcases noteRead_pile _ _ _ hm with hm | hm
      · exact hx.2 ⟨hn, hm⟩
      · simp only [Read.foldedSet, List.mem_append] at hm
        grind
  have g1 := fh _ (movable_not_folded ht)
  refine ⟨g1.1, g1.2.1, g1.2.2.1, g1.2.2.2, fun hu => ?_⟩
  have g2 := fh _ (movable_not_folded (hs hu))
  exact g2

/-- Theorem 5 (holdRelease), one step: a set hold stays set unless the event is a user event or the step gains the proof. -/
theorem holdRelease (s : State) (e : Event) (h1 : s.hold = true) (h2 : (step s e).1.hold = false) :
    isUserEvent e = true ∨ ((step s e).1.provenNotFull = true ∧ s.provenNotFull = false) := by
  cases e with
  | read r =>
    right
    have jh : (judge s r).hold = true := by
      obtain ⟨_, _, _, _, _, hj, h1', _⟩ := judge_shape s r; rw [hj]; exact h1' h1
    have := noteRead_hold (judge s r) r jh (by
      rw [step_read] at h2
      cases hd : decideMove s r <;> simp [hd, emit] at h2 <;> exact h2)
    simp only [judge_frame_provenNotFull, noteRead_judge_provenNotFull] at this
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp [hd]; exact ⟨this.2, this.1⟩
    | some a => simp [hd, emit]; exact ⟨this.2, this.1⟩
  | userEdit rec moved =>
    left
    by_cases hm : moved.isEmpty = true
    · simp [step, hm, h1] at h2
    · simp [isUserEvent, hm]
  | userRetry => left; rfl
  | retryKey k => left; rfl
  | moveResult k o p =>
    exfalso
    simp only [step] at h2
    split at h2
    · rename_i a ha
      split at h2
      · simp [result, markFail, markStrike] at h2
        split at h2 <;> (try split at h2) <;> (try split at h2) <;> simp_all
      · simp_all
    · simp_all
  | passBoundary => simp [step] at h2; simp_all


/-! ### The result of a drag -/

theorem result_spec (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).record = s.record ∧ (result s a o p).restricted = s.restricted ∧
    (result s a o p).stripGrant = s.stripGrant ∧ (result s a o p).gen = s.gen ∧
    (result s a o p).flightOwed = s.flightOwed ∧ (result s a o p).inFlight = none ∧
    (result s a o p).moveCount = s.moveCount + (if p = true ∧ a.user = false then 1 else 0) ∧
    (p = true → (result s a o p).editSessionUsed = s.editSessionUsed ∧ (result s a o p).skipped = s.skipped) ∧
    (p = false → a.strip = true → (result s a o p).editSessionUsed = false) ∧
    (p = false → a.strip = false → (result s a o p).editSessionUsed = s.editSessionUsed) ∧
    (p = false → a.subject ∈ s.skipped → (result s a o p).skipped = s.skipped) ∧
    (p = false → a.subject ∉ s.skipped → (result s a o p).skipped = a.subject :: s.skipped) ∧
    (s.flightOwed ≠ some s.gen → (result s a o p).owedKeys = s.owedKeys ∧ (result s a o p).foldRequest = s.foldRequest) ∧
    (p = true → (result s a o p).owedKeys = s.owedKeys ∧ (result s a o p).foldRequest = s.foldRequest) := by
  unfold result markFail markStrike
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind


/-! ### The invariant `Inv` (with a ghost bit `g` = "a user pass is open") -/

/-- Ghost: becomes true at a user event, false at `passBoundary`. -/
def passOpen (g : Bool) : Event → Bool
  | .passBoundary => false
  | e => isUserEvent e || g

structure Inv (s : State) (g : Bool) : Prop where
  owed_r : s.owedKeys ≠ [] → s.restricted = true
  req_r : s.foldRequest.isSome = true → s.restricted = true
  fo_r : s.flightOwed = some s.gen → s.restricted = true
  fo_gen : ∀ n, s.flightOwed = some n → n ≤ s.gen
  grant_g : s.stripGrant = true → g = true
  restr_g : s.restricted = true → g = true
  grant_used : s.stripGrant = true → s.restricted = false → s.editSessionUsed = false

theorem Inv.init (rec : List Key) : Inv (State.init rec) false := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [State.init]

theorem inv_read {s : State} {g : Bool} (h : Inv s g) (r : Read) : Inv (step s (.read r)).1 g := by
  have nf := noteRead_frame (judge s r) r
  have jf := judge_frame s r
  rw [step_read]
  cases hd : decideMove s r with
  | none =>
    simp only
    obtain ⟨h1, h2, h3, h4, h5, h6, h7⟩ := h
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind
  | some a =>
    simp only [emit]
    obtain ⟨h1, h2, h3, h4, h5, h6, h7⟩ := h
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind [List.erase_subset]


theorem inv_step {s : State} {g : Bool} (h : Inv s g) (e : Event) : Inv (step s e).1 (passOpen g e) := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7⟩ := h
  cases e with
  | read r => exact (by simpa [passOpen, isUserEvent] using inv_read ⟨h1, h2, h3, h4, h5, h6, h7⟩ r)
  | userEdit rec moved =>
    by_cases hm : moved.isEmpty = true
    · simp only [step, hm]
      simp only [passOpen, isUserEvent, hm]
      have hf : ∀ (p : Key → Bool), (s.foldRequest.filter p).isSome = true → s.foldRequest.isSome = true := by
        intro p; cases s.foldRequest <;> simp [Option.filter]
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
      · intro hh
        apply h1
        intro hn
        simp [hn] at hh
      · intro hh; exact h2 (hf _ hh)
      all_goals simp <;> grind
    · simp only [step, hm]
      simp only [passOpen, isUserEvent, hm]
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp <;> grind
  | userRetry =>
    simp only [step, passOpen, isUserEvent]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp <;> grind
  | retryKey k =>
    simp only [step, passOpen, isUserEvent]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp <;> grind
  | moveResult k o p =>
    simp only [step, passOpen, isUserEvent]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind
      · simp; exact ⟨h1, h2, h3, h4, h5, h6, h7⟩
    · simp; exact ⟨h1, h2, h3, h4, h5, h6, h7⟩
  | passBoundary =>
    simp only [step, passOpen]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp <;> grind


theorem inv_run {s : State} {g : Bool} (h : Inv s g) (es : List Event) :
    Inv (run s es).1 (es.foldl passOpen g) := by
  induction es generalizing s g with
  | nil => simpa [run_nil] using h
  | cons e es ih => simpa [run_cons] using ih (inv_step h e)

/-! ### Theorem 2: the strip is opened only for the user -/

def isBoundary : Event → Bool
  | .passBoundary => true
  | _ => false

/-- Some user event lies in `pre` with no `passBoundary` after it: the user's pass (or its chain) is open. -/
def UserPassOpen (pre : List Event) : Prop :=
  ∃ before ue after, pre = before ++ ue :: after ∧ isUserEvent ue = true ∧ ∀ x ∈ after, isBoundary x = false

theorem open_of_foldl : ∀ (pre : List Event) (g : Bool), pre.foldl passOpen g = true →
    (g = true ∧ ∀ x ∈ pre, isBoundary x = false) ∨ UserPassOpen pre
  | [], g, h => by simp at h; simp [h]
  | e :: es, g, h => by
    simp only [List.foldl] at h
    rcases open_of_foldl es _ h with ⟨h1, h2⟩ | ⟨b, ue, af, h1, h2, h3⟩
    · cases e with
      | passBoundary => simp [passOpen] at h1
      | userEdit r m =>
        by_cases hm : isUserEvent (.userEdit r m) = true
        · right; exact ⟨[], .userEdit r m, es, rfl, hm, h2⟩
        · left; refine ⟨?_, ?_⟩
          · simpa [passOpen, hm] using h1
          · intro x hx; simp at hx; rcases hx with rfl | hx
            · rfl
            · exact h2 x hx
      | read r =>
        left; refine ⟨by simpa [passOpen, isUserEvent] using h1, ?_⟩
        intro x hx; simp at hx; rcases hx with rfl | hx
        · rfl
        · exact h2 x hx
      | moveResult k o p =>
        left; refine ⟨by simpa [passOpen, isUserEvent] using h1, ?_⟩
        intro x hx; simp at hx; rcases hx with rfl | hx
        · rfl
        · exact h2 x hx
      | userRetry => right; exact ⟨[], .userRetry, es, rfl, rfl, h2⟩
      | retryKey k => right; exact ⟨[], .retryKey k, es, rfl, rfl, h2⟩
    · right; exact ⟨e :: b, ue, af, by simp [h1], h2, h3⟩

theorem inv_strip_user {s : State} {g : Bool} (h : Inv s g) {e : Event} {a : Action}
    (ha : a ∈ (step s e).2) (hs : a.strip = true) : a.user = true ∧ g = true := by
  obtain ⟨r, _, hd, _⟩ := step_acts ha
  rcases (decideMove_spec hd).2 with ⟨k, hk, hu, _⟩ | ⟨_, b, hb, hh⟩
  · refine ⟨(userMove_spec hu).1, ?_⟩
    rcases hk with hk | hk
    · apply h.restr_g; apply h.req_r
      cases hq : s.foldRequest <;> simp_all
    · apply h.restr_g; apply h.owed_r; intro hn; simp [hn] at hk
  · rcases hh with ⟨hb1, rfl⟩ | ⟨_, hg, rfl⟩
    · simp [hb1] at hs
    · exact ⟨rfl, h.grant_g hg⟩

/-- Theorem 2 (stripOnlyForUser): an action that allows the « strip is the user's own (or a Re-apply grant, also
`user := true`), and it leaves only while some user event has no `passBoundary` after it.
`pre` is the event prefix before the step, so "step i" is `pre.length`. -/
theorem stripOnlyForUser (rec : List Key) (pre : List Event) (e : Event) (a : Action)
    (ha : a ∈ (step (run (State.init rec) pre).1 e).2) (hs : a.strip = true) :
    a.user = true ∧ UserPassOpen pre := by
  have hi := inv_run (Inv.init rec) pre
  obtain ⟨hu, hg⟩ := inv_strip_user hi ha hs
  refine ⟨hu, ?_⟩
  rcases open_of_foldl pre false hg with ⟨h1, _⟩ | h
  · simp at h1
  · exact h

/-- Theorem 2, whole run: with no user event in `es`, no action allows the strip. -/
theorem noStripWithoutUser (rec : List Key) (es : List Event) (hno : ∀ e ∈ es, isUserEvent e = false) :
    ∀ a ∈ (run (State.init rec) es).2, a.strip = false := by
  intro a ha
  cases hs : a.strip with
  | false => rfl
  | true =>
  exfalso
  obtain ⟨pre, e, post, he, hm⟩ := run_action_split _ _ a ha
  obtain ⟨_, before, ue, after, hp, hue, _⟩ := stripOnlyForUser rec pre e a hm hs
  have : ue ∈ es := by rw [he, hp]; simp
  simp [hno ue this] at hue


/-! ### Theorem 4 (second half): one strip session per user event -/

def stripCount (acts : List Action) : Nat := (acts.filter (fun a => a.strip)).length

/-- 1 iff this event answers the in-flight STRIP drag with "no mouse event was posted" (the session is returned). -/
def unpostedStripStep (s : State) (e : Event) : Nat :=
  match e, s.inFlight with
  | .moveResult k _ false, some a => if a.subject == k && a.strip then 1 else 0
  | _, _ => 0

def unpostedStrip (s : State) : List Event → Nat
  | [] => 0
  | e :: es => unpostedStripStep s e + unpostedStrip (step s e).1 es

def sess (s : State) : Nat := if s.editSessionUsed then 1 else 0

theorem strip_needs_session {s : State} {g : Bool} (h : Inv s g) {r : Read} {a : Action}
    (hd : decideMove s r = some a) (hs : a.strip = true) : s.editSessionUsed = false := by
  rcases (decideMove_spec hd).2 with ⟨k, hk, hu, hal⟩ | ⟨hea, b, hb, hh⟩
  · simp [userAllowed, hs] at hal
    exact hal.1
  · rcases hh with ⟨hb1, rfl⟩ | ⟨_, hg, rfl⟩
    · simp [hb1] at hs
    · simp [engineAllowed] at hea
      exact h.grant_used hg hea.1.1.1.1

theorem session_step {s : State} {g : Bool} (h : Inv s g) {e : Event} (hn : isUserEvent e = false) :
    stripCount (step s e).2 + sess s ≤ unpostedStripStep s e + sess (step s e).1 := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp [stripCount, sess, unpostedStripStep, nf.2.2.2.2.2.2.1]
    | some a =>
      cases hs : a.strip with
      | false => simp [stripCount, sess, unpostedStripStep, emit, hs, nf.2.2.2.2.2.2.1]
      | true =>
        have := strip_needs_session h hd hs
        simp [stripCount, sess, unpostedStripStep, emit, hs, nf.2.2.2.2.2.2.1, this]
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, stripCount, sess, unpostedStripStep]
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step, stripCount, unpostedStripStep]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        rename_i hk
        have hk' : a.subject = k := by simpa using hk
        cases p <;> cases hs : a.strip <;> simp [sess, hs, hk'] <;> grind
      · simp
    · simp
  | passBoundary =>
    simp only [step, stripCount, sess, unpostedStripStep]
    grind

theorem session_run {s : State} {g : Bool} (h : Inv s g) (es : List Event)
    (hn : ∀ e ∈ es, isUserEvent e = false) :
    stripCount (run s es).2 + sess s ≤ unpostedStrip s es + sess (run s es).1 := by
  induction es generalizing s g with
  | nil => simp [run_nil, unpostedStrip, stripCount]
  | cons e es ih =>
    have h1 := session_step h (hn e (by simp))
    have h2 := ih (inv_step h e) (fun x hx => hn x (by simp [hx]))
    have : stripCount (run s (e :: es)).2 = stripCount (step s e).2 + stripCount (run (step s e).1 es).2 := by
      simp [run_cons, stripCount, List.filter_append]
    simp only [unpostedStrip, this]
    simp only [run_cons]
    omega

theorem session_reset {s : State} {e : Event} (hu : isUserEvent e = true) : (step s e).1.editSessionUsed = false := by
  cases e with
  | userEdit rec moved =>
    have : moved.isEmpty = false := by simpa [isUserEvent] using hu
    simp [step, this]
  | userRetry => simp [step]
  | retryKey k => simp [step]
  | _ => simp [isUserEvent] at hu

/-- Theorem 4 (second half), one strip session per user event: between a user event and the next, the strip
actions emitted number at most one more than the strip drags answered "no mouse event" (those return the session).
`pre` is any history, `ue` a user event, `ys` the events up to the next user event. -/
theorem oneStripSessionPerEdit (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event)
    (hue : isUserEvent ue = true) (hys : ∀ e ∈ ys, isUserEvent e = false) :
    stripCount (run (step (run (State.init rec) pre).1 ue).1 ys).2 ≤
      1 + unpostedStrip (step (run (State.init rec) pre).1 ue).1 ys := by
  have hi := inv_step (inv_run (Inv.init rec) pre) ue
  have := session_run hi ys hys
  have h0 := session_reset (s := (run (State.init rec) pre).1) hue
  simp only [sess, h0] at this
  have : sess (run (step (run (State.init rec) pre).1 ue).1 ys).1 ≤ 1 := by unfold sess; split <;> omega
  simp only [sess] at *
  omega


/-! ### Theorem 7: owed attempts expire -/

/-- Nothing owed, no fold request, and no drag in flight that the CURRENT chain owed (so a late `busy` cannot re-arm). -/
structure Expired (s : State) : Prop where
  owed : s.owedKeys = []
  req : s.foldRequest = none
  fo : s.flightOwed ≠ some s.gen

theorem expired_step {s : State} {g : Bool} (h : Inv s g) (hx : Expired s) {e : Event}
    (hn : isUserEvent e = false) : Expired (step s e).1 := by
  obtain ⟨hx1, hx2, hx3⟩ := hx
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp only; refine ⟨?_, ?_, ?_⟩ <;> grind
    | some a =>
      rcases (decideMove_spec hd).2 with ⟨k, hk, _⟩ | ⟨_⟩
      · simp [hx1, hx2] at hk
      · simp only [emit]
        refine ⟨?_, ?_, ?_⟩ <;> grind
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm]
    refine ⟨?_, ?_, ?_⟩ <;> simp [hx1, hx2] <;> grind
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        refine ⟨?_, ?_, ?_⟩ <;> grind
      · exact ⟨hx1, hx2, hx3⟩
    · exact ⟨hx1, hx2, hx3⟩
  | passBoundary =>
    simp only [step]
    refine ⟨rfl, rfl, ?_⟩
    intro hh
    dsimp only at hh
    have := h.fo_gen _ hh
    omega

theorem expired_run {s : State} {g : Bool} (h : Inv s g) (hx : Expired s) (es : List Event)
    (hn : ∀ e ∈ es, isUserEvent e = false) : Expired (run s es).1 := by
  induction es generalizing s g with
  | nil => simpa [run_nil] using hx
  | cons e es ih =>
    rw [run_cons]
    exact ih (inv_step h e) (expired_step h hx (hn e (by simp))) (fun x hx => hn x (by simp [hx]))

theorem expired_after {s : State} {g : Bool} (h : Inv s g) {e : Event}
    (he : e = .passBoundary ∨ e = .userRetry) : Expired (step s e).1 := by
  rcases he with rfl | rfl
  · refine ⟨rfl, rfl, ?_⟩
    simp only [step]
    intro hh
    have := h.fo_gen _ hh
    omega
  · refine ⟨rfl, rfl, ?_⟩
    simp only [step]
    intro hh
    have := h.fo_gen _ hh
    omega

/-- Theorem 7 (owedExpires): after `passBoundary` or `userRetry`, owedKeys = [] and foldRequest = none for every
following event list with no user event, even if a late `busy` result for a drag dispatched earlier arrives. -/
theorem owedExpires (rec : List Key) (pre : List Event) (e0 : Event)
    (he0 : e0 = .passBoundary ∨ e0 = .userRetry) (ys : List Event) (hys : ∀ e ∈ ys, isUserEvent e = false) :
    (run (step (run (State.init rec) pre).1 e0).1 ys).1.owedKeys = [] ∧
    (run (step (run (State.init rec) pre).1 e0).1 ys).1.foldRequest = none := by
  have hi := inv_run (Inv.init rec) pre
  have hx := expired_run (inv_step hi e0) (expired_after hi he0) ys hys
  exact ⟨hx.owed, hx.req⟩


/-! ### drop_expires: the attempt owed to a drop ends at the pass boundary -/

/-- Expired, and no Re-apply grant: after a pass boundary nothing can label an action as the user's. -/
structure Calm (s : State) : Prop where
  ex : Expired s
  grant : s.stripGrant = false

theorem calm_step {s : State} {g : Bool} (h : Inv s g) (hc : Calm s) {e : Event} (hn : isUserEvent e = false) :
    Calm (step s e).1 := by
  refine ⟨expired_step h hc.ex hn, ?_⟩
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r <;> simp [emit, nf.2.2.2.2.1, hc.grant]
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, hc.grant]
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        exact rs.2.2.1.trans hc.grant
      · exact hc.grant
    · exact hc.grant
  | passBoundary => simp [step]

theorem calm_actions {s : State} (hc : Calm s) {e : Event} {a : Action} (ha : a ∈ (step s e).2) : a.user = false := by
  obtain ⟨r, _, hd, _⟩ := step_acts ha
  rcases (decideMove_spec hd).2 with ⟨k, hk, _⟩ | ⟨_, b, hb, hh⟩
  · simp [hc.ex.owed, hc.ex.req] at hk
  · rcases hh with ⟨_, rfl⟩ | ⟨_, hg, _⟩
    · exact (planOrderMoves_spec hb).1
    · simp [hc.grant] at hg

theorem calm_run {s : State} {g : Bool} (h : Inv s g) (hc : Calm s) (es : List Event)
    (hn : ∀ e ∈ es, isUserEvent e = false) :
    (run s es).1.owedKeys = [] ∧ (run s es).1.foldRequest = none ∧ ∀ a ∈ (run s es).2, a.user = false := by
  induction es generalizing s g with
  | nil => simp [run_nil, hc.ex.owed, hc.ex.req]
  | cons e es ih =>
    obtain ⟨i1, i2, i3⟩ := ih (inv_step h e) (calm_step h hc (hn e (by simp))) (fun x hx => hn x (by simp [hx]))
    refine ⟨by simpa [run_cons] using i1, by simpa [run_cons] using i2, ?_⟩
    intro a ha
    rw [run_cons] at ha
    simp only [List.mem_append] at ha
    rcases ha with ha | ha
    · exact calm_actions hc ha
    · exact i3 a ha

/-- **drop_expires.**  At `passBoundary` the attempt owed to a drop (the owed list and the fold request) ends: with no user event
afterwards nothing is owed or requested again, even if a late `busy` result for a drag dispatched earlier arrives, and no action
of the run is the user's (an owed drop's attempt, or a Re-apply grant): the dropped key is not dragged again as a drop. -/
theorem drop_expires (rec : List Key) (pre : List Event) (ys : List Event) (hys : ∀ e ∈ ys, isUserEvent e = false) :
    (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).1.owedKeys = [] ∧
    (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).1.foldRequest = none ∧
    ∀ a ∈ (run (step (run (State.init rec) pre).1 .passBoundary).1 ys).2, a.user = false := by
  have hi := inv_run (Inv.init rec) pre
  have hx := expired_after hi (Or.inl rfl : (Event.passBoundary = .passBoundary ∨ Event.passBoundary = .userRetry))
  exact calm_run (inv_step hi .passBoundary) ⟨hx, by simp [step]⟩ ys hys

/-! ### Theorem 1: the budget (runs with no user event) -/

/-- The state of a run that has seen no user event: nothing is owed, nothing restricted, no strip grant, and any
drag in flight is the engine's and not skipped. -/
structure NU (s : State) : Prop where
  owed : s.owedKeys = []
  req : s.foldRequest = none
  grant : s.stripGrant = false
  restr : s.restricted = false
  fo : s.flightOwed = none
  eng : ∀ a, s.inFlight = some a → a.user = false
  skip : ∀ a, s.inFlight = some a → a.subject ∉ s.skipped

theorem NU.init (rec : List Key) : NU (State.init rec) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [State.init]

/-- Under `NU`, a read emits only an engine drag that does not allow the strip, and only when the budget has room. -/
theorem nu_decide {s : State} (h : NU s) {r : Read} {a : Action} (hd : decideMove s r = some a) :
    a.user = false ∧ a.strip = false ∧ s.inFlight = none ∧ s.moveCount < cap (fullBar s r) ∧
    s.skipped.contains a.subject = false := by
  rcases (decideMove_spec hd).2 with ⟨k, hk, _⟩ | ⟨hea, b, hb, hh⟩
  · simp [h.owed, h.req] at hk
  · have hp := planOrderMoves_spec hb
    refine ⟨?_, ?_, (decideMove_spec hd).1, ?_, ?_⟩
    · rcases hh with ⟨_, rfl⟩ | ⟨_, hg, _⟩
      · exact hp.1
      · simp [h.grant] at hg
    · rcases hh with ⟨hb1, rfl⟩ | ⟨_, hg, _⟩
      · exact hb1
      · simp [h.grant] at hg
    · simp [engineAllowed] at hea; exact hea.2
    · rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩ <;> exact hp.2.2.2.1

theorem nu_step {s : State} (h : NU s) {e : Event} (hn : isUserEvent e = false) : NU (step s e).1 := by
  obtain ⟨h1, h2, h3, h4, h5, h6, h7⟩ := h
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    have hh : NU s := ⟨h1, h2, h3, h4, h5, h6, h7⟩
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp only; refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind
    | some a =>
      have := nu_decide hh hd
      simp only [emit]
      refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm]
    refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> simp [h1, h2, h3, h4, h5] <;> grind
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> grind
      · exact ⟨h1, h2, h3, h4, h5, h6, h7⟩
    · exact ⟨h1, h2, h3, h4, h5, h6, h7⟩
  | passBoundary =>
    simp only [step]
    refine ⟨rfl, rfl, rfl, rfl, h5, h6, h7⟩

theorem nu_actions {s : State} (h : NU s) {e : Event} {a : Action} (ha : a ∈ (step s e).2) :
    a.user = false ∧ a.strip = false := by
  obtain ⟨r, _, hd, _⟩ := step_acts ha
  have := nu_decide h hd
  exact ⟨this.1, this.2.1⟩

theorem nu_run {s : State} (h : NU s) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    NU (run s es).1 ∧ ∀ a ∈ (run s es).2, a.user = false ∧ a.strip = false := by
  induction es generalizing s with
  | nil => simp [run_nil, h]
  | cons e es ih =>
    obtain ⟨i1, i2⟩ := ih (nu_step h (hn e (by simp))) (fun x hx => hn x (by simp [hx]))
    refine ⟨by simpa [run_cons] using i1, ?_⟩
    intro a ha
    rw [run_cons] at ha
    simp only [List.mem_append] at ha
    rcases ha with ha | ha
    · exact nu_actions h ha
    · exact i2 a ha

/-- the budget of the drags still to be resolved: 1 while a drag is in flight -/
def pend (s : State) : Nat := if s.inFlight.isSome then 1 else 0

theorem moveCount_step {s : State} {e : Event} (hn : isUserEvent e = false) :
    (step s e).1.moveCount = s.moveCount + postedStep s e := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r <;> simp [postedStep, emit, nf.2.1]
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, postedStep]
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step, postedStep]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        rename_i hk
        have hk' : a.subject = k := by simpa using hk
        cases p <;> simp [ha, hk', rs.2.2.2.2.2.2.1]
      · rename_i hk
        have hk' : ¬ a.subject = k := by simpa using hk
        cases p <;> simp [ha, hk']
    · rename_i hnone
      cases p <;> simp [hnone]
  | passBoundary => simp [step, postedStep]

theorem moveCount_run (s : State) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    (run s es).1.moveCount = s.moveCount + postedEngine s es := by
  induction es generalizing s with
  | nil => simp [run_nil, postedEngine]
  | cons e es ih =>
    have := ih (step s e).1 (fun x hx => hn x (by simp [hx]))
    rw [run_cons]
    simp only [postedEngine]
    rw [this, moveCount_step (hn e (by simp))]
    omega

/-- every read of the run has `cap (fullBar s_i r) ≤ C` -/
def capEv (C : Nat) (s : State) : Event → Prop
  | .read r => cap (fullBar s r) ≤ C
  | _ => True

def capOK (C : Nat) (s : State) : List Event → Prop
  | [] => True
  | e :: es => capEv C s e ∧ capOK C (step s e).1 es

theorem capOK_twenty (s : State) (es : List Event) : capOK 20 s es := by
  induction es generalizing s with
  | nil => trivial
  | cons e es ih =>
    refine ⟨?_, ih _⟩
    cases e <;> simp [capEv, cap, capFull, capNotFull] <;> split <;> omega

theorem capOK_three (s : State) (es : List Event) (h : fullThroughout s es) : capOK 3 s es := by
  induction es generalizing s with
  | nil => trivial
  | cons e es ih =>
    refine ⟨?_, ih _ h.2⟩
    have := h.1
    cases e <;> simp_all [capEv, cap, capFull]

theorem budget_step (C : Nat) {s : State} (h : NU s) {e : Event} (hn : isUserEvent e = false)
    (hc : capEv C s e)
    (hb : s.moveCount + pend s ≤ C) : (step s e).1.moveCount + pend (step s e).1 ≤ C := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    simp only [capEv] at hc
    rw [step_read]
    simp only [pend] at hb
    cases hd : decideMove s r with
    | none => simp only [pend]; grind
    | some a =>
      have := nu_decide h hd
      simp only [pend, emit]
      grind
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, pend] at *; exact hb
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      have hu := h.eng a ha
      split
      · have rs := result_spec s a o p
        simp only [pend, rs.2.2.2.2.2.1]
        simp [pend, ha] at hb
        grind
      · exact hb
    · exact hb
  | passBoundary => simp [step, pend] at *; exact hb

theorem budget_run (C : Nat) {s : State} (h : NU s) (es : List Event)
    (hn : ∀ e ∈ es, isUserEvent e = false) (hc : capOK C s es) (hb : s.moveCount + pend s ≤ C) :
    (run s es).1.moveCount + pend (run s es).1 ≤ C := by
  induction es generalizing s with
  | nil => simpa [run_nil] using hb
  | cons e es ih =>
    rw [run_cons]
    exact ih (nu_step h (hn e (by simp))) (fun x hx => hn x (by simp [hx])) hc.2
      (budget_step C h (hn e (by simp)) hc.1 hb)

/-- Theorem 1 (budget), always: from the initial state, with no user event, at most 20 engine drags are posted. -/
theorem budget_any (rec : List Key) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    postedEngine (State.init rec) es ≤ 20 := by
  have := budget_run 20 (NU.init rec) es hn (capOK_twenty _ _) (by simp [State.init, pend])
  rw [moveCount_run _ _ hn] at this
  have h0 : (State.init rec).moveCount = 0 := rfl
  have h1 : 0 ≤ pend (run (State.init rec) es).1 := Nat.zero_le _
  omega

/-- Theorem 1 (budget), full bar: if `fullBar s_i r` holds at every read, at most 3. -/
theorem budget_full (rec : List Key) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false)
    (hf : fullThroughout (State.init rec) es) : postedEngine (State.init rec) es ≤ 3 := by
  have := budget_run 3 (NU.init rec) es hn (capOK_three _ _ hf) (by simp [State.init, pend])
  rw [moveCount_run _ _ hn] at this
  have h0 : (State.init rec).moveCount = 0 := rfl
  have h1 : 0 ≤ pend (run (State.init rec) es).1 := Nat.zero_le _
  omega


/-- Every engine drag is accounted for: posted (counted), answered without a mouse event (its key is `skipped`),
or still in flight. -/
theorem action_step {s : State} (h : NU s) {e : Event} (hn : isUserEvent e = false) :
    (step s e).2.length + pend s + s.skipped.length ≤
      postedStep s e + pend (step s e).1 + (step s e).1.skipped.length := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp only [pend, postedStep]; grind
    | some a =>
      have := nu_decide h hd
      simp only [pend, postedStep, emit]
      grind
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, pend, postedStep]
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      have hu := h.eng a ha
      have hs := h.skip a ha
      split
      · have rs := result_spec s a o p
        rename_i hk
        have hk' : a.subject = k := by simpa using hk
        cases p with
        | true => simp [pend, postedStep, ha, hk', hu, rs.2.2.2.2.2.2.2.1 rfl |>.2]
        | false =>
          have := rs.2.2.2.2.2.2.2.2.2.2.2.1 rfl hs
          simp [pend, postedStep, ha, hk']
          grind
      · simp [pend, postedStep]
    · simp [pend, postedStep]
  | passBoundary => simp only [step, pend, postedStep]; grind

theorem action_run {s : State} (h : NU s) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    (run s es).2.length + pend s + s.skipped.length ≤
      postedEngine s es + pend (run s es).1 + (run s es).1.skipped.length := by
  induction es generalizing s with
  | nil => simp [run_nil, postedEngine]
  | cons e es ih =>
    have h1 := action_step h (hn e (by simp))
    have h2 := ih (nu_step h (hn e (by simp))) (fun x hx => hn x (by simp [hx]))
    rw [run_cons]
    simp only [postedEngine, List.length_append]
    omega

/-- Theorem 1 (budget), action bound: engine actions <= posted + skipped + (1 if a drag is in flight). -/
theorem engineActions_bound (rec : List Key) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    ((run (State.init rec) es).2.filter (fun a => !a.user)).length ≤
      postedEngine (State.init rec) es + (run (State.init rec) es).1.skipped.length +
        (if (run (State.init rec) es).1.inFlight.isSome then 1 else 0) := by
  have h := action_run (NU.init rec) es hn
  have hall : (run (State.init rec) es).2.filter (fun a => !a.user) = (run (State.init rec) es).2 := by
    rw [List.filter_eq_self]
    intro a ha
    simp [(nu_run (NU.init rec) es hn).2 a ha |>.1]
  rw [hall]
  have h0 : pend (State.init rec) = 0 := rfl
  have h1 : (State.init rec).skipped.length = 0 := rfl
  simp only [pend] at h
  simp only [h0, h1] at h
  omega


/-! ### Theorem 6: the proof that the bar is not full needs three consecutive qualifying reads -/

/-- Before the proof, `noChevronReads` counts exactly the qualifying reads at the end of the reads seen so far (`h`). -/
def CountInv (s : State) (h : List Read) : Prop :=
  s.provenNotFull = false → s.noChevronReads ≤ 3 ∧ s.noChevronReads ≤ h.length ∧
    ∀ x ∈ h.reverse.take s.noChevronReads, qualifying x

theorem rev_take_succ (h : List Read) (r : Read) (n : Nat) :
    (h ++ [r]).reverse.take (n + 1) = r :: h.reverse.take n := by simp

theorem noteRead_pnf_nc (s : State) (r : Read) :
    ((noteRead s r).provenNotFull, (noteRead s r).noChevronReads) =
    match r.chevron with
    | .fresh => (false, 0)
    | .stale => (false, 0)
    | .absent =>
        if s.provenNotFull then (s.provenNotFull, s.noChevronReads)
        else if r.level == .incomplete || !r.observed then (s.provenNotFull, 0)
        else if r.kind == .pass && !r.settled then (s.provenNotFull, s.noChevronReads)
        else if (if r.kind == .pass then 3 else 2) <= s.noChevronReads then (true, 0)
        else (s.provenNotFull, s.noChevronReads + 1) := by
  unfold noteRead
  cases r.chevron <;> simp <;> (repeat' split) <;> simp_all

theorem noteRead_count {s : State} {h : List Read} (hc : CountInv s h) (r : Read) :
    CountInv (noteRead s r) (h ++ cnt r) := by
  intro hp
  have key := hc
  unfold CountInv at key
  have f := noteRead_pnf_nc s r
  have f1 := congrArg Prod.fst f
  have f2 := congrArg Prod.snd f
  simp only at f1 f2
  rw [f1] at hp
  have rt := rev_take_succ h r
  have hl : (h ++ [r]).length = h.length + 1 := by simp
  by_cases hcn : counted r = true
  · have e : cnt r = [r] := by simp [cnt, hcn]
    rw [e, f2]
    cases hch : r.chevron <;> simp only [hch] at hp ⊢ <;> grind [qualifying, counted]
  · have e : cnt r = [] := by simp [cnt, hcn]
    rw [e, f2]
    simp only [List.append_nil]
    cases hch : r.chevron <;> simp only [hch] at hp ⊢ <;> grind [qualifying, counted]

theorem noteRead_proven_absent {s : State} {r : Read} (h : (noteRead s r).provenNotFull = true) :
    r.chevron = .absent := by
  unfold noteRead at h
  cases hch : r.chevron <;> simp only [hch] at h <;> grind


theorem noteRead_gain {s : State} {h : List Read} (hc : CountInv s h) {r : Read}
    (h1 : s.provenNotFull = false) (h2 : (noteRead s r).provenNotFull = true) :
    2 ≤ h.length ∧ (∀ x ∈ h.reverse.take 2, qualifying x) ∧ qualifying r ∧
      (r.kind = .pass → 3 ≤ h.length ∧ ∀ x ∈ h.reverse.take 3, qualifying x) := by
  have key := hc h1
  have hab : r.chevron = .absent := noteRead_proven_absent h2
  have f := noteRead_pnf_nc s r
  have f1 := congrArg Prod.fst f
  simp only [h2, hab, h1] at f1
  simp at f1
  obtain ⟨k1, k2, k3⟩ := key
  have hl : r.level ≠ .incomplete := by
    intro hi; simp [hi] at f1
  have hn : (if r.kind = .pass then 3 else 2) ≤ s.noChevronReads := by
    by_cases hn : (if r.kind = .pass then 3 else 2) ≤ s.noChevronReads
    · exact hn
    · by_cases ho : r.observed = false
      · simp [ho] at f1
      · by_cases hs : r.kind = .pass ∧ r.settled = false
        · simp [hl, ho, hs] at f1
        · simp [hl, ho, hs, hn] at f1
  have hq : qualifying r := ⟨hab, hl⟩
  have t2 : h.reverse.take 2 ⊆ h.reverse.take s.noChevronReads := by
    have : (h.reverse.take s.noChevronReads).take 2 = h.reverse.take 2 := by
      rw [List.take_take]; congr 1; split at hn <;> omega
    intro x hx; rw [← this] at hx; exact List.mem_of_mem_take hx
  refine ⟨?_, fun x hx => k3 x (t2 hx), hq, fun hp => ?_⟩
  · split at hn <;> omega
  · simp [hp] at hn
    refine ⟨by omega, fun x hx => k3 x ?_⟩
    have : s.noChevronReads = 3 := by omega
    rw [this]; exact hx

theorem step_read_fields (s : State) (r : Read) :
    (step s (.read r)).1.provenNotFull = (noteRead s r).provenNotFull ∧
    (step s (.read r)).1.noChevronReads = (noteRead s r).noChevronReads := by
  rw [step_read]
  split <;> simp [emit]

theorem step_nonread_fields (s : State) (e : Event) (hr : ∀ r, e ≠ .read r) :
    (step s e).1.provenNotFull = s.provenNotFull ∧ (step s e).1.noChevronReads = s.noChevronReads := by
  cases e with
  | read r => exact absurd rfl (hr r)
  | userEdit rec moved => simp only [step]; split <;> simp
  | userRetry => simp [step]
  | retryKey k => simp [step]
  | moveResult k o p =>
    simp only [step]
    split
    · split
      · simp only [result, markFail, markStrike]; grind
      · simp
    · simp
  | passBoundary => simp [step]

theorem readsOf_cons (e : Event) (es : List Event) : readsOf (e :: es) = readsOf [e] ++ readsOf es := by
  cases e <;> simp [readsOf]

theorem readsOf_nonread (e : Event) (hr : ∀ r, e ≠ .read r) : readsOf [e] = [] := by
  cases e with
  | read r => exact absurd rfl (hr r)
  | _ => simp [readsOf]

theorem readsOf_filter_read (r : Read) : (readsOf [Event.read r]).filter counted = cnt r := by
  simp only [readsOf, cnt, List.filter_cons, List.filter_nil]

theorem countInv_step {s : State} {h : List Read} (hc : CountInv s h) (e : Event) :
    CountInv (step s e).1 (h ++ (readsOf [e]).filter counted) := by
  by_cases hre : ∃ r, e = .read r
  · obtain ⟨r, rfl⟩ := hre
    have := noteRead_count hc r
    have f := step_read_fields s r
    rw [readsOf_filter_read]
    unfold CountInv at this ⊢
    rw [f.1, f.2]
    exact this
  · have hr : ∀ r, e ≠ .read r := fun r h => hre ⟨r, h⟩
    have f := step_nonread_fields s e hr
    unfold CountInv at hc ⊢
    rw [f.1, f.2, readsOf_nonread e hr]
    simpa using hc

theorem proof_gen : ∀ (es : List Event) (s : State) (h : List Read), CountInv s h →
    (run s es).1.provenNotFull = true →
    (s.provenNotFull = true ∧ ∀ r ∈ readsOf es, r.chevron = .absent) ∨
    ∃ pre r post, es = pre ++ .read r :: post ∧
      (run s pre).1.provenNotFull = false ∧ (noteRead (run s pre).1 r).provenNotFull = true ∧
      2 ≤ (h ++ (readsOf pre).filter counted).length ∧ (∀ x ∈ (h ++ (readsOf pre).filter counted).reverse.take 2, qualifying x) ∧ qualifying r ∧
      (r.kind = .pass → 3 ≤ (h ++ (readsOf pre).filter counted).length ∧
        ∀ x ∈ (h ++ (readsOf pre).filter counted).reverse.take 3, qualifying x) ∧
      ∀ r' ∈ readsOf post, r'.chevron = .absent
  | [], s, h, _, hp => by left; simpa [run_nil, readsOf] using hp
  | e :: es, s, h, hc, hp => by
    have hc1 := countInv_step hc e
    have hp1 : (run (step s e).1 es).1.provenNotFull = true := by simpa [run_cons] using hp
    rcases proof_gen es _ _ hc1 hp1 with ⟨hs1, hall⟩ | ⟨pre, r, post, he, g1, g2, g3, g4, g5, g6, g7⟩
    · by_cases hre : ∃ r, e = .read r
      · obtain ⟨r, rfl⟩ := hre
        have f := step_read_fields s r
        rw [f.1] at hs1
        have hr : r.chevron = .absent := noteRead_proven_absent hs1
        by_cases hs : s.provenNotFull = true
        · left; refine ⟨hs, ?_⟩
          intro x hx; simp only [readsOf, List.mem_cons] at hx
          rcases hx with rfl | hx
          · exact hr
          · exact hall x hx
        · right
          have hs' : s.provenNotFull = false := by simpa using hs
          have gain := noteRead_gain hc hs' hs1
          refine ⟨[], r, es, rfl, by simpa [run_nil] using hs', by simpa [run_nil] using hs1, ?_⟩
          simp only [readsOf, List.filter_nil, List.append_nil, run_nil]
          exact ⟨gain.1, gain.2.1, gain.2.2.1, gain.2.2.2, fun r' hr' => hall r' hr'⟩
      · have hr : ∀ r, e ≠ .read r := fun r h => hre ⟨r, h⟩
        have f := step_nonread_fields s e hr
        rw [f.1] at hs1
        left; refine ⟨hs1, ?_⟩
        rw [readsOf_cons, readsOf_nonread e hr]
        simpa using hall
    · right
      refine ⟨e :: pre, r, post, by simp [he], ?_⟩
      rw [run_cons, readsOf_cons, List.filter_append, ← List.append_assoc]
      exact ⟨g1, g2, g3, g4, g5, g6, g7⟩

/-- Theorem 6 (proofNeedsThreeConsecutive): if the bar is proven not full at the end of a run from the initial
state, then at the step that gained the proof (a read `r`) the last two reads before it (other events may interleave) and `r` itself were
chevronless at a qualifying level, and when `r` is a pass read (the proof arms on the third read and flips on the next pass read) the last
THREE reads before it were; every read since had no chevron.  The history is every read EXCEPT the complete, chevronless, observed, unsettled
pass reads (`counted`), which neither count nor reset (Swift): an unsettled read with a chevron or an `incomplete` one stays in it. -/
theorem proofNeedsThreeConsecutive (rec : List Key) (es : List Event)
    (h : (run (State.init rec) es).1.provenNotFull = true) :
    ∃ pre r post, es = pre ++ .read r :: post ∧
      (run (State.init rec) pre).1.provenNotFull = false ∧
      (noteRead (run (State.init rec) pre).1 r).provenNotFull = true ∧
      2 ≤ ((readsOf pre).filter counted).length ∧ (∀ x ∈ ((readsOf pre).filter counted).reverse.take 2, qualifying x) ∧ qualifying r ∧
      (r.kind = .pass → 3 ≤ ((readsOf pre).filter counted).length ∧
        ∀ x ∈ ((readsOf pre).filter counted).reverse.take 3, qualifying x) ∧
      ∀ r' ∈ readsOf post, r'.chevron = .absent := by
  have hc : CountInv (State.init rec) [] := by
    intro _; simp [State.init]
  rcases proof_gen es _ _ hc h with ⟨h1, _⟩ | ⟨pre, r, post, he, g⟩
  · simp [State.init] at h1
  · refine ⟨pre, r, post, he, ?_⟩
    simpa using g


/-! ### Lifting theorems 3 and 5 to whole runs -/

/-- Theorem 5 over a run: with a hold set and no user event, the hold is cleared only at a read that gains the proof. -/
theorem holdRelease_run : ∀ (es : List Event) (s : State), s.hold = true →
    (∀ e ∈ es, isUserEvent e = false) → (run s es).1.hold = false →
    ∃ pre r post, es = pre ++ .read r :: post ∧
      (run s pre).1.provenNotFull = false ∧ (noteRead (run s pre).1 r).provenNotFull = true
  | [], s, h1, _, h2 => by simp [run_nil] at h2; simp [h1] at h2
  | e :: es, s, h1, hn, h2 => by
    have hn0 : isUserEvent e = false := hn e (by simp)
    by_cases hh : (step s e).1.hold = true
    · have h2' : (run (step s e).1 es).1.hold = false := by simpa [run_cons] using h2
      obtain ⟨pre, r, post, he, g1, g2⟩ := holdRelease_run es _ hh (fun x hx => hn x (by simp [hx])) h2'
      exact ⟨e :: pre, r, post, by simp [he], by simpa [run_cons] using g1, by simpa [run_cons] using g2⟩
    · have hh' : (step s e).1.hold = false := by simpa using hh
      rcases holdRelease s e h1 hh' with hu | ⟨hp1, hp2⟩
      · simp [hn0] at hu
      · by_cases hre : ∃ r, e = .read r
        · obtain ⟨r, rfl⟩ := hre
          have f := step_read_fields s r
          refine ⟨[], r, es, rfl, by simpa [run_nil] using hp2, ?_⟩
          simpa [run_nil, f.1] using hp1
        · have hr : ∀ r, e ≠ .read r := fun r h => hre ⟨r, h⟩
          have f := step_nonread_fields s e hr
          rw [f.1] at hp1; rw [hp1] at hp2; simp at hp2

/-- Theorem 3 over a run: every action of a run, wherever it leaves, obeys the folded-target rule against that
read `r`, the state before it and the state after reading. -/
theorem noFoldedTarget_run (s : State) (es : List Event) (a : Action) (h : a ∈ (run s es).2) :
    ∃ pre r post, es = pre ++ .read r :: post ∧
      a.rel.target ∉ r.pile ∧ a.rel.target ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.rel.target ∉ (run s pre).1.lastFreshPile) ∧
      a.rel.target ∉ (noteRead (run s pre).1 r).lastFreshPile ∧
      (a.user = false → a.subject ∉ r.pile ∧ a.subject ∉ r.folded ∧ (¬(r.usable ∧ r.chevron = .fresh) → a.subject ∉ (run s pre).1.lastFreshPile) ∧
        a.subject ∉ (noteRead (run s pre).1 r).lastFreshPile) := by
  obtain ⟨pre, e, post, he, hm⟩ := run_action_split s es a h
  obtain ⟨r, rfl, _⟩ := step_acts hm
  exact ⟨pre, r, post, he, noFoldedTarget hm⟩


/-! ### Theorem 1, segment form: the budget between user events -/

/-- 1 iff the in-flight drag is the engine's. -/
def pendEng (s : State) : Nat := match s.inFlight with
  | some a => if a.user then 0 else 1
  | none => 0

theorem pendEng_le (s : State) : pendEng s ≤ 1 := by
  unfold pendEng; split <;> (try split) <;> omega

theorem seg_step (C : Nat) (s : State) (e : Event) (hn : isUserEvent e = false) (hc : capEv C s e) :
    (step s e).1.moveCount + pendEng (step s e).1 ≤ max C (s.moveCount + pendEng s) := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    simp only [capEv] at hc
    rw [step_read]
    cases hd : decideMove s r with
    | none =>
      simp only [pendEng, nf.2.1, nf.2.2.2.2.2.2.2.2.2.2.2.1, judge_frame_moveCount, judge_inFlight]; omega
    | some a =>
      have spec := decideMove_spec hd
      simp only [pendEng, emit, nf.2.1, spec.1, judge_frame_moveCount, judge_inFlight]
      rcases spec.2 with ⟨k, _, hu, _⟩ | ⟨hea, b, hb, hh⟩
      · simp [(userMove_spec hu).1]; omega
      · rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
        · have hu := (planOrderMoves_spec hb).1
          simp only [engineAllowed, Bool.and_eq_true, decide_eq_true_eq, judge_fullBar, judge_frame_moveCount] at hea
          simp [hu]; omega
        · simp; omega
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, pendEng]; omega
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        simp only [pendEng, rs.2.2.2.2.2.1, rs.2.2.2.2.2.2.1, ha]
        cases p <;> cases hu : a.user <;> simp <;> omega
      · simp only; omega
    · simp only; omega
  | passBoundary => simp [step, pendEng]; omega

theorem seg_run (C : Nat) (s : State) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false)
    (hc : capOK C s es) : postedEngine s es + s.moveCount ≤ max C (s.moveCount + pendEng s) := by
  induction es generalizing s with
  | nil => simp [postedEngine]; omega
  | cons e es ih =>
    have h1 := ih (step s e).1 (fun x hx => hn x (by simp [hx])) hc.2
    have h2 := seg_step C s e (hn e (by simp)) hc.1
    have h3 := moveCount_step (s := s) (e := e) (hn e (by simp))
    simp only [postedEngine]
    omega

/-- From ANY state (no reachability needed). -/
theorem budget_any_from (s : State) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    postedEngine s es ≤ 20 := by
  have := seg_run 20 s es hn (capOK_twenty _ _)
  have := pendEng_le s
  omega

theorem budget_full_from (s : State) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false)
    (hf : fullThroughout s es) : postedEngine s es ≤ 3 := by
  have := seg_run 3 s es hn (capOK_three _ _ hf)
  have := pendEng_le s
  omega

/-- The product promise: between one user event and the next. -/
theorem budget_between_user_events (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event)
    (_hue : isUserEvent ue = true) (hys : ∀ e ∈ ys, isUserEvent e = false) :
    postedEngine (step (run (State.init rec) pre).1 ue).1 ys ≤ 20 :=
  budget_any_from _ _ hys

theorem budget_full_between_user_events (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event)
    (_hue : isUserEvent ue = true) (hys : ∀ e ∈ ys, isUserEvent e = false)
    (hf : fullThroughout (step (run (State.init rec) pre).1 ue).1 ys) :
    postedEngine (step (run (State.init rec) pre).1 ue).1 ys ≤ 3 :=
  budget_full_from _ _ hys hf


/-! ### Segment form: between two user events, from ANY state -/

/-- An engine drag in flight is never in `skipped` (so its unposted result adds one skipped key). -/
def KEng (s : State) : Prop := ∀ a, s.inFlight = some a → a.user = false → a.subject ∉ s.skipped

theorem kEng_user_event {s : State} {e : Event} (hu : isUserEvent e = true) : KEng (step s e).1 := by
  intro a _ _
  cases e with
  | userEdit rec moved =>
    have : moved.isEmpty = false := by simpa [isUserEvent] using hu
    simp [step, this]
  | userRetry => simp [step]
  | retryKey k => simp [step]
  | _ => simp [isUserEvent] at hu

theorem kEng_step {s : State} (h : KEng s) {e : Event} (hn : isUserEvent e = false) : KEng (step s e).1 := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r with
    | none => intro a ha hu; simp only at ha ⊢; exact (by rw [nf.2.2.2.2.2.2.2.1, judge_frame_skipped]; exact h a (by rw [← judge_inFlight s r, ← nf.2.2.2.2.2.2.2.2.2.2.2.1]; exact ha) hu)
    | some a =>
      intro b hb hu
      simp only [emit] at hb ⊢
      have hb' : a = b := by simpa using hb
      subst hb'
      rcases (decideMove_spec hd).2 with ⟨k, _, hk, _⟩ | ⟨_, c, hc, hh⟩
      · simp [(userMove_spec hk).1] at hu
      · have hp := planOrderMoves_spec hc
        rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
        · rw [nf.2.2.2.2.2.2.2.1, judge_frame_skipped]; simpa using hp.2.2.2.1
        · simp at hu
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simpa [step, hm, KEng] using h
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · intro b hb; have := (result_spec s a o p).2.2.2.2.2.1; rw [this] at hb; cases hb
      · exact h
    · exact h
  | passBoundary => simpa [step, KEng] using h

theorem engAction_step {s : State} (h : KEng s) {e : Event} (hn : isUserEvent e = false) :
    ((step s e).2.filter (fun a => !a.user)).length + pendEng s + s.skipped.length ≤
      postedStep s e + pendEng (step s e).1 + (step s e).1.skipped.length := by
  cases e with
  | read r =>
    have nf := noteRead_frame (judge s r) r
    have jf := judge_frame s r
    rw [step_read]
    cases hd : decideMove s r with
    | none => simp only [pendEng]; rw [nf.2.2.2.2.2.2.2.1, nf.2.2.2.2.2.2.2.2.2.2.2.1]; simp [postedStep]
    | some a =>
      have spec := decideMove_spec hd
      have hnone : s.inFlight = none := by simpa using spec.1
      rcases spec.2 with ⟨k, _, hk, _⟩ | ⟨_, c, hc, hh⟩
      · have := (userMove_spec hk).1
        simp [pendEng, emit, hnone, this, postedStep, nf.2.2.2.2.2.2.2.1, judge_frame_skipped, judge_inFlight]
      · have hp := planOrderMoves_spec hc
        rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
        · simp [pendEng, emit, hnone, hp.1, postedStep, nf.2.2.2.2.2.2.2.1, judge_frame_skipped, judge_inFlight]
        · simp [pendEng, emit, hnone, postedStep, nf.2.2.2.2.2.2.2.1, judge_frame_skipped, judge_inFlight]
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using hn
    simp [step, hm, pendEng, postedStep]
  | userRetry => simp [isUserEvent] at hn
  | retryKey k => simp [isUserEvent] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have rs := result_spec s a o p
        rename_i hk
        have hk' : a.subject = k := by simpa using hk
        cases hu : a.user with
        | true =>
          cases p with
          | true => simp [pendEng, postedStep, ha, hk', hu, rs.2.2.2.2.2.1, (rs.2.2.2.2.2.2.2.1 rfl).2]
          | false =>
            by_cases hm : a.subject ∈ s.skipped
            · have := rs.2.2.2.2.2.2.2.2.2.2.1 rfl hm
              simp [pendEng, postedStep, ha, hk', hu, rs.2.2.2.2.2.1, this]
            · have := rs.2.2.2.2.2.2.2.2.2.2.2.1 rfl hm
              simp [pendEng, postedStep, ha, hk', hu, rs.2.2.2.2.2.1, this]
        | false =>
          have hs := h a ha hu
          cases p with
          | true => simp [pendEng, postedStep, ha, hk', hu, rs.2.2.2.2.2.1, (rs.2.2.2.2.2.2.2.1 rfl).2]
          | false =>
            have := rs.2.2.2.2.2.2.2.2.2.2.2.1 rfl hs
            simp [pendEng, postedStep, ha, hk', hu, rs.2.2.2.2.2.1, this]
            grind
      · simp [pendEng, postedStep]
    · simp [pendEng, postedStep]
  | passBoundary => simp only [step, pendEng, postedStep]; grind

theorem engAction_run {s : State} (h : KEng s) (es : List Event) (hn : ∀ e ∈ es, isUserEvent e = false) :
    ((run s es).2.filter (fun a => !a.user)).length + pendEng s + s.skipped.length ≤
      postedEngine s es + pendEng (run s es).1 + (run s es).1.skipped.length := by
  induction es generalizing s with
  | nil => simp [run_nil, postedEngine]
  | cons e es ih =>
    have h1 := engAction_step h (hn e (by simp))
    have h2 := ih (kEng_step h (hn e (by simp))) (fun x hx => hn x (by simp [hx]))
    rw [run_cons]
    simp only [postedEngine, List.filter_append, List.length_append]
    omega

/-- Engine actions in a segment between two user events are accounted for: posted, skipped, or in flight. -/
theorem engineActions_between_user_events (rec : List Key) (pre : List Event) (ue : Event) (ys : List Event)
    (hue : isUserEvent ue = true) (hys : ∀ e ∈ ys, isUserEvent e = false) :
    ((run (step (run (State.init rec) pre).1 ue).1 ys).2.filter (fun a => !a.user)).length ≤
      postedEngine (step (run (State.init rec) pre).1 ue).1 ys +
      (run (step (run (State.init rec) pre).1 ue).1 ys).1.skipped.length +
      pendEng (run (step (run (State.init rec) pre).1 ue).1 ys).1 := by
  have := engAction_run (kEng_user_event (s := (run (State.init rec) pre).1) hue) ys hys
  omega

/-! ### Honest strip flag -/

theorem userMove_strip {s : State} {r : Read} {k : Key} {a : Action} (h : userMove s r k = some a) :
    a.strip = needsStrip s r a.subject a.rel := by
  have hk := (userMove_spec h).2.1
  subst hk
  simp only [userMove] at h
  split at h
  · split at h
    · cases hg : List.getLast? (List.filter (fun x => (List.takeWhile (fun x => x != a.subject) s.record).contains x) (movable s r)) with
      | none => simp only [hg, Option.map, Option.filter] at h; cases h
      | some p =>
        simp only [hg, Option.map, Option.filter] at h
        split at h
        · simp at h; rw [← h]
        · simp at h
    · simp at h
  · split at h
    · split at h
      · rename_i a' ha'
        simp only [Option.some.injEq] at h; subst h
        exact (anchorMove_basic ha').2.2.2
      · exact (fallbackMove_basic h).2.2.2.2.2.1
    · simp at h
theorem strip_honest {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) :
    a.strip = needsStrip s r a.subject a.rel := by
  obtain ⟨r', he, hd, _⟩ := step_acts h
  cases he
  rcases (decideMove_spec hd).2 with ⟨k, _, hu, _⟩ | ⟨_, b, hb, hh⟩
  · exact userMove_strip hu
  · have : b.strip = needsStrip s r b.subject b.rel := by
      simp only [planOrderMoves] at hb
      split at hb
      · split at hb
        · simp at hb
        · simp at hb; subst hb; rfl
      · simp at hb
    rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩ <;> simpa using this


/-- The flag is exactly "the drag touches a folded key or one in the churn zone": it cannot be lied about in either direction. -/
theorem strip_iff {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) :
    a.strip = true ↔ (a.subject ∈ foldedAll s r ∨ a.subject ∈ r.nearFold ∨
      a.rel.target ∈ foldedAll s r ∨ a.rel.target ∈ r.nearFold) := by
  rw [strip_honest h]
  simp [needsStrip, List.mem_append]
  grind


/-- A `user := true` action is either an owed key / the fold request, or a granted strip move: the label cannot be lied about. -/
theorem userLabelHonest {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) (hu : a.user = true) :
    (a.subject ∈ s.foldRequest.toList ∨ a.subject ∈ s.owedKeys) ∨ (a.strip = true ∧ s.stripGrant = true) := by
  obtain ⟨r', he, hd, _⟩ := step_acts h
  cases he
  rcases (decideMove_spec hd).2 with ⟨k, hk, hm, _⟩ | ⟨_, b, _, hh⟩
  · have := (userMove_spec hm).2.1
    subst this
    exact Or.inl hk
  · rcases hh with ⟨_, rfl⟩ | ⟨h1, h2, rfl⟩
    · have := (planOrderMoves_spec ‹_›).1; simp [this] at hu
    · exact Or.inr ⟨by simpa using h1, h2⟩

end Sommelier
