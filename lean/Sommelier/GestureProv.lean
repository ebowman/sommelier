import Sommelier.Gesture
import Sommelier.Safety
import Sommelier.Honesty

/-!
# G5: provenance.  What the engine does after a gesture is only what the gesture moved (sommelier-ejb.32)

`applyGesture` (Gesture.lean) computes the new layout and the keys the user moved.  The engine is told them as
`userEdit (record) (moved)`, where `record` is the Visible keys the core reasons about (movable, no duplicates; see `coreRecord`).
This file proves what follows from that event: from ANY state, every action the engine emits with `user = true` on the reads that
follow, until the next user event, names a key the gesture moved, or a key that was ALREADY owed (a previous, still unserved drop),
or a fold request / drag already in flight before the gesture, or is the one strip move a Re-apply granted.

So the single drop of one item that the user made on 2026-11-10 can only ever make the core drag that item (and what was owed before it).
It composes the proved gesture (`moved = [k]`) with the existing single-step label theorem `userLabelHonest` (Safety.lean: a `user := true`
action names an owed key / the fold request, or is a granted strip move) and shows by induction over the run that no event but a user
event can put a new key into that set (`ProvInv`).

The statement is exact about what it does NOT say: keys owed BEFORE the gesture stay owed (`step` keeps `owedKeys` through a `userEdit`), so
the bound is `moved ∪ owed-before ∪ fold-request-before ∪ in-flight-before`; `drop_provenance_idle` is the corollary for a quiescent state.
-/

namespace Sommelier

/-- the keys of Visible the core takes as the record: the movable ones (the Swift `coreRecordIDs`: not the chevron, not an immovable
key such as a module), each once, in order -/
def coreRecord (mov : Key → Bool) (L : Layout3) : List Key := (L.visible.filter mov).eraseDups

/-- the bound of the invariant: `B` are the keys allowed to be user-flagged, `g` says whether a strip grant was open at the start -/
structure ProvInv (B : List Key) (g : Bool) (S : State) : Prop where
  owed : ∀ k ∈ S.owedKeys, k ∈ B
  fold : ∀ k, S.foldRequest = some k → k ∈ B
  flight : ∀ a, S.inFlight = some a → S.flightOwed ≠ none → a.subject ∈ B
  grant : S.stripGrant = true → g = true

theorem opt_filter_some {p : Key → Bool} {o : Option Key} {k : Key} (h : o.filter p = some k) : o = some k := by
  cases o with
  | none => simp [Option.filter] at h
  | some a =>
    simp only [Option.filter] at h
    split at h
    · exact h
    · simp at h

