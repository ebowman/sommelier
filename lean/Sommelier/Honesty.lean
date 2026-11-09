import Sommelier.Gates
import Sommelier.Status

/-!
# Sommelier decision core: liveness and honesty (ejb.3)

1. `quiescence`: once the budget is spent, or a hold is set, the engine does nothing without a user event.
2. `userAlwaysAnswered_*`: the user's drop is answered on a usable reading (`State.gate`); Re-apply clears every restriction.
3. No needless drag (`noNeedlessDrag*`): every action changes the drawn list.
4. The status line and the rows (`Status.lean`): what they promise, from `shownVerdict` and `rowVerdict` alone.

Imports `Gates` and `Status` (and so `Step` and `Truth`), not `Safety`: see the note in `Gates.lean`.  `Honesty` is NOT independent of `Gates`: a broken
`Gates.lean` proof stops this module from building (the mutation script credits such a kill to `Gates`, and builds this module only when `Gates` builds).
-/

set_option linter.unusedSimpArgs false

namespace Sommelier

/-! ### Runs: predicates at every read -/

/-- `P` holds, in the state before it, at every read of the event list. -/
def AtReads (P : State → Read → Prop) : State → List Event → Prop
  | _, [] => True
  | s, e :: es => (∀ r, e = .read r → P s r) ∧ AtReads P (step s e).1 es

theorem atReads_of_split {P : State → Read → Prop} (es : List Event) :
    ∀ (s : State), (∀ pre r post, es = pre ++ .read r :: post → P (run s pre).1 r) → AtReads P s es := by
  induction es with
  | nil => intro s _; trivial
  | cons e es ih =>
    intro s h
    refine ⟨fun r hr => ?_, ih _ (fun pre r post hp => ?_)⟩
    · subst hr
      simpa [run] using h [] r es (by simp)
    · have := h (e :: pre) r post (by simp [hp])
      simpa [gate_run_cons] using this

def Closed (s : State) (r : Read) : Prop := engineAllowed s r = false

theorem closed_user_run : ∀ (es : List Event) (s : State), AtReads Closed s es →
    ∀ a ∈ (run s es).2, a.user = true
  | [], s, _ => by simp [run]
  | e :: es, s, ⟨h1, h2⟩ => by
    intro a ha
    rw [gate_run_cons] at ha
    simp only [List.mem_append] at ha
    rcases ha with ha | ha
    · obtain ⟨r, hr, _, _⟩ := gate_step_acts ha
      subst hr
      exact gate_closed_user ha (h1 r rfl)
    · exact closed_user_run es _ h2 a ha

/-- Nothing is owed, nothing is in flight. -/
def Idle (s : State) : Prop := s.inFlight = none ∧ s.owedKeys = [] ∧ s.foldRequest = none

theorem decide_none_idle {s : State} {r : Read} (hi : Idle s) (hc : engineAllowed s r = false) :
    decideMove s r = none := by
  simp only [decideMove, userPick, hi.2.1, hi.2.2, hc]
  simp

theorem idle_step {s : State} (hi : Idle s) {e : Event} (hn : userEv e = false)
    (hc : ∀ r, e = .read r → engineAllowed s r = false) : Idle (step s e).1 ∧ (step s e).2 = [] := by
  obtain ⟨h1, h2, h3⟩ := hi
  cases e with
  | read r =>
    have nk := noteRead_keeps s r
    have hd := decide_none_idle ⟨h1, h2, h3⟩ (hc r rfl)
    simp only [step, hd]
    exact ⟨⟨by rw [nk.2.2.2.1]; exact h1, by rw [nk.1]; exact h2, by rw [nk.2.1]; exact h3⟩, by simp⟩
  | userEdit rec moved =>
    have hm : moved = [] := by
      cases moved with
      | nil => rfl
      | cons x xs => simp [userEv] at hn
    subst hm
    simp [step, Idle, h1, h2, h3]
  | userRetry => simp [userEv] at hn
  | retryKey k => simp [userEv] at hn
  | moveResult k o p => simp [step, Idle, h1, h2, h3]
  | passBoundary => simp [step, Idle, h1]

theorem idle_run : ∀ (es : List Event) (s : State), Idle s → (∀ e ∈ es, userEv e = false) →
    AtReads Closed s es → (run s es).2 = []
  | [], s, _, _, _ => by simp [run]
  | e :: es, s, hi, hn, ⟨h1, h2⟩ => by
    have := idle_step hi (hn e (by simp)) (fun r hr => h1 r hr)
    rw [gate_run_cons, this.2]
    simp only [List.nil_append]
    exact idle_run es _ this.1 (fun x hx => hn x (by simp [hx])) h2

/-! ### The budget never comes back without a user event, and a hold only on the proof -/

theorem moveCount_mono (s : State) {e : Event} (hn : userEv e = false) : s.moveCount ≤ (step s e).1.moveCount := by
  cases e with
  | read r =>
    have nk := noteRead_keeps s r
    simp only [step]
    cases hd : decideMove s r with
    | none => simp [nk.2.2.2.2.2.2.2.2.1]
    | some a => simp [emit, nk.2.2.2.2.2.2.2.2.1]
  | userEdit rec moved =>
    cases moved with
    | nil => simp [step]
    | cons x xs => simp [userEv] at hn
  | userRetry => simp [userEv] at hn
  | retryKey k => simp [userEv] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · split
      · rw [res_count_exact]; omega
      · exact Nat.le_refl _
    · exact Nat.le_refl _
  | passBoundary => simp [step]

theorem quiet_budget_20 : ∀ (es : List Event) (s : State), 20 ≤ s.moveCount → (∀ e ∈ es, userEv e = false) →
    AtReads Closed s es
  | [], s, _, _ => trivial
  | e :: es, s, hc, hn => by
    refine ⟨fun r _ => ?_, quiet_budget_20 es _ (Nat.le_trans hc (moveCount_mono s (hn e (by simp))))
      (fun x hx => hn x (by simp [hx]))⟩
    simp only [Closed, engineAllowed, cap, capFull, capNotFull]
    split <;> simp <;> omega

theorem quiet_budget_3 : ∀ (es : List Event) (s : State), 3 ≤ s.moveCount → (∀ e ∈ es, userEv e = false) →
    AtReads (fun s r => fullBar s r = true) s es → AtReads Closed s es
  | [], s, _, _, _ => trivial
  | e :: es, s, hc, hn, ⟨hf, hf2⟩ => by
    refine ⟨fun r hr => ?_, quiet_budget_3 es _ (Nat.le_trans hc (moveCount_mono s (hn e (by simp))))
      (fun x hx => hn x (by simp [hx])) hf2⟩
    have := hf r hr
    simp only [Closed, engineAllowed, cap, capFull, capNotFull, this]
    simp; omega

/-- A hold is released only by a user event or by gaining the proof. -/
def Gain (s : State) (r : Read) : Prop := s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true

theorem noteRead_hold_gain (s : State) (r : Read) (h1 : s.hold = true) (h2 : (noteRead s r).hold = false) : Gain s r := by
  have : s.provenNotFull = false ∧ (noteRead s r).provenNotFull = true := by
    unfold noteRead at *
    grind
  exact this

theorem hold_keeps {s : State} (h : s.hold = true) {e : Event} (hn : userEv e = false)
    (hg : ∀ r, e = .read r → ¬ Gain s r) : (step s e).1.hold = true := by
  cases e with
  | read r =>
    have nk := noteRead_keeps s r
    have hh : (noteRead s r).hold = true := by
      cases hh : (noteRead s r).hold with
      | true => rfl
      | false => exact absurd (noteRead_hold_gain s r h hh) (hg r rfl)
    simp only [step]
    cases hd : decideMove s r with
    | none => simpa using hh
    | some a => simpa [emit] using hh
  | userEdit rec moved =>
    cases moved with
    | nil => simp [step, h]
    | cons x xs => simp [userEv] at hn
  | userRetry => simp [userEv] at hn
  | retryKey k => simp [userEv] at hn
  | moveResult k o p =>
    simp only [step]
    split
    · split
      · unfold result; grind
      · exact h
    · exact h
  | passBoundary => simp [step, h]

theorem quiet_hold : ∀ (es : List Event) (s : State), s.hold = true → (∀ e ∈ es, userEv e = false) →
    AtReads (fun s r => ¬ Gain s r) s es → AtReads Closed s es
  | [], s, _, _, _ => trivial
  | e :: es, s, hh, hn, ⟨hg, hg2⟩ => by
    refine ⟨fun r _ => ?_, quiet_hold es _ (hold_keeps hh (hn e (by simp)) hg)
      (fun x hx => hn x (by simp [hx])) hg2⟩
    simp [Closed, engineAllowed, hh]

/-- **Quiescence.**  With no user event in `es`, once the budget is spent (20 posted engine drags; or 3 while the bar is full at
every read) or a hold is set that no read of `es` lifts by gaining the proof, every action of the run is the user's own
(an owed drop or the fold request); and if nothing is owed, in flight or requested, there is no action at all. -/
theorem quiescence (s : State) (es : List Event) (hn : ∀ e ∈ es, userEv e = false)
    (hcond : 20 ≤ s.moveCount ∨
      (3 ≤ s.moveCount ∧ ∀ pre r post, es = pre ++ .read r :: post → fullBar (run s pre).1 r = true) ∨
      (s.hold = true ∧ ∀ pre r post, es = pre ++ .read r :: post → ¬ Gain (run s pre).1 r)) :
    (∀ a ∈ (run s es).2, a.user = true) ∧
    (Idle s → (run s es).2 = []) := by
  have hcl : AtReads Closed s es := by
    rcases hcond with h | ⟨h, hf⟩ | ⟨h, hg⟩
    · exact quiet_budget_20 es s h hn
    · exact quiet_budget_3 es s h hn (atReads_of_split es s hf)
    · exact quiet_hold es s h hn (atReads_of_split es s hg)
  exact ⟨closed_user_run es s hcl, fun hi => idle_run es s hi hn hcl⟩

/-! ### 2. The user is always answered -/

/-- The state right after the user drops `k` (the edit's `record`, `moved = [k]`). -/
abbrev edited (s : State) (rec : List Key) (k : Key) : State := (step s (.userEdit rec [k])).1

theorem findSome_const {α : Type} (f : Key → Option α) (k : Key) :
    ∀ (l : List Key), (∀ x ∈ l, x = k) → k ∈ l → l.findSome? f = f k
  | [], _, hk => by simp at hk
  | x :: xs, h, hk => by
    have hx : x = k := h x (by simp)
    subst hx
    cases hf : f x with
    | some v => simp [List.findSome?, hf]
    | none =>
      simp only [List.findSome?, hf]
      by_cases hm : x ∈ xs
      · have := findSome_const f x xs (fun y hy => h y (by simp [hy])) hm
        simpa [hf] using this
      · have : xs = [] := by
          cases xs with
          | nil => rfl
          | cons y ys => exact absurd (by rw [h y (by simp)]; simp) hm
        simp [this]

theorem edited_facts (s : State) (rec : List Key) (k : Key) (hk : k ∈ rec) :
    (edited s rec k).inFlight = s.inFlight ∧ (edited s rec k).editSessionUsed = false ∧
    (edited s rec k).restricted = true ∧ (edited s rec k).lastFreshPile = s.lastFreshPile ∧
    (∀ j ∈ (edited s rec k).owedKeys, j = k ∨ j ∈ s.owedKeys) ∧ k ∈ (edited s rec k).owedKeys := by
  refine ⟨by simp [edited, step], by simp [edited, step], by simp [edited, step], by simp [edited, step], ?_, ?_⟩
  · intro j hj
    have := (edit_owed s rec [k] (by simp) j).1 hj
    simp at this
    grind
  · exact (edit_owed s rec [k] (by simp) k).2 ⟨hk, Or.inr (by simp)⟩

theorem mem_movable_iff (s : State) (r : Read) (k : Key) :
    k ∈ movable s r ↔ k ∈ r.drawn ∧ k ∈ r.trusted ∧ k ∉ foldedAll s r := by
  simp [movable, List.mem_filter]

/-- A true gate says the read is a settled complete-enough pass read with the strip closed (all in `Read.usable`). -/
theorem gate_facts {s : State} {r : Read} (h : s.gate r = true) :
    r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ r.stripOpen = false := by
  unfold State.gate at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  obtain ⟨⟨h1, h2, h3, _, h5, _⟩, _⟩ := h
  exact ⟨h1, h2, h3, h5⟩

/-- On a fresh chevron the gate makes the read itself usable: it supersedes the pile memory (`foldedAll`). -/
theorem gate_fresh_usable {s : State} {r : Read} (h : s.gate r = true) (hc : r.chevron = .fresh) : r.usable ∧ r.chevron = .fresh := by
  unfold State.gate at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  obtain ⟨⟨h1, h2, h3, h4, h5, _⟩, _⟩ := h
  exact ⟨⟨h1, h2, h3, h4, h5, Or.inl hc⟩, hc⟩

/-- A trusted drawn key of a gate-true FRESH-chevron read is not folded: the read is consistent, and it supersedes the memory. -/
theorem fresh_drawn_not_folded {s : State} {r : Read} (h : s.gate r = true) (hc : r.chevron = .fresh) {k : Key}
    (hd : k ∈ r.drawn) (ht : k ∈ r.trusted) : k ∉ foldedAll s r := by
  have hu := gate_fresh_usable h hc
  unfold State.gate at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  have hcons := (consistent_iff).1 h.2
  have hu' : (s.view r).usable := h.1
  have hc' : (s.view r).chevron = .fresh := hc
  have hopen : k ∈ (s.view r).pinOpen := by
    rw [pinOpen_def hu']
    show k ∈ r.trustedDrawn
    simp [Read.trustedDrawn, List.mem_filter, hd, ht]
  have hnb := hcons.2 k hopen
  rw [pinBehind_fresh hu' hc'] at hnb
  rw [mem_foldedAll]
  rintro (hf | ⟨hn, _⟩)
  · exact hnb hf
  · exact hn hu

/-- The queue head: when `k` heads the queue (the fold request, then the owed keys), its move, if it has one that is allowed, is the one
the read decides, whatever else is owed. -/
theorem decide_head {s : State} {r : Read} {k : Key} {a : Action} (hi : s.inFlight = none) (hg : s.gate r = true)
    (hfirst : (s.foldRequest.toList ++ s.owedKeys).head? = some k)
    (hum : userMove1 s r k = some a) (hal : userAllowed s r a = true) : decideMove s r = some a := by
  obtain ⟨hpass, hset, hinc, _⟩ := gate_facts hg
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  simp only [decideMove]
  rw [if_neg hc, userPick_head1 hfirst hum hal]

/-- After the drop, `k` heads the queue when nothing else was owed or requested (the usual case), and in general when the hypothesis says so. -/
theorem edited_first_of_idle (s : State) (rec : List Key) (k : Key) (hk : k ∈ rec) (ho : s.owedKeys = []) (hq : s.foldRequest = none) :
    ((edited s rec k).foldRequest.toList ++ (edited s rec k).owedKeys).head? = some k := by
  have F := edited_facts s rec k hk
  have hq1 : (edited s rec k).foldRequest = none ∨ (edited s rec k).foldRequest = some k := by
    cases hf : (edited s rec k).foldRequest with
    | none => exact Or.inl rfl
    | some p =>
      have := edit_request_origin s rec [k] (by simp) p hf
      rcases this with h | h
      · have hpk : p = k := by simpa using h.1
        rw [hpk]; exact Or.inr rfl
      · simp [hq] at h
  have hoe : ∀ j ∈ (edited s rec k).owedKeys, j = k := fun j hj => by
    rcases F.2.2.2.2.1 j hj with h | h; exact h; simp [ho] at h
  rcases hq1 with h | h
  · rw [h]
    cases hl : (edited s rec k).owedKeys with
    | nil => rw [hl] at F; simp at F
    | cons x xs => simp [hoe x (by rw [hl]; simp)]
  · simp [h]

/-- **The user's drop of a drawn key is answered** (drawn case), from ANY state with nothing in flight and `k` first in the queue, on a read where the
gate is true: if `k` is a trusted drawn key that is not counted as folded, is out of place among its anchors and the anchors admit a gap, exactly one
action leaves, a move of `k`, the user's own.  No hypothesis on the hold, the budget, the given-up keys, the strip (a true gate says it is closed and the
edit opened a new session), the fold request or the pile memory (`fresh_drawn_not_folded`: on a fresh chevron a trusted drawn key is never counted as folded). -/
theorem userAlwaysAnswered_drawn (s : State) (rec : List Key) (k : Key) (r : Read)
    (hi : s.inFlight = none) (hg : (edited s rec k).gate r = true) (hk : k ∈ rec)
    (hfirst : ((edited s rec k).foldRequest.toList ++ (edited s rec k).owedKeys).head? = some k)
    (hd : k ∈ r.drawn) (ht : k ∈ r.trusted) (hnf : k ∉ foldedAll (edited s rec k) r)
    (hne : ¬ SameKeys (seenOf (edited s rec k) r k) (wantOf (edited s rec k) r k))
    (hpf : (prefixFor (wantOf (edited s rec k) r k) (anchorsOf (edited s rec k) r k)).isSome = true) :
    ∃ a, (step (edited s rec k) (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true ∧
      userMove (edited s rec k) r k = some a := by
  have F := edited_facts s rec k hk
  obtain ⟨_, _, _, hso⟩ := gate_facts hg
  have hmov : k ∈ movable (edited s rec k) r := (mem_movable_iff _ _ _).2 ⟨hd, ht, hnf⟩
  obtain ⟨a, ha0⟩ := anchorMove_moves hmov hne hpf
  have ha1 : userMove1 (edited s rec k) r k = some a := by rw [userMove1_movable hmov]; exact ha0
  have ha : userMove (edited s rec k) r k = some a := userMove_of_phase1 ha1
  have hallowed : userAllowed (edited s rec k) r a = true := by
    simp [userAllowed, F.2.1, hso]
  have hdm : decideMove (edited s rec k) r = some a := decide_head (by rw [F.1]; exact hi) hg hfirst ha1 hallowed
  obtain ⟨hu, hsub⟩ := gate_userMove_user ha
  refine ⟨a, ?_, hsub, hu, ha⟩
  simp [step, hdm]

/-- No move is due (`userMove` is none): nothing leaves, when nothing else is owed or requested; the engine is restricted by the edit. -/
theorem userAlwaysAnswered_none (s : State) (rec : List Key) (k : Key) (r : Read)
    (hi : s.inFlight = none) (ho : s.owedKeys = []) (hq : s.foldRequest = none) (hk : k ∈ rec)
    (hnone : userMove (edited s rec k) r k = none) :
    (step (edited s rec k) (.read r)).2 = [] := by
  have F := edited_facts s rec k hk
  cases hs : (step (edited s rec k) (.read r)).2 with
  | nil => rfl
  | cons a t =>
    exfalso
    have ha : a ∈ (step (edited s rec k) (.read r)).2 := by simp [hs]
    obtain ⟨r', he, hd, _⟩ := gate_step_acts ha
    cases he
    have hq1 : (edited s rec k).foldRequest = none ∨ (edited s rec k).foldRequest = some k := by
      cases hf : (edited s rec k).foldRequest with
      | none => exact Or.inl rfl
      | some p =>
        have := edit_request_origin s rec [k] (by simp) p hf
        rcases this with h | h
        · have hpk : p = k := by simpa using h.1
          rw [hpk]; exact Or.inr rfl
        · simp [hq] at h
    rcases (gate_decide_cases hd).2 with ⟨j, hj, hjm, _⟩ | ⟨hea, _⟩
    · have hjk : j = k := by
        rcases hj with hj | hj
        · rcases hq1 with h | h
          · simp [h] at hj
          · simp [h] at hj; exact hj
        · rcases F.2.2.2.2.1 j hj with h | h; exact h; simp [ho] at h
      subst hjk
      simp [hnone] at hjm
    · simp [engineAllowed, F.2.2.1] at hea

/-- **The user's drop of a folded key is answered** (folded case), from ANY state with nothing in flight and `k` first in the queue, on a read where the
gate is true: `k` is owed (the drop), this read lists it as folded under a fresh chevron, and a movable key precedes it in the record.  Then exactly one
action leaves, a move of `k` just after the rightmost such key, with the strip, the user's own.  The drop's memory is not needed: this is the reading
that licenses the pull-out. -/
theorem userAlwaysAnswered_pull (s : State) (rec : List Key) (k : Key) (r : Read)
    (hi : s.inFlight = none) (hg : (edited s rec k).gate r = true) (hk : k ∈ rec)
    (hfirst : ((edited s rec k).foldRequest.toList ++ (edited s rec k).owedKeys).head? = some k)
    (hc : r.chevron = .fresh) (hfs : k ∈ r.foldedSet) (hnd : k ∉ r.drawn)
    (hp : ∃ x ∈ movable (edited s rec k) r, x ∈ (edited s rec k).record.takeWhile (fun y => y != k)) :
    ∃ a, (step (edited s rec k) (.read r)).2 = [a] ∧ a.strip = true ∧ a.user = true ∧ a.subject = k ∧
      userMove (edited s rec k) r k = some a := by
  have F := edited_facts s rec k hk
  obtain ⟨_, _, _, hso⟩ := gate_facts hg
  have hu := gate_fresh_usable hg hc
  have hfold : k ∈ foldedAll (edited s rec k) r := by
    rw [mem_foldedAll]; exact Or.inl hfs
  obtain ⟨x, hx, hxb⟩ := hp
  have hex : ((movable (edited s rec k) r).filter (fun y => ((edited s rec k).record.takeWhile (fun z => z != k)).contains y)).getLast? ≠ none := by
    intro h0
    rw [List.getLast?_eq_none_iff] at h0
    have : x ∈ (movable (edited s rec k) r).filter (fun y => ((edited s rec k).record.takeWhile (fun z => z != k)).contains y) := by
      simp only [List.mem_filter, List.contains_iff_mem]; exact ⟨hx, hxb⟩
    rw [h0] at this; simp at this
  obtain ⟨p, hpl⟩ : ∃ p, ((movable (edited s rec k) r).filter (fun y => ((edited s rec k).record.takeWhile (fun z => z != k)).contains y)).getLast? = some p := by
    cases h : ((movable (edited s rec k) r).filter (fun y => ((edited s rec k).record.takeWhile (fun z => z != k)).contains y)).getLast? with
    | none => exact absurd h hex
    | some p => exact ⟨p, rfl⟩
  have hpm : p ∈ movable (edited s rec k) r := by
    have := List.mem_of_getLast? hpl
    exact (List.mem_filter.1 this).1
  have hpd : p ∈ r.drawn := gate_movable_mem hpm
  have hchg : applyMove r.drawn ⟨k, .after p, needsStrip (edited s rec k) r k (.after p), true⟩ ≠ r.drawn := by
    intro heq
    have hpk : p ≠ k := fun h => hnd (h ▸ hpd)
    obtain ⟨pre, post, hh⟩ := applyMove_after r.drawn ⟨k, .after p, needsStrip (edited s rec k) r k (.after p), true⟩ p rfl (by simpa using hpk.symm) hpd
    rw [heq] at hh
    apply hnd
    rw [hh]; simp
  have hum := userMove_folded_some hfold (Or.inr F.2.2.2.2.2) hc (by simpa using hfs) hpl hchg
  have hallowed : userAllowed (edited s rec k) r ⟨k, .after p, needsStrip (edited s rec k) r k (.after p), true⟩ = true := by
    simp [userAllowed, needsStrip, F.2.1, hso]
  have hdm := decide_head (by rw [F.1]; exact hi) hg hfirst ((userMove1_folded hfold).trans hum) hallowed
  have hst := (userMove_folded hfold hum).2.2.2
  obtain ⟨p', _, _, hsub, hs2, hu2⟩ := hst
  refine ⟨_, ?_, hs2, hu2, hsub, hum⟩
  simp [step, hdm]

/-- **Only a user's drop crosses the fold.**  Any move, from ANY state and read, whose subject this read lists as folded is the user's own, on a fresh chevron,
and its subject is the fold request or an owed (dropped) key.  The engine never names a folded key (`noFoldedTarget`), and a folded key the user did not drop
never gets a pull-out; the memory alone licenses nothing. -/
theorem fold_crossed_only_by_drop {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hf : a.subject ∈ r.foldedSet) :
    a.user = true ∧ (s.foldRequest = some a.subject ∨ a.subject ∈ s.owedKeys) ∧ r.chevron = .fresh := by
  obtain ⟨r', he, hd, _⟩ := gate_step_acts h
  cases he
  have hfa : a.subject ∈ foldedAll s r := (mem_foldedAll s r a.subject).2 (Or.inl hf)
  rcases (gate_decide_cases hd).2 with ⟨k, _, hum, _⟩ | ⟨_, b, hb, hcase⟩
  · obtain ⟨hu, hsub⟩ := gate_userMove_user hum
    subst hsub
    obtain ⟨hq, hc, _⟩ := userMove_folded hfa hum
    exact ⟨hu, hq, hc⟩
  · exfalso
    obtain ⟨w, h', hw, _, hwm, _⟩ := plan_mem s r b hb
    have hsub : a.subject = b.subject := by
      rcases hcase with ⟨_, rfl⟩ | ⟨_, _, rfl⟩ <;> rfl
    exact gate_movable_not_folded (hsub ▸ hw ▸ hwm) hfa

/-- **Why a key gets no move (`userMove` is none).**  The six causes (the seventh and eighth of `owed_unanswered_reason` need a move to exist or another key to go first). -/
theorem userMove_none_reason (s : State) (r : Read) (k : Key) (howed : k ∈ s.owedKeys)
    (hum : userMove s r k = none) :
    (k ∈ movable s r ∧ misplaced s r k = false) ∨
    (k ∈ movable s r ∧ misplaced s r k = true ∧ (k ∉ s.record ∨ wholeBar s r = false ∨ NoReducingDrag s r k)) ∨
    (k ∉ foldedAll s r ∧ ¬ (k ∈ r.drawn ∧ k ∈ r.trusted)) ∨
    (k ∈ foldedAll s r ∧ ¬ (r.chevron = .fresh ∧ k ∈ r.foldedSet)) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = none) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧ ∃ p,
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn) := by
  by_cases hfd : k ∈ foldedAll s r
  · by_cases hlic : r.chevron = .fresh ∧ k ∈ r.foldedSet
    · right; right; right; right
      cases hl : ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? with
      | none => left; exact ⟨hfd, hlic.1, hlic.2, rfl⟩
      | some p =>
        right
        refine ⟨hfd, hlic.1, hlic.2, p, rfl, ?_⟩
        by_cases hchg : applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn
        · exact hchg
        · exfalso
          have := userMove_folded_some hfd (Or.inr howed) hlic.1 (by simpa using hlic.2) hl hchg
          rw [hum] at this; simp at this
    · right; right; right; left; exact ⟨hfd, hlic⟩
  · by_cases hmv : k ∈ movable s r
    · have hfm : fallbackMove s r k = none := by
        rw [userMove_drawn_spec hmv] at hum
        cases ha : anchorMove s r k with
        | some a => rw [ha] at hum; simp at hum
        | none => rw [ha] at hum; exact hum
      rcases fallbackMove_none_cases howed hmv hfm with h | ⟨hm, hn⟩
      · left; exact ⟨hmv, h⟩
      · right; left; exact ⟨hmv, hm, hn⟩
    · right; right; left
      refine ⟨hfd, fun ⟨h1, h2⟩ => hmv ((mem_movable_iff _ _ _).2 ⟨h1, h2, hfd⟩)⟩

/-- **The converse: an owed key that gets no move has a named reason.**  From ANY state with nothing in flight, on a read where the gate is true, if the
read emits no move of the owed key `k`, then one of these holds: (1) it is a movable key that is not misplaced: exactly the movable record keys that precede it in
the record precede it on the bar; (2) it is movable and misplaced, but the one place `fallbackRel` names (just after its nearest movable record predecessor, else just
before its first movable follower) is where it already stands, so the move would change nothing: the keys AROUND it are out of order; (3) it is not a trusted drawn key
and not counted as folded (it is not on the bar, or not read); (4) it is counted as folded but this read does not license a pull-out (no fresh chevron listing it: the
pile memory alone never does); (5) it is folded and licensed but no movable key precedes it in the record; (6) the pull-out would change nothing (the key is drawn
already, right after its predecessor); (7) a move exists and needs the strip, and this edit's session is used (the strip being open is excluded by the gate); (8)
another queued key went first.  (The old reasons "right among its anchors" and "the anchors admit no gap" are GONE: the fallback answers both when the key is misplaced.) -/
theorem owed_unanswered_reason (s : State) (r : Read) (k : Key) (hi : s.inFlight = none) (hg : s.gate r = true)
    (howed : k ∈ s.owedKeys) (hno : ∀ a ∈ (step s (.read r)).2, a.subject ≠ k) :
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
    (∃ j a, j ∈ s.foldRequest.toList ++ s.owedKeys ∧ j ≠ k ∧ (step s (.read r)).2 = [a] ∧ a.subject = j ∧ a.user = true) := by
  obtain ⟨hpass, hset, hinc, hso⟩ := gate_facts hg
  have hq : k ∈ s.foldRequest.toList ++ s.owedKeys := List.mem_append_right _ howed
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  cases hb : userPick s r with
  | some b =>
    -- another queued key's move is the decision
    obtain ⟨j, hjq, hj⟩ := userPick_exists hb
    have hdb : decideMove s r = some b := by simp only [decideMove]; rw [if_neg hc, hb]
    have hstep : (step s (.read r)).2 = [b] := by simp [step, hdb]
    cases hu : userMove s r j with
    | none => simp [hu] at hj
    | some c =>
      simp only [hu, Option.filter] at hj
      split at hj
      · simp only [Option.some.injEq] at hj
        subst hj
        obtain ⟨hu1, hsub⟩ := gate_userMove_user hu
        have hjk : j ≠ k := fun h => hno c (by simp [hstep]) (by rw [hsub, h])
        exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inr ⟨j, c, hjq, hjk, hstep, hsub, hu1⟩))))))
      · simp at hj
  | none =>
    have hfk : (userMove s r k).filter (userAllowed s r) = none := userPick_none hb k hq
    cases hum : userMove s r k with
    | some a =>
      -- a move exists but is not allowed: the strip session is used
      right; right; right; right; right; right; left
      have hna : userAllowed s r a = false := by
        simp only [hum, Option.filter] at hfk
        split at hfk
        · simp at hfk
        · rename_i hh; simpa using hh
      refine ⟨a, rfl, ?_, ?_⟩
      · simp only [userAllowed, Bool.not_eq_false', Bool.and_eq_true] at hna
        exact hna.1
      · simp only [userAllowed, Bool.not_eq_false', Bool.and_eq_true, Bool.or_eq_true] at hna
        rcases hna.2 with h | h
        · exact h
        · rw [hso] at h; simp at h
    | none =>
      rcases userMove_none_reason s r k howed hum with h | h | h | h | h | h
      · exact Or.inl h
      · exact Or.inr (Or.inl h)
      · exact Or.inr (Or.inr (Or.inl h))
      · exact Or.inr (Or.inr (Or.inr (Or.inl h)))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl h))))
      · exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl h)))))

