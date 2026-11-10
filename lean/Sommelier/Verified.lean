import Sommelier.Safety
import Sommelier.Honesty

/-!
# ejb.17: a verified move the next read contradicts is a strike (no repeat drags)

The actuator may report a posted drag `verified` while macOS has reverted it, so the NEXT usable read still shows the key
misplaced.  `result` remembers the subject of every verified posted engine drag in `State.verified`; the next usable read
(`gate` true, nothing in flight) JUDGES it (`judge`, `Step.lean`): if the key is `stillMisplaced` it is struck exactly like a
failed posted drag (`markFail`), otherwise the marker is just cleared.  `judge` runs before the read decides
(`decideMove s r = decideMove0 (judge s r) r`), so a repeat of a contradicted drag is never planned from the read that struck it out.

Headline: `verified_revert_bounded`.  Under any event list with no user event in which every drag of `k` is answered
`verified` (posted) and every read the gate accepts still shows `k` misplaced, at most THREE engine drags of `k` are posted
(from a fresh state; `verified_revert_bounded_from` states it from any state satisfying `VInv`).
-/

namespace Sommelier

/-- The events the bound `verified_revert_bounded` allows: reads, drag results and pass boundaries.  NO `userEdit` at all (ejb.26: every edit changes the record and so clears the
mark, even one that moves no key, which `isUserEvent` does not count), and no `userRetry` or `retryKey`. -/
def vFree : Event → Bool
  | .userEdit _ _ => false
  | .userRetry | .retryKey _ => false
  | _ => true

theorem vFree_notUser {e : Event} (h : vFree e = true) : isUserEvent e = false := by
  cases e <;> simp_all [vFree, isUserEvent]

def strikeCount (s : State) (x : Key) : Nat := (s.strikes.filter (fun y => y == x)).length

/-- 1 iff this event is the result of a POSTED drag of the engine (not the user) of `k` that is in flight. -/
def verCnt (k : Key) (s : State) (e : Event) : Nat :=
  match e with
  | .moveResult k' _ p =>
      match s.inFlight with
      | some a => if p && a.subject == k' && !a.user && a.subject == k then 1 else 0
      | none => 0
  | _ => 0

/-- Engine drags of `k` posted while running `es` from `s`. -/
def verDrags (k : Key) (s : State) : List Event → Nat
  | [] => 0
  | e :: es => verCnt k s e + verDrags k (step s e).1 es

/-- Every answer to a drag of `k` is a posted `verified`. -/
def AllVerified (k : Key) (es : List Event) : Prop :=
  ∀ e ∈ es, ∀ k' o p, e = .moveResult k' o p → k' = k → o = .verified ∧ p = true

/-- The invariant the bound needs; every state reached from `State.init` by events without a user move satisfies it. -/
structure VInv (s : State) : Prop where
  pend : s.verified.isSome = true → s.inFlight = none
  strikes : ∀ x, 3 ≤ strikeCount s x → x ∈ s.givenUp
  flight : ∀ a, s.inFlight = some a → a.user = false → a.subject ∉ s.givenUp

theorem VInv.init (rec : List Key) : VInv (State.init rec) :=
  ⟨by simp [State.init], by simp [State.init, strikeCount], by simp [State.init]⟩

/-! ### Facts about `judge`, `markFail` and `result` -/

theorem markStrike_verified (t : State) (k : Key) : (markStrike t k).verified = t.verified := rfl

theorem markStrike_inFlight (t : State) (k : Key) : (markStrike t k).inFlight = t.inFlight := rfl

theorem markStrike_givenUp_mono (t : State) (k x : Key) (hx : x ∈ t.givenUp) : x ∈ (markStrike t k).givenUp := by
  unfold markStrike
  simp
  split <;> simp [hx]

theorem markStrike_strike_other (t : State) (k x : Key) (hx : x ≠ k) : strikeCount (markStrike t k) x = strikeCount t x := by
  unfold markStrike strikeCount
  simp [List.filter_cons, Ne.symm hx]

theorem markStrike_givenUp_other (t : State) (k x : Key) (hx : x ≠ k) : x ∈ (markStrike t k).givenUp ↔ x ∈ t.givenUp := by
  unfold markStrike
  simp
  split <;> simp [hx]

theorem markStrike_strike (t : State) (k : Key) : strikeCount (markStrike t k) k = strikeCount t k + 1 := by
  unfold markStrike strikeCount
  simp [List.filter_cons]

theorem markStrike_giveup (t : State) (k : Key) (h3 : 3 ≤ strikeCount t k + 1) : k ∈ (markStrike t k).givenUp := by
  unfold markStrike
  unfold strikeCount at h3
  simp
  split
  · simp
  · rename_i hn
    exact Decidable.byContradiction fun hk => hn ⟨by omega, hk⟩

