import Sommelier.Eqns

/-!
# Sommelier decision core: the gates actually gate (ejb.3)

`Safety.lean` proves bounds that follow from the code's shape.  This file states what each gate DOES to the
engine's output, so that deleting the gate makes the statement false: a set hold, an open strip, a stale
chevron, a spent budget and a given-up key each yield no non-user action; a chevron means full; plans come
only from good reads; the folded memory is replaced or added to by exactly the named reads and the proof
clears it; a failed posted drag holds and gives up; user events release, reset and grant; one attempt per
drop; a pull-out only on request; every subject is in the record.

This file imports only `Step` (not `Safety`): a mutant that breaks a `Safety.lean` proof positionally cannot
mask a theorem here, and `lean/scripts/mutants.py` builds this file on its own to credit the kill.
Core tactics only (`simp`, `grind`, `omega`).
-/

set_option linter.unusedSimpArgs false
set_option linter.deprecated false
set_option linter.unusedVariables false

namespace Sommelier

/-! ### Shape lemmas: where an action comes from -/

theorem gate_step_acts {s : State} {e : Event} {a : Action} (h : a ∈ (step s e).2) :
    ∃ r, e = .read r ∧ decideMove s r = some a ∧ step s e = (emit (noteRead s r) a, [a]) := by
  cases e with
  | read r =>
    refine ⟨r, rfl, ?_⟩
    simp only [step] at h ⊢
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

/-- `decideMove` answers either an owed user move (the fold request first, then the rest), or a gated engine move. -/
theorem gate_decide_cases {s : State} {r : Read} {a : Action} (h : decideMove s r = some a) :
    s.inFlight = none ∧
    ((∃ k, (k ∈ s.foldRequest.toList ∨ k ∈ s.owedKeys) ∧ userMove s r k = some a ∧ userAllowed s r a = true) ∨
     (engineAllowed s r = true ∧ ∃ b, planOrderMoves s r = some b ∧
        ((b.strip = false ∧ a = b) ∨ (b.strip = true ∧ s.stripGrant = true ∧ a = { b with user := true })))) := by
  simp only [decideMove] at h
  split at h
  · simp at h
  · rename_i hc
    have hc' : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome) = true :=
      fun hh => hc (by rw [Bool.or_eq_true]; exact Or.inl hh)
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true', bne_iff_ne, ne_eq, beq_iff_eq,
      Bool.not_eq_false'] at hc'
    obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := hc'
    refine ⟨?_, ?_⟩
    · cases hi : s.inFlight with
      | none => rfl
      | some x => simp [hi] at h4
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

theorem gate_userMove_user {s : State} {r : Read} {k : Key} {a : Action} (h : userMove s r k = some a) :
    a.user = true ∧ a.subject = k := by
  simp only [userMove] at h
  split at h
  · split at h
    · cases hg : List.getLast? (List.filter (fun x => (List.takeWhile (fun x => x != k) s.record).contains x) (movable s r)) with
      | none => simp only [hg, Option.map, Option.filter] at h; cases h
      | some p =>
        simp only [hg, Option.map, Option.filter] at h
        split at h
        · simp at h; subst h; simp
        · simp at h
    · simp at h
  · split at h
    · split at h
      · rename_i a' ha'
        simp only [Option.some.injEq] at h; subst h
        exact ⟨(anchorMove_basic ha').1, (anchorMove_basic ha').2.1⟩
      · exact ⟨(fallbackMove_basic h).1, (fallbackMove_basic h).2.1⟩
    · simp at h

/-- Every engine (non-user) action is the planner's, on an allowed read. -/
theorem gate_engine_action {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hu : a.user = false) :
    engineAllowed s r = true ∧ planOrderMoves s r = some a := by
  obtain ⟨r', he, hd, _⟩ := gate_step_acts h
  cases he
  rcases (gate_decide_cases hd).2 with ⟨k, _, hk, _⟩ | ⟨hea, b, hb, hh⟩
  · have := (gate_userMove_user hk).1
    simp [this] at hu
  · refine ⟨hea, ?_⟩
    rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
    · exact hb
    · simp at hu

/-! ### 1. The gates stop the engine -/

/-- A closed engine gate leaves only user-labelled actions. -/
theorem gate_closed_user {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hn : engineAllowed s r = false) : a.user = true := by
  cases hu : a.user with
  | true => rfl
  | false => have := (gate_engine_action h hu).1; simp [hn] at this

theorem eng_no_hold {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hold : s.hold = true) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, hold])

theorem eng_no_open {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (open_ : r.stripOpen = true) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, open_])

theorem eng_no_stale {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (stale : r.chevron = .stale) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, stale])

theorem eng_no_restricted {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hr : s.restricted = true) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, hr])

/-- A spent budget: 3 posted engine drags on a bar not proven not-full, 20 on a proven one. -/
theorem eng_no_budget_full {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hf : fullBar s r = true) (hc : 3 ≤ s.moveCount) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, hf, cap, capFull]; omega)

theorem eng_no_budget_notfull {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hf : fullBar s r = false) (hc : 20 ≤ s.moveCount) : a.user = true :=
  gate_closed_user h (by simp [engineAllowed, hf, cap, capNotFull]; omega)

/-- Within the budget the gate is open: a spent budget is exactly what closes it (the converse of the two above). -/
theorem eng_budget_exact {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hu : a.user = false) :
    s.moveCount < (if fullBar s r = true then 3 else 20) := by
  have := (gate_engine_action h hu).1
  simp [engineAllowed, cap, capFull, capNotFull] at this
  split <;> simp_all

/-- A given-up or skipped key is never the subject of an engine move. -/
theorem plan_no_givenUp {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hu : a.user = false) : a.subject ∉ s.givenUp := by
  have hp := (gate_engine_action h hu).2
  simp only [planOrderMoves] at hp
  split at hp
  · split at hp
    · simp at hp
    · rename_i hn
      simp at hp; subst hp
      simp at hn
      exact hn.1
  · simp at hp

theorem plan_no_skipped {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hu : a.user = false) : a.subject ∉ s.skipped := by
  have hp := (gate_engine_action h hu).2
  simp only [planOrderMoves] at hp
  split at hp
  · split at hp
    · simp at hp
    · rename_i hn
      simp at hp; subst hp
      simp at hn
      exact hn.2
  · simp at hp

/-! ### 2. Any chevron in a read means full -/

theorem fullBar_ignores_chevron (s : State) (r : Read) (h : r.chevron ≠ .absent) : fullBar s r = true := by
  simp [fullBar, h]

/-- ... so on a read with a chevron the engine's budget is the FULL one, proven or not. -/
theorem chevron_engine_budget {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hc : r.chevron ≠ .absent) (hu : a.user = false) : s.moveCount < 3 := by
  have := eng_budget_exact h hu
  simp [fullBar_ignores_chevron s r hc] at this
  exact this

/-! ### 3. Plans only on good reads -/