/-- Re-apply leaves every state the user could be stuck in: no hold, no given-up key, no spent budget, no restriction,
no owed drop, and a strip session granted. -/
theorem userRetry_leaves (s : State) :
    (step s .userRetry).1.hold = false ∧ (step s .userRetry).1.givenUp = [] ∧ (step s .userRetry).1.moveCount = 0 ∧
    (step s .userRetry).1.strikes = [] ∧ (step s .userRetry).1.skipped = [] ∧ (step s .userRetry).1.restricted = false ∧
    (step s .userRetry).1.stripGrant = true :=
  ⟨retry_clears_hold s, retry_clears_givenUp s, retry_resets_budget s, retry_clears_strikes s, retry_clears_skipped s,
    retry_unrestricts s, retry_grants s⟩

/-- ... and then the engine's gate is open on any read that is neither stale nor shows an open strip. -/
theorem userRetry_opens_gate (s : State) (r : Read) (h1 : r.chevron ≠ .stale) (h2 : r.stripOpen = false) :
    engineAllowed (step s .userRetry).1 r = true := by
  simp [engineAllowed, retry_clears_hold, retry_unrestricts, retry_resets_budget, h1, h2, cap, capFull, capNotFull]
  split <;> simp
/-! ### 3. Order of the movable keys -/


/-- **The fold request is served before the owed keys.**  When a request is pending and its pull-out move exists and is allowed,
the next read decides exactly that move, whatever else is owed. -/
theorem request_first {s : State} {r : Read} {q : Key} {a : Action} (hq : s.foldRequest = some q)
    (hpass : r.kind = .pass) (hset : r.settled = true) (hinc : r.level ≠ .incomplete) (hi : s.inFlight = none)
    (hg : s.gate r = true)
    (hum : userMove1 s r q = some a) (hal : userAllowed s r a = true) : decideMove s r = some a := by
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  simp only [decideMove]
  rw [if_neg hc, userPick_head1 (by simp [hq]) hum hal]

/-! ### 6. No needless drag -/

set_option maxHeartbeats 1600000


theorem fi_split : ∀ (l1 l2 : List Key) (w h : Key), firstInversion l1 l2 = some (w, h) → l1.Nodup → l2.Nodup →
    (∀ x, x ∈ l1 ↔ x ∈ l2) → ∃ p t, l2 = p ++ h :: t ∧ w ∈ t ∧ w ≠ h
  | [], _, _, _, hh, _, _, _ => by simp [firstInversion] at hh
  | _ :: _, [], _, _, hh, _, _, _ => by simp [firstInversion] at hh
  | w0 :: ws, h0 :: hs, w, h, hh, n1, n2, hm => by
    unfold firstInversion at hh
    by_cases e : (w0 == h0) = true
    · simp only [e, ite_true] at hh
      have hwh : w0 = h0 := by simpa using e
      subst hwh
      have n1' := (List.nodup_cons.1 n1)
      have n2' := (List.nodup_cons.1 n2)
      have hm' : ∀ x, x ∈ ws ↔ x ∈ hs := by
        intro x
        constructor
        · intro hx
          have := (hm x).1 (List.mem_cons_of_mem _ hx)
          rcases List.mem_cons.1 this with h' | h'
          · subst h'; exact absurd hx n1'.1
          · exact h'
        · intro hx
          have := (hm x).2 (List.mem_cons_of_mem _ hx)
          rcases List.mem_cons.1 this with h' | h'
          · subst h'; exact absurd hx n2'.1
          · exact h'
      obtain ⟨p, t, h1, h2, h3⟩ := fi_split ws hs w h hh n1'.2 n2'.2 hm'
      exact ⟨w0 :: p, t, by simp [h1], h2, h3⟩
    · simp only [e] at hh
      simp at hh
      obtain ⟨rfl, rfl⟩ := hh
      have hne : w0 ≠ h0 := by simpa using e
      have : w0 ∈ h0 :: hs := (hm w0).1 (by simp)
      rcases List.mem_cons.1 this with h' | h'
      · exact absurd h' hne
      · exact ⟨[], hs, by simp, h', hne⟩

theorem sublist_split {l d : List Key} (hl : l.Sublist d) {p t : List Key} {h w : Key} (e : l = p ++ h :: t) (hw : w ∈ t) :
    ∃ A B, d = A ++ h :: B ∧ w ∈ B := by
  subst e
  have h1 : (h :: t).Sublist d := (List.sublist_append_right p (h :: t)).trans hl
  obtain ⟨r1, r2, hd, hh, ht⟩ := List.cons_sublist_iff.1 h1
  obtain ⟨A, A2, hA⟩ := List.append_of_mem hh
  refine ⟨A, A2 ++ r2, by rw [hd, hA]; simp, ?_⟩
  exact List.mem_append_right _ (ht.subset hw)

theorem applyMove_before_ne {A B : List Key} {w h : Key} (hn : (A ++ h :: B).Nodup) (hw : w ∈ B) (st us : Bool) :
    applyMove (A ++ h :: B) ⟨w, .before h, st, us⟩ ≠ A ++ h :: B := by
  intro heq
  have hnd := List.nodup_append.1 hn
  have hwh : w ≠ h := fun e => by
    subst e
    exact (List.nodup_cons.1 hnd.2.1).1 hw
  have hwA : w ∉ A := fun hA => hnd.2.2 w hA w (List.mem_cons_of_mem _ hw) rfl
  have hhB : h ∉ B := (List.nodup_cons.1 hnd.2.1).1
  have hhA : h ∉ A := fun hA => hnd.2.2 h hA h (by simp) rfl
  obtain ⟨pre, post, hpp⟩ := applyMove_before (A ++ h :: B) ⟨w, .before h, st, us⟩ h rfl hwh (by simp)
  simp only at hpp
  rw [heq] at hpp
  have : A ++ h :: B = (pre ++ [w]) ++ h :: post := by simp [hpp]
  rcases List.append_eq_append_iff.1 this with ⟨a', h1, h2⟩ | ⟨c', h1, h2⟩
  · cases a' with
    | nil =>
      simp at h2 h1
      subst h2
      exact hwA (by rw [← h1]; simp)
    | cons x a'' =>
      simp at h2
      apply hhB
      rw [h2.2]; simp
  · apply hwA
    rw [h1]; simp

theorem movable_sublist (s : State) (r : Read) : (movable s r).Sublist r.drawn := List.filter_sublist

/-- **No needless planner drag.**  Whenever the planner proposes a move, performing it changes the drawn list (given a record and
a bar listing each key once). -/
theorem noNeedlessDrag_plan {s : State} {r : Read} {b : Action} (hp : planOrderMoves s r = some b)
    (hrec : s.record.Nodup) (hd : r.drawn.Nodup) : applyMove r.drawn b ≠ r.drawn := by
  simp only [planOrderMoves] at hp
  split at hp
  · rename_i w h hmatch
    split at hp
    · simp at hp
    · simp only [Option.some.injEq] at hp
      subst hp
      have hsub : ((movable s r).filter (fun k => s.record.contains k)).Sublist r.drawn :=
        List.filter_sublist.trans (movable_sublist s r)
      have hnv : ((movable s r).filter (fun k => s.record.contains k)).Nodup := hsub.nodup hd
      have hnr : (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k)).Nodup :=
        List.filter_sublist.nodup hrec
      have hm : ∀ x, x ∈ s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k) ↔
          x ∈ (movable s r).filter (fun k => s.record.contains k) := by
        intro x
        simp only [List.mem_filter, List.contains_iff_mem, decide_eq_true_eq]
        constructor
        · exact fun h => h.2.1 |> fun h' => by simpa using h.2
        · intro h; exact ⟨(by simpa using h.2), h⟩
      obtain ⟨p, t, he, hw, _⟩ := fi_split _ _ w h hmatch hnr hnv hm
      obtain ⟨A, B, hAB, hwB⟩ := sublist_split hsub he hw
      rw [hAB] at hd ⊢
      exact applyMove_before_ne hd hwB _ _
  · simp at hp

theorem split_unique : ∀ {X X' Y Y' : List Key} {p : Key}, X ++ p :: Y = X' ++ p :: Y' → (X ++ p :: Y).Nodup → X = X'
  | [], [], _, _, _, _, _ => rfl
  | [], x' :: X'', Y, Y', p, h, hn => by
    simp at h
    obtain ⟨rfl, h2⟩ := h
    have := (List.nodup_cons.1 hn).1
    exact absurd (by rw [h2]; simp) this
  | x :: X, [], Y, Y', p, h, hn => by
    simp at h
    obtain ⟨rfl, h2⟩ := h
    have := (List.nodup_cons.1 hn).1
    exact absurd (by simp) this
  | x :: X, x' :: X'', Y, Y', p, h, hn => by
    simp at h
    obtain ⟨rfl, h2⟩ := h
    have := split_unique h2 (List.nodup_cons.1 hn).2
    rw [this]

theorem takeWhile_split (X Y : List Key) (k : Key) (hX : ∀ x ∈ X, x ≠ k) :
    (X ++ k :: Y).takeWhile (fun x => x != k) = X := by
  induction X with
  | nil => simp
  | cons x xs ih =>
    have := hX x (by simp)
    simp [List.takeWhile, this]
    exact ih (fun y hy => hX y (by simp [hy]))

/-- The shape lemma, abstractly: `d` lists each key once with `k` right after `p`; `M` = the P-keys of `d`; `anc` = the Q-keys of `M`
(never `k`); `seen` = the anchors before `k`.  Then `seen` is the anchors up to and including `p`, a prefix of `anc`. -/
theorem seen_after (d pre post : List Key) (p k : Key) (hd : d = pre ++ p :: k :: post) (hn : d.Nodup)
    (P Q : Key → Bool) (hPk : P k = true) (hPp : P p = true) (hQp : Q p = true) (hQk : Q k = false) :
    ∃ ancd post', ((d.filter P).filter Q) = ancd ++ p :: post' ∧
      (((d.filter P).filter (fun a => a == k || ((d.filter P).filter Q).contains a)).takeWhile (fun x => x != k)) = ancd ++ [p] := by
  subst hd
  have hnd := hn
  have hkpre : k ∉ pre := fun hk => by
    have := List.nodup_append.1 hnd
    exact this.2.2 k hk k (by simp) rfl
  have hpk : p ≠ k := fun e => by
    subst e
    have := List.nodup_append.1 hnd
    exact (List.nodup_cons.1 this.2.1).1 (by simp)
  have hppre : p ∉ pre := fun hp => by
    have := List.nodup_append.1 hnd
    exact this.2.2 p hp p (by simp) rfl
  have hanc : (((pre ++ p :: k :: post).filter P).filter Q) = (pre.filter P).filter Q ++ p :: ((post.filter P).filter Q) := by
    simp [List.filter_append, List.filter_cons, hPp, hQp, hPk, hQk]
  refine ⟨(pre.filter P).filter Q, (post.filter P).filter Q, hanc, ?_⟩
  rw [hanc]
  have hH : ((pre ++ p :: k :: post).filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a)
      = ((pre.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a)) ++ p :: k ::
        ((post.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a)) := by
    simp [List.filter_append, List.filter_cons, hPp, hQp, hPk, hQk]
  rw [hH]
  have hpre_post : ∀ x ∈ pre, x ∉ post := fun x hx hp => by
    have := List.nodup_append.1 hnd
    exact this.2.2 x hx x (by simp [hp]) rfl
  have hcongr : ((pre.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a))
      = (pre.filter P).filter Q := by
    apply List.filter_congr
    intro x hx
    have hxpre : x ∈ pre := (List.mem_filter.1 hx).1
    have hxk : x ≠ k := fun e => hkpre (e ▸ hxpre)
    have hxp : x ≠ p := fun e => hppre (e ▸ hxpre)
    have hxpost : x ∉ post := hpre_post x hxpre
    have hxk' : (x == k) = false := by simpa using hxk
    simp only [hxk', Bool.false_or, List.contains_append, List.contains_cons]
    have h1 : (x == p) = false := by simpa using hxp
    have h2 : ((post.filter P).filter Q).contains x = false := by
      cases hc : ((post.filter P).filter Q).contains x with
      | false => rfl
      | true =>
        exfalso
        exact hxpost (List.mem_filter.1 (List.mem_filter.1 (List.contains_iff_mem.1 hc)).1).1
    have hPx : P x = true := (List.mem_filter.1 hx).2
    simp [h1, h2, hxpre, hxpost, hPx]
  rw [hcongr]
  have : (pre.filter P).filter Q ++ p :: k :: ((post.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a))
      = ((pre.filter P).filter Q ++ [p]) ++ k :: ((post.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ p :: ((post.filter P).filter Q)).contains a)) := by simp
  rw [this]
  apply takeWhile_split
  intro x hx
  rcases List.mem_append.1 hx with h | h
  · exact fun e => hkpre (e ▸ (List.mem_filter.1 (List.mem_filter.1 h).1).1)
  · simp at h; exact h ▸ hpk