theorem markFail_verified (t : State) (k : Key) : (markFail t k).verified = t.verified := by
  unfold markFail; split <;> rfl

theorem markFail_inFlight (t : State) (k : Key) : (markFail t k).inFlight = t.inFlight := by
  unfold markFail; split <;> rfl

theorem markFail_givenUp_mono (t : State) (k x : Key) (hx : x ∈ t.givenUp) : x ∈ (markFail t k).givenUp := by
  unfold markFail
  split
  · exact markStrike_givenUp_mono t k x hx
  · simp
    split <;> simp [hx]

theorem markFail_strike_other (t : State) (k x : Key) (hx : x ≠ k) : strikeCount (markFail t k) x = strikeCount t x := by
  unfold markFail
  split
  · exact markStrike_strike_other t k x hx
  · rfl

theorem markFail_givenUp_other (t : State) (k x : Key) (hx : x ≠ k) : x ∈ (markFail t k).givenUp ↔ x ∈ t.givenUp := by
  unfold markFail
  split
  · exact markStrike_givenUp_other t k x hx
  · simp
    split <;> simp [hx]

theorem markFail_notproven (t : State) (k : Key) (h : t.provenNotFull = false) : k ∈ (markFail t k).givenUp := by
  unfold markFail; simp [h]; split <;> simp_all

theorem markFail_proven (t : State) (k : Key) (h : t.provenNotFull = true) :
    strikeCount (markFail t k) k = strikeCount t k + 1 ∧ (3 ≤ strikeCount t k + 1 → k ∈ (markFail t k).givenUp) := by
  unfold markFail
  simp only [h, if_true]
  exact ⟨markStrike_strike t k, markStrike_giveup t k⟩

theorem judge_cases (s : State) (r : Read) :
    judge s r = s ∨ ∃ k0, s.verified = some k0 ∧ s.inFlight = none ∧ s.gate r = true ∧
      ((verFailed s r k0 = false ∧ judge s r = { s with verified := none }) ∨
       (verFailed s r k0 = true ∧ judge s r = markStrike { s with verified := none } k0)) := by
  unfold judge
  cases hv : s.verified with
  | none => exact Or.inl rfl
  | some k0 =>
    by_cases hc : (s.inFlight.isNone && s.gate r) = true
    · right
      refine ⟨k0, rfl, ?_, ?_, ?_⟩
      · have := (Bool.and_eq_true _ _ ▸ hc).1
        cases hi : s.inFlight with
        | none => rfl
        | some _ => simp [hi] at this
      · exact (Bool.and_eq_true _ _ ▸ hc).2
      · simp only [hc, if_true]
        by_cases hm : verFailed s r k0 = true
        · exact Or.inr ⟨hm, by simp [hm]⟩
        · exact Or.inl ⟨by simpa using hm, by simp [hm]⟩
    · left; simp [hc]

theorem judge_flight_keeps (s : State) (r : Read) (h : s.inFlight.isSome = true) : judge s r = s := by
  rcases judge_cases s r with h1 | ⟨k0, _, hi, _⟩
  · exact h1
  · simp [hi] at h

theorem judge_verified (s : State) (r : Read) : (judge s r).verified = none ∨ (judge s r).verified = s.verified := by
  rcases judge_cases s r with h | ⟨k0, _, _, _, ⟨_, h⟩ | ⟨_, h⟩⟩
  · exact Or.inr (by rw [h])
  · exact Or.inl (by rw [h])
  · exact Or.inl (by rw [h, markStrike_verified])

theorem noteRead_verified (s : State) (r : Read) : (noteRead s r).verified = s.verified := by
  unfold noteRead; grind

theorem noteRead_strikes' (s : State) (r : Read) : (noteRead s r).strikes = s.strikes := by
  unfold noteRead; grind

theorem noteRead_givenUp' (s : State) (r : Read) : (noteRead s r).givenUp = s.givenUp := by
  unfold noteRead; grind

