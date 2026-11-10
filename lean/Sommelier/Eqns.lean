import Sommelier.Step

/-!
# Equation lemmas, generated once

`Safety.lean` and `Gates.lean` both `unfold` the same definitions.  Lean generates auxiliary declarations
(`result.match_1.congr_eq_1._sparseCasesOn_2`, ...) in the first module that needs them, so two modules that
generate them separately cannot both be imported (`Pins.lean`, `Sommelier.lean`).  Generating them here, in a module
both import, keeps `Gates.lean` and `Honesty.lean` independent of `Safety.lean` (a mutant that breaks a `Safety.lean`
proof cannot mask a theorem in `Gates.lean`).
-/

namespace Sommelier

theorem eqns_result (s : State) (a : Action) (o : Outcome) (p : Bool) : (result s a o p).inFlight = none := by
  unfold result markFail markStrike; grind

theorem eqns_noteRead (s : State) (r : Read) : (noteRead s r).record = s.record := by
  unfold noteRead; grind

/-- What counts as folded: this read's folded set, plus the memory unless this read is a usable fresh-chevron read (which supersedes it). -/
theorem mem_foldedAll (s : State) (r : Read) (k : Key) :
    k ∈ foldedAll s r ↔ k ∈ r.foldedSet ∨ (¬(r.usable ∧ r.chevron = .fresh) ∧ k ∈ s.lastFreshPile) := by
  unfold foldedAll
  by_cases h : r.usable ∧ r.chevron = .fresh
  · simp [h]
  · simp [h]

theorem tw_sub' {p : Key → Bool} : ∀ {l : List Key} {x : Key}, x ∈ l.takeWhile p → x ∈ l ∧ p x = true
  | [], _, h => by simp [List.takeWhile] at h
  | y :: l, x, h => by
    unfold List.takeWhile at h
    by_cases hy : p y = true
    · rw [hy] at h
      simp only [List.mem_cons] at h
      rcases h with h | h
      · subst h; exact ⟨by simp, hy⟩
      · have := tw_sub' h; exact ⟨List.mem_cons_of_mem _ this.1, this.2⟩
    · simp [hy] at h

theorem dw_sub' {p : Key → Bool} {l : List Key} {x : Key} (h : x ∈ l.dropWhile p) : x ∈ l := by
  have := List.takeWhile_append_dropWhile (p := p) (l := l)
  rw [← this]; exact List.mem_append_right _ h

/-- The anchor rule's move: the user's own move of `k`, to a movable target, with the honest strip flag. -/
theorem anchorMove_basic {s : State} {r : Read} {k : Key} {a : Action} (h : anchorMove s r k = some a) :
    a.user = true ∧ a.subject = k ∧ a.rel.target ∈ movable s r ∧ a.strip = needsStrip s r a.subject a.rel := by
  simp only [anchorMove] at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i i hi
      split at h
      · rename_i p hp
        have hp' := List.mem_of_mem_take (List.mem_of_getLast? hp)
        simp at h; subst h; simp [Rel.target]
        exact (List.mem_filter.1 hp').1
      · rename_i hn
        cases hh : (List.filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a) (movable s r)).head? with
        | none => simp only [hh, Option.map] at h; cases h
        | some t =>
          have ht := List.mem_of_mem_head? (by rw [hh]; simp : t ∈ _ )
          simp only [hh, Option.map] at h
          simp at h; subst h; simp [Rel.target]
          exact (List.mem_filter.1 ht).1

theorem dw_head {p : Key → Bool} : ∀ {l : List Key} {y : Key} {ys : List Key}, l.dropWhile p = y :: ys → p y = false
  | [], _, _, h => by simp at h
  | z :: l, y, ys, h => by
    unfold List.dropWhile at h
    by_cases hz : p z = true
    · rw [hz] at h; exact dw_head h
    · simp only [hz] at h
      simp at h
      obtain ⟨rfl, _⟩ := h
      simpa using hz