theorem plan_on_good_read {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) :
    r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ s.inFlight = none := by
  obtain ⟨r', he, hd, _⟩ := gate_step_acts h
  cases he
  simp only [decideMove] at hd
  split at hd
  · simp at hd
  · rename_i hc
    have hc' : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome) = true :=
      fun hh => hc (by rw [Bool.or_eq_true]; exact Or.inl hh)
    simp only [Bool.or_eq_true, not_or, Bool.not_eq_true', bne_iff_ne, ne_eq, beq_iff_eq,
      Bool.not_eq_false'] at hc'
    obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := hc'
    refine ⟨by simpa using h1, by simpa using h2, h3, ?_⟩
    cases hi : s.inFlight with
    | none => rfl
    | some x => simp [hi] at h4

theorem plan_on_poll {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) : r.kind = .pass :=
  (plan_on_good_read h).1
theorem plan_unsettled {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) : r.settled = true :=
  (plan_on_good_read h).2.1
theorem plan_incomplete {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) : r.level ≠ .incomplete :=
  (plan_on_good_read h).2.2.1

/-! ### 4. The folded memory: which reads replace the pile, which add to it, and the proof clears it -/

/-- A settled, readable, strip-closed read with a fresh chevron REPLACES the pile. -/
theorem pile_replace (s : State) (r : Read) (hc : r.chevron = .fresh) (h1 : r.settled = true)
    (h2 : r.level ≠ .incomplete) (h3 : r.stripOpen = false) :
    (noteRead s r).lastFreshPile = r.foldedSet := by
  simp [noteRead, hc, h1, h2, h3]

/-- Any other fresh-chevron read only ADDS to it. -/
theorem pile_fresh_add (s : State) (r : Read) (hc : r.chevron = .fresh)
    (hbad : r.settled = false ∨ r.level = .incomplete ∨ r.stripOpen = true) (k : Key) :
    k ∈ (noteRead s r).lastFreshPile ↔ k ∈ s.lastFreshPile ∨ k ∈ r.foldedSet := by
  have : (r.settled && decide (r.level ≠ .incomplete) && !r.stripOpen) = false := by
    rcases hbad with h | h | h <;> simp [h]
  simp [noteRead, hc, this]
  grind

/-- A stale chevron only ADDS to the pile (it never replaces it, and it is never ignored). -/
theorem pile_stale_add (s : State) (r : Read) (hc : r.chevron = .stale) (k : Key) :
    k ∈ (noteRead s r).lastFreshPile ↔ k ∈ s.lastFreshPile ∨ k ∈ r.foldedSet := by
  simp [noteRead, hc]
  grind

/-- The proof that the bar is not full clears the folded memory ... -/
theorem proof_clears_pile (s : State) (r : Read) (h0 : s.provenNotFull = false)
    (h1 : (noteRead s r).provenNotFull = true) : (noteRead s r).lastFreshPile = [] := by
  unfold noteRead at *
  grind

/-- ... and releases the hold. -/
theorem proof_clears_hold (s : State) (r : Read) (h0 : s.provenNotFull = false)
    (h1 : (noteRead s r).provenNotFull = true) : (noteRead s r).hold = false := by
  unfold noteRead at *
  grind

/-- A chevronless read that does not complete the proof leaves the pile as it was. -/
theorem pile_absent_keeps (s : State) (r : Read) (hc : r.chevron = .absent)
    (hn : ¬ (s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true)) :
    (noteRead s r).lastFreshPile = s.lastFreshPile := by
  unfold noteRead at *
  grind

/-! ### 5. A failed posted drag holds and gives up; user events release -/

theorem res_count_exact (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).moveCount = s.moveCount + (if p = true ∧ a.user = false then 1 else 0) := by
  unfold result; grind

/-- A failed POSTED drag on a bar not proven not-full holds the bar ... -/
theorem res_failed_holds (s : State) (a : Action) (hp : s.provenNotFull = false) :
    (result s a .failed true).hold = true ∧ (result s a .failed true).holdFolded = s.lastFreshPile := by
  unfold result; simp [hp]

/-- ... and gives its key up, without a strike. -/
theorem res_failed_gives_up (s : State) (a : Action) (hp : s.provenNotFull = false) :
    a.subject ∈ (result s a .failed true).givenUp := by
  unfold result; simp [hp]; grind

theorem res_failed_no_strike (s : State) (a : Action) (hp : s.provenNotFull = false) :
    (result s a .failed true).strikes = s.strikes := by
  unfold result; simp [hp]

/-- On a bar proven not full a failed posted drag takes a strike and does NOT hold. -/
theorem res_proven_no_hold (s : State) (a : Action) (hp : s.provenNotFull = true) :
    (result s a .failed true).hold = s.hold := by
  unfold result; simp [hp]

theorem res_proven_strike (s : State) (a : Action) (hp : s.provenNotFull = true) :
    (result s a .failed true).strikes = a.subject :: s.strikes := by
  unfold result; simp [hp]

/-- ... and gives the key up exactly at the third strike. -/
theorem res_proven_giveup (s : State) (a : Action) (hp : s.provenNotFull = true) :
    a.subject ∈ (result s a .failed true).givenUp ↔
      a.subject ∈ s.givenUp ∨ 2 ≤ (s.strikes.filter (fun x => x == a.subject)).length := by
  unfold result; simp [hp]; grind

theorem res_proven_giveup_other (s : State) (a : Action) (hp : s.provenNotFull = true) (j : Key)
    (hj : j ≠ a.subject) : j ∈ (result s a .failed true).givenUp ↔ j ∈ s.givenUp := by
  unfold result; simp [hp]; grind

/-- Anything else that ends a drag changes none of hold, strikes, given-up keys. -/
theorem res_other_keeps (s : State) (a : Action) (o : Outcome) (p : Bool) (h : p = false ∨ o ≠ .failed) :
    (result s a o p).hold = s.hold ∧ (result s a o p).strikes = s.strikes ∧ (result s a o p).givenUp = s.givenUp := by
  unfold result; grind

/-- User events.  `userEdit` with moved keys: the budget is reset, the engine is restricted, a new strip session. -/
theorem edit_budget_reset (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.moveCount = 0 := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

theorem edit_restricts (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.restricted = true := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

theorem edit_new_session (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.editSessionUsed = false := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

theorem edit_clears_skipped (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.skipped = [] := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

theorem edit_strikes (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.strikes = s.strikes.filter (fun k => !moved.contains k) := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

/-- A drop forgives exactly the keys it moved. -/
theorem edit_givenUp (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.givenUp = s.givenUp.filter (fun k => !moved.contains k) := by
  cases moved with | nil => contradiction | cons x xs => simp [step]

/-- The hold survives an edit unless a moved key touches the keys folded when it was set, or the current pile. -/
theorem edit_hold (s : State) (rec moved : List Key) (hm : moved ≠ []) :
    (step s (.userEdit rec moved)).1.hold = true ↔
      s.hold = true ∧ ∀ k ∈ moved, k ∉ s.holdFolded ∧ k ∉ s.lastFreshPile := by
  cases moved with
  | nil => contradiction
  | cons x xs =>
    simp [step]

/-- An edit that moves nothing changes none of the user-event state (the budget, the hold, the restriction). -/
theorem edit_empty_keeps (s : State) (rec : List Key) :
    (step s (.userEdit rec [])).1.moveCount = s.moveCount ∧ (step s (.userEdit rec [])).1.hold = s.hold ∧
    (step s (.userEdit rec [])).1.restricted = s.restricted ∧ (step s (.userEdit rec [])).1.givenUp = s.givenUp := by
  simp [step]

/-- Re-apply clears everything that stopped the engine, and grants one strip session. -/
theorem retry_clears_hold (s : State) : (step s .userRetry).1.hold = false := by simp [step]
theorem retry_clears_givenUp (s : State) : (step s .userRetry).1.givenUp = [] := by simp [step]
theorem retry_clears_strikes (s : State) : (step s .userRetry).1.strikes = [] := by simp [step]
theorem retry_clears_skipped (s : State) : (step s .userRetry).1.skipped = [] := by simp [step]
theorem retry_resets_budget (s : State) : (step s .userRetry).1.moveCount = 0 := by simp [step]
theorem retry_unrestricts (s : State) : (step s .userRetry).1.restricted = false := by simp [step]
theorem retry_grants (s : State) : (step s .userRetry).1.stripGrant = true := by simp [step]
theorem retry_clears_owed (s : State) :
    (step s .userRetry).1.owedKeys = [] ∧ (step s .userRetry).1.foldRequest = none := by simp [step]
theorem retry_new_session (s : State) : (step s .userRetry).1.editSessionUsed = false := by simp [step]

/-- The per-row "Try again" forgives its key only; it restricts the engine and never grants a session. -/
theorem rk_clears_hold (s : State) (k : Key) : (step s (.retryKey k)).1.hold = false := by simp [step]
theorem rk_resets_budget (s : State) (k : Key) : (step s (.retryKey k)).1.moveCount = 0 := by simp [step]
theorem rk_givenUp (s : State) (k : Key) : (step s (.retryKey k)).1.givenUp = s.givenUp.erase k := by simp [step]
theorem rk_strikes (s : State) (k : Key) :
    (step s (.retryKey k)).1.strikes = s.strikes.filter (fun x => x != k) := by simp [step]
theorem rk_clears_skipped (s : State) (k : Key) : (step s (.retryKey k)).1.skipped = [] := by simp [step]
theorem rk_restricts (s : State) (k : Key) : (step s (.retryKey k)).1.restricted = true := by simp [step]
theorem rk_new_session (s : State) (k : Key) : (step s (.retryKey k)).1.editSessionUsed = false := by simp [step]
theorem rk_no_grant (s : State) (k : Key) : (step s (.retryKey k)).1.stripGrant = s.stripGrant := by simp [step]

/-! ### 6. One attempt per drop -/

theorem gate_eraseDups_nodup : ∀ (n : Nat) (l : List Key), l.length ≤ n → l.eraseDups.Nodup
  | 0, l, h => by
    have : l = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this; simp [List.eraseDups]
  | n+1, [], _ => by simp [List.eraseDups]
  | n+1, a :: as, h => by
    rw [List.eraseDups_cons]
    have ih := gate_eraseDups_nodup n (as.filter (fun b => !b == a)) (by
      have := List.length_filter_le (fun b => !b == a) as
      simp at h; omega)
    rw [List.nodup_cons]
    refine ⟨?_, ih⟩
    rw [List.mem_eraseDups, List.mem_filter]
    simp

theorem gate_filter_nodup (p : Key → Bool) (l : List Key) (h : l.Nodup) : (l.filter p).Nodup :=
  List.Nodup.sublist (List.filter_sublist) h

theorem noteRead_keeps (s : State) (r : Read) :
    (noteRead s r).owedKeys = s.owedKeys ∧ (noteRead s r).foldRequest = s.foldRequest ∧
    (noteRead s r).record = s.record ∧ (noteRead s r).inFlight = s.inFlight ∧
    (noteRead s r).flightReq = s.flightReq ∧ (noteRead s r).flightOwed = s.flightOwed ∧
    (noteRead s r).gen = s.gen ∧ (noteRead s r).restricted = s.restricted ∧
    (noteRead s r).moveCount = s.moveCount ∧ (noteRead s r).givenUp = s.givenUp ∧
    (noteRead s r).skipped = s.skipped ∧ (noteRead s r).editSessionUsed = s.editSessionUsed ∧
    (noteRead s r).stripGrant = s.stripGrant ∧ (noteRead s r).holdFolded = s.holdFolded ∧
    (noteRead s r).strikes = s.strikes := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩ <;> (unfold noteRead; grind)

theorem result_owed_cases (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).owedKeys = s.owedKeys ∨ (result s a o p).owedKeys = (a.subject :: s.owedKeys).eraseDups := by
  unfold result; grind

theorem result_req_cases (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).foldRequest = s.foldRequest ∨ (result s a o p).foldRequest = some a.subject := by
  unfold result; grind

/-- Owed keys are listed once. -/
theorem owed_nodup_step {s : State} (h : s.owedKeys.Nodup) (e : Event) : (step s e).1.owedKeys.Nodup := by
  cases e with
  | read r =>
    have nk := noteRead_keeps s r
    simp only [step]
    cases hd : decideMove s r with
    | none => simp [nk.1, h]
    | some a =>
      simp only [emit, nk.1]
      exact List.Nodup.erase _ h
  | userEdit rec moved =>
    simp only [step]
    split
    · exact gate_filter_nodup _ _ h
    · exact gate_filter_nodup _ _ (gate_eraseDups_nodup _ _ (Nat.le_refl _))
  | userRetry => simp [step]
  | retryKey k => simp only [step]; exact gate_filter_nodup _ _ (gate_eraseDups_nodup _ _ (Nat.le_refl _))
  | moveResult k o p =>
    simp only [step]
    split
    · split
      · rcases result_owed_cases s _ o p with h' | h'
        · rw [h']; exact h
        · rw [h']; exact gate_eraseDups_nodup _ _ (Nat.le_refl _)
      · exact h
    · exact h
  | passBoundary => simp [step]

theorem owed_nodup_run {s : State} (h : s.owedKeys.Nodup) (es : List Event) : (run s es).1.owedKeys.Nodup := by
  induction es generalizing s with
  | nil => simpa [run] using h
  | cons e es ih => simp only [run]; exact ih (owed_nodup_step h e)

theorem owed_nodup_init (rec : List Key) (es : List Event) : (run (State.init rec) es).1.owedKeys.Nodup :=
  owed_nodup_run (by simp [State.init]) es

/-- Once a key's move leaves, it is no longer owed and no longer the fold request: the drop gets ONE attempt. -/
theorem emit_consumes {s : State} {r : Read} {a : Action} (hn : s.owedKeys.Nodup)
    (h : a ∈ (step s (.read r)).2) :
    a.subject ∉ (step s (.read r)).1.owedKeys ∧ (step s (.read r)).1.foldRequest ≠ some a.subject := by
  obtain ⟨r', he, hd, hs⟩ := gate_step_acts h
  cases he
  rw [hs]
  have nk := noteRead_keeps s r
  refine ⟨?_, ?_⟩
  · simp only [emit, nk.1]
    intro hm
    have := (List.Nodup.mem_erase_iff hn).1 hm
    exact this.1 rfl
  · simp only [emit, nk.2.1]
    split <;> simp_all

/-- The move that leaves records whether its subject was owed by the current chain, and whether it was the fold request. -/
theorem emit_flight_owed {s : State} (a : Action) (g : Nat) :
    (emit s a).flightOwed = some g ↔ a.subject ∈ s.owedKeys ∧ g = s.gen := by
  simp only [emit]
  split <;> simp_all [eq_comm]

theorem emit_flightReq (s : State) (a : Action) :
    (emit s a).flightReq = true ↔ s.foldRequest = some a.subject := by
  simp [emit]

/-- When a drag ends with no mouse event, its user's key is re-armed once and only under these conditions. -/
def Rearm (s : State) (a : Action) (o : Outcome) (p : Bool) : Prop :=
  p = false ∧ o = .busy ∧ s.flightOwed = some s.gen ∧ a.subject ∉ s.skipped ∧ a.subject ∈ s.record

theorem rearm_iff (s : State) (a : Action) (o : Outcome) (p : Bool) (j : Key) :
    j ∈ (result s a o p).owedKeys ↔ j ∈ s.owedKeys ∨ (j = a.subject ∧ Rearm s a o p) := by
  unfold result Rearm
  by_cases hp : p = true
  · simp [hp]; grind
  · have hp' : p = false := by simpa using hp
    subst hp'
    by_cases hc : o = .busy ∧ s.flightOwed = some s.gen ∧ a.subject ∉ s.skipped ∧ a.subject ∈ s.record
    · have hc' : (o == .busy && s.flightOwed == some s.gen && !decide (a.subject ∈ s.skipped) && decide (a.subject ∈ s.record)) = true := by
        simp [hc]
      simp [hc, List.mem_eraseDups]
      grind
    · have hc' : ¬ (o == .busy && s.flightOwed == some s.gen && !decide (a.subject ∈ s.skipped) && decide (a.subject ∈ s.record)) = true := by
        simp; grind
      simp [hc]
      grind

open Classical in
theorem rearm_request (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).foldRequest =
      if Rearm s a o p ∧ s.flightReq = true ∧ s.foldRequest = none then some a.subject else s.foldRequest := by
  unfold result Rearm
  by_cases hp : p = true
  · cases o <;> simp [hp] <;> split <;> simp
  · have hp' : p = false := by simpa using hp
    subst hp'
    by_cases hc : o = .busy ∧ s.flightOwed = some s.gen ∧ a.subject ∉ s.skipped ∧ a.subject ∈ s.record
    · simp [hc]
    · have hc2 : ¬ (((o = Outcome.busy ∧ s.flightOwed = some s.gen) ∧ a.subject ∉ s.skipped) ∧ a.subject ∈ s.record) := by
        grind
      simp [hc2]
      grind

/-! ### 7. A pull-out is asked for only on request, and a request is not lost silently -/

theorem edit_request_origin (s : State) (rec moved : List Key) (hm : moved ≠ []) (p : Key)
    (h : (step s (.userEdit rec moved)).1.foldRequest = some p) :
    (p ∈ moved ∧ p ∈ rec ∧ p ∈ s.lastFreshPile ∧ ∃ x ∈ rec.takeWhile (fun x => x != p), x ∈ s.lastDrawn) ∨
    (s.foldRequest = some p ∧ p ∉ moved ∧ p ∈ rec) := by
  cases moved with
  | nil => contradiction
  | cons x xs =>
    simp only [step, List.isEmpty_cons, Bool.false_eq_true, ↓reduceIte] at h
    cases hf : rec.find? (fun k => (x :: xs).contains k && s.lastFreshPile.contains k &&
        (rec.takeWhile (fun y => y != k)).any (fun y => s.lastDrawn.contains y)) with
    | some q =>
      simp only [hf, Option.some.injEq] at h
      subst h
      have := List.find?_some hf
      have hq := List.mem_of_find?_eq_some hf
      simp at this
      left
      refine ⟨by simpa using this.1.1, hq, by simpa using this.1.2, ?_⟩
      obtain ⟨y, hy, hy2⟩ := this.2
      exact ⟨y, by simpa using hy, by simpa using hy2⟩
    | none =>
      simp only [hf] at h
      right
      cases hr : s.foldRequest with
      | none => simp [hr] at h
      | some q =>
        simp [hr, Option.filter] at h
        grind

/-- The converse: a moved key that is folded now and has a drawn key before it in the record DOES ask for a pull-out. -/
theorem edit_requests_pull (s : State) (rec moved : List Key) (q : Key) (hq : q ∈ rec) (hqm : q ∈ moved)
    (hf : q ∈ s.lastFreshPile) (hd : ∃ x ∈ rec.takeWhile (fun x => x != q), x ∈ s.lastDrawn) :
    (step s (.userEdit rec moved)).1.foldRequest ≠ none := by
  cases moved with
  | nil => simp at hqm
  | cons x xs =>
    simp only [step, List.isEmpty_cons]
    cases hf' : rec.find? (fun k => (x :: xs).contains k && s.lastFreshPile.contains k &&
        (rec.takeWhile (fun y => y != k)).any (fun y => s.lastDrawn.contains y)) with
    | some q' => simp
    | none =>
      exfalso
      have h1 := List.find?_eq_none.1 hf' q hq
      obtain ⟨y, hy, hy2⟩ := hd
      apply h1
      simp [hqm, hf]
      exact ⟨y, by simpa using hy, by simpa using hy2⟩

/-- A later edit that moves the key whose pull-out is in flight clears the flight's claim on the request. -/
theorem edit_flightReq (s : State) (rec moved : List Key) (hm : moved ≠ []) (a : Action)
    (hf : s.inFlight = some a) (ha : a.subject ∈ moved) : (step s (.userEdit rec moved)).1.flightReq = false := by
  cases moved with
  | nil => contradiction
  | cons x xs => simp [step, hf, ha]; grind

/-- An edit that moves nothing but reorders the record also drops the claim. -/
theorem edit_empty_flightReq (s : State) (rec : List Key) (h : rec ≠ s.record) :
    (step s (.userEdit rec [])).1.flightReq = false := by
  simp [step, h]

theorem rk_flightReq (s : State) (k : Key) (a : Action) (hf : s.inFlight = some a) (ha : a.subject = k) :
    (step s (.retryKey k)).1.flightReq = false := by
  simp [step, hf, ha]

/-! ### 9. Subjects are in the record -/

theorem edit_owed (s : State) (rec moved : List Key) (hm : moved ≠ []) (j : Key) :
    j ∈ (step s (.userEdit rec moved)).1.owedKeys ↔ j ∈ rec ∧ (j ∈ s.owedKeys ∨ j ∈ moved) := by
  cases moved with
  | nil => contradiction
  | cons x xs => simp [step, List.mem_eraseDups]; grind

theorem edit_empty_owed (s : State) (rec : List Key) (j : Key) :
    j ∈ (step s (.userEdit rec [])).1.owedKeys ↔ j ∈ rec ∧ j ∈ s.owedKeys := by
  simp [step]; grind

theorem edit_request_in_record (s : State) (rec moved : List Key) (p : Key)
    (h : (step s (.userEdit rec moved)).1.foldRequest = some p) : p ∈ rec := by
  by_cases hm : moved = []
  · subst hm
    simp only [step, List.isEmpty_nil, ite_true] at h
    cases hr : s.foldRequest with
    | none => simp [hr] at h
    | some q => simp [hr, Option.filter] at h; grind
  · rcases edit_request_origin s rec moved hm p h with h | h
    · exact h.2.1
    · exact h.2.2

theorem rk_owed (s : State) (k j : Key) :
    j ∈ (step s (.retryKey k)).1.owedKeys ↔ j ∈ s.record ∧ (j = k ∨ j ∈ s.owedKeys) := by
  simp [step, List.mem_eraseDups]; grind

theorem rk_request (s : State) (k p : Key) (h : (step s (.retryKey k)).1.foldRequest = some p) :
    (p = k ∧ k ∈ s.record ∧ k ∈ s.lastFreshPile ∧ ∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) ∨
    s.foldRequest = some p := by
  simp only [step] at h
  split at h
  · rename_i hp
    simp at h; subst h
    simp at hp
    left
    refine ⟨rfl, hp.1.1, hp.1.2, ?_⟩
    obtain ⟨y, hy, hy2⟩ := hp.2
    exact ⟨y, by simpa using hy, by simpa using hy2⟩
  · right; exact h

theorem rk_requests_pull (s : State) (k : Key) (hk : k ∈ s.record) (hf : k ∈ s.lastFreshPile)
    (hd : ∃ x ∈ s.record.takeWhile (fun x => x != k), x ∈ s.lastDrawn) :
    (step s (.retryKey k)).1.foldRequest = some k := by
  obtain ⟨y, hy, hy2⟩ := hd
  simp [step, hk, hf]
  intro hall
  exact absurd hy2 (hall y (by simpa using hy))

/-! ### 6b. The user's own move: where a dropped key goes, and when it stays -/

theorem gate_movable_not_folded {s : State} {r : Read} {k : Key} (h : k ∈ movable s r) : k ∉ foldedAll s r := by
  unfold movable at h
  simp [List.mem_filter] at h
  simpa using h.2.2

theorem gate_movable_mem {s : State} {r : Read} {k : Key} (h : k ∈ movable s r) : k ∈ r.drawn := by
  unfold movable at h; exact (List.mem_filter.1 h).1

/-- Two key lists with the same members. -/
def SameKeys (l1 l2 : List Key) : Prop := (∀ a ∈ l1, a ∈ l2) ∧ (∀ a ∈ l2, a ∈ l1)

/-- The other movable keys the record fixes in place: not the dropped key, in the record, not themselves still owed. -/
def anchorsOf (s : State) (r : Read) (k : Key) : List Key :=
  (movable s r).filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a)

/-- The anchors that precede `k` in the record. -/
def wantOf (s : State) (r : Read) (k : Key) : List Key :=
  (s.record.takeWhile (fun x => x != k)).filter (fun a => (anchorsOf s r k).contains a)

/-- The anchors that precede `k` on the bar. -/
def seenOf (s : State) (r : Read) (k : Key) : List Key :=
  ((movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a)).takeWhile (fun x => x != k)

theorem sameKeys_bool (l w : List Key) :
    ((l.all (fun a => w.contains a)) && (w.all (fun a => l.contains a))) = true ↔ SameKeys l w := by
  simp [SameKeys, List.all_eq_true]

theorem prefixFor_spec {want l : List Key} {i : Nat} (h : prefixFor want l = some i) :
    i ≤ l.length ∧ SameKeys (l.take i) want ∧ ∀ j, j < i → ¬ SameKeys (l.take j) want := by
  unfold prefixFor at h
  rw [List.find?_eq_some_iff_getElem] at h
  obtain ⟨hp, n, hn, hget, hlt⟩ := h
  simp only [List.getElem_range] at hget
  subst hget
  refine ⟨?_, (sameKeys_bool _ _).1 hp, ?_⟩
  · simp at hn; omega
  · intro j hj hs
    have h1 := hlt j hj
    rw [List.getElem_range] at h1
    have h2 := (sameKeys_bool _ _).2 hs
    rw [h2] at h1
    simp at h1

theorem prefixFor_isSome {want l : List Key} (i : Nat) (hi : i ≤ l.length) (hs : SameKeys (l.take i) want) :
    (prefixFor want l).isSome = true := by
  unfold prefixFor
  rw [List.find?_isSome]
  exact ⟨i, by simp; omega, (sameKeys_bool _ _).2 hs⟩

theorem anchorMove_spec {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r) :
    anchorMove s r k =
      if ((seenOf s r k).all (fun a => (wantOf s r k).contains a) &&
          (wantOf s r k).all (fun a => (seenOf s r k).contains a)) = true then none
      else match prefixFor (wantOf s r k) (anchorsOf s r k) with
        | none => none
        | some i =>
          match ((anchorsOf s r k).take i).getLast? with
          | some p => some ⟨k, .after p, needsStrip s r k (.after p), true⟩
          | none => (anchorsOf s r k).head?.map (fun t => ⟨k, .before t, needsStrip s r k (.before t), true⟩) := by
  simp only [anchorMove]
  simp [seenOf, wantOf, anchorsOf]
  rfl

/-- The key is already right: exactly the anchors that precede it in the record precede it on the bar.  No move. -/
theorem anchorMove_right_place {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r)
    (hs : SameKeys (seenOf s r k) (wantOf s r k)) : anchorMove s r k = none := by
  rw [anchorMove_spec hk]
  have := (sameKeys_bool _ _).2 hs
  rw [if_pos this]

/-- Otherwise, if the anchors admit a gap, there IS a move of this key. -/
theorem takeWhile_all_eq {k : Key} : ∀ (l : List Key), (∀ x ∈ l, x = k) → l.takeWhile (fun x => x != k) = []
  | [], _ => rfl
  | x :: xs, h => by simp [List.takeWhile, h x (by simp)]

theorem anchorMove_moves {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r)
    (hs : ¬ SameKeys (seenOf s r k) (wantOf s r k))
    (hp : (prefixFor (wantOf s r k) (anchorsOf s r k)).isSome = true) : ∃ a, anchorMove s r k = some a := by
  rw [anchorMove_spec hk]
  have : ¬ ((seenOf s r k).all (fun a => (wantOf s r k).contains a) &&
          (wantOf s r k).all (fun a => (seenOf s r k).contains a)) = true := fun h => hs ((sameKeys_bool _ _).1 h)
  rw [if_neg this]
  cases hq : prefixFor (wantOf s r k) (anchorsOf s r k) with
  | none => simp [hq] at hp
  | some i =>
    simp only
    cases hg : ((anchorsOf s r k).take i).getLast? with
    | some p => exact ⟨_, rfl⟩
    | none =>
      cases hh : (anchorsOf s r k).head? with
      | some t => exact ⟨⟨k, .before t, needsStrip s r k (.before t), true⟩, by simp [hh]⟩
      | none =>
        exfalso
        have han : anchorsOf s r k = [] := by simpa using hh
        apply hs
        have h1 : seenOf s r k = [] := by
          unfold seenOf
          apply takeWhile_all_eq
          intro x hx
          simp [List.mem_filter] at hx
          rw [han] at hx
          simp at hx
          exact hx.2
        have h2 : wantOf s r k = [] := by
          unfold wantOf
          rw [han]; simp
        rw [h1, h2]
        exact ⟨by simp, by simp⟩

/-- Where the move goes: after the last anchor of the SMALLEST prefix of anchors (in drawn order) whose set is the wanted one,
or before the first anchor when the wanted set is empty.  And the move is not asked for when the key is already right. -/
theorem anchorMove_target {s : State} {r : Read} {k : Key} {a : Action} (hk : k ∈ movable s r)
    (h : anchorMove s r k = some a) :
    ¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t)) := by
  rw [anchorMove_spec hk] at h
  by_cases hc : ((seenOf s r k).all (fun a => (wantOf s r k).contains a) &&
          (wantOf s r k).all (fun a => (seenOf s r k).contains a)) = true
  · rw [if_pos hc] at h; simp at h
  · rw [if_neg hc] at h
    refine ⟨fun hs => hc ((sameKeys_bool _ _).2 hs), ?_⟩
    cases hq : prefixFor (wantOf s r k) (anchorsOf s r k) with
    | none => simp [hq] at h
    | some i =>
      simp only [hq] at h
      cases hg : ((anchorsOf s r k).take i).getLast? with
      | some p =>
        simp only [hg, Option.some.injEq] at h
        subst h
        exact ⟨rfl, rfl, rfl, i, by simpa using hq, Or.inl ⟨p, by simpa using hg, rfl⟩⟩
      | none =>
        simp only [hg] at h
        cases hh : (anchorsOf s r k).head? with
        | none => simp [hh] at h
        | some t =>
          simp only [hh, Option.map, Option.some.injEq] at h
          subst h
          exact ⟨rfl, rfl, rfl, i, by simpa using hq, Or.inr ⟨by simpa using hg, t, by simpa using hh, rfl⟩⟩

/-- The drawn case of a drop is the anchor rule's move, or, when that gives none, the fallback's. -/
theorem userMove_drawn_spec {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r) :
    userMove s r k = (match anchorMove s r k with | some a => some a | none => fallbackMove s r k) := by
  have hf := gate_movable_not_folded hk
  have hc : (movable s r).contains k = true := by simpa using hk
  have hf' : (foldedAll s r).contains k = false := by simpa using hf
  simp only [userMove, hf', hc]
  rfl

theorem userMove1_movable {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r) : userMove1 s r k = anchorMove s r k := by
  have hf := gate_movable_not_folded hk
  have hc : (movable s r).contains k = true := by simpa using hk
  have hf' : (foldedAll s r).contains k = false := by simpa using hf
  unfold userMove1; rw [if_neg (by rw [hf']; simp), if_pos hc]

theorem userMove1_folded {s : State} {r : Read} {k : Key} (hf : k ∈ foldedAll s r) : userMove1 s r k = userMove s r k := by
  have hf' : (foldedAll s r).contains k = true := by simpa using hf
  unfold userMove1; rw [if_pos hf']

theorem userMove_of_phase1 {s : State} {r : Read} {k : Key} {a : Action} (h : userMove1 s r k = some a) : userMove s r k = some a := by
  rw [userMove_phases, h]; rfl

/-- If the anchors admit a gap, there IS a move of this key (the anchor rule's, which comes first). -/
theorem userMove_moves {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r)
    (hs : ¬ SameKeys (seenOf s r k) (wantOf s r k))
    (hp : (prefixFor (wantOf s r k) (anchorsOf s r k)).isSome = true) : ∃ a, userMove s r k = some a := by
  obtain ⟨a, ha⟩ := anchorMove_moves hk hs hp
  exact ⟨a, by rw [userMove_drawn_spec hk, ha]⟩

/-- Where a drawn drop's move goes: the anchor rule's (after the last anchor of the smallest prefix whose set is the wanted one, or before the first anchor), or,
when the anchor rule gives none, the fallback's: the key is owed and misplaced among all the movable keys, and the move changes the bar. -/
theorem userMove_target {s : State} {r : Read} {k : Key} {a : Action} (hk : k ∈ movable s r)
    (h : userMove s r k = some a) :
    (¬ SameKeys (seenOf s r k) (wantOf s r k) ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧
    ∃ i, prefixFor (wantOf s r k) (anchorsOf s r k) = some i ∧
      ((∃ p, ((anchorsOf s r k).take i).getLast? = some p ∧ a.rel = .after p) ∨
       (((anchorsOf s r k).take i).getLast? = none ∧ ∃ t, (anchorsOf s r k).head? = some t ∧ a.rel = .before t))) ∨
    (anchorMove s r k = none ∧ a.subject = k ∧ a.user = true ∧ a.strip = needsStrip s r k a.rel ∧ k ∈ s.owedKeys ∧
      misplaced s r k = true ∧ applyMove r.drawn a ≠ r.drawn) := by
  rw [userMove_drawn_spec hk] at h
  cases ha : anchorMove s r k with
  | some a' =>
    rw [ha] at h
    simp only [Option.some.injEq] at h; subst h
    exact Or.inl (anchorMove_target hk ha)
  | none =>
    rw [ha] at h
    have hb := fallbackMove_basic h
    obtain ⟨hu, hsub, _, _, _, hst, hov, _, _, _, hmis, hch, _⟩ := hb
    refine Or.inr ⟨rfl, hsub, hu, ?_, hov, hmis, hch⟩
    rw [hst, hsub]

/-- A misplaced key always HAS a fallback place: some movable record key `x` differs from `k` in side, so either `x` precedes `k` in the record (a movable
predecessor exists) or it follows `k` (a movable follower exists). -/
theorem misplaced_fallbackRel {s : State} {r : Read} {k : Key} (h : misplaced s r k = true) :
    ∃ rel, fallbackRel s r k = some rel := by
  unfold misplaced at h
  obtain ⟨x, hx, hxd⟩ := List.any_eq_true.1 h
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem] at hxd
  obtain ⟨⟨hxk, hxr⟩, hxne⟩ := hxd
  by_cases hxb : x ∈ s.record.takeWhile (fun x => x != k)
  · have hne : (List.filter (fun x => (movable s r).contains x) (s.record.takeWhile (fun x => x != k))) ≠ [] := by
      intro e
      have : x ∈ List.filter (fun x => (movable s r).contains x) (s.record.takeWhile (fun x => x != k)) := by
        simp [List.mem_filter, hxb, hx]
      rw [e] at this; simp at this
    cases hl : (List.filter (fun x => (movable s r).contains x) (s.record.takeWhile (fun x => x != k))).getLast? with
    | some p => exact ⟨Rel.after p, by simp only [fallbackRel, hl]⟩
    | none => exact absurd (List.getLast?_eq_none_iff.1 hl) hne
  · have hxdw : x ∈ (s.record.dropWhile (fun x => x != k)) := by
      have := List.takeWhile_append_dropWhile (p := fun x => x != k) (l := s.record)
      rw [← this] at hxr
      rcases List.mem_append.1 hxr with h1 | h1
      · exact absurd h1 hxb
      · exact h1
    have hxt : x ∈ (s.record.dropWhile (fun x => x != k)).tail := by
      cases hdw : s.record.dropWhile (fun x => x != k) with
      | nil => rw [hdw] at hxdw; simp at hxdw
      | cons y ys =>
        have hy := dw_head hdw
        rw [hdw] at hxdw
        simp only [List.mem_cons] at hxdw
        rcases hxdw with e | e
        · subst e
          simp at hy
          exact absurd hy hxk
        · simpa using e
    cases hl : (List.filter (fun x => (movable s r).contains x) (s.record.takeWhile (fun x => x != k))).getLast? with
    | some p => exact ⟨Rel.after p, by simp only [fallbackRel, hl]⟩
    | none =>
      have hsome : ((s.record.dropWhile (fun x => x != k)).tail.find? (fun x => x != k && (movable s r).contains x)).isSome = true := by
        rw [List.find?_isSome]
        exact ⟨x, hxt, by simp [hxk, hx]⟩
      cases hf : (s.record.dropWhile (fun x => x != k)).tail.find? (fun x => x != k && (movable s r).contains x) with
      | none => rw [hf] at hsome; simp at hsome
      | some t => exact ⟨Rel.before t, by simp only [fallbackRel, hl, hf, Option.map]⟩

/-- No single drag of `k` (to either side of any movable record key other than `k`) leaves fewer inversions among the movable record keys than the bar has now. -/
def NoReducingDrag (s : State) (r : Read) (k : Key) : Prop :=
  ∀ rel : Rel, rel.target ∈ movable s r → rel.target ∈ s.record → rel.target ≠ k →
    ¬ invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) < invCount s r r.drawn

theorem legal_mem_cands {s : State} {r : Read} {k : Key} {rel : Rel} (h1 : rel.target ∈ movable s r) (h2 : rel.target ∈ s.record)
    (h3 : rel.target ≠ k) : rel ∈ fallbackCands s r k := by
  unfold fallbackCands
  apply List.mem_append_right
  simp only [List.mem_flatMap, List.mem_filter, Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem, decide_eq_true_eq]
  refine ⟨rel.target, ⟨h1, h3, h2⟩, ?_⟩
  cases rel <;> simp [Rel.target]

/-- The fallback fails only when the bar is not verified (`wholeBar`) or no drag helps: for an owed misplaced key in the record, no move means `wholeBar = false` or `NoReducingDrag`. -/
theorem fallbackMove_none_cases {s : State} {r : Read} {k : Key} (ho : k ∈ s.owedKeys) (hmv : k ∈ movable s r) (h : fallbackMove s r k = none) :
    misplaced s r k = false ∨ (misplaced s r k = true ∧ (k ∉ s.record ∨ wholeBar s r = false ∨ NoReducingDrag s r k)) := by
  by_cases hm : misplaced s r k = true
  · right
    refine ⟨hm, ?_⟩
    by_cases hrk : k ∈ s.record
    · by_cases hw : wholeBar s r = true
      · right; right
        intro rel h1 h2 h3 hlt
        obtain ⟨q, hq⟩ := misplaced_fallbackRel hm
        have hne : fallbackCands s r k ≠ [] := by
          unfold fallbackCands; simp [hq]
        obtain ⟨b, hb⟩ := argmin_isSome (f := afterCount s r k) hne
        have hs := argmin_spec hb
        have hle := hs.2 rel (legal_mem_cands h1 h2 h3)
        have hlt' : afterCount s r k b < invCount s r r.drawn := by
          have : afterCount s r k rel = invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) := rfl
          omega
        have : fallbackMove s r k = some ⟨k, b, needsStrip s r k b, true⟩ := by
          simp only [fallbackMove, hb, Option.map, Option.filter]
          simp [ho, hrk, hmv, hw, hm, hlt']
        rw [this] at h; simp at h
      · right; left; simpa using hw
    · left; exact hrk
  · left; simpa using hm

/-- A reducing drag of an owed misplaced key in the record, on a verified bar, gives a fallback move. -/
theorem fallbackMove_exists {s : State} {r : Read} {k : Key} (ho : k ∈ s.owedKeys) (hrk : k ∈ s.record) (hmv : k ∈ movable s r) (hw : wholeBar s r = true)
    (hm : misplaced s r k = true)
    {rel : Rel} (h1 : rel.target ∈ movable s r) (h2 : rel.target ∈ s.record) (h3 : rel.target ≠ k)
    (hlt : invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) < invCount s r r.drawn) : ∃ a, fallbackMove s r k = some a := by
  obtain ⟨q, hq⟩ := misplaced_fallbackRel hm
  have hne : fallbackCands s r k ≠ [] := by unfold fallbackCands; simp [hq]
  obtain ⟨b, hb⟩ := argmin_isSome (f := afterCount s r k) hne
  have hs := argmin_spec hb
  have hle := hs.2 rel (legal_mem_cands h1 h2 h3)
  have hlt' : afterCount s r k b < invCount s r r.drawn := by
    have : afterCount s r k rel = invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) := rfl
    omega
  exact ⟨⟨k, b, needsStrip s r k b, true⟩, by
    simp only [fallbackMove, hb, Option.map, Option.filter]
    simp [ho, hrk, hmv, hw, hm, hlt']⟩

/-- A folded key is pulled out only if it is the fold request or owed, and the chevron is fresh; it goes just after the rightmost
movable key that precedes it in the record, and only if that changes the drawn list. -/
theorem userMove_folded {s : State} {r : Read} {k : Key} {a : Action} (hf : k ∈ foldedAll s r)
    (h : userMove s r k = some a) :
    (s.foldRequest = some k ∨ k ∈ s.owedKeys) ∧ r.chevron = .fresh ∧ applyMove r.drawn a ≠ r.drawn ∧
    ∃ p, a.rel = .after p ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      a.subject = k ∧ a.strip = true ∧ a.user = true := by
  have hf' : (foldedAll s r).contains k = true := by simpa using hf
  simp only [userMove] at h
  split at h
  · split at h
    · rename_i hq
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq, List.contains_iff_mem] at hq
      cases hg : List.getLast? (List.filter (fun x => (List.takeWhile (fun x => x != k) s.record).contains x) (movable s r)) with
      | none => simp only [hg, Option.map, Option.filter] at h; cases h
      | some p =>
        simp only [hg, Option.map, Option.filter] at h
        split at h
        · rename_i hc
          simp at h; subst h
          refine ⟨hq.1.1, hq.1.2, by simpa using hc, p, rfl, by simpa using hg, rfl, ?_, rfl⟩
          simp only [needsStrip, Bool.or_eq_true, List.contains_iff_mem]
          simp only [List.mem_append]
          exact Or.inl (Or.inl hf)
        · simp at h
    · simp at h
  · rename_i hn; exact absurd hf' hn

theorem userMove_folded_some {s : State} {r : Read} {k p : Key} (hf : k ∈ foldedAll s r)
    (hq : s.foldRequest = some k ∨ k ∈ s.owedKeys) (hc : r.chevron = .fresh) (hfs : r.foldedSet.contains k = true)
    (hg : ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p)
    (hchg : applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ ≠ r.drawn) :
    userMove s r k = some ⟨k, .after p, needsStrip s r k (.after p), true⟩ := by
  have hf' : (foldedAll s r).contains k = true := by simpa using hf
  have hq' : (s.foldRequest == some k || s.owedKeys.contains k) = true := by
    rcases hq with hq | hq <;> simp [hq]
  simp only [userMove, hf', if_true, hq', hc, hfs, Bool.and_self, ite_true, hg, Option.map, Option.filter]
  simp [hchg]

/-- `applyMove` puts the subject right next to the target: just before it ... -/
theorem applyMove_before (l : List Key) (a : Action) (t : Key) (hr : a.rel = .before t) (hne : a.subject ≠ t)
    (ht : t ∈ l) : ∃ pre post, applyMove l a = pre ++ a.subject :: t :: post := by
  have hmem : t ∈ l.filter (fun x => x != a.subject) := by
    simp [List.mem_filter]; exact ⟨ht, fun h => hne h.symm⟩
  obtain ⟨A, B, hAB⟩ := List.append_of_mem hmem
  refine ⟨A.flatMap fun x => if x == t then [a.subject, x] else [x],
    B.flatMap fun x => if x == t then [a.subject, x] else [x], ?_⟩
  unfold applyMove
  rw [hr]
  have : ¬ (!(l.filter (fun x => x != a.subject)).contains (Rel.before t).target) = true := by
    simpa [Rel.target] using hmem
  rw [if_neg this]
  simp only [Rel.target]
  rw [hAB]
  simp [List.flatMap_append]

/-- ... or just after it. -/
theorem applyMove_after (l : List Key) (a : Action) (t : Key) (hr : a.rel = .after t) (hne : a.subject ≠ t)
    (ht : t ∈ l) : ∃ pre post, applyMove l a = pre ++ t :: a.subject :: post := by
  have hmem : t ∈ l.filter (fun x => x != a.subject) := by
    simp [List.mem_filter]; exact ⟨ht, fun h => hne h.symm⟩
  obtain ⟨A, B, hAB⟩ := List.append_of_mem hmem
  refine ⟨A.flatMap fun x => if x == t then [x, a.subject] else [x],
    B.flatMap fun x => if x == t then [x, a.subject] else [x], ?_⟩
  unfold applyMove
  rw [hr]
  have : ¬ (!(l.filter (fun x => x != a.subject)).contains (Rel.after t).target) = true := by
    simpa [Rel.target] using hmem
  rw [if_neg this]
  simp only [Rel.target]
  rw [hAB]
  simp [List.flatMap_append]

/-! ### 9b. Subjects are in the record -/

theorem gate_firstInversion_mem : ∀ (l1 l2 : List Key) (w h : Key), firstInversion l1 l2 = some (w, h) → w ∈ l1 ∧ h ∈ l2
  | w :: ws, h :: hs, a, b, hh => by
    unfold firstInversion at hh
    by_cases e : (w == h) = true
    · simp only [e, ite_true] at hh
      have := gate_firstInversion_mem ws hs a b hh
      simp [this]
    · simp only [e] at hh
      simp at hh
      simp [hh]
  | [], _, _, _, hh => by simp [firstInversion] at hh
  | _ :: _, [], _, _, hh => by simp [firstInversion] at hh

theorem plan_spec {s : State} {r : Read} {b : Action} (hp : planOrderMoves s r = some b) :
    b.subject ∈ s.record ∧ b.rel.target ∈ s.record := by
  simp only [planOrderMoves] at hp
  split at hp
  · rename_i w hh hmatch
    split at hp
    · simp at hp
    · have := gate_firstInversion_mem _ _ _ _ hmatch
      simp at hp; subst hp
      simp [List.mem_filter] at this
      simp [Rel.target]
      exact ⟨this.1.1, this.2.2⟩
  · simp at hp

/-- The planner names only keys of the record, as subject and as target. -/
theorem plan_in_record {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) (hu : a.user = false) :
    a.subject ∈ s.record ∧ a.rel.target ∈ s.record :=
  plan_spec (gate_engine_action h hu).2

/-- Reading a plannable read (settled, readable pass) records its drawn keys; any other read leaves them. -/
theorem lastDrawn_set (s : State) (r : Read) (h1 : r.kind = .pass) (h2 : r.settled = true) (h3 : r.level ≠ .incomplete) :
    (noteRead s r).lastDrawn = r.drawn := by
  unfold noteRead; simp [h1, h2, h3]; grind

theorem lastDrawn_kept (s : State) (r : Read) (h : r.kind = .poll ∨ r.settled = false ∨ r.level = .incomplete) :
    (noteRead s r).lastDrawn = s.lastDrawn := by
  unfold noteRead
  rcases h with h | h | h <;> simp [h] <;> grind

/-- Every owed key and the fold request is in the record. -/
def SubjInRec (s : State) : Prop :=
  (∀ k ∈ s.owedKeys, k ∈ s.record) ∧ (∀ k, s.foldRequest = some k → k ∈ s.record)

theorem edit_record (s : State) (rec moved : List Key) : (step s (.userEdit rec moved)).1.record = rec := by
  cases moved <;> simp [step]

theorem subjInRec_step {s : State} (h : SubjInRec s) (e : Event) : SubjInRec (step s e).1 := by
  obtain ⟨h1, h2⟩ := h
  cases e with
  | read r =>
    have nk := noteRead_keeps s r
    simp only [step]
    cases hd : decideMove s r with
    | none => simp only [SubjInRec, nk.1, nk.2.1, nk.2.2.1]; exact ⟨h1, h2⟩
    | some a =>
      simp only [SubjInRec, emit, nk.1, nk.2.1, nk.2.2.1]
      refine ⟨fun k hk => h1 k (List.mem_of_mem_erase hk), fun k hk => ?_⟩
      split at hk
      · simp at hk
      · exact h2 k hk
  | userEdit rec moved =>
    by_cases hm : moved = []
    · subst hm
      refine ⟨fun k hk => ?_, fun k hk => ?_⟩
      · have := (edit_empty_owed s rec k).1 hk; exact this.1
      · exact edit_request_in_record s rec [] k hk
    · rw [SubjInRec, edit_record]
      exact ⟨fun k hk => ((edit_owed s rec moved hm k).1 hk).1, fun k hk => edit_request_in_record s rec moved k hk⟩
  | userRetry => simp [SubjInRec, step]
  | retryKey k =>
    refine ⟨fun j hj => ((rk_owed s k j).1 hj).1, fun j hj => ?_⟩
    rcases rk_request s k j hj with h | h
    · exact h.1 ▸ h.2.1
    · exact h2 j h
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · have hrec : (result s a o p).record = s.record := by unfold result; grind
        simp only [SubjInRec, hrec]
        refine ⟨fun j hj => ?_, fun j hj => ?_⟩
        · rcases (rearm_iff s a o p j).1 hj with h | h
          · exact h1 j h
          · obtain ⟨rfl, hr⟩ := h; exact hr.2.2.2.2
        · rw [rearm_request] at hj
          split at hj
          · rename_i hc; simp at hj; subst hj; exact hc.1.2.2.2.2
          · exact h2 j hj
      · exact ⟨h1, h2⟩
    · exact ⟨h1, h2⟩
  | passBoundary => simp [SubjInRec, step]

theorem subjInRec_run {s : State} (h : SubjInRec s) (es : List Event) : SubjInRec (run s es).1 := by
  induction es generalizing s with
  | nil => simpa [run] using h
  | cons e es ih => simp only [run]; exact ih (subjInRec_step h e)

theorem subjInRec_init (rec : List Key) : SubjInRec (State.init rec) := by simp [SubjInRec, State.init]

/-- Every move is of a key of the record (the record at the time of the read), from any reachable state. -/
theorem action_in_record {s : State} (hs : SubjInRec s) {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2) :
    a.subject ∈ s.record := by
  obtain ⟨r', he, hd, _⟩ := gate_step_acts h
  cases he
  rcases (gate_decide_cases hd).2 with ⟨k, hk, hm, _⟩ | ⟨_, b, hb, hh⟩
  · have := (gate_userMove_user hm).2
    subst this
    rcases hk with hk | hk
    · exact hs.2 _ (by simpa using hk)
    · exact hs.1 _ hk
  · have hps := plan_spec hb
    rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
    · exact hps.1
    · exact hps.1

/-! ### Runs -/

theorem gate_run_cons (s : State) (e : Event) (es : List Event) :
    run s (e :: es) = ((run (step s e).1 es).1, (step s e).2 ++ (run (step s e).1 es).2) := by
  simp [run]

theorem gate_run_append (s : State) (xs ys : List Event) :
    run s (xs ++ ys) = ((run (run s xs).1 ys).1, (run s xs).2 ++ (run (run s xs).1 ys).2) := by
  induction xs generalizing s with
  | nil => simp [run]
  | cons e xs ih => simp [gate_run_cons, ih]

theorem gate_run_action_split (s : State) (es : List Event) (a : Action) (h : a ∈ (run s es).2) :
    ∃ pre e post, es = pre ++ e :: post ∧ a ∈ (step (run s pre).1 e).2 := by
  induction es generalizing s with
  | nil => simp [run] at h
  | cons e es ih =>
    rw [gate_run_cons] at h
    simp only [List.mem_append] at h
    rcases h with h | h
    · exact ⟨[], e, es, rfl, by simpa [run] using h⟩
    · obtain ⟨pre, e', post, h1, h2⟩ := ih _ h
      exact ⟨e :: pre, e', post, by simp [h1], by simpa [gate_run_cons] using h2⟩

/-- From the initial state, every move of a run is of a key that is in the record at the time of its read. -/
theorem subjects_in_record (rec : List Key) (es : List Event) (a : Action) (h : a ∈ (run (State.init rec) es).2) :
    ∃ pre r post, es = pre ++ .read r :: post ∧ a.subject ∈ (run (State.init rec) pre).1.record := by
  obtain ⟨pre, e, post, he, ha⟩ := gate_run_action_split _ _ _ h
  obtain ⟨r, hr, _, _⟩ := gate_step_acts ha
  subst hr
  exact ⟨pre, r, post, he, action_in_record (subjInRec_run (subjInRec_init rec) pre) ha⟩

/-- A user event: a non-empty `userEdit`, `userRetry`, `retryKey` (an edit that moved nothing is not one). -/
def userEv : Event → Bool
  | .userEdit _ m => !m.isEmpty
  | .userRetry | .retryKey _ => true
  | _ => false

/-- The flag "the drag in flight was an engine drag decided on a full read", after event `e`. -/
def fullFlag (s : State) (f : Bool) : Event → Bool
  | .read r => match (step s (.read r)).2 with
      | [a] => if a.user = false then fullBar s r else f
      | _ => f
  | _ => f

/-- Engine drags that were decided on a read where the bar was full and that were then actually posted. -/
def postedFull : State → Bool → List Event → Nat
  | _, _, [] => 0
  | s, f, e :: es =>
      (match e, s.inFlight with
        | .moveResult k _ true, some a => if a.subject == k && !a.user && f then 1 else 0
        | _, _ => 0) + postedFull (step s e).1 (fullFlag s f e) es

/-- The in-flight engine drag was decided on a full read only if the budget then allowed it. -/
def FullFlagOK (s : State) (f : Bool) : Prop :=
  ∀ a, s.inFlight = some a → a.user = false → f = true → s.moveCount < 3

theorem res_inflight (s : State) (a : Action) (o : Outcome) (p : Bool) : (result s a o p).inFlight = none := by
  unfold result; grind

theorem edit_empty_frame (s : State) (rec : List Key) :
    (step s (.userEdit rec [])).1.moveCount = s.moveCount ∧ (step s (.userEdit rec [])).1.inFlight = s.inFlight := by
  simp [step]

theorem pb_frame (s : State) : (step s .passBoundary).1.moveCount = s.moveCount ∧ (step s .passBoundary).1.inFlight = s.inFlight := by
  simp [step]

theorem postedFull_le {s : State} {f : Bool} (h : FullFlagOK s f) (es : List Event)
    (hn : ∀ e ∈ es, userEv e = false) : postedFull s f es ≤ 3 - s.moveCount := by
  induction es generalizing s f with
  | nil => simp [postedFull]
  | cons e es ih =>
    have hn' : ∀ x ∈ es, userEv x = false := fun x hx => hn x (by simp [hx])
    have he := hn e (by simp)
    simp only [postedFull]
    cases e with
    | read r =>
      have nk := noteRead_keeps s r
      simp only [fullFlag]
      cases hd : decideMove s r with
      | none =>
        have hs : step s (.read r) = (noteRead s r, []) := by simp [step, hd]
        rw [hs]
        simp only [Nat.zero_add]
        have := ih (s := noteRead s r) (f := f) (fun a ha hu hf => by
          rw [nk.2.2.2.1] at ha
          have := h a ha hu hf
          rw [nk.2.2.2.2.2.2.2.2.1]; exact this) hn'
        rw [nk.2.2.2.2.2.2.2.2.1] at this
        simpa [hs] using this
      | some a =>
        have hs : step s (.read r) = (emit (noteRead s r) a, [a]) := by simp [step, hd]
        have hact : a ∈ (step s (.read r)).2 := by simp [hs]
        have hmc : (emit (noteRead s r) a).moveCount = s.moveCount := by simp [emit, nk.2.2.2.2.2.2.2.2.1]
        simp only [hs]
        simp only [Nat.zero_add]
        have := ih (s := emit (noteRead s r) a) (f := if a.user = false then fullBar s r else f) (fun b hb hu hf => by
          have hb2 : b = a := by simpa [emit] using hb.symm
          rw [hb2] at hu
          rw [hmc]
          cases hau : a.user with
          | true => simp [hau] at hu
          | false =>
            simp [hau] at hf
            have := eng_budget_exact hact hau
            simp [hf] at this
            exact this) hn'
        rw [hmc] at this
        simpa [hs] using this
    | userEdit rec moved =>
      have hm : moved = [] := by
        cases moved with
        | nil => rfl
        | cons x xs => simp [userEv] at he
      subst hm
      have fr := edit_empty_frame s rec
      simp only [fullFlag]
      simp only [Nat.zero_add]
      have := ih (s := (step s (.userEdit rec [])).1) (f := f) (fun a ha hu hf => by
        rw [fr.2] at ha; rw [fr.1]; exact h a ha hu hf) hn'
      rw [fr.1] at this
      simpa using this
    | userRetry => simp [userEv] at he
    | retryKey k => simp [userEv] at he
    | moveResult k o p =>
      simp only [fullFlag]
      cases hi : s.inFlight with
      | none =>
        have hs : step s (.moveResult k o p) = (s, []) := by simp [step, hi]
        simp only [hs]
        have := ih (s := s) (f := f) h hn'
        simpa [hi] using this
      | some a =>
        by_cases hk : a.subject == k
        · have hs : step s (.moveResult k o p) = (result s a o p, []) := by simp [step, hi, hk]
          simp only [hs]
          have hfl : FullFlagOK (result s a o p) f := by
            intro b hb; rw [res_inflight] at hb; simp at hb
          have ih' := ih (s := result s a o p) (f := f) hfl hn'
          rw [res_count_exact] at ih'
          have hflag := h a hi
          cases hp : p with
          | false =>
            simp [hi, hk, hp] at ih' ⊢
            exact ih'
          | true =>
            cases hu : a.user with
            | true => simp [hi, hk, hp, hu] at ih' ⊢; exact ih'
            | false =>
              cases hf : f with
              | false => simp [hi, hk, hp, hu, hf] at ih' ⊢; omega
              | true =>
                have hm3 := hflag hu hf
                simp [hi, hk, hp, hu, hf] at ih' ⊢
                omega
        · have hs : step s (.moveResult k o p) = (s, []) := by simp [step, hi, hk]
          simp only [hs]
          have := ih (s := s) (f := f) h hn'
          have hk' : ¬ (a.subject == k) = true := hk
          cases p <;> simp [hi, hk'] <;> omega
    | passBoundary =>
      have fr := pb_frame s
      simp only [fullFlag]
      simp only [Nat.zero_add]
      have := ih (s := (step s .passBoundary).1) (f := f) (fun a ha hu hf => by
        rw [fr.2] at ha; rw [fr.1]; exact h a ha hu hf) hn'
      rw [fr.1] at this
      simpa using this

/-- Posted engine drags decided on a full read: at most 3, with NO hypothesis about the other reads. -/
theorem postedFull_init (rec : List Key) (es : List Event) (hn : ∀ e ∈ es, userEv e = false) :
    postedFull (State.init rec) false es ≤ 3 := by
  have := postedFull_le (s := State.init rec) (f := false) (fun a ha => by simp [State.init] at ha) es hn
  simpa [State.init] using this

end Sommelier