theorem result_cases (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (p = true ∧ o = .failed ∧ ∃ t : State, t.givenUp = s.givenUp ∧ t.strikes = s.strikes ∧ t.provenNotFull = s.provenNotFull ∧
        result s a o p = markFail t a.subject) ∨
    ((result s a o p).strikes = s.strikes ∧ (result s a o p).givenUp = s.givenUp) := by
  by_cases hf : p = true ∧ o = .failed
  · left
    obtain ⟨rfl, rfl⟩ := hf
    exact ⟨rfl, rfl, { s with inFlight := none, moveCount := s.moveCount + (if (!a.user) = true then 1 else 0), verified := none, verRel := a.rel },
      rfl, rfl, rfl, by unfold result; simp⟩
  · right
    unfold result markFail markStrike
    grind

theorem result_facts (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).inFlight = none ∧
    (result s a o p).verified = (if p = true ∧ a.user = false ∧ o = .verified then some a.subject else none) ∧
    (∀ x, x ∈ s.givenUp → x ∈ (result s a o p).givenUp) ∧
    (∀ x, x ≠ a.subject → strikeCount (result s a o p) x = strikeCount s x) ∧
    (∀ x, x ≠ a.subject → (x ∈ (result s a o p).givenUp ↔ x ∈ s.givenUp)) ∧
    ((p = false ∨ o ≠ .failed) → (result s a o p).strikes = s.strikes ∧ (result s a o p).givenUp = s.givenUp) := by
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_⟩
  · unfold result markFail markStrike; grind
  · unfold result markFail markStrike; grind
  · intro x hx
    rcases result_cases s a o p with ⟨_, _, t, h1, h2, h3, h4⟩ | ⟨h1, h2⟩
    · rw [h4]; exact markFail_givenUp_mono t _ _ (h1 ▸ hx)
    · rw [h2]; exact hx
  · intro x hx
    rcases result_cases s a o p with ⟨_, _, t, h1, h2, h3, h4⟩ | ⟨h1, h2⟩
    · rw [h4, markFail_strike_other t _ _ hx]; unfold strikeCount; rw [h2]
    · unfold strikeCount; rw [h1]
  · intro x hx
    rcases result_cases s a o p with ⟨_, _, t, h1, h2, h3, h4⟩ | ⟨h1, h2⟩
    · rw [h4, markFail_givenUp_other t _ _ hx, h1]
    · rw [h2]
  · intro h
    rcases result_cases s a o p with ⟨hp, hf, _⟩ | h2
    · rcases h with h | h
      · simp [hp] at h
      · exact absurd hf h
    · exact h2

/-! ### The invariant `VInv` is preserved by every event that is not a user move -/

theorem judge_vinv {s : State} (h : VInv s) (r : Read) : VInv (judge s r) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hv
    rw [judge_inFlight]
    rcases judge_verified s r with h1 | h1
    · rw [h1] at hv; simp at hv
    · rw [h1] at hv; exact h.pend hv
  · intro x hx
    rcases judge_cases s r with h1 | ⟨k0, _, _, _, ⟨_, h1⟩ | ⟨_, h1⟩⟩
    · rw [h1] at hx ⊢; exact h.strikes x hx
    · rw [h1] at hx ⊢; exact h.strikes x hx
    · rw [h1] at hx ⊢
      by_cases hk : x = k0
      · subst hk
        have hc : strikeCount { s with verified := none } x = strikeCount s x := rfl
        rw [markStrike_strike, hc] at hx
        exact markStrike_giveup _ _ (by rw [hc]; exact hx)
      · rw [markStrike_strike_other _ _ _ hk] at hx
        have hc : strikeCount { s with verified := none } x = strikeCount s x := rfl
        rw [hc] at hx
        exact (markStrike_givenUp_other _ _ _ hk).2 (h.strikes x hx)
  · intro a ha hu
    have hs : s.inFlight = some a := by rw [← judge_inFlight]; exact ha
    rw [judge_flight_keeps s r (by simp [hs])]
    exact h.flight a hs hu

theorem noteRead_vinv {s : State} (h : VInv s) (r : Read) : VInv (noteRead s r) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hv
    rw [noteRead_verified] at hv
    have := h.pend hv
    rw [(noteRead_keeps s r).2.2.2.1]; exact this
  · intro x hx
    unfold strikeCount at hx
    rw [noteRead_strikes'] at hx
    rw [noteRead_givenUp']
    exact h.strikes x hx
  · intro a ha hu
    rw [(noteRead_keeps s r).2.2.2.1] at ha
    rw [noteRead_givenUp']
    exact h.flight a ha hu

theorem emit_vinv {t : State} (h : VInv t) (a : Action) (hv : t.verified = none)
    (hg : a.user = false → a.subject ∉ t.givenUp) : VInv (emit t a) := by
  refine ⟨?_, ?_, ?_⟩
  · intro hv'; simp [emit, hv] at hv'
  · intro x hx; exact h.strikes x hx
  · intro b hb hu
    simp only [emit, Option.some.injEq] at hb
    subst hb
    exact hg hu

/-- A decided move: nothing in flight, the gate true, so the read judged the pending move, and an engine move is the planner's on the judged state. -/
theorem decide_facts {s : State} {r : Read} {a : Action} (h : decideMove s r = some a) :
    s.inFlight = none ∧ s.gate r = true ∧ (a.user = false → planOrderMoves (judge s r) r = some a) := by
  have h0 : decideMove0 (judge s r) r = some a := h
  have hc := gate_decide_cases0 h0
  refine ⟨?_, ?_, ?_⟩
  · have := hc.1; rwa [judge_inFlight] at this
  · have := decideMove_gated s r a h
    unfold State.gate
    simpa [Bool.and_eq_true] using this
  · intro hu
    rcases hc.2 with ⟨k, _, hk, _⟩ | ⟨_, b, hb, hh⟩
    · have := (gate_userMove_user hk).1
      simp [this] at hu
    · rcases hh with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
      · exact hb
      · simp at hu

theorem judge_verified_none {s : State} {r : Read} (hi : s.inFlight = none) (hg : s.gate r = true) : (judge s r).verified = none := by
  unfold judge
  cases hv : s.verified with
  | none => simpa using hv
  | some k0 =>
    simp only [hi, hg, Option.isNone_none, Bool.and_self, ite_true]
    split
    · rw [markStrike_verified]
    · rfl

theorem plan_subject_not_givenUp {t : State} {r : Read} {a : Action} (h : planOrderMoves t r = some a) : a.subject ∉ t.givenUp := by
  simp only [planOrderMoves] at h
  split at h
  · split at h
    · simp at h
    · rename_i hn
      simp at h; subst h
      simp at hn
      exact hn.1
  · simp at h

theorem step_read_state (s : State) (r : Read) :
    (step s (.read r)).1 = noteRead (judge s r) r ∨
    ∃ a, decideMove s r = some a ∧ (step s (.read r)).1 = emit (noteRead (judge s r) r) a := by
  rw [step_read]
  cases hd : decideMove s r with
  | none => exact Or.inl rfl
  | some a => exact Or.inr ⟨a, rfl, rfl⟩

theorem result_vinv {s : State} (h : VInv s) (a : Action) (o : Outcome) (p : Bool) : VInv (result s a o p) := by
  have hf := result_facts s a o p
  refine ⟨?_, ?_, ?_⟩
  · intro hv; rw [hf.1]
  · intro x hx
    rcases result_cases s a o p with ⟨_, _, t, h1, h2, h3, h4⟩ | ⟨h1, h2⟩
    · rw [h4] at hx ⊢
      by_cases hk : x = a.subject
      · rw [hk] at hx ⊢
        by_cases hp : t.provenNotFull = true
        · have := markFail_proven t a.subject hp
          have hc : strikeCount t a.subject = strikeCount s a.subject := by unfold strikeCount; rw [h2]
          rw [hc] at this
          rw [this.1] at hx
          exact this.2 hx
        · exact markFail_notproven _ _ (by simpa using hp)
      · rw [markFail_strike_other _ _ _ hk] at hx
        have hc : strikeCount t x = strikeCount s x := by unfold strikeCount; rw [h2]
        rw [hc] at hx
        have := h.strikes x hx
        exact (markFail_givenUp_other _ _ _ hk).2 (h1 ▸ this)
    · have hc : strikeCount (result s a o p) x = strikeCount s x := by unfold strikeCount; rw [h1]
      rw [hc] at hx
      rw [h2]; exact h.strikes x hx
  · intro b hb; rw [hf.1] at hb; cases hb

theorem vinv_step {s : State} (h : VInv s) (e : Event) (hn : vFree e = true) : VInv (step s e).1 := by
  cases e with
  | read r =>
    have hj := judge_vinv h r
    have hn' := noteRead_vinv hj r
    rcases step_read_state s r with h1 | ⟨a, hd, h1⟩
    · rw [h1]; exact hn'
    · rw [h1]
      obtain ⟨hi, hg, hp⟩ := decide_facts hd
      refine emit_vinv hn' a ?_ ?_
      · rw [noteRead_verified]; exact judge_verified_none hi hg
      · intro hu
        rw [noteRead_givenUp']
        exact plan_subject_not_givenUp (hp hu)
  | userEdit rec moved => simp [vFree] at hn
  | userRetry => simp [vFree] at hn
  | retryKey k => simp [vFree] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · exact result_vinv h a o p
      · exact h
    · exact h
  | passBoundary => simp only [step]; exact ⟨h.pend, h.strikes, h.flight⟩

/-! ### The potential: how many more drags of `k` the rule can allow -/

/-- Engine drags of `k` still possible: none once `k` is given up; otherwise three less its strikes, less one for a verified drag the next read will judge. -/
def pot (k : Key) (s : State) : Nat :=
  if k ∈ s.givenUp then 0 else 3 - strikeCount s k - (if s.verified = some k then 1 else 0)

theorem pot_congr {k : Key} {s t : State} (h1 : t.givenUp = s.givenUp) (h2 : t.strikes = s.strikes) (h3 : t.verified = s.verified) :
    pot k t = pot k s := by
  unfold pot strikeCount; rw [h1, h2, h3]

theorem pot_judge {s : State} (r : Read) (k : Key)
    (hr : s.verified = some k → s.gate r = true → verFailed s r k = true) : pot k (judge s r) ≤ pot k s := by
  rcases judge_cases s r with h | ⟨k0, hv, hi, hg, ⟨hm, h⟩ | ⟨hm, h⟩⟩
  · rw [h]; exact Nat.le_refl _
  · rw [h]
    by_cases hk : k0 = k
    · subst hk; rw [hr hv hg] at hm; cases hm
    · unfold pot strikeCount
      have : ¬ (s.verified = some k) := by rw [hv]; simpa using hk
      simp [this]
  · rw [h]
    by_cases hgu : k ∈ s.givenUp
    · have : k ∈ (markStrike { s with verified := none } k0).givenUp := markStrike_givenUp_mono _ _ _ hgu
      unfold pot; simp [this]
    · by_cases hk : k0 = k
      · subst hk
        have hs : pot k0 s = 3 - strikeCount s k0 - 1 := by unfold pot; simp [hgu, hv]
        rw [hs]
        have hc : strikeCount { s with verified := none } k0 = strikeCount s k0 := rfl
        have h1 := markStrike_strike { s with verified := none } k0
        rw [hc] at h1
        by_cases hg3 : k0 ∈ (markStrike { s with verified := none } k0).givenUp
        · unfold pot; simp [hg3]
        · have hlt : ¬ (3 ≤ strikeCount s k0 + 1) := fun h3 => hg3 (markStrike_giveup _ _ (by rw [hc]; exact h3))
          unfold pot
          simp only [hg3, ite_false, h1, markStrike_verified]
          simp
          omega
      · have hng : k ∉ (markStrike { s with verified := none } k0).givenUp := by
          intro hh; exact hgu ((markStrike_givenUp_other { s with verified := none } k0 k (Ne.symm hk)).1 hh)
        have hsc : strikeCount (markStrike { s with verified := none } k0) k = strikeCount s k := by
          rw [markStrike_strike_other _ _ _ (Ne.symm hk)]; rfl
        have : ¬ (s.verified = some k) := by rw [hv]; simpa using hk
        unfold pot
        simp [hng, hgu, hsc, markStrike_verified, this]

theorem pot_step {s : State} (h : VInv s) (k : Key) (e : Event) (hn : vFree e = true)
    (hv : ∀ k' o p, e = .moveResult k' o p → k' = k → o = .verified ∧ p = true)
    (hr : ∀ r, e = .read r → s.verified = some k → s.gate r = true → verFailed s r k = true) :
    verCnt k s e + pot k (step s e).1 ≤ pot k s := by
  cases e with
  | read r =>
    have h0 : verCnt k s (.read r) = 0 := by simp [verCnt]
    rw [h0, Nat.zero_add]
    have hj := pot_judge (s := s) r k (hr r rfl)
    have heq : pot k (step s (.read r)).1 = pot k (judge s r) := by
      rcases step_read_state s r with h1 | ⟨a, _, h1⟩
      · rw [h1]
        exact pot_congr (noteRead_givenUp' _ _) (noteRead_strikes' _ _) (noteRead_verified _ _)
      · rw [h1]
        exact pot_congr (by simp [emit, noteRead_givenUp']) (by simp [emit, noteRead_strikes']) (by simp [emit, noteRead_verified])
    rw [heq]; exact hj
  | userEdit rec moved => simp [vFree] at hn
  | userRetry => simp [vFree] at hn
  | retryKey k => simp [vFree] at hn
  | passBoundary =>
    have h0 : verCnt k s .passBoundary = 0 := by simp [verCnt]
    rw [h0, Nat.zero_add]
    simp only [step]
    exact Nat.le_of_eq (pot_congr rfl rfl rfl)
  | moveResult k' o p =>
    cases hf : s.inFlight with
    | none =>
      have hs' : step s (.moveResult k' o p) = (s, []) := by simp [step, hf]
      have h0 : verCnt k s (.moveResult k' o p) = 0 := by simp [verCnt, hf]
      rw [hs', h0]; simp
    | some a =>
      by_cases hs : (a.subject == k') = true
      · have hk' : a.subject = k' := by simpa using hs
        subst hk'
        have hs' : step s (.moveResult a.subject o p) = (result s a o p, []) := by simp [step, hf, hs]
        rw [hs']
        simp only []
        have hfa := result_facts s a o p
        have hpend : s.verified = none := by
          cases hv' : s.verified with
          | none => rfl
          | some _ => have := h.pend (by simp [hv']); rw [hf] at this; cases this
        by_cases hsk : a.subject = k
        · obtain ⟨ho, hp⟩ := hv a.subject o p rfl hsk
          subst ho; subst hp
          have hstr := hfa.2.2.2.2.2 (Or.inr (by simp))
          have hgu : ∀ x, x ∈ (result s a .verified true).givenUp ↔ x ∈ s.givenUp := fun x => by rw [hstr.2]
          have hsc : strikeCount (result s a .verified true) k = strikeCount s k := by unfold strikeCount; rw [hstr.1]
          have hver := hfa.2.1
          cases hu : a.user with
          | true =>
            have h0 : verCnt k s (.moveResult a.subject .verified true) = 0 := by simp [verCnt, hf, hu]
            rw [h0, Nat.zero_add]
            have : (result s a .verified true).verified = none := by rw [hver]; simp [hu]
            unfold pot
            simp only [hgu, hsc, this, hpend]
            simp
          | false =>
            have h1 : verCnt k s (.moveResult a.subject .verified true) = 1 := by
              simp [verCnt, hf, hu, hsk]
            rw [h1]
            have hng : k ∉ s.givenUp := hsk ▸ h.flight a hf hu
            have hlt : strikeCount s k < 3 := Nat.lt_of_not_le (fun hc => hng (h.strikes k hc))
            have : (result s a .verified true).verified = some k := by rw [hver]; simp [hu, hsk]
            unfold pot
            simp only [hgu, hsc, this, hpend, hng, if_false]
            simp
            omega
        · have h0 : verCnt k s (.moveResult a.subject o p) = 0 := by
            simp [verCnt, hf, hsk]
          rw [h0, Nat.zero_add]
          have hgu := (hfa.2.2.2.2.1 k (Ne.symm hsk))
          have hsc := hfa.2.2.2.1 k (Ne.symm hsk)
          have hver : (result s a o p).verified ≠ some k := by
            rw [hfa.2.1]
            split
            · simp; exact hsk
            · simp
          unfold pot
          simp only [hgu, hsc, hpend]
          simp [hver]
      · have hs' : step s (.moveResult k' o p) = (s, []) := by simp [step, hf, hs]
        have hs2 : (a.subject == k') = false := by simpa using hs
        have h0 : verCnt k s (.moveResult k' o p) = 0 := by
          simp [verCnt, hf, hs2]
        rw [hs', h0]; simp

/-! ### The theorem -/

/-- Every read the gate accepts, while a verified drag of `k` awaits judgement, shows that drag undone (macOS reverted every move of `k`): `k` still misplaced AND on the wrong side of its anchor. -/
def StillMisplacedAtGate (k : Key) : State → Read → Prop := fun s r => s.verified = some k → s.gate r = true → verFailed s r k = true

theorem verDrags_le_pot (k : Key) : ∀ (es : List Event) (s : State), VInv s → (∀ e ∈ es, vFree e = true) →
    AllVerified k es → AtReads (StillMisplacedAtGate k) s es → verDrags k s es ≤ pot k s
  | [], s, _, _, _, _ => by simp [verDrags]
  | e :: es, s, h, hn, hv, hr => by
    have h1 := pot_step h k e (hn e (by simp)) (fun k' o p he hk => hv e (by simp) k' o p he hk) hr.1
    have h2 := verDrags_le_pot k es (step s e).1 (vinv_step h e (hn e (by simp)))
      (fun x hx => hn x (by simp [hx])) (fun x hx => hv x (by simp [hx])) hr.2
    simp only [verDrags]
    omega

/-- **verified_revert_bounded.**  From ANY state satisfying `VInv`: under any event list with no user event in which every drag of `k` is answered
`verified` (posted) and every read the gate accepts still shows `k` misplaced, the engine posts at most THREE drags of `k`
(fewer if `k` already has strikes).  No hypothesis on the hold, the budget (3 on a full bar, 20 on a proven one), the pile, or what the other keys do. -/
theorem verified_revert_bounded_from (k : Key) (s : State) (es : List Event) (h : VInv s)
    (hn : ∀ e ∈ es, vFree e = true) (hv : AllVerified k es) (hr : AtReads (StillMisplacedAtGate k) s es) :
    verDrags k s es ≤ 3 - strikeCount s k := by
  have := verDrags_le_pot k es s h hn hv hr
  unfold pot at this
  split at this <;> omega

/-- The same from a fresh state: at most three posted engine drags of `k`, however many reads follow. -/
theorem verified_revert_bounded (rec : List Key) (k : Key) (es : List Event)
    (hn : ∀ e ∈ es, vFree e = true) (hv : AllVerified k es) (hr : AtReads (StillMisplacedAtGate k) (State.init rec) es) :
    verDrags k (State.init rec) es ≤ 3 := by
  have := verified_revert_bounded_from k (State.init rec) es (VInv.init rec) hn hv hr
  omega

/-! ### The rule itself, one clause at a time -/

/-- A posted engine drag answered `verified` leaves its subject to be judged by the next usable read ... -/
theorem res_verified_marks (s : State) (a : Action) (h : a.user = false) :
    (result s a .verified true).verified = some a.subject := by
  rw [(result_facts s a .verified true).2.1]; simp [h]

/-- ... and nothing else leaves a mark (a user's drag, a failed, refused or interrupted one, a drag with no mouse event). -/
theorem res_unverified_no_mark (s : State) (a : Action) (o : Outcome) (p : Bool) (h : a.user = true ∨ o ≠ .verified ∨ p = false) :
    (result s a o p).verified = none := by
  rw [(result_facts s a o p).2.1]
  rcases h with h | h | h <;> simp [h]

/-- The next usable read (gate true, nothing in flight) that still finds the marked key misplaced takes a strike for it, clears the mark, and never touches the hold
(on any bar: the contradiction is no evidence that the bar is full) ... -/
theorem judge_contradicted_strikes {s : State} {r : Read} {k : Key} (hv : s.verified = some k) (hi : s.inFlight = none)
    (hg : s.gate r = true) (hm : verFailed s r k = true) :
    (judge s r).strikes = k :: s.strikes ∧ (judge s r).verified = none ∧ (judge s r).hold = s.hold := by
  have h : judge s r = markStrike { s with verified := none } k := by
    unfold judge; simp [hv, hi, hg, hm]
  rw [h]
  exact ⟨rfl, rfl, rfl⟩

/-- ... and given up at the third strike. -/
theorem judge_contradicted_giveup {s : State} {r : Read} {k : Key} (hv : s.verified = some k) (hi : s.inFlight = none)
    (hg : s.gate r = true) (hm : verFailed s r k = true) (h2 : 2 ≤ strikeCount s k) :
    k ∈ (judge s r).givenUp := by
  have h : judge s r = markStrike { s with verified := none } k := by
    unfold judge; simp [hv, hi, hg, hm]
  rw [h]
  have hc : strikeCount { s with verified := none } k = strikeCount s k := rfl
  exact markStrike_giveup { s with verified := none } k (by rw [hc]; omega)

/-- A read that confirms the move (the key is no longer misplaced) clears the mark and takes no strike. -/
theorem judge_confirmed_clears {s : State} {r : Read} {k : Key} (hv : s.verified = some k) (hi : s.inFlight = none)
    (hg : s.gate r = true) (hm : verFailed s r k = false) :
    (judge s r).verified = none ∧ (judge s r).strikes = s.strikes ∧ (judge s r).givenUp = s.givenUp ∧ (judge s r).hold = s.hold := by
  have h : judge s r = { s with verified := none } := by
    unfold judge; simp [hv, hi, hg, hm]
  rw [h]; exact ⟨rfl, rfl, rfl, rfl⟩

/-- A read that cannot judge (no gate, or a drag in flight) leaves the mark. -/
theorem judge_unusable_keeps {s : State} {r : Read} (h : s.inFlight.isSome = true ∨ s.gate r = false) : judge s r = s := by
  rcases judge_cases s r with h1 | ⟨k0, _, hi, hg, _⟩
  · exact h1
  · rcases h with h | h <;> simp_all

/-- User events reset the mark with the key's strikes. -/
theorem filter_some_pred (o : Option Key) (p : Key → Bool) (k : Key) (h : o.filter p = some k) : p k = true := by
  cases o with
  | none => simp [Option.filter] at h
  | some v =>
    simp only [Option.filter] at h
    split at h
    · rename_i hp; injection h with h; subst h; exact hp
    · simp at h

/-- ejb.26: ANY record change clears the mark, whether or not it moves a key. -/
theorem edit_clears_verified (s : State) (rec moved : List Key) :
    (step s (.userEdit rec moved)).1.verified = none := by
  simp only [step]; split <;> rfl

/-- (a') After a user edit the next read judges nothing: it takes no strike, whichever key was pending. -/
theorem edit_read_no_strike (s : State) (rec moved : List Key) (r : Read) :
    (step (step s (.userEdit rec moved)).1 (.read r)).1.strikes = (step s (.userEdit rec moved)).1.strikes ∧
    (step (step s (.userEdit rec moved)).1 (.read r)).1.givenUp = (step s (.userEdit rec moved)).1.givenUp := by
  have hv := edit_clears_verified s rec moved
  generalize (step s (.userEdit rec moved)).1 = t at hv ⊢
  have hj : judge t r = t := by unfold judge; rw [hv]
  rcases step_read_state t r with h1 | ⟨a, _, h1⟩
  · rw [h1, hj]; exact ⟨noteRead_strikes' _ _, noteRead_givenUp' _ _⟩
  · rw [h1, hj]; exact ⟨by simp [emit, noteRead_strikes'], by simp [emit, noteRead_givenUp']⟩

/-- (a'), the whole story: an engine drag of `k` answered `verified`, then a user edit (of any kind), then any read: `k` has no more strikes than before the drag, and is given up only
if it already was. -/
theorem verified_drag_edit_read_no_strike (s : State) (a : Action) (hu : a.user = false) (rec moved : List Key) (r : Read) :
    strikeCount (step (step (result s a .verified true) (.userEdit rec moved)).1 (.read r)).1 a.subject ≤ strikeCount s a.subject ∧
    (a.subject ∈ (step (step (result s a .verified true) (.userEdit rec moved)).1 (.read r)).1.givenUp → a.subject ∈ s.givenUp) := by
  have h := edit_read_no_strike (result s a .verified true) rec moved r
  have hf := (result_facts s a .verified true).2.2.2.2.2 (Or.inr (by simp))
  have e1 : strikeCount (step (result s a .verified true) (.userEdit rec moved)).1 a.subject ≤ strikeCount (result s a .verified true) a.subject := by
    simp only [step]; split
    · exact Nat.le_refl _
    · unfold strikeCount
      exact ((List.filter_sublist).filter _).length_le
  have e2 : ∀ x, x ∈ (step (result s a .verified true) (.userEdit rec moved)).1.givenUp → x ∈ (result s a .verified true).givenUp := by
    intro x hx; simp only [step] at hx; split at hx
    · exact hx
    · exact (List.mem_filter.1 hx).1
  have e3 : strikeCount (result s a .verified true) a.subject = strikeCount s a.subject := by unfold strikeCount; rw [hf.1]
  refine ⟨?_, fun hg => ?_⟩
  · unfold strikeCount at e1 e3 ⊢
    rw [h.1]; omega
  · rw [h.2] at hg
    have := e2 _ hg
    rwa [hf.2] at this

/-- (b') THE VERDICT LOOKS AT `k` AND ITS ANCHOR ALONE: it is a function of the movable keys `k` and the anchor, in the order the read draws them.  Two reads that draw those two keys in the same
order (whatever the other keys, the record keys macOS moved across `k` among them) give the same verdict. -/
theorem crossing_keeps_verdict (s : State) (r r' : Read) (k : Key) (rel : Rel)
    (h : (movable s r).filter (fun x => x == k || x == rel.target) = (movable s r').filter (fun x => x == k || x == rel.target)) :
    revertedFromAnchor s r k rel = revertedFromAnchor s r' k rel := by
  unfold revertedFromAnchor; rw [h]

/-- A key `y` other than `k` and the anchor that is moved to another place (the bar without it is unchanged) does not change what is drawn of `k` and the anchor. -/
theorem filter_erase_other (l : List Key) (y : Key) (p : Key → Bool) (hy : p y = false) : (l.erase y).filter p = l.filter p := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x = y
    · subst hx; simp [hy]
    · simp [hx, List.filter_cons, ih]

theorem crossing_move_keeps_verdict (s : State) (r r' : Read) (k y : Key) (rel : Rel) (hk : y ≠ k) (ht : y ≠ rel.target)
    (h : (movable s r).erase y = (movable s r').erase y) :
    revertedFromAnchor s r k rel = revertedFromAnchor s r' k rel := by
  apply crossing_keeps_verdict
  have hp : (fun x => x == k || x == rel.target) y = false := by simp [hk, ht]
  rw [← filter_erase_other _ y _ hp, ← filter_erase_other (movable s r') y _ hp, h]

/-- (b') A read that shows `k` on the side of its anchor the drag put it (not `revertedFromAnchor`) takes NO strike for it, whatever else it shows: the key's mark is cleared and strikes and
given-up keys are exactly as before. -/
theorem judge_landed_no_strike {s : State} {r : Read} {k : Key} (hv : s.verified = some k)
    (hl : revertedFromAnchor s r k s.verRel = false) :
    (judge s r).strikes = s.strikes ∧ (judge s r).givenUp = s.givenUp := by
  rcases judge_cases s r with h | ⟨k0, hv0, _, _, ⟨_, h⟩ | ⟨hm, h⟩⟩
  · rw [h]; exact ⟨rfl, rfl⟩
  · rw [h]; exact ⟨rfl, rfl⟩
  · exfalso
    rw [hv0] at hv; cases hv
    unfold verFailed at hm
    simp [hl] at hm

theorem retry_clears_verified (s : State) : (step s .userRetry).1.verified = none := by simp [step]

theorem rk_clears_verified (s : State) (k : Key) : (step s (.retryKey k)).1.verified ≠ some k := by
  simp only [step]
  intro heq
  have := filter_some_pred _ _ _ heq
  simp at this

end Sommelier