/-- The fallback's target is a movable record key other than `k`. -/
theorem fallbackRel_target {s : State} {r : Read} {k : Key} {rel : Rel} (h : fallbackRel s r k = some rel) :
    rel.target ∈ movable s r ∧ rel.target ∈ s.record ∧ rel.target ≠ k := by
  unfold fallbackRel at h
  cases hr : (List.getLast? (List.filter (fun x => (movable s r).contains x) (List.takeWhile (fun x => x != k) s.record))) with
  | some p =>
    have hpm := List.mem_of_getLast? hr
    simp only [List.mem_filter, List.contains_iff_mem] at hpm
    have hpk : p ≠ k := by
      intro e; subst e
      have := (tw_sub' hpm.1).2
      simp at this
    simp only [hr, Option.some.injEq] at h
    subst h
    exact ⟨by simpa [Rel.target] using hpm.2, by simpa [Rel.target] using (tw_sub' hpm.1).1, by simpa [Rel.target] using hpk⟩
  | none =>
    cases hf : (List.find? (fun x => x != k && (movable s r).contains x) (List.dropWhile (fun x => x != k) s.record).tail) with
    | none => simp only [hr, hf, Option.map] at h; cases h
    | some t =>
      have ht := List.find?_some hf
      have htm := List.mem_of_find?_eq_some hf
      simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem] at ht
      have htr : t ∈ s.record := dw_sub' (List.mem_of_mem_tail htm)
      simp only [hr, hf, Option.map, Option.some.injEq] at h
      subst h
      exact ⟨by simpa [Rel.target] using ht.2, by simpa [Rel.target] using htr, by simpa [Rel.target] using ht.1⟩

theorem argmin_aux (f : Rel → Nat) : ∀ (l : List Rel) (b0 b : Rel),
    l.foldl (fun acc x => match acc with | none => some x | some b => if f x < f b then some x else acc) (some b0) = some b →
    (b = b0 ∨ b ∈ l) ∧ ∀ c, (c = b0 ∨ c ∈ l) → f b ≤ f c
  | [], b0, b, h => by
    simp at h; subst h; exact ⟨Or.inl rfl, fun c hc => by rcases hc with rfl | hc; exact Nat.le_refl _; simp at hc⟩
  | x :: l, b0, b, h => by
    simp only [List.foldl_cons] at h
    by_cases hx : f x < f b0
    · simp only [hx, ite_true] at h
      obtain ⟨h1, h2⟩ := argmin_aux f l x b h
      refine ⟨?_, fun c hc => ?_⟩
      · rcases h1 with rfl | h1
        · exact Or.inr (List.mem_cons_self)
        · exact Or.inr (List.mem_cons_of_mem _ h1)
      · rcases hc with rfl | hc
        · have := h2 x (Or.inl rfl); omega
        · rcases List.mem_cons.1 hc with rfl | hc
          · exact h2 _ (Or.inl rfl)
          · exact h2 c (Or.inr hc)
    · simp only [hx, ite_false] at h
      obtain ⟨h1, h2⟩ := argmin_aux f l b0 b h
      refine ⟨?_, fun c hc => ?_⟩
      · rcases h1 with rfl | h1
        · exact Or.inl rfl
        · exact Or.inr (List.mem_cons_of_mem _ h1)
      · rcases hc with rfl | hc
        · exact h2 _ (Or.inl rfl)
        · rcases List.mem_cons.1 hc with rfl | hc
          · have := h2 b0 (Or.inl rfl); omega
          · exact h2 c (Or.inr hc)

theorem argmin_spec {f : Rel → Nat} {l : List Rel} {b : Rel} (h : argmin f l = some b) : b ∈ l ∧ ∀ c ∈ l, f b ≤ f c := by
  unfold argmin at h
  cases l with
  | nil => simp at h
  | cons x l =>
    simp only [List.foldl_cons] at h
    obtain ⟨h1, h2⟩ := argmin_aux f l x b h
    refine ⟨?_, fun c hc => h2 c ?_⟩
    · rcases h1 with rfl | h1
      · exact List.mem_cons_self
      · exact List.mem_cons_of_mem _ h1
    · rcases List.mem_cons.1 hc with rfl | hc
      · exact Or.inl rfl
      · exact Or.inr hc

theorem argmin_isSome {f : Rel → Nat} {l : List Rel} (h : l ≠ []) : ∃ b, argmin f l = some b := by
  cases l with
  | nil => exact absurd rfl h
  | cons x l =>
    unfold argmin
    simp only [List.foldl_cons]
    generalize hq : (x :: l) = q
    clear hq
    suffices ∀ (l : List Rel) (b0 : Rel), ∃ b, l.foldl (fun acc x => match acc with | none => some x | some b => if f x < f b then some x else acc) (some b0) = some b from this l x
    intro l
    induction l with
    | nil => intro b0; exact ⟨b0, rfl⟩
    | cons y l ih =>
      intro b0
      simp only [List.foldl_cons]
      by_cases hy : f y < f b0
      · simp only [hy, ite_true]; exact ih y
      · simp only [hy, ite_false]; exact ih b0

/-- Every candidate drag names a movable record key other than `k`. -/
theorem fallbackCands_target {s : State} {r : Read} {k : Key} {rel : Rel} (h : rel ∈ fallbackCands s r k) :
    rel.target ∈ movable s r ∧ rel.target ∈ s.record ∧ rel.target ≠ k := by
  unfold fallbackCands at h
  rcases List.mem_append.1 h with h | h
  · cases hf : fallbackRel s r k with
    | none => simp [hf] at h
    | some q => simp [hf] at h; subst h; exact fallbackRel_target hf
  · simp only [List.mem_flatMap, List.mem_filter, Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem, decide_eq_true_eq] at h
    obtain ⟨t, ⟨ht1, ht2, ht3⟩, hr⟩ := h
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hr
    rcases hr with rfl | rfl <;> exact ⟨ht1, ht3, ht2⟩

theorem applyMove_flags (l : List Key) (k : Key) (rel : Rel) (s1 u1 s2 u2 : Bool) :
    applyMove l ⟨k, rel, s1, u1⟩ = applyMove l ⟨k, rel, s2, u2⟩ := rfl

/-- The fallback's move: the user's own move of the owed, misplaced `k`, to a movable record key other than `k`, whose WORST CASE (`worstCount`: the inversions of the movable record keys after the drag
plus the free keys' `penalty`) is STRICTLY lower than the inversions of the movable record keys now, and no other single drag of `k` (from the candidates) has a lower worst case.  The tenth component is the firing test. -/
theorem fallbackMove_basic {s : State} {r : Read} {k : Key} {a : Action} (h : fallbackMove s r k = some a) :
    a.user = true ∧ a.subject = k ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    a.strip = needsStrip s r a.subject a.rel ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ worstCount s r k a.rel < invCount s r r.drawn ∧ misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn ∧
    invCount s r (applyMove r.drawn a) < invCount s r r.drawn ∧
    ∀ rel ∈ fallbackCands s r k, worstCount s r k a.rel ≤ worstCount s r k rel := by
  simp only [fallbackMove] at h
  split at h
  · rename_i hc
    simp only [Bool.and_eq_true, List.contains_iff_mem] at hc
    obtain ⟨⟨⟨hco, hrk⟩, hmv⟩, hcm⟩ := hc
    cases hb : argmin (worstCount s r k) (fallbackCands s r k) with
    | none => simp [hb] at h
    | some rel =>
      simp only [hb, Option.map, Option.filter] at h
      split at h
      · rename_i hlt
        simp only [Option.some.injEq] at h; subst h
        simp only [decide_eq_true_eq] at hlt
        have hs := argmin_spec hb
        have ht := fallbackCands_target hs.1
        have hlt2 : afterCount s r k rel < invCount s r r.drawn := by
          unfold worstCount at hlt; omega
        refine ⟨rfl, rfl, ht.1, ht.2.1, ht.2.2, rfl, hco, hrk, hmv, hlt, hcm, ?_, ?_, fun c hc => hs.2 c hc⟩
        · intro heq
          unfold afterCount at hlt2
          simp only [applyMove_flags r.drawn k rel false true (needsStrip s r k rel) true] at hlt2
          simp only [heq] at hlt2
          exact Nat.lt_irrefl _ hlt2
        · unfold afterCount at hlt2
          simpa [applyMove_flags r.drawn k rel false true (needsStrip s r k rel) true] using hlt2
      · simp at h
  · simp at h

/-- The two phases make up `userMove`: the phase-one move if there is one, else the phase-two (fallback) move. -/
theorem userMove_phases (s : State) (r : Read) (k : Key) : userMove s r k = (userMove1 s r k).or (userMove2 s r k) := by
  by_cases hf : (foldedAll s r).contains k = true
  · have e1 : userMove1 s r k = userMove s r k := by unfold userMove1; rw [if_pos hf]
    have hc : ¬ ((userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k) = true := by rw [hf]; simp
    have e2 : userMove2 s r k = none := by unfold userMove2; rw [if_neg hc]
    rw [e1, e2]; cases userMove s r k <;> rfl
  · have hf' : (foldedAll s r).contains k = false := by simpa using hf
    by_cases hm : (movable s r).contains k = true
    · have e1 : userMove1 s r k = anchorMove s r k := by unfold userMove1; rw [if_neg hf, if_pos hm]
      have e0 : userMove s r k = (match anchorMove s r k with | some a => some a | none => fallbackMove s r k) := by
        unfold userMove; rw [if_neg hf, if_pos hm]; rfl
      rw [e0]
      cases ha : anchorMove s r k with
      | some a =>
        have hc : ¬ ((userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k) = true := by rw [e1, ha]; simp
        have e2 : userMove2 s r k = none := by unfold userMove2; rw [if_neg hc]
        rw [e1, e2, ha]; rfl
      | none =>
        have hc : ((userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k) = true := by rw [e1, ha, hf', hm]; simp
        have e2 : userMove2 s r k = fallbackMove s r k := by unfold userMove2; rw [if_pos hc]
        rw [e1, e2, ha]; rfl
    · have e1 : userMove1 s r k = none := by unfold userMove1; rw [if_neg hf, if_neg hm]
      have e0 : userMove s r k = none := by unfold userMove; rw [if_neg hf, if_neg hm]
      have hm' : (movable s r).contains k = false := by simpa using hm
      have hc : ¬ ((userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k) = true := by rw [hm']; simp
      have e2 : userMove2 s r k = none := by unfold userMove2; rw [if_neg hc]
      rw [e0, e1, e2]; rfl

theorem userPick_exists {s : State} {r : Read} {b : Action} (h : userPick s r = some b) :
    ∃ k, k ∈ s.foldRequest.toList ++ s.owedKeys ∧ (userMove s r k).filter (userAllowed s r) = some b := by
  unfold userPick at h
  split at h
  · rename_i b' hb
    simp only [Option.some.injEq] at h; subst h
    obtain ⟨k, hk, hk2⟩ := List.exists_of_findSome?_eq_some hb
    refine ⟨k, hk, ?_⟩
    rw [userMove_phases]
    cases h1 : userMove1 s r k with
    | none => simp [h1] at hk2
    | some c => simpa [h1] using hk2
  · obtain ⟨k, hk, hk2⟩ := List.exists_of_findSome?_eq_some h
    refine ⟨k, hk, ?_⟩
    rw [userMove_phases]
    cases h1 : userMove2 s r k with
    | none => simp [h1] at hk2
    | some c =>
      have hn : userMove1 s r k = none := by
        refine Classical.byContradiction fun hh => ?_
        have : (userMove1 s r k).isNone = false := by cases e : userMove1 s r k <;> simp_all
        simp [userMove2, this] at h1
      simpa [hn, h1] using hk2

theorem userPick_none {s : State} {r : Read} (h : userPick s r = none) :
    ∀ k ∈ s.foldRequest.toList ++ s.owedKeys, (userMove s r k).filter (userAllowed s r) = none := by
  intro k hk
  unfold userPick at h
  split at h
  · simp at h
  · rename_i hn
    have h1 := (List.findSome?_eq_none_iff.mp hn) k hk
    have h2 := (List.findSome?_eq_none_iff.mp h) k hk
    rw [userMove_phases]
    cases e1 : userMove1 s r k with
    | some c => simp [e1] at h1 ⊢; exact h1
    | none => simpa [e1] using h2

theorem userPick_head1 {s : State} {r : Read} {k : Key} {a : Action} (hfirst : (s.foldRequest.toList ++ s.owedKeys).head? = some k)
    (hum : userMove1 s r k = some a) (hal : userAllowed s r a = true) : userPick s r = some a := by
  obtain ⟨tl, htl⟩ : ∃ tl, (s.foldRequest.toList ++ s.owedKeys) = k :: tl := by
    cases hl : (s.foldRequest.toList ++ s.owedKeys) with
    | nil => simp [hl] at hfirst
    | cons x xs => simp [hl] at hfirst; exact ⟨xs, by rw [hfirst]⟩
  unfold userPick
  rw [htl]
  simp [List.findSome?, hum, Option.filter, hal]

/-- `wholeBar` is exactly "no free record key". -/
theorem wholeBar_iff_free (s : State) (r : Read) : wholeBar s r = true ↔ freeKeys s r = [] := by
  unfold wholeBar freeKeys
  rw [List.filter_eq_nil_iff, List.all_eq_true]
  apply forall_congr'; intro x
  apply forall_congr'; intro _
  generalize (r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) = L
  generalize (movable s r).contains x = m
  generalize (r.chevron == .fresh && r.foldedSet.contains x) = f
  cases L <;> cases m <;> cases f <;> simp

/-- **wholeBar_unlisted.**  Record keys that the read lists NOWHERE (not drawn, not in the pile, not folded, not unread: an app that is not running) never make `wholeBar` false:
appending any number of such keys to the record leaves `wholeBar` unchanged.  (`movable` does not depend on the record.) -/
theorem wholeBar_unlisted (s : State) (r : Read) (u : List Key)
    (hu : ∀ x ∈ u, r.drawn.contains x = false ∧ r.pile.contains x = false ∧ r.folded.contains x = false ∧ r.unread.contains x = false) :
    wholeBar { s with record := s.record ++ u } r = wholeBar s r := by
  unfold wholeBar
  have hm : movable { s with record := s.record ++ u } r = movable s r := rfl
  simp only [hm, List.all_append]
  have : u.all (fun x => !(r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) ||
      (movable s r).contains x || (r.chevron == .fresh && r.foldedSet.contains x)) = true := by
    rw [List.all_eq_true]; intro x hx
    obtain ⟨h1, h2, h3, h4⟩ := hu x hx
    rw [h1, h2, h3, h4]; rfl
  rw [this, Bool.and_true]

/-- With no free key the penalty is nil: `worstCount` is `afterCount`. -/
theorem penalty_wholeBar {s : State} {r : Read} (h : wholeBar s r = true) (k : Key) (rel : Rel) : penalty s r k rel = 0 := by
  have := (wholeBar_iff_free s r).1 h
  unfold penalty; rw [this]; rfl

theorem worstCount_wholeBar {s : State} {r : Read} (h : wholeBar s r = true) (k : Key) (rel : Rel) : worstCount s r k rel = afterCount s r k rel := by
  unfold worstCount; rw [penalty_wholeBar h]; rfl

/-! ### ejb.17: what `judge` changes

`judge` (Step.lean) overwrites only `hold`, `holdFolded`, `givenUp`, `strikes` and `verified`; it can only ADD to the hold and the given-up keys. -/

theorem judge_shape (s : State) (r : Read) :
    ∃ h hf g st v, judge s r = { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } ∧
      (s.hold = true → h = true) ∧ (∀ x, x ∈ s.givenUp → x ∈ g) := by
  unfold judge
  cases hv : s.verified with
  | none => exact ⟨s.hold, s.holdFolded, s.givenUp, s.strikes, none, by cases s; simp_all, fun h => h, fun x hx => hx⟩
  | some k =>
    simp only
    split
    · split
      · unfold markStrike
        exact ⟨s.hold, s.holdFolded, _, _, none, rfl, fun h => h, by intro x hx; simp; grind⟩
      · exact ⟨s.hold, s.holdFolded, s.givenUp, s.strikes, none, rfl, fun h => h, fun x hx => hx⟩
    · exact ⟨s.hold, s.holdFolded, s.givenUp, s.strikes, s.verified, by cases s; simp_all, fun h => h, fun x hx => hx⟩

@[simp] theorem judge_inFlight (s : State) (r : Read) : (judge s r).inFlight = s.inFlight := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_stripGrant (s : State) (r : Read) : (judge s r).stripGrant = s.stripGrant := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

theorem judge_gate (s : State) (r : Read) : (judge s r).gate r = s.gate r := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

theorem judge_userPick (s : State) (r : Read) : userPick (judge s r) r = userPick s r := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

theorem judge_engineAllowed {s : State} {r : Read} (h : engineAllowed (judge s r) r = true) : engineAllowed s r = true := by
  obtain ⟨hh, _, _, _, _, hj, h1, _⟩ := judge_shape s r
  rw [hj] at h
  simp only [engineAllowed, fullBar, cap, Bool.and_eq_true, Bool.not_eq_true'] at h ⊢
  grind

theorem judge_plan {s : State} {r : Read} {a : Action} (h : planOrderMoves (judge s r) r = some a) : planOrderMoves s r = some a := by
  obtain ⟨_, _, g, _, _, hj, _, h2⟩ := judge_shape s r
  have hm : movable (judge s r) r = movable s r := by rw [hj]; rfl
  have hn : ∀ w rel, needsStrip (judge s r) r w rel = needsStrip s r w rel := by intro w rel; rw [hj]; rfl
  have hr : (judge s r).record = s.record := by rw [hj]
  have hsk : (judge s r).skipped = s.skipped := by rw [hj]
  have hg : (judge s r).givenUp = g := by rw [hj]
  unfold planOrderMoves at h ⊢
  simp only [hm, hn, hr, hsk, hg] at h
  have h2' : ∀ x, s.givenUp.contains x = true → g.contains x = true := by
    intro x hx; simpa using h2 x (by simpa using hx)
  grind

/-- The judged state decides no move the unjudged one would not: `judge` only closes the engine's gates.  So whatever `decideMove` decides,
`decideMove0` (the decision on the state as it is) decides too. -/
theorem decide_judge {s : State} {r : Read} {a : Action} (h : decideMove s r = some a) : decideMove0 s r = some a := by
  unfold decideMove at h
  unfold decideMove0 at h ⊢
  rw [judge_inFlight, judge_gate, judge_userPick, judge_stripGrant] at h
  generalize hU : userPick s r = U at h ⊢
  cases U with
  | some b => simpa using h
  | none =>
    simp only at h ⊢
    split at h
    · simp at h
    · rename_i hn
      simp only [hn] at ⊢
      split at h
      · simp at h
      · rename_i hea
        have e1 : engineAllowed s r = true := judge_engineAllowed (by simpa using hea)
        simp only [e1]
        simp only [Bool.not_true, Bool.false_eq_true, if_false]
        revert h
        cases hp : planOrderMoves (judge s r) r with
        | none => simp
        | some b => simp [judge_plan hp]

/-! `noteRead` after `judge` agrees with `noteRead` alone on every field `judge` leaves alone. -/
theorem noteRead_patch_record (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).record = (noteRead s r).record := by
  unfold noteRead
  simp only [apply_ite State.record]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_record (s : State) (r : Read) : (noteRead (judge s r) r).record = (noteRead s r).record := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_record _ _ _ _ _ _ _

theorem noteRead_patch_moveCount (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).moveCount = (noteRead s r).moveCount := by
  unfold noteRead
  simp only [apply_ite State.moveCount]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_moveCount (s : State) (r : Read) : (noteRead (judge s r) r).moveCount = (noteRead s r).moveCount := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_moveCount _ _ _ _ _ _ _

theorem noteRead_patch_owedKeys (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).owedKeys = (noteRead s r).owedKeys := by
  unfold noteRead
  simp only [apply_ite State.owedKeys]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_owedKeys (s : State) (r : Read) : (noteRead (judge s r) r).owedKeys = (noteRead s r).owedKeys := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_owedKeys _ _ _ _ _ _ _

theorem noteRead_patch_foldRequest (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).foldRequest = (noteRead s r).foldRequest := by
  unfold noteRead
  simp only [apply_ite State.foldRequest]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_foldRequest (s : State) (r : Read) : (noteRead (judge s r) r).foldRequest = (noteRead s r).foldRequest := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_foldRequest _ _ _ _ _ _ _

theorem noteRead_patch_stripGrant (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).stripGrant = (noteRead s r).stripGrant := by
  unfold noteRead
  simp only [apply_ite State.stripGrant]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_stripGrant (s : State) (r : Read) : (noteRead (judge s r) r).stripGrant = (noteRead s r).stripGrant := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_stripGrant _ _ _ _ _ _ _

theorem noteRead_patch_restricted (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).restricted = (noteRead s r).restricted := by
  unfold noteRead
  simp only [apply_ite State.restricted]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_restricted (s : State) (r : Read) : (noteRead (judge s r) r).restricted = (noteRead s r).restricted := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_restricted _ _ _ _ _ _ _

theorem noteRead_patch_editSessionUsed (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).editSessionUsed = (noteRead s r).editSessionUsed := by
  unfold noteRead
  simp only [apply_ite State.editSessionUsed]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_editSessionUsed (s : State) (r : Read) : (noteRead (judge s r) r).editSessionUsed = (noteRead s r).editSessionUsed := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_editSessionUsed _ _ _ _ _ _ _

theorem noteRead_patch_skipped (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).skipped = (noteRead s r).skipped := by
  unfold noteRead
  simp only [apply_ite State.skipped]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_skipped (s : State) (r : Read) : (noteRead (judge s r) r).skipped = (noteRead s r).skipped := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_skipped _ _ _ _ _ _ _

theorem noteRead_patch_gen (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).gen = (noteRead s r).gen := by
  unfold noteRead
  simp only [apply_ite State.gen]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_gen (s : State) (r : Read) : (noteRead (judge s r) r).gen = (noteRead s r).gen := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_gen _ _ _ _ _ _ _

theorem noteRead_patch_flightOwed (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).flightOwed = (noteRead s r).flightOwed := by
  unfold noteRead
  simp only [apply_ite State.flightOwed]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_flightOwed (s : State) (r : Read) : (noteRead (judge s r) r).flightOwed = (noteRead s r).flightOwed := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_flightOwed _ _ _ _ _ _ _

theorem noteRead_patch_flightReq (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).flightReq = (noteRead s r).flightReq := by
  unfold noteRead
  simp only [apply_ite State.flightReq]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_flightReq (s : State) (r : Read) : (noteRead (judge s r) r).flightReq = (noteRead s r).flightReq := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_flightReq _ _ _ _ _ _ _

theorem noteRead_patch_inFlight (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).inFlight = (noteRead s r).inFlight := by
  unfold noteRead
  simp only [apply_ite State.inFlight]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_inFlight (s : State) (r : Read) : (noteRead (judge s r) r).inFlight = (noteRead s r).inFlight := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_inFlight _ _ _ _ _ _ _

theorem noteRead_patch_provenNotFull (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).provenNotFull = (noteRead s r).provenNotFull := by
  unfold noteRead
  simp only [apply_ite State.provenNotFull]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_provenNotFull (s : State) (r : Read) : (noteRead (judge s r) r).provenNotFull = (noteRead s r).provenNotFull := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_provenNotFull _ _ _ _ _ _ _

theorem noteRead_patch_noChevronReads (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).noChevronReads = (noteRead s r).noChevronReads := by
  unfold noteRead
  simp only [apply_ite State.noChevronReads]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_noChevronReads (s : State) (r : Read) : (noteRead (judge s r) r).noChevronReads = (noteRead s r).noChevronReads := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_noChevronReads _ _ _ _ _ _ _

theorem noteRead_patch_lastFreshPile (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).lastFreshPile = (noteRead s r).lastFreshPile := by
  unfold noteRead
  simp only [apply_ite State.lastFreshPile]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_lastFreshPile (s : State) (r : Read) : (noteRead (judge s r) r).lastFreshPile = (noteRead s r).lastFreshPile := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_lastFreshPile _ _ _ _ _ _ _

theorem noteRead_patch_lastDrawn (s : State) (r : Read) (h hf g st v) :
    (noteRead { s with hold := h, holdFolded := hf, givenUp := g, strikes := st, verified := v } r).lastDrawn = (noteRead s r).lastDrawn := by
  unfold noteRead
  simp only [apply_ite State.lastDrawn]
  split <;> (repeat' split) <;> simp_all

@[simp] theorem noteRead_judge_lastDrawn (s : State) (r : Read) : (noteRead (judge s r) r).lastDrawn = (noteRead s r).lastDrawn := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; exact noteRead_patch_lastDrawn _ _ _ _ _ _ _

@[simp] theorem judge_frame_record (s : State) (r : Read) : (judge s r).record = s.record := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_moveCount (s : State) (r : Read) : (judge s r).moveCount = s.moveCount := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_owedKeys (s : State) (r : Read) : (judge s r).owedKeys = s.owedKeys := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_foldRequest (s : State) (r : Read) : (judge s r).foldRequest = s.foldRequest := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_stripGrant (s : State) (r : Read) : (judge s r).stripGrant = s.stripGrant := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_restricted (s : State) (r : Read) : (judge s r).restricted = s.restricted := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_editSessionUsed (s : State) (r : Read) : (judge s r).editSessionUsed = s.editSessionUsed := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_skipped (s : State) (r : Read) : (judge s r).skipped = s.skipped := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_gen (s : State) (r : Read) : (judge s r).gen = s.gen := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_flightOwed (s : State) (r : Read) : (judge s r).flightOwed = s.flightOwed := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_flightReq (s : State) (r : Read) : (judge s r).flightReq = s.flightReq := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_provenNotFull (s : State) (r : Read) : (judge s r).provenNotFull = s.provenNotFull := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_noChevronReads (s : State) (r : Read) : (judge s r).noChevronReads = s.noChevronReads := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_lastFreshPile (s : State) (r : Read) : (judge s r).lastFreshPile = s.lastFreshPile := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

@[simp] theorem judge_frame_lastDrawn (s : State) (r : Read) : (judge s r).lastDrawn = s.lastDrawn := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]

theorem judge_frame (s : State) (r : Read) :
    (judge s r).record = s.record ∧ (judge s r).moveCount = s.moveCount ∧ (judge s r).owedKeys = s.owedKeys ∧ (judge s r).foldRequest = s.foldRequest ∧ (judge s r).stripGrant = s.stripGrant ∧ (judge s r).restricted = s.restricted ∧ (judge s r).editSessionUsed = s.editSessionUsed ∧ (judge s r).skipped = s.skipped ∧ (judge s r).gen = s.gen ∧ (judge s r).flightOwed = s.flightOwed ∧ (judge s r).flightReq = s.flightReq ∧ (judge s r).inFlight = s.inFlight ∧ (judge s r).provenNotFull = s.provenNotFull ∧ (judge s r).noChevronReads = s.noChevronReads ∧ (judge s r).lastFreshPile = s.lastFreshPile ∧ (judge s r).lastDrawn = s.lastDrawn := by
  exact ⟨by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp, by simp⟩

@[simp] theorem judge_fullBar (s : State) (r : Read) : fullBar (judge s r) r = fullBar s r := by
  simp [fullBar]

theorem judge_hold_true {s : State} (r : Read) (h : s.hold = true) : (judge s r).hold = true := by
  obtain ⟨_, _, _, _, _, hj, h1, _⟩ := judge_shape s r; rw [hj]; exact h1 h

theorem judge_givenUp_mem {s : State} (r : Read) {x : Key} (h : x ∈ s.givenUp) : x ∈ (judge s r).givenUp := by
  obtain ⟨_, _, g, _, _, hj, _, h2⟩ := judge_shape s r; rw [hj]; exact h2 x h

theorem judge_userMove1 (s : State) (r : Read) (k : Key) : userMove1 (judge s r) r k = userMove1 s r k := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

theorem judge_userMove2 (s : State) (r : Read) (k : Key) : userMove2 (judge s r) r k = userMove2 s r k := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

theorem judge_userMove (s : State) (r : Read) (k : Key) : userMove (judge s r) r k = userMove s r k := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

theorem judge_userAllowed (s : State) (r : Read) (a : Action) : userAllowed (judge s r) r a = userAllowed s r a := by
  obtain ⟨_, _, _, _, _, hj, _, _⟩ := judge_shape s r; rw [hj]; rfl

/-- A decision made by the user's queue is the same on the judged state. -/
theorem decide_of_pick {s : State} {r : Read} {a : Action} (hp : userPick s r = some a) (hd : decideMove0 s r = some a) :
    decideMove s r = some a := by
  unfold decideMove0 at hd
  unfold decideMove decideMove0
  rw [judge_inFlight, judge_gate, judge_userPick, hp]
  rw [hp] at hd
  exact hd

theorem decide_user_pick {s : State} {r : Read} {a : Action}
    (hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true)
    (hp : userPick s r = some a) : decideMove s r = some a :=
  decide_of_pick hp (by unfold decideMove0; rw [if_neg hc, hp])

end Sommelier
