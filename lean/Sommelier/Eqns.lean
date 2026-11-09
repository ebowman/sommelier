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
  unfold result; grind

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

/-- The fallback's move: the user's own move of the owed, misplaced `k`, to a movable record key other than `k`, leaving STRICTLY fewer inversions than the bar has now,
and no other single drag of `k` (from the candidates) leaves fewer. -/
theorem fallbackMove_basic {s : State} {r : Read} {k : Key} {a : Action} (h : fallbackMove s r k = some a) :
    a.user = true ∧ a.subject = k ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    a.strip = needsStrip s r a.subject a.rel ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ wholeBar s r = true ∧ misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn ∧
    invCount s r (applyMove r.drawn a) < invCount s r r.drawn ∧
    ∀ rel ∈ fallbackCands s r k, invCount s r (applyMove r.drawn ⟨k, a.rel, false, true⟩) ≤ invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) := by
  simp only [fallbackMove] at h
  split at h
  · rename_i hc
    simp only [Bool.and_eq_true, List.contains_iff_mem] at hc
    obtain ⟨⟨⟨⟨hco, hrk⟩, hmv⟩, hwb⟩, hcm⟩ := hc
    cases hb : argmin (afterCount s r k) (fallbackCands s r k) with
    | none => simp [hb] at h
    | some rel =>
      simp only [hb, Option.map, Option.filter] at h
      split at h
      · rename_i hlt
        simp only [Option.some.injEq] at h; subst h
        simp only [decide_eq_true_eq] at hlt
        have hs := argmin_spec hb
        have ht := fallbackCands_target hs.1
        refine ⟨rfl, rfl, ht.1, ht.2.1, ht.2.2, rfl, hco, hrk, hmv, hwb, hcm, ?_, ?_, fun c hc => hs.2 c hc⟩
        · intro heq
          unfold afterCount at hlt
          simp only [applyMove_flags r.drawn k rel false true (needsStrip s r k rel) true] at hlt
          simp only [heq] at hlt
          exact Nat.lt_irrefl _ hlt
        · unfold afterCount at hlt
          simpa [applyMove_flags r.drawn k rel false true (needsStrip s r k rel) true] using hlt
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

end Sommelier
