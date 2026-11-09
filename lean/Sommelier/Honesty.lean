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
  simp only [decideMove, hi.2.1, hi.2.2, hc]
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
    (hum : userMove s r k = some a) (hal : userAllowed s r a = true) : decideMove s r = some a := by
  obtain ⟨hpass, hset, hinc, _⟩ := gate_facts hg
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  obtain ⟨tl, htl⟩ : ∃ tl, (s.foldRequest.toList ++ s.owedKeys) = k :: tl := by
    cases hl : (s.foldRequest.toList ++ s.owedKeys) with
    | nil => simp [hl] at hfirst
    | cons x xs => simp [hl] at hfirst; exact ⟨xs, by rw [hfirst]⟩
  simp only [decideMove]
  rw [if_neg hc, htl]
  simp [List.findSome?, hum, Option.filter, hal]

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
  obtain ⟨a, ha⟩ := userMove_moves hmov hne hpf
  have hallowed : userAllowed (edited s rec k) r a = true := by
    simp [userAllowed, F.2.1, hso]
  have hdm : decideMove (edited s rec k) r = some a := decide_head (by rw [F.1]; exact hi) hg hfirst ha hallowed
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
  have hdm := decide_head (by rw [F.1]; exact hi) hg hfirst hum hallowed
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

/-- **The converse: an owed key that gets no move has a named reason.**  From ANY state with nothing in flight, on a read where the gate is true, if the
read emits no move of the owed key `k`, then one of these holds: (1) `k` is a movable key already right among its anchors; (2) it is movable but its anchors
admit no gap (they are out of record order); (3) it is not a trusted drawn key and not counted as folded (it is not on the bar, or not read); (4) it is counted
as folded but this read does not license a pull-out (no fresh chevron listing it: the pile memory alone never does); (5) it is folded and licensed but no
movable key precedes it in the record; (6) the pull-out would change nothing (the key is drawn already, right after its predecessor); (7) a move exists and
needs the strip, and this edit's session is used (the strip being open is excluded by the gate); (8) another queued key went first. -/
theorem owed_unanswered_reason (s : State) (r : Read) (k : Key) (hi : s.inFlight = none) (hg : s.gate r = true)
    (howed : k ∈ s.owedKeys) (hno : ∀ a ∈ (step s (.read r)).2, a.subject ≠ k) :
    (k ∈ movable s r ∧ SameKeys (seenOf s r k) (wantOf s r k)) ∨
    (k ∈ movable s r ∧ prefixFor (wantOf s r k) (anchorsOf s r k) = none) ∨
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
  cases hb : (s.foldRequest.toList ++ s.owedKeys).findSome? (fun j => (userMove s r j).filter (userAllowed s r)) with
  | some b =>
    -- another queued key's move is the decision
    obtain ⟨l1, j, l2, hqeq, hj, _⟩ := List.findSome?_eq_some_iff.mp hb
    have hjq : j ∈ s.foldRequest.toList ++ s.owedKeys := by rw [hqeq]; simp
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
    have hfk : (userMove s r k).filter (userAllowed s r) = none := (List.findSome?_eq_none_iff.mp hb) k hq
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
      by_cases hfd : k ∈ foldedAll s r
      · by_cases hlic : r.chevron = .fresh ∧ k ∈ r.foldedSet
        · right; right; right; right
          cases hl : ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast? with
          | none => left; exact ⟨hfd, hlic.1, hlic.2, rfl⟩
          | some p =>
            right; left
            refine ⟨hfd, hlic.1, hlic.2, p, rfl, ?_⟩
            by_cases hchg : applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ = r.drawn
            · exact hchg
            · exfalso
              have := userMove_folded_some hfd (Or.inr howed) hlic.1 (by simpa using hlic.2) hl hchg
              rw [hum] at this; simp at this
        · right; right; right; left; exact ⟨hfd, hlic⟩
      · by_cases hmv : k ∈ movable s r
        · by_cases hsk : SameKeys (seenOf s r k) (wantOf s r k)
          · left; exact ⟨hmv, hsk⟩
          · right; left
            refine ⟨hmv, ?_⟩
            cases hp : prefixFor (wantOf s r k) (anchorsOf s r k) with
            | none => rfl
            | some i =>
              exfalso
              obtain ⟨a, ha⟩ := userMove_moves hmv hsk (by simp [hp])
              rw [hum] at ha; simp at ha
        · right; right; left
          refine ⟨hfd, fun ⟨h1, h2⟩ => hmv ((mem_movable_iff _ _ _).2 ⟨h1, h2, hfd⟩)⟩

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
    (hum : userMove s r q = some a) (hal : userAllowed s r a = true) : decideMove s r = some a := by
  have hc : ¬ (r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r) = true := by
    simp [hpass, hset, hinc, hi, hg]
  simp only [decideMove]
  rw [if_neg hc, hq]
  simp [hum, Option.filter, hal]

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
  obtain ⟨hns, hsub, hu, hstr, i, hpi, hcase⟩ := userMove_target hk h
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


end Sommelier