/-- ... and `k` right BEFORE the first anchor `t`: nothing precedes `k` among the anchors. -/
theorem seen_before (d pre post : List Key) (t k : Key) (hd : d = pre ++ k :: t :: post) (hn : d.Nodup)
    (P Q : Key → Bool) (hPk : P k = true) (hPt : P t = true) (hQt : Q t = true) (hQk : Q k = false)
    (hh : ((d.filter P).filter Q).head? = some t) :
    (((d.filter P).filter (fun a => a == k || ((d.filter P).filter Q).contains a)).takeWhile (fun x => x != k)) = [] := by
  subst hd
  have hnd := hn
  have hkpre : k ∉ pre := fun hk => by
    have := List.nodup_append.1 hnd
    exact this.2.2 k hk k (by simp) rfl
  have htpre : t ∉ pre := fun hp => by
    have := List.nodup_append.1 hnd
    exact this.2.2 t hp t (by simp) rfl
  have hanc : (((pre ++ k :: t :: post).filter P).filter Q) = (pre.filter P).filter Q ++ t :: ((post.filter P).filter Q) := by
    simp [List.filter_append, hPt, hQt, hPk, hQk]
  have hanc0 : (pre.filter P).filter Q = [] := by
    rw [hanc] at hh
    cases hc : (pre.filter P).filter Q with
    | nil => rfl
    | cons x xs =>
      rw [hc] at hh
      simp at hh
      exfalso; apply htpre
      rw [← hh]
      exact (List.mem_filter.1 (List.mem_filter.1 (by rw [hc]; simp : x ∈ (pre.filter P).filter Q)).1).1
  rw [hanc]
  have hH : ((pre ++ k :: t :: post).filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ t :: ((post.filter P).filter Q)).contains a)
      = ((pre.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ t :: ((post.filter P).filter Q)).contains a)) ++ k :: t ::
        ((post.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ t :: ((post.filter P).filter Q)).contains a)) := by
    simp [List.filter_append, hPt, hQt, hPk, hQk]
  rw [hH]
  have hpre_post : ∀ x ∈ pre, x ∉ post := fun x hx hp => by
    have := List.nodup_append.1 hnd
    exact this.2.2 x hx x (by simp [hp]) rfl
  have hcongr : ((pre.filter P).filter (fun a => a == k || ((pre.filter P).filter Q ++ t :: ((post.filter P).filter Q)).contains a))
      = [] := by
    rw [← hanc0]
    apply List.filter_congr
    intro x hx
    have hxpre : x ∈ pre := (List.mem_filter.1 hx).1
    have hxk : x ≠ k := fun e => hkpre (e ▸ hxpre)
    have hxp : x ≠ t := fun e => htpre (e ▸ hxpre)
    have hxpost : x ∉ post := hpre_post x hxpre
    have hxk' : (x == k) = false := by simpa using hxk
    simp only [hxk', Bool.false_or, List.contains_append, List.contains_cons]
    have h1 : (x == t) = false := by simpa using hxp
    have h2 : ((post.filter P).filter Q).contains x = false := by
      cases hc : ((post.filter P).filter Q).contains x with
      | false => rfl
      | true =>
        exfalso
        exact hxpost (List.mem_filter.1 (List.mem_filter.1 (List.contains_iff_mem.1 hc)).1).1
    have hPx : P x = true := (List.mem_filter.1 hx).2
    simp [h1, h2, hxpre, hxpost, hPx]
  rw [hcongr]
  simp

theorem noNeedlessDrag_user {s : State} {r : Read} {k : Key} {a : Action} (h : userMove s r k = some a)
    (hd : r.drawn.Nodup) : applyMove r.drawn a ≠ r.drawn := by
  by_cases hf : k ∈ foldedAll s r
  · exact (userMove_folded hf h).2.2.1
  have hk : k ∈ movable s r := by
    by_cases hk : k ∈ movable s r
    · exact hk
    · exfalso
      have hf' : (foldedAll s r).contains k = false := by simpa using hf
      have hk' : (movable s r).contains k = false := by simpa using hk
      simp [userMove, hf, hk] at h
  rcases userMove_target hk h with ⟨hns, hsub, hu, hstr, i, hpi, hcase⟩ | ⟨_, _, _, _, _, _, hch⟩
  rotate_left
  · exact hch
  intro heq
  have hsp := prefixFor_spec hpi
  have hanc_sub : (anchorsOf s r k).Sublist r.drawn :=
    (List.filter_sublist : (anchorsOf s r k).Sublist (movable s r)).trans (movable_sublist s r)
  have hanc_nd : (anchorsOf s r k).Nodup := hanc_sub.nodup hd
  have hPk : (r.trusted.contains k && !(foldedAll s r).contains k) = true := (List.mem_filter.1 hk).2
  have hQk : (k != k && s.record.contains k && !s.owedKeys.contains k) = false := by simp
  rcases hcase with ⟨p, hlast, hrel⟩ | ⟨hlast, t, hhead, hrel⟩
  · have hpT : p ∈ (anchorsOf s r k).take i := by
      obtain ⟨ys, hys⟩ := List.getLast?_eq_some_iff.1 hlast
      rw [hys]; simp
    have hpA : p ∈ anchorsOf s r k := List.mem_of_mem_take hpT
    have hpA' := List.mem_filter.1 hpA
    have hpM := List.mem_filter.1 hpA'.1
    have hQp : (p != k && s.record.contains p && !s.owedKeys.contains p) = true := hpA'.2
    have hpk : p ≠ k := by
      intro e; subst e; simp at hQp
    have hrel' : a.rel = .after p := hrel
    obtain ⟨pre, post, hpp⟩ := applyMove_after r.drawn a p hrel' (by rw [hsub]; exact fun e => hpk e.symm) hpM.1
    rw [heq, hsub] at hpp
    have hn' : (pre ++ p :: k :: post).Nodup := by rw [← hpp]; exact hd
    obtain ⟨ancd, post', hanc, hseen⟩ := seen_after r.drawn pre post p k hpp hd
      (fun x => r.trusted.contains x && !(foldedAll s r).contains x)
      (fun x => x != k && s.record.contains x && !s.owedKeys.contains x) hPk hpM.2 hQp hQk
    obtain ⟨T0, hT0⟩ := List.getLast?_eq_some_iff.1 hlast
    have h1 : anchorsOf s r k = T0 ++ p :: (anchorsOf s r k).drop i := by
      have := List.take_append_drop i (anchorsOf s r k)
      rw [hT0] at this
      simpa using this.symm
    have hanc' : anchorsOf s r k = ancd ++ p :: post' := hanc
    have h2 : T0 = ancd := split_unique (h1.symm.trans hanc') (by rw [← h1]; exact hanc_nd)
    apply hns
    have hs : seenOf s r k = ancd ++ [p] := hseen
    rw [hs, ← h2, ← hT0]
    exact hsp.2.1
  · have htA : t ∈ anchorsOf s r k := by
      cases hh : anchorsOf s r k with
      | nil => rw [hh] at hhead; simp at hhead
      | cons x xs => rw [hh] at hhead; simp at hhead; rw [← hhead]; simp
    have htA' := List.mem_filter.1 htA
    have htM := List.mem_filter.1 htA'.1
    have hQt : (t != k && s.record.contains t && !s.owedKeys.contains t) = true := htA'.2
    have htk : t ≠ k := by
      intro e; subst e; simp at hQt
    have hrel' : a.rel = .before t := hrel
    obtain ⟨pre, post, hpp⟩ := applyMove_before r.drawn a t hrel' (by rw [hsub]; exact fun e => htk e.symm) htM.1
    rw [heq, hsub] at hpp
    have hn' : (pre ++ k :: t :: post).Nodup := by rw [← hpp]; exact hd
    have hs := seen_before r.drawn pre post t k hpp hd
      (fun x => r.trusted.contains x && !(foldedAll s r).contains x)
      (fun x => x != k && s.record.contains x && !s.owedKeys.contains x) hPk htM.2 hQt hQk hhead
    have hs' : seenOf s r k = [] := hs
    have htake : (anchorsOf s r k).take i = [] := List.getLast?_eq_none_iff.1 hlast
    apply hns
    rw [hs', ← htake]
    exact hsp.2.1

/-- **No needless drag, for every move the engine emits.**  A key list with each key once on the record and on the bar: whatever
a read makes the engine emit (the planner's move, a granted move, an owed drop or a pull-out), performing it changes the drawn
list. -/
theorem noNeedlessDrag {s : State} {r : Read} {a : Action} (h : a ∈ (step s (.read r)).2)
    (hrec : s.record.Nodup) (hd : r.drawn.Nodup) : applyMove r.drawn a ≠ r.drawn := by
  obtain ⟨r', he, hdm, _⟩ := gate_step_acts h
  cases he
  rcases (gate_decide_cases hdm).2 with ⟨j, _, hj, _⟩ | ⟨_, b, hb, hcase⟩
  · exact noNeedlessDrag_user hj hd
  · rcases hcase with ⟨_, rfl⟩ | ⟨_, _, rfl⟩
    · exact noNeedlessDrag_plan hb hrec hd
    · have h' := noNeedlessDrag_plan hb hrec hd
      exact h'


/-! ### 4. The status line and the rows

`statusLine` and `rowLine` (`Status.lean`) are pure functions of `State` and `Read`.  There is no drop memory: the order they claim
is `shownVerdict` and `rowVerdict` (`Truth.lean`), and the bridges below say exactly that, in both directions. -/

section StatusBridge
variable {s : State} {r : Read}

/-- Case split of the status line: moving iff pending, else one form per verdict. -/
theorem statusLine_moving_iff : statusLine s r = .moving ↔ pending s r = true := by
  unfold statusLine
  cases hp : pending s r <;> simp <;> (cases hv : shownVerdict s r <;> simp [hv])

/-- `notStuck`: the status says Moving only when a drag is in flight or the read decides one. -/
theorem notStuck (h : statusLine s r = .moving) : s.inFlight.isSome = true ∨ (decideMove s r).isSome = true := by
  have := statusLine_moving_iff.mp h
  simpa [pending] using this

/-- ... and the converse: whenever a drag is in flight or decided, the status is Moving. -/
theorem notStuck_conv (h : s.inFlight.isSome = true ∨ (decideMove s r).isSome = true) : statusLine s r = .moving :=
  statusLine_moving_iff.mpr (by simpa [pending] using h)

theorem status_matches_bridge (h : statusLine s r = .matches) : shownVerdict s r = .matches := by
  unfold statusLine at h
  cases hp : pending s r <;> simp only [hp] at h
  · cases hv : shownVerdict s r <;> simp [hv] at h ⊢
  · simp at h

theorem status_except_bridge {U : List Key} (h : statusLine s r = .matchesExcept U) : shownVerdict s r = .matchesExcept U := by
  unfold statusLine at h
  cases hp : pending s r <;> simp only [hp] at h
  · cases hv : shownVerdict s r <;> simp [hv] at h ⊢
    exact h
  · simp at h

theorem status_differs_bridge {w : Why} (h : statusLine s r = .differs w) : shownVerdict s r = .differs := by
  unfold statusLine at h
  cases hp : pending s r <;> simp only [hp] at h
  · cases hv : shownVerdict s r <;> simp [hv] at h ⊢
  · simp at h

theorem status_checking_bridge (h : statusLine s r = .checking) : shownVerdict s r = .cannotTell := by
  unfold statusLine at h
  cases hp : pending s r <;> simp only [hp] at h
  · cases hv : shownVerdict s r <;> simp [hv] at h ⊢
  · simp at h

/-- The converse, where nothing is pending: the status is the verdict's form. -/
theorem status_matches_conv (hp : pending s r = false) (hv : shownVerdict s r = .matches) : statusLine s r = .matches := by
  simp [statusLine, hp, hv]

theorem status_except_conv {U : List Key} (hp : pending s r = false) (hv : shownVerdict s r = .matchesExcept U) :
    statusLine s r = .matchesExcept U := by
  simp [statusLine, hp, hv]

theorem status_differs_conv (hp : pending s r = false) (hv : shownVerdict s r = .differs) :
    statusLine s r = .differs (if budgetSpent s r then .stopped else if s.hold then .barFull else .plain) := by
  simp [statusLine, hp, hv]

theorem status_checking_conv (hp : pending s r = false) (hv : shownVerdict s r = .cannotTell) : statusLine s r = .checking := by
  simp [statusLine, hp, hv]

/-- What "Menu bar matches" CLAIMS, against the real bar (T1 through the bridge): the read is usable and every bar the reading allows matches. -/
theorem status_matches_true (hn : s.record.Nodup) (h : statusLine s r = .matches) :
    (s.view r).usable ∧ (∃ b, Possible (s.view r) b) ∧ ∀ b, Possible (s.view r) b → barMatches s.record b :=
  (verdict_matches_iff s.record (s.view r) hn).mp (status_matches_bridge h)

/-- "Differs": some bar is allowed and none matches (T2). -/
theorem status_differs_true {w : Why} (hn : s.record.Nodup) (h : statusLine s r = .differs w) :
    (∃ b, Possible (s.view r) b) ∧ ∀ b, Possible (s.view r) b → ¬ barMatches s.record b :=
  (verdict_differs_iff s.record (s.view r) hn).mp (status_differs_bridge h)

/-- "Matches except U": some bar is allowed and `U` is valid (T3). -/
theorem status_except_true {U : List Key} (hn : s.record.Nodup) (h : statusLine s r = .matchesExcept U) :
    (∃ b, Possible (s.view r) b) ∧ ValidU s.record (s.view r) U :=
  (verdict_except_iff s.record (s.view r) U hn).mp (status_except_bridge h)

/-- "Cannot tell" (T4) is the "Checking the menu bar" text. -/
theorem status_checking_true (hn : s.record.Nodup) (h : statusLine s r = .checking) :
    ¬ (s.view r).usable ∨ ¬ (∃ b, Possible (s.view r) b) ∨
      (¬ (∀ b, Possible (s.view r) b → barMatches s.record b) ∧ ¬ (∀ b, Possible (s.view r) b → ¬ barMatches s.record b) ∧
        ∀ U, ¬ ((∃ b, Possible (s.view r) b) ∧ ValidU s.record (s.view r) U)) := by
  have hv := status_checking_bridge h
  by_cases hu : (s.view r).usable
  · by_cases he : ∃ b, Possible (s.view r) b
    · right; right
      refine ⟨fun hall => ?_, fun hall => ?_, fun U hU => ?_⟩
      · have := (verdict_matches_iff s.record (s.view r) hn).mpr ⟨hu, he, hall⟩
        unfold shownVerdict at hv; rw [this] at hv; cases hv
      · have := (verdict_differs_iff s.record (s.view r) hn).mpr ⟨he, hall⟩
        unfold shownVerdict at hv; rw [this] at hv; cases hv
      · have := (verdict_except_iff s.record (s.view r) U hn).mpr hU
        unfold shownVerdict at hv; rw [this] at hv; cases hv
    · exact Or.inr (Or.inl he)
  · exact Or.inl hu

/-- The status is `plain` only with no spent budget and no hold. -/
theorem status_plain_iff (h : statusLine s r = .differs .plain) : budgetSpent s r = false ∧ s.hold = false := by
  unfold statusLine at h
  cases hp : pending s r <;> simp only [hp] at h
  · cases hv : shownVerdict s r <;> simp [hv] at h
    by_cases h1 : budgetSpent s r = true <;> by_cases h2 : s.hold = true <;> simp_all
  · simp at h

/-- **stopped_true.**  "Stopped" is shown only when the bar differs, nothing is pending, and the budget is spent; and then (the
quiescence theorem) no engine move follows on any further events without a user event, as long as the bar stays full at every
further read (or 20 moves are already spent). -/
theorem stopped_true (h : statusLine s r = .differs .stopped) :
    shownVerdict s r = .differs ∧ pending s r = false ∧ cap (fullBar s r) ≤ s.moveCount ∧
    ∀ es : List Event, (∀ e ∈ es, userEv e = false) →
      (20 ≤ s.moveCount ∨ ∀ pre r' post, es = pre ++ .read r' :: post → fullBar (run s pre).1 r' = true) →
      ∀ a ∈ (run s es).2, a.user = true := by
  have hv := status_differs_bridge h
  have hp : pending s r = false := by
    cases hp : pending s r
    · rfl
    · exact absurd (statusLine_moving_iff.mpr hp) (by rw [h]; simp)
  have hb : budgetSpent s r = true := by
    unfold statusLine at h
    simp only [hp] at h
    cases hv' : shownVerdict s r <;> simp [hv'] at h
    by_cases h1 : budgetSpent s r = true
    · exact h1
    · by_cases h2 : s.hold = true <;> simp_all
  have hcap : cap (fullBar s r) ≤ s.moveCount := by simpa [budgetSpent] using hb
  refine ⟨hv, hp, hcap, fun es hn hc => ?_⟩
  have hcap3 : 3 ≤ cap (fullBar s r) := by
    unfold cap; split <;> simp [capFull, capNotFull]
  refine (quiescence s es hn ?_).1
  rcases hc with h20 | hf
  · exact Or.inl h20
  · exact Or.inr (Or.inl ⟨by omega, hf⟩)

/-- **barFull_true.**  "The bar is full" is shown only when the bar differs, nothing is pending and a hold is set; and then no engine
move follows without a user event, as long as no further read gains the proof that the bar is not full. -/
theorem barFull_true (h : statusLine s r = .differs .barFull) :
    shownVerdict s r = .differs ∧ pending s r = false ∧ s.hold = true ∧
    ∀ es : List Event, (∀ e ∈ es, userEv e = false) →
      (∀ pre r' post, es = pre ++ .read r' :: post → ¬ Gain (run s pre).1 r') →
      ∀ a ∈ (run s es).2, a.user = true := by
  have hv := status_differs_bridge h
  have hp : pending s r = false := by
    cases hp : pending s r
    · rfl
    · exact absurd (statusLine_moving_iff.mpr hp) (by rw [h]; simp)
  have hh : s.hold = true := by
    unfold statusLine at h
    simp only [hp] at h
    cases hv' : shownVerdict s r <;> simp [hv'] at h
    by_cases h1 : budgetSpent s r = true <;> by_cases h2 : s.hold = true <;> simp_all
  refine ⟨hv, hp, hh, fun es hn hg => ?_⟩
  exact (quiescence s es hn (Or.inr (Or.inr ⟨hh, hg⟩))).1

end StatusBridge

section RowBridge
variable {s : State} {r : Read} {k : Key}

theorem row_moving_iff : rowLine s r k = .moving ↔ movingKey s r k = true := by
  unfold rowLine
  cases hm : movingKey s r k
  · cases ho : waitingKey s r k <;> cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line]
  · simp

/-- `notStuck` for a row: Moving only for the subject of a drag in flight or of the drag the read decides. -/
theorem row_notStuck (h : rowLine s r k = .moving) :
    (∃ a, s.inFlight = some a ∧ a.subject = k) ∨ (∃ a, decideMove s r = some a ∧ a.subject = k) := by
  have := row_moving_iff.mp h
  simp only [movingKey, Bool.or_eq_true, Option.any_eq_true, beq_iff_eq] at this
  exact this

theorem row_notStuck_conv (h : (∃ a, s.inFlight = some a ∧ a.subject = k) ∨ (∃ a, decideMove s r = some a ∧ a.subject = k)) :
    rowLine s r k = .moving := by
  apply row_moving_iff.mpr
  simp only [movingKey, Bool.or_eq_true, Option.any_eq_true, beq_iff_eq]
  exact h

/-- `waiting` is shown only for an owed or requested key whose drag is not leaving, and only when the read is not good (the gate is false) or a
move of the key exists and is blocked. -/
theorem row_waiting_true (h : rowLine s r k = .waiting) :
    (k ∈ s.owedKeys ∨ s.foldRequest = some k) ∧ movingKey s r k = false ∧
      (s.gate r = false ∨ (userMove s r k).isSome = true) := by
  unfold rowLine at h
  cases hm : movingKey s r k
  · cases hw : waitingKey s r k
    · simp only [hm, hw] at h
      cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at h
    · refine ⟨?_, rfl, ?_⟩
      · simp only [waitingKey, Bool.and_eq_true, owedNow, Bool.or_eq_true, List.contains_iff_mem, beq_iff_eq] at hw
        exact hw.1
      · simp only [waitingKey, Bool.and_eq_true, Bool.or_eq_true, Bool.not_eq_true'] at hw
        exact hw.2
  · simp [hm] at h

theorem row_waiting_conv (hm : movingKey s r k = false) (ho : k ∈ s.owedKeys ∨ s.foldRequest = some k)
    (hw : s.gate r = false ∨ (userMove s r k).isSome = true) : rowLine s r k = .waiting := by
  have : waitingKey s r k = true := by
    simp only [waitingKey, owedNow, Bool.and_eq_true, Bool.or_eq_true, List.contains_iff_mem, beq_iff_eq, Bool.not_eq_true']
    exact ⟨ho, hw⟩
  simp [rowLine, hm, this]

/-- **A good read with nothing to move never shows `waiting`.**  The gate is true, no move of the key exists, nothing of it is leaving: the row
is its `rowVerdict`, owed or not. -/
theorem row_good_read_verdict (hm : movingKey s r k = false) (hg : s.gate r = true) (hn : userMove s r k = none) :
    rowLine s r k = (rowVerdict s.record (s.view r) k).line := by
  have : waitingKey s r k = false := by simp [waitingKey, hg, hn]
  simp [rowLine, hm, this]

/-- No row mark other than moving and waiting is derived from anything but `rowVerdict`. -/
theorem row_free_of_memory (hm : movingKey s r k = false) (ho : owedNow s k = false) :
    rowLine s r k = (rowVerdict s.record (s.view r) k).line := by
  have : waitingKey s r k = false := by simp [waitingKey, ho]
  simp [rowLine, hm, this]

theorem row_line_cases (h : rowLine s r k ≠ .moving) (h2 : rowLine s r k ≠ .waiting) :
    rowLine s r k = (rowVerdict s.record (s.view r) k).line := by
  unfold rowLine at h h2 ⊢
  cases hm : movingKey s r k
  · cases hw : waitingKey s r k
    · simp [hm, hw]
    · simp [hm, hw] at h2
  · simp [hm] at h

/-- A row shown as a check mark has `rowVerdict = inOrder` ... -/
theorem row_tick_bridge (h : rowLine s r k = .tick) : rowVerdict s.record (s.view r) k = .inOrder := by
  have := row_line_cases (s := s) (r := r) (k := k) (by rw [h]; simp) (by rw [h]; simp)
  rw [h] at this
  cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at this ⊢

/-- ... a « has `behindChevron` ... -/
theorem row_behind_bridge (h : rowLine s r k = .behind) : rowVerdict s.record (s.view r) k = .behindChevron := by
  have := row_line_cases (s := s) (r := r) (k := k) (by rw [h]; simp) (by rw [h]; simp)
  rw [h] at this
  cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at this ⊢

/-- ... "not where you put it" is `outOfPlace` or `behindOutOfTurn` ... -/
theorem row_notWherePut_bridge (h : rowLine s r k = .notWherePut) :
    rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn := by
  have := row_line_cases (s := s) (r := r) (k := k) (by rw [h]; simp) (by rw [h]; simp)
  rw [h] at this
  cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at this ⊢

theorem row_notOnBar_bridge (h : rowLine s r k = .notOnBar) : rowVerdict s.record (s.view r) k = .notOnBar := by
  have := row_line_cases (s := s) (r := r) (k := k) (by rw [h]; simp) (by rw [h]; simp)
  rw [h] at this
  cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at this ⊢

theorem row_cannotTell_bridge (h : rowLine s r k = .cannotTell) : rowVerdict s.record (s.view r) k = .cannotTell := by
  have := row_line_cases (s := s) (r := r) (k := k) (by rw [h]; simp) (by rw [h]; simp)
  rw [h] at this
  cases hv : rowVerdict s.record (s.view r) k <;> simp [hv, RowVerdict.line] at this ⊢

/-- ... and the converses, for a row that is neither moving nor owed. -/
theorem row_tick_conv (hm : movingKey s r k = false) (ho : owedNow s k = false)
    (hv : rowVerdict s.record (s.view r) k = .inOrder) : rowLine s r k = .tick := by
  simp [rowLine, waitingKey, hm, ho, hv, RowVerdict.line]

theorem row_behind_conv (hm : movingKey s r k = false) (ho : owedNow s k = false)
    (hv : rowVerdict s.record (s.view r) k = .behindChevron) : rowLine s r k = .behind := by
  simp [rowLine, waitingKey, hm, ho, hv, RowVerdict.line]

theorem row_notWherePut_conv (hm : movingKey s r k = false) (ho : owedNow s k = false)
    (hv : rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn) :
    rowLine s r k = .notWherePut := by
  rcases hv with hv | hv <;> simp [rowLine, waitingKey, hm, ho, hv, RowVerdict.line]

/-- What a check mark CLAIMS about the real bar (T5): on every allowed bar the key is open and in order among the keys the reading fixes. -/
theorem row_tick_true (hn : s.record.Nodup) (hk : k ∈ s.record) (h : rowLine s r k = .tick) :
    (∃ b, Possible (s.view r) b) ∧ ∀ b, Possible (s.view r) b → RowPlaced (s.view r) s.record b k :=
  (rowVerdict_inOrder_iff s.record (s.view r) k hn hk).mp (row_tick_bridge h)

/-- A « claims: the key is behind the chevron on every allowed bar. -/
theorem row_behind_true (hn : s.record.Nodup) (hk : k ∈ s.record) (h : rowLine s r k = .behind) :
    (∃ b, Possible (s.view r) b) ∧ ∀ b, Possible (s.view r) b → k ∈ b.behind :=
  let hh := (rowVerdict_behind_iff s.record (s.view r) k hn hk).mp (row_behind_bridge h)
  ⟨hh.1, hh.2.1⟩

/-- "Not where you put it" claims: on every allowed bar the key is open and out of order, or it is behind the chevron while a record key
before it is open. -/
theorem row_notWherePut_true (hn : s.record.Nodup) (hk : k ∈ s.record) (h : rowLine s r k = .notWherePut) :
    (∃ b, Possible (s.view r) b) ∧
      ((∀ b, Possible (s.view r) b → RowMisplaced (s.view r) s.record b k) ∨
        (∀ b, Possible (s.view r) b → OutOfTurn s.record b k)) := by
  rcases row_notWherePut_bridge h with hv | hv
  · have := (rowVerdict_outOfPlace_iff s.record (s.view r) k hn hk).mp hv
    exact ⟨this.1, Or.inl this.2⟩
  · have := (rowVerdict_behindOutOfTurn_iff s.record (s.view r) k hn hk).mp hv
    exact ⟨this.1, Or.inr this.2⟩

end RowBridge

/-! ### 5. Scenario theorems, at the level of a run -/

/-- An event that names `k`: an edit that moved it, or a per-row retry of it. -/
def names (k : Key) : Event → Bool
  | .userEdit _ moved => moved.contains k
  | .retryKey j => j == k
  | _ => false

/-- **drop_truth.**  After the user drops `k` (`userEdit rec [k]`) and any events that name `k` in no user event, on a final read `r`:
if the status says "Menu bar matches", then on EVERY bar the reading allows, `k` is not on the bar or it is on the bar and the bar matches
the record (`barMatches`: the open keys stand in the record's order, and every folded key comes before every open key in the record).
No ghost is involved: it is the bridge and T1.  (The hypothesis on `es` is not needed by the proof; the guarantee holds after any events.) -/
theorem drop_truth (s : State) (rec : List Key) (k : Key) (es : List Event) (r : Read)
    (hnd : (run (step s (.userEdit rec [k])).1 es).1.record.Nodup)
    (hk : k ∈ (run (step s (.userEdit rec [k])).1 es).1.record)
    (_hno : ∀ e ∈ es, userEv e = true → names k e = false)
    (h : statusLine (run (step s (.userEdit rec [k])).1 es).1 r = .matches) :
    ∀ b, Possible ((run (step s (.userEdit rec [k])).1 es).1.view r) b →
      (k ∉ b.open_ ∧ k ∉ b.behind) ∨
      ((k ∈ b.open_ ∨ k ∈ b.behind) ∧ barMatches (run (step s (.userEdit rec [k])).1 es).1.record b) := by
  intro b hb
  have hm := (status_matches_true hnd h).2.2 b hb
  by_cases ho : k ∈ b.open_
  · exact Or.inr ⟨Or.inl ho, hm⟩
  · by_cases hbh : k ∈ b.behind
    · exact Or.inr ⟨Or.inr hbh, hm⟩
    · exact Or.inl ⟨ho, hbh⟩

/-- **user_drop_answered.**  A drop gets its move on the next good reading.  From ANY state with nothing in flight and `k` first in the queue, on a read
where the gate is true (usable and consistent), with no hypothesis on the hold, the budget, the strip, the fold request or the pile memory:
(drawn case) a trusted drawn `k` that is out of place among its anchors, with a gap for it, yields exactly one action, a move of `k`, the user's own;
(folded case) a `k` this read lists as folded under a fresh chevron, not also drawn, with a movable key before it in the record, yields exactly one
action, the user's pull-out of `k` (subject `k`, with the strip, the user's). -/
theorem user_drop_answered (s : State) (rec : List Key) (k : Key) (r : Read)
    (hi : s.inFlight = none) (hg : (edited s rec k).gate r = true) (hk : k ∈ rec)
    (hfirst : ((edited s rec k).foldRequest.toList ++ (edited s rec k).owedKeys).head? = some k) :
    ((k ∈ r.drawn → k ∈ r.trusted → k ∉ foldedAll (edited s rec k) r →
      ¬ SameKeys (seenOf (edited s rec k) r k) (wantOf (edited s rec k) r k) →
      (prefixFor (wantOf (edited s rec k) r k) (anchorsOf (edited s rec k) r k)).isSome = true →
      ∃ a, (step (edited s rec k) (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true) ∧
    (r.chevron = .fresh → k ∈ r.foldedSet → k ∉ r.drawn →
      (∃ x ∈ movable (edited s rec k) r, x ∈ (edited s rec k).record.takeWhile (fun y => y != k)) →
      ∃ a, (step (edited s rec k) (.read r)).2 = [a] ∧ a.subject = k ∧ a.strip = true ∧ a.user = true)) :=
  ⟨fun hd ht hnf hne hpf =>
    let ⟨a, h1, h2, h3, _⟩ := userAlwaysAnswered_drawn s rec k r hi hg hk hfirst hd ht hnf hne hpf
    ⟨a, h1, h2, h3⟩,
   fun hc hfs hnd hp =>
    let ⟨a, h1, h2, h3, h4, _⟩ := userAlwaysAnswered_pull s rec k r hi hg hk hfirst hc hfs hnd hp
    ⟨a, h1, h4, h2, h3⟩⟩

/-- **user_can_leave.**  From ANY state: after Re-apply the hold, the given-up keys and the budget are clear (and so are the strikes, the
skipped keys and the restriction); and a user edit is always accepted: the record is the new one, the edit's own keys are owed and no
longer given up or skipped, and the budget is fresh. -/
theorem user_can_leave (s : State) :
    ((step s .userRetry).1.hold = false ∧ (step s .userRetry).1.givenUp = [] ∧ (step s .userRetry).1.moveCount = 0 ∧
      (step s .userRetry).1.strikes = [] ∧ (step s .userRetry).1.skipped = [] ∧ (step s .userRetry).1.restricted = false) ∧
    ∀ (rec moved : List Key), (step s (.userEdit rec moved)).1.record = rec ∧ (step s (.userEdit rec moved)).2 = [] ∧
      (moved.isEmpty = false →
        (step s (.userEdit rec moved)).1.moveCount = 0 ∧ (step s (.userEdit rec moved)).1.skipped = [] ∧
        (∀ j ∈ moved, j ∉ (step s (.userEdit rec moved)).1.givenUp ∧ j ∉ (step s (.userEdit rec moved)).1.strikes) ∧
        (∀ j ∈ moved, j ∈ rec → j ∈ (step s (.userEdit rec moved)).1.owedKeys)) := by
  refine ⟨⟨(userRetry_leaves s).1, (userRetry_leaves s).2.1, (userRetry_leaves s).2.2.1, (userRetry_leaves s).2.2.2.1,
    (userRetry_leaves s).2.2.2.2.1, (userRetry_leaves s).2.2.2.2.2.1⟩, fun rec moved => ?_⟩
  by_cases hm : moved.isEmpty = true
  · refine ⟨by simp [step, hm], by simp [step, hm], fun h => absurd hm (by simp [h])⟩
  · have hm' : moved.isEmpty = false := by simpa using hm
    refine ⟨by simp [step, hm'], by simp [step, hm'], fun _ => ⟨by simp [step, hm'], by simp [step, hm'], ?_, ?_⟩⟩
    · intro j hj
      simp [step, hm', hj]
    · intro j hj hjr
      simp [step, hm', hj, hjr]

/-! ### 8. Closing two gaps (additive): reachable drops, and what the row says about an unanswered drop -/

/-- The pile memory is empty on a proven-not-full bar.  Preserved by every event (a chevron read revokes the proof, the proof clears the memory), so it
holds in every state reachable from  (). -/
def PileInv (s : State) : Prop := s.provenNotFull = true → s.lastFreshPile = []

theorem pileInv_noteRead {s : State} (h : PileInv s) (r : Read) : PileInv (noteRead s r) := by
  unfold PileInv at *
  unfold noteRead
  grind

theorem pileInv_result {s : State} (h : PileInv s) (a : Action) (o : Outcome) (p : Bool) : PileInv (result s a o p) := by
  unfold PileInv at *
  unfold result
  grind

theorem pileInv_emit {s : State} (h : PileInv s) (a : Action) : PileInv (emit s a) := by
  unfold PileInv at *; unfold emit; simpa using h

theorem pileInv_step {s : State} (h : PileInv s) (e : Event) : PileInv (step s e).1 := by
  cases e with
  | read r =>
    have := pileInv_noteRead h r
    simp only [step]
    cases hd : decideMove s r with
    | none => simpa using this
    | some a => simpa using pileInv_emit this a
  | userEdit rec moved =>
    simp only [step]; unfold PileInv at *; split <;> simpa using h
  | userRetry => simp only [step]; unfold PileInv at *; simpa using h
  | retryKey k => simp only [step]; unfold PileInv at *; simpa using h
  | moveResult k o p =>
    simp only [step]
    cases hi : s.inFlight with
    | none => simpa using h
    | some a =>
      by_cases hs : a.subject == k
      · simpa [hs] using pileInv_result h a o p
      · simpa [hs] using h
  | passBoundary => simp only [step]; unfold PileInv at *; simpa using h

theorem pileInv_run : ∀ (es : List Event) (s : State), PileInv s → PileInv (run s es).1
  | [], s, h => by simpa [run] using h
  | e :: es, s, h => by
    simp only [run]
    exact pileInv_run es _ (pileInv_step h e)

theorem pileInv_init (rec : List Key) : PileInv (State.init rec) := by
  simp [PileInv, State.init]

/-- **The invariant, for every state reachable from `init`:** a bar proven not full has no pile memory. -/
theorem provenNotFull_pile_empty (rec : List Key) (es : List Event) :
    (run (State.init rec) es).1.provenNotFull = true → (run (State.init rec) es).1.lastFreshPile = [] :=
  pileInv_run es _ (pileInv_init rec)

/-- **drop_answered_reachable.**  The drawn case of `user_drop_answered` with NO `k ∉ foldedAll` hypothesis, from a state reachable from `init`: on a read where the
gate is true, `k` first in the queue, `k` trusted and drawn and not listed folded by this read, out of place among its anchors with a gap: exactly one action, a
move of `k`, the user's.  (`k ∉ foldedAll` follows: on a fresh chevron the read supersedes the memory; on a proven chevronless read the memory is empty by
`provenNotFull_pile_empty`.) -/
theorem drop_answered_reachable (rec0 : List Key) (es : List Event) (rec : List Key) (k : Key) (r : Read)
    (hi : (run (State.init rec0) es).1.inFlight = none)
    (hg : (edited (run (State.init rec0) es).1 rec k).gate r = true) (hk : k ∈ rec)
    (hfirst : ((edited (run (State.init rec0) es).1 rec k).foldRequest.toList ++
      (edited (run (State.init rec0) es).1 rec k).owedKeys).head? = some k)
    (hd : k ∈ r.drawn) (ht : k ∈ r.trusted) (hnf : k ∉ r.foldedSet)
    (hne : ¬ SameKeys (seenOf (edited (run (State.init rec0) es).1 rec k) r k) (wantOf (edited (run (State.init rec0) es).1 rec k) r k))
    (hpf : (prefixFor (wantOf (edited (run (State.init rec0) es).1 rec k) r k)
      (anchorsOf (edited (run (State.init rec0) es).1 rec k) r k)).isSome = true) :
    ∃ a, (step (edited (run (State.init rec0) es).1 rec k) (.read r)).2 = [a] ∧ a.subject = k ∧ a.user = true := by
  have hinv : PileInv (edited (run (State.init rec0) es).1 rec k) :=
    pileInv_step (pileInv_run es _ (pileInv_init rec0)) _
  have hnfa : k ∉ foldedAll (edited (run (State.init rec0) es).1 rec k) r := by
    rw [mem_foldedAll]
    rintro (hf | ⟨hn, hm⟩)
    · exact hnf hf
    · have hg' := hg
      unfold State.gate at hg'
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hg'
      obtain ⟨⟨_, _, _, _, _, hc⟩, _⟩ := hg'
      rcases hc with hc | ⟨_, hp⟩
      · exact hn (gate_fresh_usable hg hc)
      · have := hinv hp
        rw [this] at hm; simp at hm
  obtain ⟨a, h1, h2, h3, _⟩ := userAlwaysAnswered_drawn (run (State.init rec0) es).1 rec k r hi hg hk hfirst hd ht hnfa hne hpf
  exact ⟨a, h1, h2, h3⟩

/-- **A key listed folded AND drawn on a chevronless read** is an adapter contradiction (A2 pins the folded list only under a fresh chevron, so the model's
consistency check does not catch it).  What happens: the key counts as folded (`foldedAll`), a chevronless read never licenses a pull-out, so NO move of it
leaves; the row is its `rowVerdict` (read from the trusted drawn position, ignoring the folded list, which means nothing without a chevron), never `waiting`
and never the « mark.  A tick, if shown, is the truthful `row_tick_true` about the trusted drawn position. -/
theorem foldedDrawn_chevronless {s : State} {r : Read} {k : Key} (hi : s.inFlight = none) (hg : s.gate r = true)
    (hc : r.chevron = .absent) (hf : k ∈ r.foldedSet) :
    userMove s r k = none ∧ rowLine s r k = (rowVerdict s.record (s.view r) k).line ∧ rowLine s r k ≠ .behind := by
  have hfa : k ∈ foldedAll s r := (mem_foldedAll s r k).2 (Or.inl hf)
  have hum : userMove s r k = none := by
    cases h : userMove s r k with
    | none => rfl
    | some a =>
      have := userMove_folded hfa h
      rw [hc] at this; exact absurd this.2.1 (by simp)
  have hm : movingKey s r k = false := by
    cases hm : movingKey s r k
    · rfl
    · exfalso
      simp only [movingKey, Bool.or_eq_true, Option.any_eq_true, beq_iff_eq] at hm
      rcases hm with ⟨a, ha, _⟩ | ⟨a, ha, hsub⟩
      · rw [hi] at ha; cases ha
      · have hmem : a ∈ (step s (.read r)).2 := by
          simp [step, ha]
        have := fold_crossed_only_by_drop hmem (hsub ▸ hf)
        rw [hc] at this; exact absurd this.2.2 (by simp)
  have hrow := row_good_read_verdict hm hg hum
  refine ⟨hum, hrow, ?_⟩
  rw [hrow]
  intro hb
  have := row_behind_bridge (s := s) (r := r) (k := k) (by rw [hrow]; exact hb)
  unfold rowVerdict at this
  have hpb : (s.view r).pinBehind = [] := pinBehind_nf (by simpa [State.view] using (by rw [hc]; simp : r.chevron ≠ .fresh))
  by_cases hcn : (s.view r).consistent = true
  · simp only [hcn, hpb] at this
    simp at this
    split at this <;> (try split at this) <;> simp at this
  · simp [hcn] at this

/-- **in_place_row.**  The converse's case 1 (a movable key right among its anchors) against the row.  The row says `inOrder`, OR a NAMED key is the reason it
does not: a record key, trusted and drawn, that is not an anchor because it is another OWED key, or because it is counted as folded (only possible on a chevronless
read, where the folded list contradicts the drawn list, or from stale memory).  Untrusted and unread keys can never be the reason: the row ignores them (it reads
only the pinned open keys).  So this is stronger than "owed, untrusted, unread or folded": untrusted and unread are excluded. -/
theorem in_place_row {s : State} {r : Read} {k : Key} (hg : s.gate r = true) (hmv : k ∈ movable s r)
    (hsame : SameKeys (seenOf s r k) (wantOf s r k)) :
    rowVerdict s.record (s.view r) k = .inOrder ∨
    ∃ x, x ≠ k ∧ x ∈ s.record ∧ x ∈ r.drawn ∧ x ∈ r.trusted ∧ (x ∈ s.owedKeys ∨ x ∈ foldedAll s r) := by
  have hg' := hg
  unfold State.gate at hg'
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hg'
  obtain ⟨hu, hcons⟩ := hg'
  have hcm := consistent_iff.1 hcons
  by_cases hrv : rowVerdict s.record (s.view r) k = .inOrder
  · exact Or.inl hrv
  · right
    have hkp : k ∈ (s.view r).pinOpen := ((mov_mem hu k).1 hmv).1
    have hpb : (s.view r).pinBehind.contains k = false := by
      simpa using hcm.2 k hkp
    have hpo : (s.view r).pinOpen.contains k = true := by simpa using hkp
    have hc' : (s.view r).consistent = true := hcons
    unfold rowVerdict at hrv
    simp only [hc', hpb, hpo, Bool.not_true, Bool.false_eq_true, if_false, if_true, ite_true, ite_false] at hrv
    have hany : (s.record.any fun x => x != k && (s.view r).pinOpen.contains x &&
        decide (x ∈ List.takeWhile (fun y => y != k) s.record) !=
          decide (List.idxOf x (s.view r).pinOpen < List.idxOf k (s.view r).pinOpen)) = true := by
      cases h : (s.record.any fun x => x != k && (s.view r).pinOpen.contains x &&
        decide (x ∈ List.takeWhile (fun y => y != k) s.record) !=
          decide (List.idxOf x (s.view r).pinOpen < List.idxOf k (s.view r).pinOpen))
      · exfalso; apply hrv; simp only [h, Bool.false_eq_true, ite_false]
      · rfl
    obtain ⟨x, hxr, hx⟩ := List.any_eq_true.1 hany
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem] at hx
    obtain ⟨⟨hxk, hxp⟩, hxd⟩ := hx
    have hdraw : (s.view r).pinOpen = r.drawn.filter (fun k => r.trusted.contains k) := view_usable_pin hu
    have hxdt : x ∈ r.drawn ∧ x ∈ r.trusted := by
      rw [hdraw] at hxp; simpa [List.mem_filter] using hxp
    refine ⟨x, hxk, hxr, hxdt.1, hxdt.2, ?_⟩
    by_cases hno : x ∈ s.owedKeys
    · exact Or.inl hno
    by_cases hnf : x ∈ foldedAll s r
    · exact Or.inr hnf
    exfalso
    have hxM : x ∈ movable s r := (mov_mem hu x).2 ⟨hxp, hnf⟩
    have hxA : x ∈ anchorsOf s r k := by
      simp only [anchorsOf, List.mem_filter, Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem, Bool.not_eq_true']
      exact ⟨hxM, ⟨hxk, hxr⟩, by simpa using hno⟩
    have hkA : k ∈ (movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a) := by
      simp [List.mem_filter, hmv]
    have hxF : x ∈ (movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a) := by
      simp [List.mem_filter, hxM, hxA]
    have e1 : x ∈ seenOf s r k ↔ x ∈ (movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a) ∧
        ((movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a)).idxOf x <
          ((movable s r).filter (fun a => a == k || (anchorsOf s r k).contains a)).idxOf k := by
      unfold seenOf; exact tw_mem hkA x
    have e2 := idx_filter_iff (fun a => a == k || (anchorsOf s r k).contains a) (movable s r) x k hxM hmv
      (by simp [hxA]) (by simp)
    have e3 := mov_idx hu hxM hmv
    have e4 : x ∈ wantOf s r k ↔ x ∈ s.record.takeWhile (fun y => y != k) := by
      unfold wantOf; simp [List.mem_filter, hxA]
    have hseen : x ∈ seenOf s r k ↔ (s.view r).pinOpen.idxOf x < (s.view r).pinOpen.idxOf k := by
      rw [e1]; constructor
      · rintro ⟨_, h⟩; exact e3.1 (e2.1 h)
      · intro h; exact ⟨hxF, e2.2 (e3.2 h)⟩
    have hiff : x ∈ s.record.takeWhile (fun y => y != k) ↔ (s.view r).pinOpen.idxOf x < (s.view r).pinOpen.idxOf k := by
      rw [← e4, ← hseen]
      exact ⟨fun h => hsame.2 x h, fun h => hsame.1 x h⟩
    exact hxd (decide_eq_decide.2 hiff)

/-- **An owed key that gets no move never sits behind a row that claims more than the reading says.**  On a gate-true read with nothing in flight, if no move of
the owed key `k` leaves, its row is its `rowVerdict` (`row_good_read_verdict`: this covers every case of `owed_unanswered_reason` where `userMove` is none), or it
is `waiting` and a move of `k` exists and is blocked (the strip session is used, or another queued key went first). -/
theorem unanswered_row {s : State} {r : Read} {k : Key} (hi : s.inFlight = none) (hg : s.gate r = true)
    (howed : k ∈ s.owedKeys) (hno : ∀ a ∈ (step s (.read r)).2, a.subject ≠ k) :
    rowLine s r k = (rowVerdict s.record (s.view r) k).line ∨
    (rowLine s r k = .waiting ∧ ∃ a, userMove s r k = some a) := by
  have hm : movingKey s r k = false := by
    cases hm : movingKey s r k
    · rfl
    · exfalso
      simp only [movingKey, Bool.or_eq_true, Option.any_eq_true, beq_iff_eq] at hm
      rcases hm with ⟨a, ha, _⟩ | ⟨a, ha, hsub⟩
      · rw [hi] at ha; cases ha
      · exact hno a (by simp [step, ha]) hsub
  cases hu : userMove s r k with
  | none => exact Or.inl (row_good_read_verdict hm hg hu)
  | some a =>
    exact Or.inr ⟨row_waiting_conv hm (Or.inl howed) (Or.inr (by simp [hu])), a, rfl⟩

/-! ### A drop that gets no move says so (ejb.10)

`rowNote` (Status.lean) is the text beside a row whose drop is not answered by a drag of its key.  It is shown exactly for an owed key whose row says "not where you put it"
(`rowNote_true`), and the reasons behind it are classified (`rowNote_reason`).  `try_again_answers`: pressing "Try again" on such a row either makes a move leave, or the
row, after the press, carries the note. -/

/-- The note is shown only where it is true: the key is owed, the row says "not where you put it" (so nothing of the key is leaving and it is not waiting), the read is good,
and no move of the key exists. -/
theorem rowNote_true {s : State} {r : Read} {k : Key} {w : RowNote} (h : rowNote s r k = some w) :
    rowLine s r k = .notWherePut ∧ owedNow s k = true ∧ s.gate r = true ∧ userMove s r k = none ∧ movingKey s r k = false ∧
    (rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn) := by
  unfold rowNote at h
  split at h
  · rename_i hc
    simp only [Bool.and_eq_true, beq_iff_eq] at hc
    obtain ⟨hrow, hown⟩ := hc
    have hm : movingKey s r k = false := by
      cases hm : movingKey s r k
      · rfl
      · have := row_moving_iff.mpr hm
        rw [hrow] at this; cases this
    have hown' : k ∈ s.owedKeys ∨ s.foldRequest = some k := by
      simpa [owedNow] using hown
    have hg : s.gate r = true := by
      cases hg : s.gate r
      · have := row_waiting_conv hm hown' (Or.inl hg)
        rw [hrow] at this; cases this
      · rfl
    have hu : userMove s r k = none := by
      cases hu : userMove s r k
      · rfl
      · have := row_waiting_conv hm hown' (Or.inr (by simp [hu]))
        rw [hrow] at this; cases this
    exact ⟨hrow, hown, hg, hu, hm, row_notWherePut_bridge hrow⟩
  · simp at h

/-- **The reasons behind the note.**  An owed key with the note shown has a row that says `outOfPlace` or `behindOutOfTurn`, no move of it exists, and one of the causes
`userMove_none_reason` lists holds: the keys AROUND it are out of order (movable and misplaced, the one place `fallbackRel` names changes nothing), or the reading contradicts itself
about the key (counted folded and also drawn and trusted; a pull-out that changes nothing; ...).  There is no cause hidden from the screen. -/
theorem rowNote_reason {s : State} {r : Read} {k : Key} {w : RowNote} (howed : k ∈ s.owedKeys) (h : rowNote s r k = some w) :
    (rowVerdict s.record (s.view r) k = .outOfPlace ∨ rowVerdict s.record (s.view r) k = .behindOutOfTurn) ∧ userMove s r k = none ∧
    ((k ∈ movable s r ∧ misplaced s r k = false) ∨
    (k ∈ movable s r ∧ misplaced s r k = true ∧ (k ∉ s.record ∨ wholeBar s r = false ∨ NoReducingDrag s r k)) ∨
    (k ∉ foldedAll s r ∧ ¬ (k ∈ r.drawn ∧ k ∈ r.trusted)) ∨
    (k ∈ foldedAll s r ∧ ¬ (r.chevron = .fresh ∧ k ∈ r.foldedSet)) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = none) ∨
    (k ∈ foldedAll s r ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧ ∃ p,
      ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? = some p ∧
      applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn)) := by
  have ht := rowNote_true h
  exact ⟨ht.2.2.2.2.2, ht.2.2.2.1, userMove_none_reason s r k howed ht.2.2.2.1⟩

/-- A queued key with an allowed move makes the read decide a move (maybe another queued key's, which comes first). -/
theorem queue_move_decides {s : State} {r : Read} {j : Key} {a : Action} (hi : s.inFlight = none) (hg : s.gate r = true)
    (hq : j ∈ s.foldRequest.toList ++ s.owedKeys) (hum : userMove s r j = some a) (hal : userAllowed s r a = true) :
    ∃ b, decideMove s r = some b := by
  obtain ⟨hpass, hset, hinc, _⟩ := gate_facts hg
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  cases hb : userPick s r with
  | some b => exact ⟨b, by simp only [decideMove]; rw [if_neg hc, hb]⟩
  | none =>
    have := userPick_none hb j hq
    simp [hum, Option.filter, hal] at this

/-- The core of `try_again_answers` for any state `S` that differs from `s` only as a press of "Try again" does. -/
theorem try_again_core (s S : State) (r : Read) (k : Key) (hrec : S.record = s.record) (hinf : S.inFlight = none)
    (hpn : S.provenNotFull = s.provenNotFull) (hed : S.editSessionUsed = false) (hres : S.restricted = true)
    (hown : k ∈ S.owedKeys) (hg : s.gate r = true) (hrow : rowLine s r k = .notWherePut) :
    (∃ a, (step S (.read r)).2 = [a] ∧ a.user = true) ∨
    (rowLine S r k = .notWherePut ∧ (rowNote S r k).isSome = true ∧ userMove S r k = none) := by
  have hg' : S.gate r = true := by
    simp only [State.gate, State.view, hpn]; exact hg
  have hview : S.view r = s.view r := by simp only [State.view, hpn]
  obtain ⟨_, _, _, hso⟩ := gate_facts hg
  cases hd : decideMove S r with
  | some b =>
    left
    refine ⟨b, by simp [step, hd], ?_⟩
    rcases (gate_decide_cases hd).2 with ⟨j, _, hj, _⟩ | ⟨hea, _⟩
    · exact (gate_userMove_user hj).1
    · simp [engineAllowed, hres] at hea
  | none =>
    right
    have hu : userMove S r k = none := by
      cases hu : userMove S r k with
      | none => rfl
      | some a =>
        exfalso
        have hal : userAllowed S r a = true := by
          simp [userAllowed, hed, hso]
        obtain ⟨b, hb⟩ := queue_move_decides hinf hg' (List.mem_append_right _ hown) hu hal
        rw [hd] at hb; cases hb
    have hm : movingKey S r k = false := by
      simp [movingKey, hinf, hd]
    have hwait : waitingKey S r k = false := by
      simp [waitingKey, hg', hu]
    have hv := row_notWherePut_bridge hrow
    have hl : rowLine S r k = .notWherePut := by
      unfold rowLine
      rw [hm, hwait]
      simp only [Bool.false_eq_true, ite_false, hrec, hview]
      rcases hv with hv | hv <;> simp [hv, RowVerdict.line]
    refine ⟨hl, ?_, hu⟩
    unfold rowNote
    have : owedNow S k = true := by simp [owedNow, hown]
    simp only [hl, this, beq_self_eq_true, Bool.and_self, ite_true]
    split <;> (try split) <;> simp

/-- **try_again_answers.**  A row that says "not where you put it", on a good read with nothing in flight: pressing its "Try again" (`retryKey`) either makes a user's move leave on
this read (the key's own, or another queued key's that goes first), or the row after the press still says "not where you put it" AND carries the note, with no move of the key existing
(`rowNote_reason` classifies why).  A press never does nothing silently.  (A press restricts the engine, so every move that leaves is the user's; the strip session is fresh.) -/
theorem try_again_answers (s : State) (r : Read) (k : Key) (hi : s.inFlight = none) (hk : k ∈ s.record)
    (hg : s.gate r = true) (hrow : rowLine s r k = .notWherePut) :
    (∃ a, (step (step s (.retryKey k)).1 (.read r)).2 = [a] ∧ a.user = true) ∨
    (rowLine (step s (.retryKey k)).1 r k = .notWherePut ∧ (rowNote (step s (.retryKey k)).1 r k).isSome = true ∧
      userMove (step s (.retryKey k)).1 r k = none) :=
  try_again_core s _ r k (by simp [step]) (by simp [step, hi]) (by simp [step]) (by simp [step]) (by simp [step])
    ((rk_owed s k k).2 ⟨hk, Or.inl rfl⟩) hg hrow


/-! ### The drain -/

/-- Weighted length of a list of keys. -/
def wsum (f : Key → Nat) : List Key → Nat
  | [] => 0
  | x :: xs => f x + wsum f xs

theorem wsum_erase_add (f : Key → Nat) : ∀ (l : List Key) (j : Key), j ∈ l → wsum f (l.erase j) + f j = wsum f l
  | [], _, h => by simp at h
  | x :: xs, j, h => by
    by_cases hx : x = j
    · subst hx; simp [wsum, List.erase_cons]; omega
    · have hj : j ∈ xs := by simpa [Ne.symm hx] using h
      have := wsum_erase_add f xs j hj
      have hb : (x == j) = false := by simpa using hx
      simp [wsum, List.erase_cons, hb]
      omega

theorem wsum_erase_not (f : Key → Nat) (l : List Key) (j : Key) (h : j ∉ l) : wsum f (l.erase j) = wsum f l := by
  rw [List.erase_of_not_mem h]

theorem wsum_le (f g : Key → Nat) (hfg : ∀ x, f x ≤ g x) : ∀ l : List Key, wsum f l ≤ wsum g l
  | [] => by simp [wsum]
  | x :: xs => by
    have := wsum_le f g hfg xs
    have := hfg x
    simp [wsum]; omega

theorem wsum_filter_le (f : Key → Nat) (p : Key → Bool) : ∀ l : List Key, wsum f (l.filter p) ≤ wsum f l
  | [] => by simp [wsum]
  | x :: xs => by
    have := wsum_filter_le f p xs
    by_cases hp : p x = true
    · simp [List.filter_cons, hp, wsum]; omega
    · simp [List.filter_cons, hp, wsum]; omega

theorem wsum_eraseDups_le (f : Key → Nat) : ∀ (n : Nat) (l : List Key), l.length ≤ n → wsum f l.eraseDups ≤ wsum f l
  | 0, l, h => by
    have : l = [] := List.eq_nil_of_length_eq_zero (by omega)
    subst this; simp [List.eraseDups, wsum]
  | n+1, [], _ => by simp [List.eraseDups, wsum]
  | n+1, a :: as, h => by
    rw [List.eraseDups_cons]
    have ih := wsum_eraseDups_le f n (as.filter (fun b => !b == a)) (by
      have := List.length_filter_le (fun b => !b == a) as
      simp at h; omega)
    have h2 := wsum_filter_le f (fun b => !b == a) as
    simp only [wsum]; omega

theorem wsum_le_two (sk : List Key) (f : Key → Nat) (hf : ∀ x, f x ≤ 2) : ∀ l : List Key, wsum f l ≤ 2 * l.length
  | [] => by simp [wsum]
  | x :: xs => by
    have := wsum_le_two sk f hf xs
    have := hf x
    simp [wsum]; omega

/-- A key's weight in the potential: two attempts left if it was never skipped (an interrupted drag re-arms it once), one if it was. -/
def skipW (sk : List Key) (j : Key) : Nat := if sk.contains j then 1 else 2

/-- The request-only key (the request is not also owed) is one more thing to serve. -/
def reqExtra (s : State) : Nat :=
  match s.foldRequest with
  | some j => if s.owedKeys.contains j then 0 else 1
  | none => 0

/-- The drag in flight, if its busy result could re-arm its key once more. -/
def flightPot (s : State) : Nat :=
  match s.inFlight with
  | some a => if s.flightOwed == some s.gen && !s.skipped.contains a.subject then 1 else 0
  | none => 0

/-- The potential of the owed queue: attempts left, counting the one a busy result may give back. -/
def potential (s : State) : Nat := wsum (skipW s.skipped) s.owedKeys + reqExtra s + flightPot s

theorem potential_noteRead (s : State) (r : Read) : potential (noteRead s r) = potential s := by
  have nk := noteRead_keeps s r
  unfold potential reqExtra flightPot
  rw [nk.1, nk.2.1, nk.2.2.2.1, nk.2.2.2.2.2.1, nk.2.2.2.2.2.2.1, nk.2.2.2.2.2.2.2.2.2.2.1]


theorem contains_erase_ne (l : List Key) (i j : Key) (h : i ≠ j) : (l.erase j).contains i = l.contains i := by
  cases hl : l.contains i
  · cases hh : (l.erase j).contains i
    · rfl
    · simp [List.contains_iff_mem] at hh hl
      exact absurd (List.mem_of_mem_erase hh) (by simpa using hl)
  · simp [List.contains_iff_mem] at hl ⊢
    exact List.mem_erase_of_ne h |>.2 hl

theorem emit_flightPot (S : State) (a : Action) :
    flightPot (emit S a) = if S.owedKeys.contains a.subject && !S.skipped.contains a.subject then 1 else 0 := by
  unfold flightPot emit
  cases hc : S.owedKeys.contains a.subject <;> simp [hc]

theorem emit_wsum_req (S : State) (a : Action) (hjc : S.owedKeys.contains a.subject = true) :
    reqExtra (emit S a) = reqExtra S := by
  unfold reqExtra emit
  cases hf : S.foldRequest with
  | none => simp [hf]
  | some i =>
    by_cases hij : i = a.subject
    · subst hij
      have hjm : a.subject ∈ S.owedKeys := by simpa [List.contains_iff_mem] using hjc
      simp [hf, hjm]
    · have hb : (some i == some a.subject) = false := by simpa using hij
      simp only [hf, hb, Bool.false_eq_true, ite_false]
      rw [contains_erase_ne _ _ _ hij]

theorem potential_emit_queue (S : State) (a : Action) (hi : S.inFlight = none)
    (hq : S.owedKeys.contains a.subject = true ∨ S.foldRequest = some a.subject) : potential (emit S a) + 1 ≤ potential S := by
  have hpS : potential S = wsum (skipW S.skipped) S.owedKeys + reqExtra S := by
    simp [potential, flightPot, hi]
  rw [hpS]
  cases hjc : S.owedKeys.contains a.subject
  · have hf : S.foldRequest = some a.subject := by
      rcases hq with h | h
      · rw [hjc] at h; cases h
      · exact h
    have hj : a.subject ∉ S.owedKeys := by simpa [List.contains_iff_mem] using hjc
    have e := wsum_erase_not (skipW S.skipped) S.owedKeys a.subject hj
    have h1 : reqExtra S = 1 := by simp [reqExtra, hf, hj]
    have h2 : reqExtra (emit S a) = 0 := by simp [reqExtra, emit, hf]
    unfold potential
    rw [emit_flightPot, hjc]
    simp only [emit, e] at h2 ⊢
    rw [h2, h1]; simp
  · have hj : a.subject ∈ S.owedKeys := by simpa [List.contains_iff_mem] using hjc
    have e := wsum_erase_add (skipW S.skipped) S.owedKeys a.subject hj
    have hreq := emit_wsum_req S a hjc
    have eo : (emit S a).owedKeys = S.owedKeys.erase a.subject := rfl
    have es : (emit S a).skipped = S.skipped := rfl
    unfold potential
    rw [eo, es, emit_flightPot, hjc, hreq]
    cases hs : S.skipped.contains a.subject
    · have hs' : a.subject ∉ S.skipped := by simpa [List.contains_iff_mem] using hs
      have : skipW S.skipped a.subject = 2 := by simp [skipW, hs']
      rw [this] at e
      simp [hs']; omega
    · have hs' : a.subject ∈ S.skipped := by simpa [List.contains_iff_mem] using hs
      have : skipW S.skipped a.subject = 1 := by simp [skipW, hs']
      rw [this] at e
      simp [hs']; omega

theorem potential_emit_other (S : State) (a : Action) (hi : S.inFlight = none)
    (hq : S.owedKeys.contains a.subject = false ∧ S.foldRequest ≠ some a.subject) : potential (emit S a) ≤ potential S := by
  have hpS : potential S = wsum (skipW S.skipped) S.owedKeys + reqExtra S := by
    simp [potential, flightPot, hi]
  have hj : a.subject ∉ S.owedKeys := by simpa [List.contains_iff_mem] using hq.1
  have e := wsum_erase_not (skipW S.skipped) S.owedKeys a.subject hj
  have hb : (S.foldRequest == some a.subject) = false := by simpa using hq.2
  have h2 : reqExtra (emit S a) = reqExtra S := by
    unfold reqExtra emit
    simp only [hb, Bool.false_eq_true, ite_false]
    rw [List.erase_of_not_mem hj]
  rw [hpS]
  unfold potential
  rw [emit_flightPot, hq.1]
  simp only [emit] at h2 ⊢
  rw [h2, e]; simp


theorem result_fields (s : State) (a : Action) (o : Outcome) (p : Bool) :
    (result s a o p).inFlight = none ∧ (result s a o p).gen = s.gen ∧ (result s a o p).flightOwed = s.flightOwed ∧
    (result s a o p).stripGrant = s.stripGrant := by
  unfold result; grind

theorem result_skipped_mono (s : State) (a : Action) (o : Outcome) (p : Bool) (j : Key)
    (h : s.skipped.contains j = true) : (result s a o p).skipped.contains j = true := by
  unfold result; grind

theorem result_shape (s : State) (a : Action) (o : Outcome) (p : Bool) :
    ((result s a o p).owedKeys = s.owedKeys ∧ (result s a o p).foldRequest = s.foldRequest) ∨
    ((result s a o p).owedKeys = (a.subject :: s.owedKeys).eraseDups ∧ s.flightOwed = some s.gen ∧
      s.skipped.contains a.subject = false ∧ (result s a o p).skipped.contains a.subject = true ∧
      ((result s a o p).foldRequest = s.foldRequest ∨ (result s a o p).foldRequest = some a.subject)) := by
  unfold result; grind


theorem skipW_true (sk : List Key) (j : Key) (h : sk.contains j = true) : skipW sk j = 1 := by
  unfold skipW; rw [if_pos h]

theorem skipW_false (sk : List Key) (j : Key) (h : sk.contains j = false) : skipW sk j = 2 := by
  unfold skipW; rw [if_neg (by intro hh; rw [h] at hh; cases hh)]

theorem skipW_mono (sk sk' : List Key) (h : ∀ j, sk.contains j = true → sk'.contains j = true) (j : Key) :
    skipW sk' j ≤ skipW sk j := by
  cases h1 : sk.contains j
  · rw [skipW_false _ _ h1]
    cases h2 : sk'.contains j
    · rw [skipW_false _ _ h2]; exact Nat.le_refl _
    · rw [skipW_true _ _ h2]; omega
  · rw [skipW_true _ _ h1, skipW_true _ _ (h j h1)]; exact Nat.le_refl _

theorem potential_result (s : State) (a : Action) (o : Outcome) (p : Bool) (hf : s.inFlight = some a) :
    potential (result s a o p) ≤ potential s := by
  obtain ⟨hi, hg, hfo, _⟩ := result_fields s a o p
  have hw : wsum (skipW (result s a o p).skipped) s.owedKeys ≤ wsum (skipW s.skipped) s.owedKeys :=
    wsum_le _ _ (skipW_mono _ _ (result_skipped_mono s a o p)) _
  have hpf : potential (result s a o p) = wsum (skipW (result s a o p).skipped) (result s a o p).owedKeys + reqExtra (result s a o p) := by
    simp [potential, flightPot, hi]
  rcases result_shape s a o p with ⟨ho, hr⟩ | ⟨ho, hflo, hns, hsk, hr⟩
  · rw [hpf, ho]
    have : reqExtra (result s a o p) = reqExtra s := by unfold reqExtra; rw [hr, ho]
    rw [this]
    unfold potential
    omega
  · rw [hpf, ho]
    have hfp : flightPot s = 1 := by
      unfold flightPot; rw [hf]; simp only [hflo, hns]; simp
    have hsw : skipW (result s a o p).skipped a.subject = 1 := skipW_true _ _ hsk
    have h1 := wsum_eraseDups_le (skipW (result s a o p).skipped) _ (a.subject :: s.owedKeys) (Nat.le_refl _)
    have h2 : wsum (skipW (result s a o p).skipped) (a.subject :: s.owedKeys) =
        1 + wsum (skipW (result s a o p).skipped) s.owedKeys := by simp [wsum, hsw]
    have hreq : reqExtra (result s a o p) ≤ reqExtra s := by
      unfold reqExtra
      rw [ho]
      rcases hr with hr | hr
      · rw [hr]
        cases hq : s.foldRequest with
        | none => exact Nat.le_refl _
        | some i =>
          show (if ((a.subject :: s.owedKeys).eraseDups).contains i = true then 0 else 1) ≤ (if s.owedKeys.contains i = true then 0 else 1)
          by_cases hio : s.owedKeys.contains i = true
          · have : ((a.subject :: s.owedKeys).eraseDups).contains i = true := by
              rw [List.contains_iff_mem, List.mem_eraseDups]
              exact List.mem_cons_of_mem _ (List.contains_iff_mem.1 hio)
            rw [if_pos this, if_pos hio]; exact Nat.le_refl _
          · rw [if_neg hio]
            by_cases hn : ((a.subject :: s.owedKeys).eraseDups).contains i = true
            · rw [if_pos hn]; omega
            · rw [if_neg hn]; exact Nat.le_refl _
      · rw [hr]
        have : ((a.subject :: s.owedKeys).eraseDups).contains a.subject = true := by
          rw [List.contains_iff_mem, List.mem_eraseDups]; exact List.mem_cons_self
        show (if ((a.subject :: s.owedKeys).eraseDups).contains a.subject = true then 0 else 1) ≤ _
        rw [if_pos this]; omega
    unfold potential
    rw [hfp]
    omega


theorem planOrderMoves_user {s : State} {r : Read} {b : Action} (h : planOrderMoves s r = some b) : b.user = false := by
  unfold planOrderMoves at h
  simp only at h
  split at h
  · rename_i w h' _
    split at h
    · simp at h
    · simp at h; subst h; rfl
  · simp at h

/-- With no strip grant, a user's action is the move of a queued key. -/
theorem decide_user_queue {s : State} {r : Read} {a : Action} (hd : decideMove s r = some a) (hu : a.user = true)
    (hgr : s.stripGrant = false) : s.owedKeys.contains a.subject = true ∨ s.foldRequest = some a.subject := by
  rcases (gate_decide_cases hd).2 with ⟨k, hk, hum, _⟩ | ⟨_, b, hb, hh⟩
  · have hs := (gate_userMove_user hum).2
    rw [hs]
    rcases hk with hk | hk
    · right; simpa using hk
    · left; simpa using hk
  · rcases hh with ⟨_, rfl⟩ | ⟨_, hsg, _⟩
    · rw [planOrderMoves_user hb] at hu; cases hu
    · rw [hgr] at hsg; cases hsg

theorem emit_stripGrant (S : State) (a : Action) (h : S.stripGrant = false) : (emit S a).stripGrant = false := by
  unfold emit; split <;> simp [h]

theorem potential_read (s : State) (r : Read) (hgr : s.stripGrant = false) :
    potential (step s (.read r)).1 + ((step s (.read r)).2.filter (fun a => a.user)).length ≤ potential s ∧
    (step s (.read r)).1.stripGrant = false := by
  have nk := noteRead_keeps s r
  cases hd : decideMove s r with
  | none =>
    simp only [step, hd]
    refine ⟨?_, by rw [nk.2.2.2.2.2.2.2.2.2.2.2.2.1]; exact hgr⟩
    simp [potential_noteRead]
  | some a =>
    have hi := (gate_decide_cases hd).1
    have hSi : (noteRead s r).inFlight = none := by rw [nk.2.2.2.1]; exact hi
    have hq : (noteRead s r).owedKeys = s.owedKeys := nk.1
    have hqf : (noteRead s r).foldRequest = s.foldRequest := nk.2.1
    have hgS : (noteRead s r).stripGrant = false := by rw [nk.2.2.2.2.2.2.2.2.2.2.2.2.1]; exact hgr
    simp only [step, hd]
    refine ⟨?_, emit_stripGrant _ _ hgS⟩
    by_cases hqm : (noteRead s r).owedKeys.contains a.subject = true ∨ (noteRead s r).foldRequest = some a.subject
    · have := potential_emit_queue (noteRead s r) a hSi hqm
      rw [potential_noteRead] at this
      have hl : ([a].filter (fun a => a.user)).length ≤ 1 := by
        have := List.length_filter_le (fun a : Action => a.user) [a]
        simpa using this
      omega
    · have hu : a.user = false := by
        cases hu : a.user
        · rfl
        · exfalso; apply hqm; rw [hq, hqf]; exact decide_user_queue hd hu hgr
      have hq2 : (noteRead s r).owedKeys.contains a.subject = false ∧ (noteRead s r).foldRequest ≠ some a.subject := by
        constructor
        · cases hc : (noteRead s r).owedKeys.contains a.subject
          · rfl
          · exact absurd (Or.inl hc) hqm
        · intro h; exact hqm (Or.inr h)
      have := potential_emit_other (noteRead s r) a hSi hq2
      rw [potential_noteRead] at this
      simp [hu]
      exact this

theorem potential_result_step (s : State) (k : Key) (o : Outcome) (p : Bool) (hgr : s.stripGrant = false) :
    potential (step s (.moveResult k o p)).1 ≤ potential s ∧ (step s (.moveResult k o p)).1.stripGrant = false := by
  simp only [step]
  cases hf : s.inFlight with
  | none => exact ⟨Nat.le_refl _, hgr⟩
  | some a =>
    simp only []
    split
    · exact ⟨potential_result s a o p hf, by rw [(result_fields s a o p).2.2.2]; exact hgr⟩
    · exact ⟨Nat.le_refl _, hgr⟩

/-- Over any events that are reads and results of drags (an adversarial macOS may answer each drag `verified`, `failed`, `refused` or `busy`, posted or not),
the user's moves that leave number at most `potential s`. -/
theorem drain_potential (s : State) (hgr : s.stripGrant = false) (es : List Event)
    (hes : ∀ e ∈ es, (∃ r, e = .read r) ∨ (∃ k o p, e = .moveResult k o p)) :
    ((run s es).2.filter (fun a => a.user)).length ≤ potential s := by
  induction es generalizing s with
  | nil => simp [run]
  | cons e es ih =>
    have he := hes e (by simp)
    have hes' : ∀ e' ∈ es, (∃ r, e' = .read r) ∨ (∃ k o p, e' = .moveResult k o p) := fun e' h => hes e' (by simp [h])
    simp only [run, List.filter_append, List.length_append]
    rcases he with ⟨r, rfl⟩ | ⟨k, o, p, rfl⟩
    · obtain ⟨h1, h2⟩ := potential_read s r hgr
      have := ih (step s (.read r)).1 h2 hes'
      omega
    · obtain ⟨h1, h2⟩ := potential_result_step s k o p hgr
      have hn : ((step s (.moveResult k o p)).2.filter (fun a => a.user)).length = 0 := by
        simp only [step]
        cases hf : s.inFlight with
        | none => simp
        | some a => simp only []; split <;> simp
      have := ih (step s (.moveResult k o p)).1 h2 hes'
      omega

theorem potential_le (s : State) (hi : s.inFlight = none) : potential s ≤ 2 * (s.owedKeys.length + reqExtra s) := by
  have h1 : wsum (skipW s.skipped) s.owedKeys ≤ 2 * s.owedKeys.length :=
    wsum_le_two s.skipped (skipW s.skipped) (fun x => by unfold skipW; split <;> omega) _
  have h2 : flightPot s = 0 := by simp [flightPot, hi]
  unfold potential
  omega

/-- **drops_drain.**  From ANY state with nothing in flight and no strip grant, over ANY events that are reads and drag results (no user event, no pass boundary; the reads need
not be good, the results are the adversary's: `verified`, `failed`, `refused`, `busy`, posted or not), the user's moves that leave number at most `2 * n`, where `n` is the length of the
owed queue plus one if the fold request is not itself owed.  The factor 2 is the busy re-arm: an interrupted drag (`busy`, no mouse event) gives its key back ONCE (`Rearm`), so a key is
attempted at most twice.  Without busy results the bound is `n`.  Strip session: a move that needs the strip waits (never leaves) once the edit's session is used, so it only
makes the count smaller; budget: user moves are exempt from it.  So after at most `2n` moves no user move leaves, on any read: each key still owed then has a named reason
(`owed_unanswered_reason`, `rowNote_reason`).  Keys that need no move stay owed until the pass boundary (they are not "drained" by a move). -/
theorem drops_drain (s : State) (hi : s.inFlight = none) (hgr : s.stripGrant = false) (es : List Event)
    (hes : ∀ e ∈ es, (∃ r, e = .read r) ∨ (∃ k o p, e = .moveResult k o p)) :
    ((run s es).2.filter (fun a => a.user)).length ≤ 2 * (s.owedKeys.length + reqExtra s) :=
  Nat.le_trans (drain_potential s hgr es hes) (potential_le s hi)

/-! ### The drops that used to get no move (ejb.10), on the exact traces

A good read: a pass, settled, complete, strip closed, fresh chevron with key 9 in the pile, every drawn key trusted. -/

/-- A good read of a bar drawing `d`, with key 9 behind the chevron. -/
def dropRead (d : List Key) : Read :=
  { kind := .pass, chevron := .fresh, level := .complete, settled := true, stripOpen := false,
    drawn := d, pile := [9], folded := [], trusted := d ++ [9], nearFold := [] }

/-- **(b) The mutual inversion is answered.**  Record [1,2,3], the user drops [1,2] (both owed), the bar draws [2,1,3]: the first good read moves key 1 before key 2; once that drag
is verified the bar is [1,2,3] and key 2 (now right among the served key 1, which is an anchor) needs no move.  Each key dropped ALONE also gets its move. -/
theorem drop_mutual_inversion :
    (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [1, 2], .read (dropRead [2, 1, 3])]).2 = [⟨1, .before 2, false, true⟩] ∧
    (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [1, 2], .read (dropRead [2, 1, 3]), .moveResult 1 .verified true,
      .read (dropRead [1, 2, 3])]).2 = [⟨1, .before 2, false, true⟩] ∧
    (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [1], .read (dropRead [2, 1, 3])]).2 = [⟨1, .before 2, false, true⟩] ∧
    (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [2], .read (dropRead [2, 1, 3])]).2 = [⟨2, .after 1, false, true⟩] := by decide

/-- **(c) The bar with no gap: a move exactly where it strictly helps.**  Record [1,2,4,3], bar [2,3,4,1] (4 inversions).  Dropping 1, 3 or 4 gives a move (1 `before` 2, 3 `after` 1, 4
`after` 2); dropping 2 gives NO move, because no single drag of 2 leaves fewer inversions (the old rule dragged it to the end: 4 inversions, worse), and its row says so
(`drop_no_gap_note`).  After a pass boundary a fresh press on 2 shows the same. -/
theorem drop_no_gap :
    (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [1], .read (dropRead [2, 3, 4, 1])]).2 = [⟨1, .before 2, false, true⟩] ∧
    (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [2], .read (dropRead [2, 3, 4, 1])]).2 = [] ∧
    (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [3], .read (dropRead [2, 3, 4, 1])]).2 = [⟨3, .after 1, false, true⟩] ∧
    (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [4], .read (dropRead [2, 3, 4, 1])]).2 = [⟨4, .after 2, false, true⟩] ∧
    (run (State.init [1, 2, 4, 3]) [.userEdit [1, 2, 4, 3] [4], .passBoundary, .retryKey 2, .read (dropRead [2, 3, 4, 1])]).2 = [] := by decide

/-- The dropped key 2 of (c) says why: "No single move of this item would improve the order". -/
theorem drop_no_gap_note :
    let s := (step (State.init [1, 2, 4, 3]) (.userEdit [1, 2, 4, 3] [2])).1
    rowLine s (dropRead [2, 3, 4, 1]) 2 = .notWherePut ∧ rowNote s (dropRead [2, 3, 4, 1]) 2 = some .noMoveHelps ∧
    invCount s (dropRead [2, 3, 4, 1]) [2, 3, 4, 1] = 4 ∧ invCount s (dropRead [2, 3, 4, 1]) [3, 4, 1, 2] = 5 := by decide

/-- **A drop that still gets no move says so.**  Record [1,2,3,4], bar [2,3,4,1], the user drops 3 and 2 is not owed: no drag of 3 improves the order, the row says "not where you put it"
with the note `noMoveHelps`; "Try again" leaves the same note on the row. -/
theorem drop_keys_around_say_so :
    let s := (step (State.init [1, 2, 3, 4]) (.userEdit [1, 2, 3, 4] [2])).1
    (step s (.read (dropRead [2, 3, 4, 1]))).2 = [] ∧
    rowNote s (dropRead [2, 3, 4, 1]) 2 = some .noMoveHelps ∧ rowLine s (dropRead [2, 3, 4, 1]) 2 = .notWherePut ∧
    (step (step s (.retryKey 2)).1 (.read (dropRead [2, 3, 4, 1]))).2 = [] ∧
    rowNote (step s (.retryKey 2)).1 (dropRead [2, 3, 4, 1]) 2 = some .noMoveHelps ∧
    rowNote s (dropRead [2, 3, 4, 1]) 3 = none := by decide

/-- **The drain bound is attained.**  One owed key whose drag is interrupted twice (no mouse event, `busy`) leaves twice, the second time through the one re-arm, and never a third time:
`2 * n` with `n = 1`. -/
theorem drain_bound_attained :
    let s := (step (State.init [1, 2]) (.userEdit [1, 2] [1])).1
    ((run s [.read (dropRead [2, 1]), .moveResult 1 .busy false, .read (dropRead [2, 1]), .moveResult 1 .busy false,
      .read (dropRead [2, 1]), .moveResult 1 .busy false]).2.filter (fun a => a.user)).length = 2 := by decide


/-! ### The fallback minimises inversions (ejb.10, corrective pass) -/

/-- **fallback_reduces_inversions.**  A fallback move strictly lowers the inversion count among the movable record keys, measured on the bar AFTER the drag (`applyMove`). -/
theorem fallback_reduces_inversions {s : State} {r : Read} {k : Key} {a : Action} (h : fallbackMove s r k = some a) :
    invCount s r (applyMove r.drawn a) < invCount s r r.drawn := (fallbackMove_basic h).2.2.2.2.2.2.2.2.2.2.2.2.1

/-- **fallback_best.**  The fallback's drag has the lowest WORST CASE (`worstCount`: the inversions of the movable record keys after the drag plus the most the free keys can add) of every
single drag of `k` to either side of a movable record key other than `k`.  This is the rule as stated: it does NOT say the drag is best on every particular bar (a bar with no free key
between `k` and the place may be helped more by another drag), nor over places no key names. -/
theorem fallback_best {s : State} {r : Read} {k : Key} {a : Action} (h : fallbackMove s r k = some a) :
    ∀ rel : Rel, rel.target ∈ movable s r → rel.target ∈ s.record → rel.target ≠ k →
      worstCount s r k a.rel ≤ worstCount s r k rel := by
  intro rel h1 h2 h3
  exact (fallbackMove_basic h).2.2.2.2.2.2.2.2.2.2.2.2.2 rel (legal_mem_cands h1 h2 h3)

/-- **fallback_best_whole.**  On a read that verifies the whole bar there is no free key, and no other single drag of `k` (to either side of ANY movable record key other than `k`, i.e. to any place `k`
may go) leaves fewer inversions than the fallback's (the ejb.10 statement of `fallback_best`). -/
theorem fallback_best_whole {s : State} {r : Read} {k : Key} {a : Action} (hw : wholeBar s r = true) (h : fallbackMove s r k = some a) :
    ∀ rel : Rel, rel.target ∈ movable s r → rel.target ∈ s.record → rel.target ≠ k →
      invCount s r (applyMove r.drawn a) ≤ invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩) := by
  intro rel h1 h2 h3
  have := fallback_best h rel h1 h2 h3
  rw [worstCount_wholeBar hw, worstCount_wholeBar hw] at this
  have hb := fallbackMove_basic h
  have hs : a.subject = k := hb.2.1
  have hq : a = ⟨k, a.rel, a.strip, a.user⟩ := by cases a; simp_all
  rw [hq]
  rw [applyMove_flags r.drawn k a.rel a.strip a.user false true]
  exact this

/-- A key that misplaced-tests false, or any movable key with a mismatch witness, bridges `misplaced` to the position test. -/
theorem misplaced_of_witness {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r) {x : Key} (hx : x ∈ movable s r) (hxk : x ≠ k)
    (hxr : x ∈ s.record)
    (hn : ¬ (x ∈ s.record.takeWhile (fun y => y != k) ↔ (movable s r).idxOf x < (movable s r).idxOf k)) : misplaced s r k = true := by
  unfold misplaced
  apply List.any_eq_true.2
  refine ⟨x, hx, ?_⟩
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem]
  refine ⟨⟨hxk, hxr⟩, fun heq => hn ?_⟩
  have e := tw_mem hk x
  have h2 : x ∈ s.record.takeWhile (fun y => y != k) ↔ x ∈ (movable s r).takeWhile (fun y => y != k) := by
    have := congrArg (fun b : Bool => b = true) heq
    simpa [List.contains_iff_mem] using this
  rw [h2, e]
  simp [hx]

/-- **right_everywhere_no_move.**  A movable key that is in order against ALL the movable record keys (`misplaced` false: each of them is before it on the bar exactly when it is before it in the
record) gets no move at all, from the anchor rule or the fallback.  (This replaces the ejb.3 `userMove_right_place`, which was stated for the anchors only and, with the fallback, needed
the fallback's own answer as a hypothesis.) -/
theorem right_everywhere_no_move {s : State} {r : Read} {k : Key} (hk : k ∈ movable s r) (h : misplaced s r k = false) : userMove s r k = none := by
  rw [userMove_drawn_spec hk]
  have hfm : fallbackMove s r k = none := by simp [fallbackMove, h]
  cases ha : anchorMove s r k with
  | none => simp [hfm]
  | some a =>
    exfalso
    obtain ⟨_, _, _, _, _, _, x, hx, hxk, hxr, hn⟩ := anchorMove_drawn s r k a hk ha
    have := misplaced_of_witness hk hx hxk hxr hn
    rw [h] at this; cases this

/-- **noMoveHelps_true.**  The note `noMoveHelps` ("No single move of this item would improve the order") is shown only where it is true: the read is good and verifies the whole bar
(`wholeBar`); the key is owed, in the record, movable and misplaced; EVERY single drag of it (either side of any movable record key other than itself) leaves at least as many
inversions among the movable record keys as the bar has now; no queued key has an allowed move on this read; and the row says "not where you put it".  `noMoveHelps_bar` lifts this to the
real bar: every possible bar, every place in its open keys. -/
theorem noMoveHelps_true {s : State} {r : Read} {k : Key} (h : rowNote s r k = some .noMoveHelps) :
    s.gate r = true ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ wholeBar s r = true ∧ misplaced s r k = true ∧ NoReducingDrag s r k ∧
    userPick s r = none ∧ userMove s r k = none ∧ rowLine s r k = .notWherePut := by
  have ht := rowNote_true h
  unfold rowNote at h
  split at h
  · split at h
    · rename_i hc
      simp only [Bool.and_eq_true, List.contains_iff_mem, Option.isNone_iff_eq_none] at hc
      obtain ⟨⟨⟨⟨⟨⟨hm, ho⟩, hrk⟩, hwb⟩, hmis⟩, hfm⟩, hp⟩ := hc
      rcases fallbackMove_none_cases ho hm hfm with h1 | ⟨_, h2 | h2 | hn⟩
      · rw [hmis] at h1; cases h1
      · exact absurd hrk h2
      · rw [hwb] at h2; cases h2
      · exact ⟨ht.2.2.1, ho, hrk, hm, hwb, hmis, hn, hp, ht.2.2.2.1, ht.1⟩
    · split at h <;> simp at h
  · simp at h

/-- **cantJudge_iff.**  The note `cantJudge` ("Sommelier can't yet see enough of the bar to place this item") is shown IF AND ONLY IF the row says "not where you put it", the key is owed
(and in the record), movable and misplaced among the keys the read corroborates, the read does NOT verify the whole bar, NO drag of the key improves the order on every possible bar (the fallback
finds none), and no move is decided on this read. -/
theorem cantJudge_iff {s : State} {r : Read} {k : Key} :
    rowNote s r k = some .cantJudge ↔
      (rowLine s r k = .notWherePut ∧ k ∈ s.owedKeys ∧ k ∈ s.record ∧ k ∈ movable s r ∧ wholeBar s r = false ∧ misplaced s r k = true ∧
        fallbackMove s r k = none ∧ decideMove s r = none) := by
  unfold rowNote
  constructor
  · intro h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true, beq_iff_eq] at hc
      split at h
      · rename_i hh
        simp only [Bool.and_eq_true] at hh
        have := hh.1.2; simp at h
      · split at h
        · rename_i hh
          simp only [Bool.and_eq_true, List.contains_iff_mem, Bool.not_eq_true', Option.isNone_iff_eq_none] at hh
          obtain ⟨⟨⟨⟨⟨⟨hm, ho⟩, hrk⟩, hwb⟩, hmis⟩, hfm⟩, hd⟩ := hh
          exact ⟨hc.1, ho, hrk, hm, hwb, hmis, hfm, hd⟩
        · simp at h
    · simp at h
  · rintro ⟨hrow, ho, hrk, hm, hwb, hmis, hfm, hd⟩
    have hown : owedNow s k = true := by simp [owedNow, ho]
    have hc : (rowLine s r k == RowLine.notWherePut && owedNow s k) = true := by simp [hrow, hown]
    rw [if_pos hc]
    have h1 : ¬ ((movable s r).contains k && s.owedKeys.contains k && s.record.contains k && wholeBar s r && misplaced s r k
        && (fallbackMove s r k).isNone && (userPick s r).isNone) = true := by simp [hwb]
    rw [if_neg h1]
    have h2 : ((movable s r).contains k && s.owedKeys.contains k && s.record.contains k && !wholeBar s r && misplaced s r k
        && (fallbackMove s r k).isNone && (decideMove s r).isNone) = true := by simp [List.contains_iff_mem, hm, ho, hrk, hwb, hmis, hfm, hd]
    rw [if_pos h2]

/-- **cantJudge_free.**  Where `cantJudge` is shown the read leaves some record key free (`freeKeys` is not empty): a listed record key that is not movable and not pinned behind a fresh chevron.
Nothing is claimed about the item beyond that. -/
theorem cantJudge_free {s : State} {r : Read} {k : Key} (h : rowNote s r k = some .cantJudge) : freeKeys s r ≠ [] := by
  have := (cantJudge_iff.1 h).2.2.2.2.1
  intro hf
  have := (wholeBar_iff_free s r).2 hf
  simp_all

/-- A pass whose status is "differs" without a reason of the budget or a hold (`plain`) is exactly a pass on which no move is decided and nothing is in flight. -/
theorem plain_is_no_move {s : State} {r : Read} (h : statusLine s r = .differs .plain) :
    s.inFlight = none ∧ decideMove s r = none ∧ shownVerdict s r = .differs := by
  unfold statusLine at h
  split at h
  · simp at h
  · rename_i hp
    simp only [pending, Bool.or_eq_true, Bool.not_eq_true] at hp
    refine ⟨?_, ?_, ?_⟩
    · cases hi : s.inFlight with
      | none => rfl
      | some a => simp [hi] at hp
    · cases hd : decideMove s r with
      | none => rfl
      | some a => simp [hd] at hp
    · split at h <;> simp_all

/-- **userRetry_answers.**  After "Re-apply layout" (`userRetry`), on a good read with nothing in flight whose verdict is "differs": either a move leaves on this read (the planner's or a granted one),
or the status is `differs plain`, which is shown IF AND ONLY IF no move is decided on that read (nothing leaves) and carries the reason "Sommelier has no move to make right now".  This is
all it says: the planner is not optimal, so it does NOT claim that no move would help. -/
theorem userRetry_answers (s : State) (r : Read) (hi : s.inFlight = none) (hg : s.gate r = true)
    (hd : shownVerdict (step s .userRetry).1 r = .differs) :
    (∃ a, (step (step s .userRetry).1 (.read r)).2 = [a]) ∨
    (statusLine (step s .userRetry).1 r = .differs .plain ∧ decideMove (step s .userRetry).1 r = none ∧
      (step (step s .userRetry).1 (.read r)).2 = []) := by
  have hpn : (step s .userRetry).1.provenNotFull = s.provenNotFull := by simp [step]
  have hinf : (step s .userRetry).1.inFlight = none := by simp [step, hi]
  have hg' : (step s .userRetry).1.gate r = true := by simp only [State.gate, State.view, hpn]; exact hg
  generalize hS : (step s .userRetry).1 = S at *
  cases hdm : decideMove S r with
  | some a => left; exact ⟨a, by simp [step, hdm]⟩
  | none =>
    right
    refine ⟨?_, rfl, by simp [step, hdm]⟩
    have hbud : budgetSpent S r = false := by
      have : S.moveCount = 0 := by rw [← hS]; simp [step]
      simp [budgetSpent, this, cap]; split <;> simp [capFull, capNotFull]
    have hhold : S.hold = false := by rw [← hS]; simp [step]
    unfold statusLine
    have : pending S r = false := by simp [pending, hinf, hdm]
    rw [this]
    simp [hd, hbud, hhold]


/-- **The count looks at movable record keys only.**  Dropping a key the engine may not name (not movable, or not in the record) from the bar changes no inversion count. -/
theorem invCount_ignores_unmovable {s : State} {r : Read} {x : Key} (hx : x ∉ movable s r ∨ x ∉ s.record) (l : List Key) :
    invCount s r (l.filter (fun y => y != x)) = invCount s r l := by
  unfold invCount
  rw [List.filter_filter]
  congr 1
  apply List.filter_congr
  intro y _
  by_cases hy : y = x
  · subst hy
    rcases hx with h | h
    · have : (movable s r).contains y = false := by simpa [List.contains_iff_mem] using h
      simp [this]; intro h'; exact absurd h' h
    · have : s.record.contains y = false := by simpa [List.contains_iff_mem] using h
      simp [this]; intro _; exact h
  · simp [hy]


/-! ### The fallback and the note against the REAL bar (ejb.10, corrective pass 2) -/


theorem flatMap_filter_comm (R : Key → Bool) (g : Key → List Key)
    (h1 : ∀ x, R x = true → (g x).all R = true) (h2 : ∀ x, R x = false → (g x).filter R = []) :
    ∀ l : List Key, (l.flatMap g).filter R = (l.filter R).flatMap g
  | [] => by simp
  | x :: xs => by
    have ih := flatMap_filter_comm R g h1 h2 xs
    cases hx : R x
    · simp [List.flatMap_cons, List.filter_append, h2 x hx, hx, ih]
    · have := h1 x hx
      have e : (g x).filter R = g x := List.filter_eq_self.mpr (by simpa [List.all_eq_true] using this)
      simp [List.flatMap_cons, List.filter_append, e, hx, ih]

theorem applyMove_filter (R : Key → Bool) (l : List Key) (a : Action) (hk : R a.subject = true) (ht : R a.rel.target = true) :
    (applyMove l a).filter R = applyMove (l.filter R) a := by
  unfold applyMove
  simp only []
  have e1 : (l.filter R).filter (fun x => x != a.subject) = (l.filter (fun x => x != a.subject)).filter R := by
    rw [List.filter_filter, List.filter_filter]
    apply List.filter_congr
    intro x _
    simp [Bool.and_comm]
  rw [e1]
  by_cases hc : (l.filter (fun x => x != a.subject)).contains a.rel.target = true
  · have hc2 : ((l.filter (fun x => x != a.subject)).filter R).contains a.rel.target = true := by
      rw [List.contains_iff_mem] at hc ⊢
      exact List.mem_filter.2 ⟨hc, ht⟩
    rw [if_neg (by rw [hc]; simp), if_neg (by rw [hc2]; simp)]
    apply flatMap_filter_comm
    · intro x hx
      by_cases hxt : (x == a.rel.target) = true
      · simp only [hxt, ite_true]
        cases a.rel <;> simp [hk, hx]
      · simp only [hxt]; simp [hx]
    · intro x hx
      have : (x == a.rel.target) = false := by
        cases h : (x == a.rel.target)
        · rfl
        · have := beq_iff_eq.1 h; subst this; rw [ht] at hx; cases hx
      simp [this, hx]
  · have hc2 : ¬ ((l.filter (fun x => x != a.subject)).filter R).contains a.rel.target = true := by
      intro h
      rw [List.contains_iff_mem] at h
      exact hc (List.contains_iff_mem.2 (List.mem_filter.1 h).1)
    have hc' := Bool.eq_false_iff.2 hc
    have hc2' := Bool.eq_false_iff.2 hc2
    rw [if_pos (by rw [hc']; rfl), if_pos (by rw [hc2']; rfl)]


/-- Inversions among the record keys of a list of keys (the real bar's open keys). -/
def recInv (rec l : List Key) : Nat := invs rec (l.filter (fun x => rec.contains x))

/-- `k` inserted into `l` at position `i`. -/
def ins (k : Key) (l : List Key) (i : Nat) : List Key := l.take i ++ k :: l.drop i

theorem wholeBar_cases {s : State} {r : Read} (hw : wholeBar s r = true) {x : Key} (hx : x ∈ s.record)
    (hl : x ∈ r.drawn ∨ x ∈ r.pile ∨ x ∈ r.folded ∨ x ∈ r.unread) :
    x ∈ movable s r ∨ (r.chevron = .fresh ∧ x ∈ r.foldedSet) := by
  unfold wholeBar at hw
  have h2 := (List.all_eq_true.1 hw) x hx
  have hl' : (r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) = true := by
    simp only [Bool.or_eq_true, List.contains_iff_mem]
    rcases hl with h | h | h | h
    · exact Or.inl (Or.inl (Or.inl h))
    · exact Or.inl (Or.inl (Or.inr h))
    · exact Or.inl (Or.inr h)
    · exact Or.inr h
  rw [hl'] at h2
  simp only [Bool.not_true, Bool.false_or, Bool.or_eq_true] at h2
  rcases h2 with h | h
  · left; exact List.contains_iff_mem.1 h
  · right
    simp only [Bool.and_eq_true, beq_iff_eq, List.contains_iff_mem] at h
    exact h

/-- On a good read that verifies the whole bar, the record keys open on any possible bar are exactly the movable record keys, in the order the read draws them. -/
theorem bar_open_record {s : State} {r : Read} {b : Bar} (hg : s.gate r = true) (hw : wholeBar s r = true) (hb : Possible (s.view r) b) :
    b.open_.filter (fun x => s.record.contains x) = r.drawn.filter (fun x => (movable s r).contains x && s.record.contains x) := by
  have hg' := hg
  unfold State.gate at hg'
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hg'
  have hu : (s.view r).usable := hg'.1
  have hcm := consistent_iff.1 hg'.2
  have hpo : (s.view r).pinOpen = r.drawn.filter (fun k => r.trusted.contains k) := view_usable_pin hu
  have hf := ((poss_iff hu (b)).mp hb).2.1
  have hwf := poss_wf hb
  have hvr : (s.view r).chevron = r.chevron := rfl
  have hmem : ∀ x, x ∈ (s.view r).pinOpen ↔ x ∈ r.drawn ∧ x ∈ r.trusted := by
    intro x; rw [hpo]; simp [List.mem_filter]
  -- Claim A
  have hA : ∀ x ∈ b.open_, x ∈ s.record → x ∈ (s.view r).pinOpen := by
    intro x hx hxr
    have hl := poss_open_listed hu hb hx
    rcases wholeBar_cases hw hxr (by simpa [Read.listed, State.view] using hl) with hm | ⟨hfr, hfs⟩
    · have := (mem_movable_iff s r x).1 hm
      exact (hmem x).2 ⟨this.1, this.2.1⟩
    · exfalso
      have hbeh : x ∈ (s.view r).pinBehind := by
        rw [pinBehind_fresh hu (by rw [hvr]; exact hfr)]; exact hfs
      exact hwf.2.2 x hx (poss_pin_behind hu hb hbeh)
  -- Claim B
  have hB : ∀ x ∈ r.drawn, x ∈ r.trusted → x ∈ s.record → x ∈ movable s r := by
    intro x hd ht hxr
    rcases wholeBar_cases hw hxr (Or.inl hd) with hm | ⟨hfr, hfs⟩
    · exact hm
    · exfalso
      have hbeh : x ∈ (s.view r).pinBehind := by
        rw [pinBehind_fresh hu (by rw [hvr]; exact hfr)]; exact hfs
      exact (by simpa using hcm.2 x ((hmem x).2 ⟨hd, ht⟩) : x ∉ (s.view r).pinBehind) hbeh
  have e1 : b.open_.filter (fun x => s.record.contains x) = (b.open_.filter (fun k => decide (k ∈ (s.view r).pinOpen))).filter (fun x => s.record.contains x) := by
    rw [List.filter_filter]
    apply List.filter_congr
    intro x hx
    by_cases hxr : s.record.contains x = true
    · have := hA x hx (List.contains_iff_mem.1 hxr)
      have hd : decide (x ∈ (s.view r).pinOpen) = true := by simpa using this
      simp only [hxr, hd, Bool.and_self]
    · have hn : s.record.contains x = false := Bool.eq_false_iff.2 hxr
      simp only [hn, Bool.and_false, Bool.false_and]
  rw [e1, hf, hpo, List.filter_filter]
  apply List.filter_congr
  intro x hx
  by_cases hxr : s.record.contains x = true
  · by_cases ht : r.trusted.contains x = true
    · have hm := hB x hx (List.contains_iff_mem.1 ht) (List.contains_iff_mem.1 hxr)
      have hm' : (movable s r).contains x = true := List.contains_iff_mem.2 hm
      simp only [hxr, ht, hm', Bool.and_self]
    · have hm : (movable s r).contains x = false := by
        cases h : (movable s r).contains x
        · rfl
        · exfalso; exact ht (List.contains_iff_mem.2 ((mem_movable_iff s r x).1 (List.contains_iff_mem.1 h)).2.1)
      have ht' := Bool.eq_false_iff.2 ht
      simp only [ht', hm, Bool.false_and, Bool.and_false]
  · have hn : s.record.contains x = false := Bool.eq_false_iff.2 hxr
    simp only [hn, Bool.and_false, Bool.false_and]


theorem fm_before (t k : Key) : ∀ l : List Key, (∀ x ∈ l, x ≠ t) →
    l.flatMap (fun x => if (x == t) = true then [k, x] else [x]) = l
  | [], _ => rfl
  | x :: xs, h => by
    have hx : (x == t) = false := by simpa using h x (by simp)
    simp only [List.flatMap_cons, hx, Bool.false_eq_true, ite_false]
    rw [fm_before t k xs (fun y hy => h y (by simp [hy]))]; rfl

theorem fm_after (t k : Key) : ∀ l : List Key, (∀ x ∈ l, x ≠ t) →
    l.flatMap (fun x => if (x == t) = true then [x, k] else [x]) = l
  | [], _ => rfl
  | x :: xs, h => by
    have hx : (x == t) = false := by simpa using h x (by simp)
    simp only [List.flatMap_cons, hx, Bool.false_eq_true, ite_false]
    rw [fm_after t k xs (fun y hy => h y (by simp [hy]))]; rfl

/-- Dragging `k` next to `t` in a list whose other keys are `pre ++ t :: post` (no repeats). -/
theorem applyMove_split (l pre post : List Key) (t k : Key) (hl : l.filter (fun x => x != k) = pre ++ t :: post)
    (hn : (pre ++ t :: post).Nodup) (sa su : Bool) :
    applyMove l ⟨k, .before t, sa, su⟩ = pre ++ k :: t :: post ∧ applyMove l ⟨k, .after t, sa, su⟩ = pre ++ t :: k :: post := by
  have hnd := List.nodup_append.1 hn
  have hpre : ∀ x ∈ pre, x ≠ t := fun x hx e => by
    subst e; exact hnd.2.2 x hx x (by simp) rfl
  have hpost : ∀ x ∈ post, x ≠ t := fun x hx e => by subst e; exact (List.nodup_cons.1 hnd.2.1).1 hx
  have hc : (l.filter (fun x => x != k)).contains t = true := by rw [hl]; simp
  have hnc : ¬ (!(l.filter (fun x => x != k)).contains t) = true := by rw [hc]; simp
  constructor
  · have e : applyMove l ⟨k, .before t, sa, su⟩ = if (!(l.filter (fun x => x != k)).contains t) = true then l
        else (l.filter (fun x => x != k)).flatMap (fun x => if (x == t) = true then [k, x] else [x]) := rfl
    rw [e, if_neg hnc, hl, List.flatMap_append, List.flatMap_cons, fm_before t k pre hpre, fm_before t k post hpost]
    simp
  · have e : applyMove l ⟨k, .after t, sa, su⟩ = if (!(l.filter (fun x => x != k)).contains t) = true then l
        else (l.filter (fun x => x != k)).flatMap (fun x => if (x == t) = true then [x, k] else [x]) := rfl
    rw [e, if_neg hnc, hl, List.flatMap_append, List.flatMap_cons, fm_after t k pre hpre, fm_after t k post hpost]
    simp

theorem filter_ins (R : Key → Bool) (k : Key) (hk : R k = true) (rest : List Key) (i : Nat) :
    (ins k rest i).filter R = ins k (rest.filter R) ((rest.take i).filter R).length := by
  unfold ins
  have e : rest.filter R = (rest.take i).filter R ++ (rest.drop i).filter R := by
    rw [← List.filter_append, List.take_append_drop]
  rw [List.filter_append, List.filter_cons_of_pos hk, e, List.take_left' rfl, List.drop_left' rfl]

theorem exists_drag (M Mrest : List Key) (k : Key) (hM : M.filter (fun x => x != k) = Mrest) (hn : Mrest.Nodup) (hne : Mrest ≠ [])
    (j : Nat) (hj : j ≤ Mrest.length) :
    ∃ rel : Rel, rel.target ∈ Mrest ∧ applyMove M ⟨k, rel, false, true⟩ = ins k Mrest j := by
  rcases Nat.eq_zero_or_pos j with rfl | hpos
  · cases hm : Mrest with
    | nil => exact absurd hm hne
    | cons t post =>
      refine ⟨.before t, by simp [Rel.target, hm], ?_⟩
      have := (applyMove_split M [] post t k (by rw [hM, hm]; rfl) (by rw [hm] at hn; simpa using hn) false true).1
      rw [this]; simp [ins]
  · obtain ⟨j', rfl⟩ : ∃ j', j = j' + 1 := ⟨j - 1, by omega⟩
    have hlt : j' < Mrest.length := by omega
    obtain ⟨t, ht⟩ : ∃ t, t = Mrest[j'] := ⟨_, rfl⟩
    have hsplit : Mrest = Mrest.take j' ++ t :: Mrest.drop (j' + 1) := by
      have h0 := List.take_append_drop j' Mrest
      rw [List.drop_eq_getElem_cons hlt] at h0
      rw [ht]; exact h0.symm
    refine ⟨.after t, by rw [ht]; exact List.getElem_mem hlt, ?_⟩
    have := (applyMove_split M (Mrest.take j') (Mrest.drop (j' + 1)) t k (by rw [hM]; exact hsplit)
      (by rw [← hsplit]; exact hn) false true).2
    rw [this]
    unfold ins
    have h1 : Mrest.take (j' + 1) = Mrest.take j' ++ [Mrest[j']] := by
      rw [List.take_succ, List.getElem?_eq_getElem hlt]; rfl
    rw [h1, ← ht]; simp

theorem invs_all_eq (rec : List Key) (k : Key) : ∀ l : List Key, (∀ x ∈ l, x = k) → invs rec l = 0
  | [], _ => rfl
  | x :: xs, h => by
    have hx := h x (by simp)
    have h0 : (xs.filter (fun y => decide (rec.idxOf y < rec.idxOf x))).length = 0 := by
      apply List.length_eq_zero_iff.2
      apply List.filter_eq_nil_iff.2
      intro y hy
      have := h y (by simp [hy])
      simp [this, hx]
    simp [invs, h0, invs_all_eq rec k xs (fun y hy => h y (by simp [hy]))]


/-! ### The fallback against every possible bar (ejb.11) -/

theorem invs_split (rec : List Key) (k : Key) : ∀ (P R : List Key),
    invs rec (P ++ k :: R) = invs rec (P ++ R) + (P.filter (fun y => decide (rec.idxOf k < rec.idxOf y))).length
      + (R.filter (fun y => decide (rec.idxOf y < rec.idxOf k))).length
  | [], R => by simp [invs]; omega
  | x :: P, R => by
    have ih := invs_split rec k P R
    simp only [List.cons_append, invs, List.filter_append, List.length_append, List.filter_cons] at ih ⊢
    by_cases h : rec.idxOf k < rec.idxOf x
    · have h2 : ¬ rec.idxOf x < rec.idxOf k := by omega
      simp [h] at ih ⊢
      omega
    · by_cases h3 : rec.idxOf x < rec.idxOf k
      · simp [h] at ih ⊢
        omega
      · simp [h] at ih ⊢
        omega



/-- Keys of `l` that should come AFTER `k` in the record. -/
def ca (rec : List Key) (k : Key) (l : List Key) : Nat := (l.filter (fun y => decide (rec.idxOf k < rec.idxOf y))).length
/-- Keys of `l` that should come BEFORE `k` in the record. -/
def cb (rec : List Key) (k : Key) (l : List Key) : Nat := (l.filter (fun y => decide (rec.idxOf y < rec.idxOf k))).length

theorem ca_append (rec k) (A B : List Key) : ca rec k (A ++ B) = ca rec k A + ca rec k B := by
  simp [ca, List.filter_append]
theorem cb_append (rec k) (A B : List Key) : cb rec k (A ++ B) = cb rec k A + cb rec k B := by
  simp [cb, List.filter_append]

theorem len_filter_split (p Q : Key → Bool) : ∀ l : List Key,
    (l.filter p).length = ((l.filter Q).filter p).length + ((l.filter (fun y => !Q y)).filter p).length
  | [] => by simp
  | x :: l => by
    have ih := len_filter_split p Q l
    cases hq : Q x <;> cases hp : p x <;> simp [List.filter_cons, hq, hp] at ih ⊢ <;> omega

theorem ca_split (rec k) (Q : Key → Bool) (l : List Key) :
    ca rec k l = ca rec k (l.filter Q) + ((l.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf k < rec.idxOf y))).length :=
  len_filter_split _ Q l
theorem cb_split (rec k) (Q : Key → Bool) (l : List Key) :
    cb rec k l = cb rec k (l.filter Q) + ((l.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf y < rec.idxOf k))).length :=
  len_filter_split _ Q l

/-- Moving `k` to the right across `S`: the inversions change by `ca S - cb S`. -/
theorem eq_right (rec : List Key) (k : Key) (P S R : List Key) :
    invs rec (P ++ S ++ k :: R) + cb rec k S = invs rec (P ++ k :: (S ++ R)) + ca rec k S := by
  have h1 := invs_split rec k (P ++ S) R
  have h2 := invs_split rec k P (S ++ R)
  have e : invs rec (P ++ S ++ R) = invs rec (P ++ (S ++ R)) := by rw [List.append_assoc]
  have c1 : ca rec k (P ++ S) = ca rec k P + ca rec k S := ca_append _ _ _ _
  have c2 : cb rec k (S ++ R) = cb rec k S + cb rec k R := cb_append _ _ _ _
  unfold ca at c1 ⊢
  unfold cb at c2 ⊢
  omega

theorem move_cmp_right (rec : List Key) (k : Key) (Q : Key → Bool) (hQ : Q k = true) (P S R : List Key) :
    invs rec (P ++ S ++ k :: R) + invs rec ((P ++ k :: (S ++ R)).filter Q) ≤
      invs rec (P ++ k :: (S ++ R)) + invs rec ((P ++ S ++ k :: R).filter Q) +
        ((S.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf k < rec.idxOf y))).length := by
  have e1 := eq_right rec k P S R
  have e2 := eq_right rec k (P.filter Q) (S.filter Q) (R.filter Q)
  have f1 : (P ++ k :: (S ++ R)).filter Q = P.filter Q ++ k :: (S.filter Q ++ R.filter Q) := by
    simp [List.filter_append, List.filter_cons, hQ]
  have f2 : (P ++ S ++ k :: R).filter Q = P.filter Q ++ S.filter Q ++ k :: R.filter Q := by
    simp [List.filter_append, List.filter_cons, hQ]
  rw [f1, f2]
  have a1 := ca_split rec k Q S
  have b1 := cb_split rec k Q S
  omega

theorem move_cmp_left (rec : List Key) (k : Key) (Q : Key → Bool) (hQ : Q k = true) (P S R : List Key) :
    invs rec (P ++ k :: (S ++ R)) + invs rec ((P ++ S ++ k :: R).filter Q) ≤
      invs rec (P ++ S ++ k :: R) + invs rec ((P ++ k :: (S ++ R)).filter Q) +
        ((S.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf y < rec.idxOf k))).length := by
  have e1 := eq_right rec k P S R
  have e2 := eq_right rec k (P.filter Q) (S.filter Q) (R.filter Q)
  have f1 : (P ++ k :: (S ++ R)).filter Q = P.filter Q ++ k :: (S.filter Q ++ R.filter Q) := by
    simp [List.filter_append, List.filter_cons, hQ]
  have f2 : (P ++ S ++ k :: R).filter Q = P.filter Q ++ S.filter Q ++ k :: R.filter Q := by
    simp [List.filter_append, List.filter_cons, hQ]
  rw [f1, f2]
  have a1 := ca_split rec k Q S
  have b1 := cb_split rec k Q S
  omega

/-- The free keys of `L` that a forward drag (`b`) or backward drag (`a`) can cost. -/
def freeB (rec : List Key) (k : Key) (Q : Key → Bool) (L : List Key) : Nat :=
  ((L.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf y < rec.idxOf k))).length
def freeA (rec : List Key) (k : Key) (Q : Key → Bool) (L : List Key) : Nat :=
  ((L.filter (fun y => !Q y)).filter (fun y => decide (rec.idxOf k < rec.idxOf y))).length

theorem sub_free_le (p : Key → Bool) (Q : Key → Bool) {S L : List Key} (hS : S.Nodup) (hsub : ∀ x ∈ S, x ∈ L) :
    ((S.filter (fun y => !Q y)).filter p).length ≤ ((L.filter (fun y => !Q y)).filter p).length := by
  apply List.Nodup.length_le_of_subset
  · have h1 : (S.filter (fun y => !Q y)).Nodup := hS.sublist List.filter_sublist
    exact h1.sublist List.filter_sublist
  · intro x hx
    simp only [List.mem_filter] at hx ⊢
    exact ⟨⟨hsub x hx.1.1, hx.1.2⟩, hx.2⟩

theorem filter_ne_split (k : Key) (X Y : List Key) (hX : k ∉ X) (hY : k ∉ Y) :
    (X ++ k :: Y).filter (fun x => x != k) = X ++ Y := by
  rw [List.filter_append, List.filter_cons]
  have h1 : X.filter (fun x => x != k) = X := List.filter_eq_self.2 (fun x hx => by
    have : x ≠ k := fun e => hX (e ▸ hx)
    simpa using this)
  have h2 : Y.filter (fun x => x != k) = Y := List.filter_eq_self.2 (fun x hx => by
    have : x ≠ k := fun e => hY (e ▸ hx)
    simpa using this)
  simp [h1, h2]

theorem idx_before (X Y : List Key) (k t : Key) (hX : k ∉ X) (ht : t ∈ X) : (X ++ k :: Y).idxOf t < (X ++ k :: Y).idxOf k := by
  rw [List.idxOf_append, List.idxOf_append, if_pos ht, if_neg hX]
  have := idx_lt_len ht
  simp [idx_cons]
  omega

theorem idx_after (X Y : List Key) (k t : Key) (hX : k ∉ X) (hY : k ∉ Y) (ht : t ∈ Y) (htX : t ∉ X) :
    (X ++ k :: Y).idxOf k < (X ++ k :: Y).idxOf t := by
  rw [List.idxOf_append, List.idxOf_append, if_neg hX, if_neg htX]
  simp [idx_cons]
  have : t ≠ k := fun e => hY (e ▸ ht)
  simp [Ne.symm this]

theorem move_bound (rec : List Key) (k t : Key) (Q : Key → Bool) (hQk : Q k = true) (L : List Key) (hnd : L.Nodup)
    (hk : k ∈ L) (ht : t ∈ L) (hne : t ≠ k) (a : Action) (hs : a.subject = k) (hr : a.rel.target = t) :
    invs rec (applyMove L a) + invs rec (L.filter Q) ≤
      invs rec L + invs rec ((applyMove L a).filter Q) + (if L.idxOf t < L.idxOf k then freeB rec k Q L else freeA rec k Q L) := by
  obtain ⟨X, Y, rfl⟩ := List.append_of_mem hk
  have hnd' := List.nodup_append.1 hnd
  have hkX : k ∉ X := fun h => hnd'.2.2 k h k (by simp) rfl
  have hkY : k ∉ Y := (List.nodup_cons.1 hnd'.2.1).1
  have hXY : (X ++ Y).Nodup := hnd.sublist (List.Sublist.append_left (List.sublist_cons_self k Y) X)
  have hf := filter_ne_split k X Y hkX hkY
  have hdisj : ∀ x ∈ X, x ∉ Y := fun x hx hy => hnd'.2.2 x hx x (List.mem_cons_of_mem _ hy) rfl
  obtain ⟨sub, rel, sa, su⟩ := a
  simp only at hs hr
  subst hs
  have htXY : t ∈ X ∨ t ∈ Y := by
    have := List.mem_append.1 ht
    rcases this with h | h
    · exact Or.inl h
    · rcases List.mem_cons.1 h with h | h
      · exact absurd h hne
      · exact Or.inr h
  rcases htXY with htX | htY
  · -- t before k
    rw [if_pos (idx_before X Y sub t hkX htX)]
    obtain ⟨X1, X2, rfl⟩ := List.append_of_mem htX
    have hl : (X1 ++ t :: X2 ++ sub :: Y).filter (fun x => x != sub) = X1 ++ t :: (X2 ++ Y) := by
      rw [hf]; simp
    have hn : (X1 ++ t :: (X2 ++ Y)).Nodup := by simpa using hXY
    obtain ⟨hbef, haft⟩ := applyMove_split (X1 ++ t :: X2 ++ sub :: Y) X1 (X2 ++ Y) t sub hl hn sa su
    have hS1 : (t :: X2).Nodup := (List.nodup_append.1 hnd'.1).2.1
    cases rel with
    | before t' =>
      simp only [Rel.target] at hr
      obtain rfl : t = t' := hr.symm
      rw [hbef]
      have key := move_cmp_left rec sub Q hQk X1 (t :: X2) Y
      have hp := sub_free_le (fun y => decide (rec.idxOf y < rec.idxOf sub)) Q hS1 (L := X1 ++ t :: X2 ++ sub :: Y) (fun x hx => by simp only [List.mem_append, List.mem_cons] at hx ⊢; grind)
      exact Nat.le_trans key (Nat.add_le_add_left hp _)
    | after t' =>
      simp only [Rel.target] at hr
      obtain rfl : t = t' := hr.symm
      rw [haft]
      have key := move_cmp_left rec sub Q hQk (X1 ++ [t]) X2 Y
      have hp := sub_free_le (fun y => decide (rec.idxOf y < rec.idxOf sub)) Q (List.nodup_cons.1 hS1).2 (L := X1 ++ t :: X2 ++ sub :: Y) (fun x hx => by simp only [List.mem_append, List.mem_cons] at hx ⊢; grind)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at key hp ⊢
      exact Nat.le_trans key (Nat.add_le_add_left hp _)
  · -- t after k
    have htX : t ∉ X := fun h => hdisj t h htY
    rw [if_neg (by have := idx_after X Y sub t hkX hkY htY htX; omega)]
    obtain ⟨Y1, Y2, rfl⟩ := List.append_of_mem htY
    have hl : (X ++ sub :: (Y1 ++ t :: Y2)).filter (fun x => x != sub) = (X ++ Y1) ++ t :: Y2 := by
      rw [hf]; simp
    have hn : ((X ++ Y1) ++ t :: Y2).Nodup := by simpa using hXY
    obtain ⟨hbef, haft⟩ := applyMove_split (X ++ sub :: (Y1 ++ t :: Y2)) (X ++ Y1) Y2 t sub hl hn sa su
    have hY : (Y1 ++ t :: Y2).Nodup := (List.nodup_cons.1 hnd'.2.1).2
    cases rel with
    | before t' =>
      simp only [Rel.target] at hr
      obtain rfl : t = t' := hr.symm
      rw [hbef]
      have key := move_cmp_right rec sub Q hQk X Y1 (t :: Y2)
      have hp := sub_free_le (fun y => decide (rec.idxOf sub < rec.idxOf y)) Q ((List.nodup_append.1 hY).1) (L := X ++ sub :: (Y1 ++ t :: Y2)) (fun x hx => by simp only [List.mem_append, List.mem_cons] at hx ⊢; grind)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at key hp ⊢
      exact Nat.le_trans key (Nat.add_le_add_left hp _)
    | after t' =>
      simp only [Rel.target] at hr
      obtain rfl : t = t' := hr.symm
      rw [haft]
      have key := move_cmp_right rec sub Q hQk X (Y1 ++ [t]) Y2
      have hS : (Y1 ++ [t]).Nodup := hY.sublist (List.Sublist.append_left (by simp) Y1)
      have hp := sub_free_le (fun y => decide (rec.idxOf sub < rec.idxOf y)) Q hS (L := X ++ sub :: (Y1 ++ t :: Y2)) (fun x hx => by simp only [List.mem_append, List.mem_cons, List.mem_singleton] at hx ⊢; grind)
      simp only [List.append_assoc, List.cons_append, List.nil_append] at key hp ⊢
      exact Nat.le_trans key (Nat.add_le_add_left hp _)

/-- On a good read, whatever the read verifies of the bar: the movable keys are open on every possible bar and stand there in the order the read draws them; and a record key open on a possible bar
that is not movable is free. -/
theorem bar_movable_facts {s : State} {r : Read} {b : Bar} (hg : s.gate r = true) (hb : Possible (s.view r) b) :
    b.open_.filter (fun x => (movable s r).contains x) = r.drawn.filter (fun x => (movable s r).contains x) ∧
    (∀ x ∈ b.open_, x ∈ s.record → x ∉ movable s r → x ∈ freeKeys s r) := by
  have hg' := hg
  unfold State.gate at hg'
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hg'
  have hu : (s.view r).usable := hg'.1
  have hcm := consistent_iff.1 hg'.2
  have hpo : (s.view r).pinOpen = r.drawn.filter (fun k => r.trusted.contains k) := view_usable_pin hu
  have hf := ((poss_iff hu (b)).mp hb).2.1
  have hwf := poss_wf hb
  have hvr : (s.view r).chevron = r.chevron := rfl
  have hmem : ∀ x, x ∈ (s.view r).pinOpen ↔ x ∈ r.drawn ∧ x ∈ r.trusted := by
    intro x; rw [hpo]; simp [List.mem_filter]
  constructor
  · have e1 : b.open_.filter (fun x => (movable s r).contains x) =
        (b.open_.filter (fun k => decide (k ∈ (s.view r).pinOpen))).filter (fun x => (movable s r).contains x) := by
      rw [List.filter_filter]
      apply List.filter_congr
      intro x hx
      by_cases hxm : (movable s r).contains x = true
      · have := (mem_movable_iff s r x).1 (List.contains_iff_mem.1 hxm)
        have hd : decide (x ∈ (s.view r).pinOpen) = true := by simpa using (hmem x).2 ⟨this.1, this.2.1⟩
        simp only [hxm, hd, Bool.and_self]
      · have hn : (movable s r).contains x = false := Bool.eq_false_iff.2 hxm
        simp only [hn]; rfl
    rw [e1, hf, hpo, List.filter_filter]
    apply List.filter_congr
    intro x hx
    by_cases hxm : (movable s r).contains x = true
    · have := (mem_movable_iff s r x).1 (List.contains_iff_mem.1 hxm)
      have ht : r.trusted.contains x = true := List.contains_iff_mem.2 this.2.1
      simp only [hxm, ht, Bool.and_self]
    · have hn : (movable s r).contains x = false := Bool.eq_false_iff.2 hxm
      simp only [hn]; rfl
  · intro x hx hxr hxm
    have hl := poss_open_listed hu hb hx
    have hl' : (r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) = true := by
      have : r.listed x := by simpa [Read.listed, State.view] using hl
      simp only [Bool.or_eq_true, List.contains_iff_mem]
      rcases this with h | h | h | h
      · exact Or.inl (Or.inl (Or.inl h))
      · exact Or.inl (Or.inl (Or.inr h))
      · exact Or.inl (Or.inr h)
      · exact Or.inr h
    have hnf : (r.chevron == .fresh && r.foldedSet.contains x) = false := by
      refine Classical.byContradiction fun hc => ?_
      have hc : (r.chevron == .fresh && r.foldedSet.contains x) = true := by simpa using hc
      simp only [Bool.and_eq_true, beq_iff_eq, List.contains_iff_mem] at hc
      have hbeh : x ∈ (s.view r).pinBehind := by
        rw [pinBehind_fresh hu (by rw [hvr]; exact hc.1)]; exact hc.2
      exact hwf.2.2 x hx (poss_pin_behind hu hb hbeh)
    unfold freeKeys
    rw [List.mem_filter]
    refine ⟨hxr, ?_⟩
    have hm : (movable s r).contains x = false := by
      cases h : (movable s r).contains x
      · rfl
      · exact absurd (List.contains_iff_mem.1 h) hxm
    rw [hl', hm, hnf]; rfl

theorem filter_comm' (p q : Key → Bool) (l : List Key) : (l.filter p).filter q = (l.filter q).filter p := by
  rw [List.filter_filter, List.filter_filter]
  exact List.filter_congr (fun x _ => Bool.and_comm _ _)

/-- **fallback_improves_bar.**  A fallback move strictly lowers the record inversions of EVERY possible real bar, with or without the whole-bar condition: for every bar `b` the view of the read could have been taken
of, the number of inversions against the record among the OPEN keys of `b` (record keys only) is strictly smaller on the bar after the drag (`applyMove b.open_ a`) than on `b`.  Why: the movable keys are open on every
possible bar in the order the read draws them, so the drag changes the inversions among them exactly as `afterCount` says; the only other keys the drag can cross on a possible bar are free record keys (listed,
not movable, not pinned behind a fresh chevron), and each such crossing adds at most one inversion, and only when it is one `penalty` counts.  The fallback fires only when `afterCount + penalty` is below the
inversions now.  Keys behind the « take no part: the drag never names one (a target is a movable key, a subject is `k`) and the open order is all the drag changes. -/
theorem fallback_improves_bar {s : State} {r : Read} {k : Key} {a : Action} (hg : s.gate r = true) (h : fallbackMove s r k = some a) :
    ∀ b : Bar, Possible (s.view r) b → recInv s.record (applyMove b.open_ a) < recInv s.record b.open_ := by
  intro b hb
  obtain ⟨_, hsub, htm, htr, htk, _, _, hrk, hmk, hwc, _, _, _, _⟩ := fallbackMove_basic h
  obtain ⟨sub, rel, sa, su⟩ := a
  simp only at hsub htm htr htk hwc ⊢
  subst sub
  obtain ⟨hmeq, hfree⟩ := bar_movable_facts hg hb
  have hwf := poss_wf hb
  -- the data
  obtain ⟨t, ht⟩ : ∃ t, t = rel.target := ⟨_, rfl⟩
  obtain ⟨Q, hQ⟩ : ∃ Q : Key → Bool, Q = fun x => (movable s r).contains x := ⟨_, rfl⟩
  have hQk : Q k = true := by rw [hQ]; simpa [List.contains_iff_mem] using hmk
  have hQt : Q t = true := by rw [hQ, ht]; simpa [List.contains_iff_mem] using htm
  have hRk : s.record.contains k = true := List.contains_iff_mem.2 hrk
  have hRt : s.record.contains t = true := by rw [ht]; exact List.contains_iff_mem.2 htr
  have hdk : k ∈ r.drawn := ((mem_movable_iff s r k).1 hmk).1
  have hdt : t ∈ r.drawn := by rw [ht]; exact ((mem_movable_iff s r _).1 htm).1
  -- open
  have hok : k ∈ b.open_ := by
    have : k ∈ r.drawn.filter Q := List.mem_filter.2 ⟨hdk, hQk⟩
    rw [hQ, ← hmeq] at this
    exact (List.mem_filter.1 this).1
  have hot : t ∈ b.open_ := by
    have : t ∈ r.drawn.filter Q := List.mem_filter.2 ⟨hdt, hQt⟩
    rw [hQ, ← hmeq] at this
    exact (List.mem_filter.1 this).1
  obtain ⟨L, hL⟩ : ∃ L, L = b.open_.filter (fun x => s.record.contains x) := ⟨_, rfl⟩
  have hLnd : L.Nodup := by rw [hL]; exact nodup_filter' _ hwf.1
  have hkL : k ∈ L := by rw [hL]; exact List.mem_filter.2 ⟨hok, hRk⟩
  have htL : t ∈ L := by rw [hL]; exact List.mem_filter.2 ⟨hot, hRt⟩
  have htk' : t ≠ k := by rw [ht]; exact htk
  have hmb := move_bound s.record k t Q hQk L hLnd hkL htL htk' ⟨k, rel, sa, su⟩ rfl ht.symm
  -- the filtered lists
  obtain ⟨D, hD⟩ : ∃ D, D = r.drawn.filter (fun x => (movable s r).contains x && s.record.contains x) := ⟨_, rfl⟩
  have hmeq' : b.open_.filter Q = r.drawn.filter Q := by rw [hQ]; exact hmeq
  have hLQ : L.filter Q = D := by
    have e7 : (r.drawn.filter Q).filter (fun x => s.record.contains x) = D := by
      rw [hD, List.filter_filter, hQ]
      exact List.filter_congr (fun x _ => Bool.and_comm _ _)
    rw [hL, filter_comm', hmeq', e7]
  have hAQ : (applyMove L ⟨k, rel, sa, su⟩).filter Q = applyMove D ⟨k, rel, sa, su⟩ := by
    rw [applyMove_filter Q L ⟨k, rel, sa, su⟩ hQk (by rw [← ht]; exact hQt), hLQ]
  have hAL : applyMove L ⟨k, rel, sa, su⟩ = (applyMove b.open_ ⟨k, rel, sa, su⟩).filter (fun x => s.record.contains x) := by
    rw [hL, applyMove_filter (fun x => s.record.contains x) b.open_ ⟨k, rel, sa, su⟩ hRk (by rw [← ht]; exact hRt)]
  -- the corroborated inversions
  have hQD : ∀ (a' : Action), a'.subject = k → a'.rel.target = t → (applyMove r.drawn a').filter (fun x => (movable s r).contains x && s.record.contains x) = applyMove D a' := by
    intro a' h1 h2
    rw [hD]
    exact applyMove_filter _ r.drawn a' (by rw [h1]; simp [List.contains_iff_mem, hmk, hrk]) (by rw [h2]; rw [ht] at *; simp [List.contains_iff_mem, htm, htr])
  have hcnt : invCount s r r.drawn = invs s.record D := by unfold invCount; rw [hD]
  have haft : afterCount s r k rel = invs s.record (applyMove D ⟨k, rel, sa, su⟩) := by
    unfold afterCount invCount
    rw [hQD ⟨k, rel, false, true⟩ rfl ht.symm]
    exact congrArg _ (applyMove_flags D k rel false true sa su)
  -- direction
  have hdir : L.idxOf t < L.idxOf k ↔ r.drawn.idxOf t < r.drawn.idxOf k := by
    rw [hL, idx_filter_iff _ b.open_ t k hot hok hRt hRk, ← idx_filter_iff Q b.open_ t k hot hok hQt hQk, hmeq',
      idx_filter_iff Q r.drawn t k hdt hdk hQt hQk]
  -- the penalty bounds the free keys on the bar
  have hfreeb : ∀ p : Key → Bool, ((L.filter (fun y => !Q y)).filter p).length ≤ ((freeKeys s r).filter p).length := by
    intro p
    apply List.Nodup.length_le_of_subset
    · have h1 : (L.filter (fun y => !Q y)).Nodup := hLnd.sublist List.filter_sublist
      exact h1.sublist List.filter_sublist
    · intro y hy
      simp only [List.mem_filter, hL] at hy ⊢
      obtain ⟨⟨⟨hyo, hyr⟩, hyq⟩, hyp⟩ := hy
      refine ⟨hfree y hyo (List.contains_iff_mem.1 hyr) ?_, hyp⟩
      intro hym
      have : Q y = true := by rw [hQ]; simpa [List.contains_iff_mem] using hym
      rw [this] at hyq; simp at hyq
  have hpen : (if L.idxOf t < L.idxOf k then freeB s.record k Q L else freeA s.record k Q L) ≤ penalty s r k rel := by
    unfold penalty leftward
    rw [← ht]
    by_cases hlt : L.idxOf t < L.idxOf k
    · have hd := hdir.1 hlt
      simp only [hlt, hd, if_true, decide_true]
      exact hfreeb _
    · have hd : ¬ r.drawn.idxOf t < r.drawn.idxOf k := fun hh => hlt (hdir.2 hh)
      simp only [hlt, hd, if_false, decide_false]
      exact hfreeb _
  have hrecA : recInv s.record (applyMove b.open_ ⟨k, rel, sa, su⟩) = invs s.record (applyMove L ⟨k, rel, sa, su⟩) := by
    unfold recInv; rw [hAL]
  have hrecB : recInv s.record b.open_ = invs s.record L := by unfold recInv; rw [hL]
  rw [hrecA, hrecB]
  rw [hAQ, hLQ] at hmb
  unfold worstCount at hwc
  rw [haft] at hwc
  rw [hcnt] at hwc
  omega



/-- **noMoveHelps_bar.**  Where `noMoveHelps` is shown, on EVERY possible bar `b` of the view and EVERY place in its open keys (an insertion position `i` of `k` into the other open keys of `b`,
beside a movable key or not), moving `k` there does not lower the record inversions among the open keys of `b`.  (Keys behind the « take no part; under `wholeBar` every record key is movable or pinned behind.) -/
theorem noMoveHelps_bar {s : State} {r : Read} {k : Key} (h : rowNote s r k = some .noMoveHelps) :
    ∀ b : Bar, Possible (s.view r) b → ∀ i : Nat,
      ¬ recInv s.record (ins k (b.open_.filter (fun x => x != k)) i) < recInv s.record b.open_ := by
  obtain ⟨hg, _, hrk, hmk, hwb, _, hnr, _, _, _⟩ := noMoveHelps_true h
  intro b hb i
  have eo := bar_open_record hg hwb hb
  have hwf := poss_wf hb
  obtain ⟨M, hM⟩ : ∃ M, M = r.drawn.filter (fun x => (movable s r).contains x && s.record.contains x) := ⟨_, rfl⟩
  rw [← hM] at eo
  have hRk : s.record.contains k = true := List.contains_iff_mem.2 hrk
  have hQk : ((movable s r).contains k && s.record.contains k) = true := by simp [List.contains_iff_mem, hmk, hrk]
  have hrest : (b.open_.filter (fun x => x != k)).filter (fun x => s.record.contains x) = M.filter (fun x => x != k) := by
    rw [← eo, List.filter_filter, List.filter_filter]
    apply List.filter_congr; intro x _; simp [Bool.and_comm]
  have hMn : M.Nodup := by rw [← eo]; exact nodup_filter' _ hwf.1
  have hMrn : (M.filter (fun x => x != k)).Nodup := nodup_filter' _ hMn
  unfold recInv
  rw [filter_ins _ k hRk, hrest, eo]
  obtain ⟨Mrest, hMrest⟩ : ∃ Mrest, Mrest = M.filter (fun x => x != k) := ⟨_, rfl⟩
  rw [← hMrest] at hMrn ⊢
  have hj : ((b.open_.filter (fun x => x != k)).take i |>.filter (fun x => s.record.contains x)).length ≤ Mrest.length := by
    rw [← hMrest] at hrest
    rw [← hrest]
    have := List.length_filter_le (fun x => s.record.contains x) ((b.open_.filter (fun x => x != k)).drop i)
    have e : (b.open_.filter (fun x => x != k)).filter (fun x => s.record.contains x) =
        ((b.open_.filter (fun x => x != k)).take i).filter (fun x => s.record.contains x) ++ ((b.open_.filter (fun x => x != k)).drop i).filter (fun x => s.record.contains x) := by
      rw [← List.filter_append, List.take_append_drop]
    rw [e, List.length_append]; omega
  generalize ((b.open_.filter (fun x => x != k)).take i |>.filter (fun x => s.record.contains x)).length = j at hj ⊢
  by_cases hne : Mrest = []
  · have : j = 0 := by rw [hne] at hj; simpa using hj
    subst this
    rw [hne]
    have h0 : invs s.record (ins k [] 0) = 0 := by simp [ins, invs]
    have h1 : invs s.record M = 0 := invs_all_eq s.record k M (fun x hx => by
      refine Classical.byContradiction fun hxk => ?_
      have : x ∈ Mrest := by rw [hMrest]; exact List.mem_filter.2 ⟨hx, by simpa using hxk⟩
      rw [hne] at this; simp at this)
    rw [h0, h1]; exact Nat.lt_irrefl 0
  · obtain ⟨rel, hrelm, hrel⟩ := exists_drag M Mrest k hMrest.symm hMrn hne j hj
    rw [hMrest] at hrelm
    have ht := List.mem_filter.1 hrelm
    have hmem : rel.target ∈ r.drawn.filter (fun x => (movable s r).contains x && s.record.contains x) := hM ▸ ht.1
    have ht2 := List.mem_filter.1 hmem
    simp only [Bool.and_eq_true, List.contains_iff_mem] at ht2
    have htk : rel.target ≠ k := by simpa using ht.2
    have hQt : ((movable s r).contains rel.target && s.record.contains rel.target) = true := by
      simp [List.contains_iff_mem, ht2.2.1, ht2.2.2]
    have := hnr rel ht2.2.1 ht2.2.2 htk
    unfold invCount at this
    rw [applyMove_filter _ r.drawn ⟨k, rel, false, true⟩ hQk hQt, ← hM, hrel] at this
    exact this

end Sommelier