theorem provInv_userEdit (S : State) (rec moved : List Key) :
    ProvInv (moved ++ S.owedKeys ++ S.foldRequest.toList ++ (S.inFlight.map (·.subject)).toList) S.stripGrant
      (step S (.userEdit rec moved)).1 := by
  have hfl : ∀ a, S.inFlight = some a → a.subject ∈ moved ++ S.owedKeys ++ S.foldRequest.toList ++ (S.inFlight.map (·.subject)).toList := by
    intro a ha; simp [ha]
  by_cases hm : moved.isEmpty = true
  · simp only [step, hm, if_true]
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro k hk
      have := (List.mem_filter.mp hk).1
      simp [this]
    · intro k hk
      have h1 : S.foldRequest = some k := opt_filter_some hk
      simp [h1]
    · intro a ha _; exact hfl a ha
    · intro h; simpa using h
  · have hm' : moved.isEmpty = false := by simpa using hm
    simp only [step, hm', Bool.false_eq_true, if_false]
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro k hk
      have := (List.mem_filter.mp hk).1
      rw [List.mem_eraseDups, List.mem_append] at this
      rcases this with h | h
      · simp [h]
      · have := (List.mem_filter.mp h).2
        simp at this
        simp [this]
    · intro k hk
      simp only at hk
      split at hk
      · rename_i p hp
        have hpk : p = k := Option.some.inj hk
        subst hpk
        have h2 := List.find?_some hp
        simp at h2
        simp [h2.1]
      · have hk' := opt_filter_some hk
        simp [hk']
    · intro a ha _; exact hfl a ha
    · intro h; simpa using h

theorem provInv_result {B : List Key} {g : Bool} {S : State} {a : Action} (o : Outcome) (p : Bool)
    (hI : ProvInv B g S) (ha : S.inFlight = some a) : ProvInv B g (result S a o p) := by
  have hb : S.flightOwed ≠ none → a.subject ∈ B := hI.flight a ha
  obtain ⟨ho, hf, -, hg⟩ := hI
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro k hk
    unfold result markFail markStrike at hk
    split at hk <;> (try split at hk) <;> (try split at hk) <;> simp_all [List.mem_eraseDups] <;> grind [List.mem_eraseDups, List.mem_cons]
  · intro k hk
    unfold result markFail markStrike at hk
    split at hk <;> (try split at hk) <;> (try split at hk) <;> simp_all <;> grind [List.mem_eraseDups, List.mem_cons]
  · intro a' ha' _
    rw [(result_fields S a o p).1] at ha'; cases ha'
  · intro h
    rw [(result_fields S a o p).2.2.2] at h; exact hg h

theorem provInv_emit {B : List Key} {g : Bool} {S : State} (a : Action) (hI : ProvInv B g S) : ProvInv B g (emit S a) := by
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro k hk
    unfold emit at hk
    exact hI.owed k (List.mem_of_mem_erase hk)
  · intro k hk
    unfold emit at hk
    split at hk
    · simp at hk
    · exact hI.fold k hk
  · intro a' ha' hne
    unfold emit at ha' hne
    simp only [Option.some.injEq] at ha'
    subst ha'
    simp only at hne
    split at hne
    · rename_i hc
      exact hI.owed _ (by simpa using hc)
    · simp at hne
  · intro h
    unfold emit at h
    simp only at h
    by_cases hc : (a.strip && !S.owedKeys.contains a.subject) = true
    · simp [hc] at h; exact hI.grant h.2
    · simp [hc] at h; exact hI.grant h.2

theorem provInv_noteRead {B : List Key} {g : Bool} {S : State} (r : Read) (hI : ProvInv B g S) :
    ProvInv B g (noteRead (judge S r) r) := by
  obtain ⟨k1, k2, _, k4, _, k6, _, _, _, _, _, _, k13, _⟩ := noteRead_keeps_j S r
  refine ⟨?_, ?_, ?_, ?_⟩
  · intro k hk; rw [k1] at hk; exact hI.owed k hk
  · intro k hk; rw [k2] at hk; exact hI.fold k hk
  · intro a ha hne; rw [k4] at ha; rw [k6] at hne; exact hI.flight a ha hne
  · intro h; rw [k13] at h; exact hI.grant h

/-- Every event that is not a user event keeps the invariant. -/
theorem provInv_step {B : List Key} {g : Bool} {S : State} (hI : ProvInv B g S) (e : Event) (he : isUserEvent e = false) :
    ProvInv B g (step S e).1 := by
  cases e with
  | read r =>
    rw [step_read]
    cases hd : decideMove S r with
    | none => exact provInv_noteRead r hI
    | some a => exact provInv_emit a (provInv_noteRead r hI)
  | userEdit rec moved =>
    have hm : moved.isEmpty = true := by simpa [isUserEvent] using he
    simp only [step, hm, if_true]
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro k hk; exact hI.owed k (List.mem_filter.mp hk).1
    · intro k hk; exact hI.fold k (opt_filter_some hk)
    · intro a ha hne; exact hI.flight a ha hne
    · intro h; exact hI.grant h
  | userRetry => simp [isUserEvent] at he
  | retryKey k => simp [isUserEvent] at he
  | moveResult k o p =>
    simp only [step]
    split
    · rename_i a ha
      split
      · exact provInv_result o p hI ha
      · exact hI
    · exact hI
  | passBoundary =>
    simp only [step]
    refine ⟨?_, ?_, ?_, ?_⟩
    · intro k hk; simp at hk
    · intro k hk; simp at hk
    · intro a ha hne; exact hI.flight a ha hne
    · intro h; simp at h

/-- THE RUN: every `user := true` action emitted while no user event arrives is on a key of `B`, or is a granted strip move. -/
theorem run_provenance {B : List Key} {g : Bool} : ∀ (es : List Event) (S : State), ProvInv B g S →
    (∀ e ∈ es, isUserEvent e = false) → ∀ a ∈ (run S es).2, a.user = true → a.subject ∈ B ∨ (a.strip = true ∧ g = true)
  | [], S, _, _ => by intro a ha; simp [run] at ha
  | e :: es, S, hI, hes => by
    intro a ha hu
    rw [run_cons] at ha
    simp only [List.mem_append] at ha
    have he : isUserEvent e = false := hes e (by simp)
    rcases ha with ha | ha
    · obtain ⟨r, hr, _⟩ := step_acts ha
      subst hr
      rcases userLabelHonest ha hu with h | ⟨h1, h2⟩
      · left
        rcases h with h | h
        · simp only [Option.mem_toList, Option.mem_def] at h
          exact hI.fold _ h
        · exact hI.owed _ h
      · exact Or.inr ⟨h1, hI.grant h2⟩
    · exact run_provenance es _ (provInv_step hI e he) (fun e' he' => hes e' (by simp [he'])) a ha hu

/-- (G5, any edit) From ANY state, after `userEdit rec moved`, every `user := true` action the engine emits on the reads that follow (no further user event) names a
moved key, or a key that was already owed / the fold request / the drag in flight before the edit, or is the move a Re-apply granted. -/
theorem userEdit_provenance (s : State) (rec moved : List Key) (es : List Event) (hes : ∀ e ∈ es, isUserEvent e = false) :
    ∀ a ∈ (run (step s (.userEdit rec moved)).1 es).2, a.user = true →
      a.subject ∈ moved ∨ a.subject ∈ s.owedKeys ∨ s.foldRequest = some a.subject ∨ (∃ f, s.inFlight = some f ∧ f.subject = a.subject) ∨
      (a.strip = true ∧ s.stripGrant = true) := by
  intro a ha hu
  rcases run_provenance es _ (provInv_userEdit s rec moved) hes a ha hu with h | h
  · simp only [List.mem_append, Option.mem_toList, Option.mem_def] at h
    rcases h with ((h | h) | h) | h
    · exact Or.inl h
    · exact Or.inr (Or.inl h)
    · exact Or.inr (Or.inr (Or.inl h))
    · obtain ⟨f, hf, hfs⟩ := Option.map_eq_some_iff.mp h
      exact Or.inr (Or.inr (Or.inr (Or.inl ⟨f, hf, hfs⟩)))
  · exact Or.inr (Or.inr (Or.inr (Or.inr h)))

/-- (G5) THE GESTURE, COMPOSED WITH THE CORE.  Let `(L', moved) = applyGesture … L g` and `s' = step s (userEdit (coreRecord mov L') moved)`.  From any state `s`,
every user-flagged action of the following reads (until the next user event) has its subject in `moved`, or in what was already owed / requested / in flight before the
gesture, or is the Re-apply-granted strip move. -/
theorem gesture_provenance (unit : Key → Nat) (sys mov : Key → Bool) (s : State) (L : Layout3) (g : Gesture) (es : List Event)
    (hes : ∀ e ∈ es, isUserEvent e = false) :
    ∀ a ∈ (run (step s (.userEdit (coreRecord mov (applyGesture unit sys L g).1) (applyGesture unit sys L g).2)).1 es).2, a.user = true →
      a.subject ∈ (applyGesture unit sys L g).2 ∨ a.subject ∈ s.owedKeys ∨ s.foldRequest = some a.subject ∨
      (∃ f, s.inFlight = some f ∧ f.subject = a.subject) ∨ (a.strip = true ∧ s.stripGrant = true) :=
  userEdit_provenance s _ _ es hes

/-- (G5, a drop) a dropped item `k`: every user-flagged action that follows is a drag of `k` (or of what was already owed before the drop, or the granted move). -/
theorem drop_provenance (unit : Key → Nat) (sys mov : Key → Bool) (s : State) (L : Layout3) (k : Key) (t : Section) (idx : Option Nat)
    (es : List Event) (hes : ∀ e ∈ es, isUserEvent e = false) :
    ∀ a ∈ (run (step s (.userEdit (coreRecord mov (moveKey unit sys L k t idx)) [k])).1 es).2, a.user = true →
      a.subject = k ∨ a.subject ∈ s.owedKeys ∨ s.foldRequest = some a.subject ∨
      (∃ f, s.inFlight = some f ∧ f.subject = a.subject) ∨ (a.strip = true ∧ s.stripGrant = true) := by
  intro a ha hu
  rcases userEdit_provenance s _ [k] es hes a ha hu with h | h
  · left; simpa using h
  · exact Or.inr h

/-- (G5, a drop from a quiescent core) nothing owed, requested, in flight or granted before: then the ONLY user-flagged drag after a drop of `k` is a drag of `k`. -/
theorem drop_provenance_idle (unit : Key → Nat) (sys mov : Key → Bool) (s : State) (L : Layout3) (k : Key) (t : Section) (idx : Option Nat)
    (es : List Event) (hes : ∀ e ∈ es, isUserEvent e = false)
    (h1 : s.owedKeys = []) (h2 : s.foldRequest = none) (h3 : s.inFlight = none) (h4 : s.stripGrant = false) :
    ∀ a ∈ (run (step s (.userEdit (coreRecord mov (moveKey unit sys L k t idx)) [k])).1 es).2, a.user = true → a.subject = k := by
  intro a ha hu
  rcases drop_provenance unit sys mov s L k t idx es hes a ha hu with h | h | h | h | h
  · exact h
  · simp [h1] at h
  · simp [h2] at h
  · obtain ⟨f, hf, _⟩ := h; simp [h3] at hf
  · simp [h4] at h

end Sommelier
