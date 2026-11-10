import Sommelier.GestureDef

/-!
# Gestures: the proofs (sommelier-ejb.32)

The definitions (`Layout3`, `moveKey`, `hideStep`, `applyGesture`) are in `GestureDef.lean`; see its header for the semantics.  G1 `same_*`, G2 `cross_*`,
G3 `gesture_nodup` / `gesture_mem`, G4 `hide_spec`.  The composition with `step` (G5) is in `GestureProv.lean`.
-/

set_option linter.deprecated false
set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

namespace Sommelier

/-! ## Basic facts -/

section
variable {L : Layout3} {s s' : Section}

theorem set_keys_same (ks : List Key) : (L.set s ks).keys s = ks := by cases s <;> rfl
theorem set_keys_ne (ks : List Key) (h : s' ≠ s) : (L.set s ks).keys s' = L.keys s' := by
  cases s <;> cases s' <;> first | rfl | exact absurd rfl h
theorem keep_keys (f : Key → Bool) : (L.keep f).keys s = (L.keys s).filter f := by cases s <;> rfl
theorem keep_allKeys (f : Key → Bool) : (L.keep f).allKeys = L.allKeys.filter f := by
  simp [Layout3.keep, Layout3.allKeys, List.filter_append]

theorem mem_allKeys {x : Key} : x ∈ L.allKeys ↔ ∃ t, x ∈ L.keys t := by
  constructor
  · intro h
    simp only [Layout3.allKeys, List.mem_append] at h
    rcases h with (h | h) | h
    · exact ⟨.visible, h⟩
    · exact ⟨.hidden, h⟩
    · exact ⟨.alwaysHidden, h⟩
  · rintro ⟨t, h⟩
    cases t <;> simp_all [Layout3.keys, Layout3.allKeys]

theorem sectionOf_eq_some {k : Key} (h : L.sectionOf k = some s) : k ∈ L.keys s := by
  unfold Layout3.sectionOf at h
  cases s <;> (split at h <;> try split at h <;> try split at h) <;> simp_all [Layout3.keys]

theorem sectionOf_none {k : Key} (h : L.sectionOf k = none) : k ∉ L.allKeys := by
  unfold Layout3.sectionOf at h
  simp only [Layout3.allKeys, List.mem_append]
  by_cases h1 : k ∈ L.visible
  · simp [h1] at h
  by_cases h2 : k ∈ L.hidden
  · simp [h1, h2] at h
  by_cases h3 : k ∈ L.alwaysHidden
  · simp [h1, h2, h3] at h
  simp [h1, h2, h3]

theorem sectionOf_isSome {k : Key} (h : k ∈ L.allKeys) : ∃ t, L.sectionOf k = some t := by
  unfold Layout3.sectionOf
  simp only [Layout3.allKeys, List.mem_append] at h
  split
  · exact ⟨_, rfl⟩
  · split
    · exact ⟨_, rfl⟩
    · split
      · exact ⟨_, rfl⟩
      · simp_all

/-- in a duplicate-free layout a key listed in one section is in no other -/
theorem keys_disjoint (hnd : L.Nodup) {k : Key} (hk : k ∈ L.keys s) (hne : s' ≠ s) : k ∉ L.keys s' := by
  unfold Layout3.Nodup Layout3.allKeys at hnd
  simp only [List.nodup_append] at hnd
  obtain ⟨⟨_, _, h12⟩, _, h3⟩ := hnd
  intro h'
  cases s <;> cases s' <;> simp only [Layout3.keys] at hk h'
  · exact hne rfl
  · exact h12 k hk k h' rfl
  · exact h3 k (List.mem_append.mpr (Or.inl hk)) k h' rfl
  · exact h12 k h' k hk rfl
  · exact hne rfl
  · exact h3 k (List.mem_append.mpr (Or.inr hk)) k h' rfl
  · exact h3 k (List.mem_append.mpr (Or.inl h')) k hk rfl
  · exact h3 k (List.mem_append.mpr (Or.inr h')) k hk rfl
  · exact hne rfl

theorem insertGroup_keys_same (sys : Key → Bool) (g : List Key) (idx : Option Nat) :
    (insertGroup sys L g s idx).keys s =
      (L.keys s).take (insIdx sys (L.keys s) s idx) ++ g ++ (L.keys s).drop (insIdx sys (L.keys s) s idx) := by
  unfold insertGroup; exact set_keys_same _

theorem insertGroup_keys_ne (sys : Key → Bool) (g : List Key) (idx : Option Nat) (h : s' ≠ s) :
    (insertGroup sys L g s idx).keys s' = L.keys s' := by
  unfold insertGroup; exact set_keys_ne _ h

theorem trailStart_le (sys : Key → Bool) (ks : List Key) : trailStart sys ks ≤ ks.length := by
  unfold trailStart; omega

theorem insIdx_le (sys : Key → Bool) (ks : List Key) (idx : Option Nat) : insIdx sys ks s idx ≤ ks.length := by
  unfold insIdx
  cases idx with
  | some n => exact Nat.min_le_right _ _
  | none => (by_cases hs : s = .visible <;> simp [hs, trailStart_le])

theorem insertGroup_allKeys (sys : Key → Bool) (g : List Key) (idx : Option Nat) :
    (insertGroup sys L g s idx).allKeys.Perm (L.allKeys ++ g) := by
  rw [List.perm_iff_count]
  intro x
  have h := List.take_append_drop (insIdx sys (L.keys s) s idx) (L.keys s)
  have hc : ((L.keys s).take (insIdx sys (L.keys s) s idx)).count x + ((L.keys s).drop (insIdx sys (L.keys s) s idx)).count x
      = (L.keys s).count x := by
    rw [← List.count_append, h]
  unfold insertGroup
  cases s <;> simp only [Layout3.set, Layout3.keys, Layout3.allKeys, List.count_append] at hc ⊢ <;> omega

end

/-! ## Lists -/

theorem idxOf_ins (l : List Key) (k : Key) (i : Nat) (hk : k ∉ l.take i) (r : List Key) :
    (l.take i ++ k :: r).idxOf k = i ∨ i > l.length := by
  induction l generalizing i with
  | nil => simp; omega
  | cons a l ih =>
    cases i with
    | zero => simp [List.idxOf_cons]
    | succ i =>
      have hne : a ≠ k := by intro h; apply hk; simp [h]
      have hk' : k ∉ l.take i := by intro h; apply hk; simp [h]
      rcases ih i hk' with h | h
      · left; simp [List.idxOf_cons, hne, h]
      · right; simp; omega

theorem idxOf_ins' (l : List Key) (k : Key) (i : Nat) (hk : k ∉ l.take i) (hi : i ≤ l.length) (r : List Key) :
    (l.take i ++ k :: r).idxOf k = i := by
  rcases idxOf_ins l k i hk r with h | h
  · exact h
  · omega

theorem perm_filter_ne {l : List Key} (hnd : l.Nodup) {k : Key} (hk : k ∈ l) :
    (l.filter (fun x => x != k) ++ [k]).Perm l := by
  rw [List.perm_iff_count]
  intro x
  by_cases hx : x = k
  · subst hx
    have h1 : l.count x = 1 := by simp [hnd.count, hk]
    have h0 : (l.filter (fun y => y != x)).count x = 0 := by
      apply List.count_eq_zero.mpr; simp
    simp [h0, h1]
  · have hp := List.count_filter (p := fun y => y != k) (a := x) (l := l) (by simp [hx])
    rw [List.count_append, hp]
    simp [List.count_singleton, hx]
    intro h; exact absurd h.symm hx

/-! ## G1: a same-section drop moves exactly the dropped key -/

section same
variable {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat}

/-- the section after the drop: the section without `k`, with `k` re-inserted at the (clamped) index -/
theorem same_target (h : L.sectionOf k = some s) :
    ((moveKey unit sys L k s idx).keys s) =
      ((L.keys s).filter (fun x => x != k)).take (insIdx sys ((L.keys s).filter (fun x => x != k)) s idx) ++ [k] ++
      ((L.keys s).filter (fun x => x != k)).drop (insIdx sys ((L.keys s).filter (fun x => x != k)) s idx) := by
  unfold moveKey; rw [if_pos h, insertGroup_keys_same, keep_keys]

/-- (G1) every other key keeps its relative order: the section without `k` is the old section without `k` -/
theorem same_order (h : L.sectionOf k = some s) :
    ((moveKey unit sys L k s idx).keys s).filter (fun x => x != k) = (L.keys s).filter (fun x => x != k) := by
  rw [same_target h]
  simp only [List.filter_append]
  have : List.filter (fun x => x != k) [k] = [] := by simp
  rw [this, List.append_nil, ← List.filter_append, List.take_append_drop, List.filter_filter]
  apply List.filter_congr; intro x _; simp

/-- (G1) the other sections are untouched -/
theorem same_other (hnd : L.Nodup) (h : L.sectionOf k = some s) {t : Section} (ht : t ≠ s) :
    (moveKey unit sys L k s idx).keys t = L.keys t := by
  unfold moveKey; rw [if_pos h, insertGroup_keys_ne _ _ _ ht, keep_keys]
  apply List.filter_eq_self.mpr
  intro x hx
  have := keys_disjoint hnd (sectionOf_eq_some h) ht
  simp only [bne_iff_ne, ne_eq]
  intro hxk; subst hxk; exact this hx

/-- (G1) `k` is in its section, at the clamped index of the section without it -/
theorem same_idx (h : L.sectionOf k = some s) :
    ((moveKey unit sys L k s idx).keys s).idxOf k =
      insIdx sys ((L.keys s).filter (fun x => x != k)) s idx := by
  rw [same_target h]
  have hle := insIdx_le (s := s) sys ((L.keys s).filter (fun x => x != k)) idx
  rw [List.append_assoc]
  apply idxOf_ins' _ _ _ _ hle
  intro hm
  have := List.mem_filter.mp (List.mem_of_mem_take hm)
  simp at this

theorem same_mem (h : L.sectionOf k = some s) : k ∈ (moveKey unit sys L k s idx).keys s := by
  rw [same_target h]; simp

/-- (G1) no key is gained or lost: a permutation -/
theorem same_perm (hnd : L.Nodup) (h : L.sectionOf k = some s) :
    (moveKey unit sys L k s idx).allKeys.Perm L.allKeys := by
  unfold moveKey; rw [if_pos h]
  refine (insertGroup_allKeys _ _ _).trans ?_
  rw [keep_allKeys]
  have hk : k ∈ L.allKeys := mem_allKeys.mpr ⟨s, sectionOf_eq_some h⟩
  exact perm_filter_ne hnd hk

/-- (G1) every key other than `k` keeps its section -/
theorem same_section (hnd : L.Nodup) (h : L.sectionOf k = some s) {x : Key} (hx : x ≠ k) (t : Section) :
    x ∈ (moveKey unit sys L k s idx).keys t ↔ x ∈ L.keys t := by
  by_cases ht : t = s
  · subst ht
    have := congrArg (fun l => x ∈ l) (same_order (unit := unit) (sys := sys) (idx := idx) h)
    simp only [List.mem_filter, bne_iff_ne, ne_eq, hx, not_false_eq_true, and_true, eq_iff_iff] at this
    exact this
  · rw [same_other hnd h ht]

end same

/-! ## G2: a cross-section drop moves the whole unit; everything else keeps section and order -/

section cross
variable {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat}

theorem mem_groupOf {x : Key} : x ∈ groupOf unit L k ↔ x = k ∨ (x ∈ L.allKeys ∧ unit x = unit k) := by
  unfold groupOf
  simp only [List.mem_cons, List.mem_filter, Bool.and_eq_true, bne_iff_ne, ne_eq, beq_iff_eq]
  constructor
  · rintro (h | ⟨h1, _, h3⟩)
    · exact Or.inl h
    · exact Or.inr ⟨h1, h3⟩
  · rintro (h | ⟨h1, h3⟩)
    · exact Or.inl h
    · by_cases hx : x = k
      · exact Or.inl hx
      · exact Or.inr ⟨h1, hx, h3⟩

theorem groupOf_unit {x : Key} (h : x ∈ groupOf unit L k) : unit x = unit k := by
  rcases mem_groupOf.mp h with h | ⟨_, h⟩
  · rw [h]
  · exact h

theorem groupOf_head : k ∈ groupOf unit L k := by simp [groupOf]

/-- for a key of the layout: it is in the group exactly when it has the unit -/
theorem groupOf_iff {x : Key} (hx : x ∈ L.allKeys) : x ∈ groupOf unit L k ↔ unit x = unit k := by
  rw [mem_groupOf]
  constructor
  · rintro (h | ⟨_, h⟩)
    · rw [h]
    · exact h
  · intro h; exact Or.inr ⟨hx, h⟩

theorem groupOf_nodup (hnd : L.Nodup) : (groupOf unit L k).Nodup := by
  unfold groupOf
  rw [List.nodup_cons]
  refine ⟨?_, ?_⟩
  · simp [List.mem_filter]
  · exact List.Pairwise.filter _ hnd

theorem cross_target (h : L.sectionOf k ≠ some s) :
    (moveKey unit sys L k s idx).keys s =
      ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)).take
        (insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx) ++ groupOf unit L k ++
      ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)).drop
        (insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx) := by
  unfold moveKey; rw [if_neg h, insertGroup_keys_same, keep_keys]

theorem cross_ne (h : L.sectionOf k ≠ some s) {t : Section} (ht : t ≠ s) :
    (moveKey unit sys L k s idx).keys t = (L.keys t).filter (fun x => !(groupOf unit L k).contains x) := by
  unfold moveKey; rw [if_neg h, insertGroup_keys_ne _ _ _ ht, keep_keys]

/-- (G2) every key of `k`'s unit that is in the layout (and `k`) is in the target section afterwards -/
theorem cross_unit_in (h : L.sectionOf k ≠ some s) {x : Key} (hx : x = k ∨ x ∈ L.allKeys) (hu : unit x = unit k) :
    x ∈ (moveKey unit sys L k s idx).keys s := by
  rw [cross_target h]
  have : x ∈ groupOf unit L k := by
    rcases hx with hx | hx
    · rw [hx]; exact groupOf_head
    · exact (groupOf_iff hx).mpr hu
  simp [this]

theorem lifted_ne {x : Key} (hx : x ∈ L.allKeys) (hg : (!(groupOf unit L k).contains x) = true) : unit x ≠ unit k := by
  intro hu
  have := (groupOf_iff (unit := unit) (k := k) hx).mpr hu
  simp [this] at hg

theorem notgroup_of_ne {x : Key} (hx : x ∈ L.allKeys) (hu : unit x ≠ unit k) : (!(groupOf unit L k).contains x) = true := by
  refine Classical.byContradiction fun hc => ?_
  have : x ∈ groupOf unit L k := by simpa using hc
  exact hu (groupOf_unit this)

/-- (G2) a key outside the unit keeps its section -/
theorem cross_section (h : L.sectionOf k ≠ some s) {x : Key} (hx : x ∈ L.allKeys) (hu : unit x ≠ unit k) (t : Section) :
    x ∈ (moveKey unit sys L k s idx).keys t ↔ x ∈ L.keys t := by
  have hng := notgroup_of_ne (unit := unit) (k := k) hx hu
  have hnm : x ∉ groupOf unit L k := fun hm => hu (groupOf_unit hm)
  by_cases ht : t = s
  · subst ht
    rw [cross_target h]
    simp only [List.mem_append, hnm, or_false]
    constructor
    · rintro (hm | hm)
      · exact (List.mem_filter.mp (List.mem_of_mem_take hm)).1
      · exact (List.mem_filter.mp (List.mem_of_mem_drop hm)).1
    · intro hm
      have : x ∈ (L.keys t).filter (fun x => !(groupOf unit L k).contains x) := List.mem_filter.mpr ⟨hm, hng⟩
      rw [← List.mem_append, List.take_append_drop]; exact this
  · rw [cross_ne h ht, List.mem_filter]
    simp [hng, hnm]

/-- (G2) the relative order of the keys outside the unit is unchanged, in every section -/
theorem cross_order (h : L.sectionOf k ≠ some s) (t : Section) :
    ((moveKey unit sys L k s idx).keys t).filter (fun x => unit x != unit k) = (L.keys t).filter (fun x => unit x != unit k) := by
  have key : ((L.keys t).filter (fun x => !(groupOf unit L k).contains x)).filter (fun x => unit x != unit k) =
      (L.keys t).filter (fun x => unit x != unit k) := by
    rw [List.filter_filter]
    apply List.filter_congr
    intro x hx
    have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨t, hx⟩
    by_cases hu : unit x = unit k
    · simp [hu]
    · have hnm : x ∉ groupOf unit L k := fun hm => hu (groupOf_unit hm)
      simp [hu, hnm]
  by_cases ht : t = s
  · subst ht
    rw [cross_target h]
    simp only [List.filter_append]
    have hg : (groupOf unit L k).filter (fun x => unit x != unit k) = [] := by
      rw [List.filter_eq_nil_iff]; intro x hx; simp [groupOf_unit hx]
    rw [hg, List.append_nil, ← List.filter_append, List.take_append_drop]
    exact key
  · rw [cross_ne h ht]; exact key

/-- (G2) the unit's keys in the target section are exactly the group: `k` first, then its siblings in their previous layout order -/
theorem cross_group (h : L.sectionOf k ≠ some s) :
    ((moveKey unit sys L k s idx).keys s).filter (fun x => unit x == unit k) = groupOf unit L k := by
  rw [cross_target h]
  simp only [List.filter_append]
  have hl : ∀ l : List Key, (∀ x ∈ l, x ∈ (L.keys s).filter (fun x => !(groupOf unit L k).contains x)) →
      l.filter (fun x => unit x == unit k) = [] := by
    intro l hl
    rw [List.filter_eq_nil_iff]
    intro x hx
    obtain ⟨hxs, hxg⟩ := List.mem_filter.mp (hl x hx)
    have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨s, hxs⟩
    simpa using lifted_ne hxa hxg
  have h1 := hl (((L.keys s).filter (fun x => !(groupOf unit L k).contains x)).take
    (insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx)) (fun x hx => List.mem_of_mem_take hx)
  have h2 := hl (((L.keys s).filter (fun x => !(groupOf unit L k).contains x)).drop
    (insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx)) (fun x hx => List.mem_of_mem_drop hx)
  have h3 : (groupOf unit L k).filter (fun x => unit x == unit k) = groupOf unit L k := by
    rw [List.filter_eq_self]; intro x hx; simp [groupOf_unit hx]
  rw [h1, h2, h3]; simp

/-- (G2) no other section keeps a key of the unit -/
theorem cross_group_ne (h : L.sectionOf k ≠ some s) {t : Section} (ht : t ≠ s) :
    ((moveKey unit sys L k s idx).keys t).filter (fun x => unit x == unit k) = [] := by
  rw [cross_ne h ht, List.filter_filter, List.filter_eq_nil_iff]
  intro x hx
  have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨t, hx⟩
  by_cases hu : unit x = unit k
  · have : x ∈ groupOf unit L k := (groupOf_iff hxa).mpr hu
    simp [this]
  · simp [hu]

/-- (G2) `k` lands at the clamped index of the section without the unit, its siblings right behind it -/
theorem cross_idx (h : L.sectionOf k ≠ some s) :
    ((moveKey unit sys L k s idx).keys s).idxOf k =
      insIdx sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) s idx := by
  rw [cross_target h]
  have hle := insIdx_le (s := s) sys ((L.keys s).filter (fun x => !(groupOf unit L k).contains x)) idx
  have hg : ∀ (a b : List Key), a ++ groupOf unit L k ++ b =
      a ++ k :: (L.allKeys.filter (fun x => x != k && unit x == unit k) ++ b) := by
    intro a b; simp [groupOf]
  rw [hg]
  apply idxOf_ins' _ _ _ _ hle
  intro hm
  have := (List.mem_filter.mp (List.mem_of_mem_take hm)).2
  have hk : k ∈ groupOf unit L k := groupOf_head
  simp [hk] at this

theorem cross_allKeys (h : L.sectionOf k ≠ some s) :
    (moveKey unit sys L k s idx).allKeys.Perm (L.allKeys.filter (fun x => !(groupOf unit L k).contains x) ++ groupOf unit L k) := by
  unfold moveKey; rw [if_neg h]
  refine (insertGroup_allKeys _ _ _).trans ?_
  rw [keep_allKeys]

/-- (G3, cross-section) no duplicate appears -/
theorem cross_nodup (hnd : L.Nodup) (h : L.sectionOf k ≠ some s) : (moveKey unit sys L k s idx).Nodup := by
  unfold Layout3.Nodup
  refine ((cross_allKeys h).nodup_iff).mpr ?_
  rw [List.nodup_append]
  refine ⟨List.Pairwise.filter _ hnd, groupOf_nodup hnd, ?_⟩
  intro a ha b hb hab
  subst hab
  have := (List.mem_filter.mp ha).2
  simp [hb] at this

/-- (G3, cross-section) no key is lost: the keys are the layout's keys and `k` -/
theorem cross_mem (h : L.sectionOf k ≠ some s) {x : Key} :
    x ∈ (moveKey unit sys L k s idx).allKeys ↔ x ∈ L.allKeys ∨ x = k := by
  rw [(cross_allKeys h).mem_iff, List.mem_append, List.mem_filter, mem_groupOf]
  constructor
  · rintro (⟨h1, _⟩ | h2)
    · exact Or.inl h1
    · rcases h2 with h2 | ⟨h2, _⟩
      · exact Or.inr h2
      · exact Or.inl h2
  · rintro (h1 | h1)
    · by_cases hg : x ∈ groupOf unit L k
      · exact Or.inr (mem_groupOf.mp hg)
      · exact Or.inl ⟨h1, by simpa using hg⟩
    · exact Or.inr (Or.inl h1)

end cross

/-! ## G3 for a drop -/

section drop3
variable {unit : Key → Nat} {sys : Key → Bool} {L : Layout3} {k : Key} {s : Section} {idx : Option Nat}

/-- (G3) a drop never duplicates a key -/
theorem moveKey_nodup (hnd : L.Nodup) : (moveKey unit sys L k s idx).Nodup := by
  by_cases h : L.sectionOf k = some s
  · exact ((same_perm hnd h).nodup_iff).mpr hnd
  · exact cross_nodup hnd h

/-- (G3) a drop never loses a key: the keys afterwards are the layout's keys and the dropped key -/
theorem moveKey_mem (hnd : L.Nodup) {x : Key} : x ∈ (moveKey unit sys L k s idx).allKeys ↔ x ∈ L.allKeys ∨ x = k := by
  by_cases h : L.sectionOf k = some s
  · rw [(same_perm hnd h).mem_iff]
    constructor
    · exact Or.inl
    · rintro (h1 | h1)
      · exact h1
      · subst h1; exact mem_allKeys.mpr ⟨s, sectionOf_eq_some h⟩
  · exact cross_mem h

end drop3

/-! ## G4: hide what does not fit -/

theorem addMoved_foldl (g : List Key) : ∀ (mv : List Key), mv.Nodup →
    (g.foldl addMoved mv).Nodup ∧ (∀ m ∈ mv, m ∈ g.foldl addMoved mv) ∧ (∀ m ∈ g.foldl addMoved mv, m ∈ mv ∨ m ∈ g)
  | mv, hnd => by
    induction g generalizing mv with
    | nil => exact ⟨hnd, fun m hm => hm, fun m hm => Or.inl hm⟩
    | cons a g ih =>
      have hnd' : (addMoved mv a).Nodup := by
        unfold addMoved
        split
        · exact hnd
        · rename_i hc
          rw [List.nodup_append]
          exact ⟨hnd, by simp, by simp only [List.mem_singleton]; intro x hx y hy; subst hy; intro hxy; subst hxy; simp [hx] at hc⟩
      obtain ⟨i1, i2, i3⟩ := ih (addMoved mv a) hnd'
      refine ⟨i1, fun m hm => i2 m ?_, fun m hm => ?_⟩
      · unfold addMoved; split <;> simp_all
      · rcases i3 m hm with h | h
        · unfold addMoved at h; split at h
          · exact Or.inl h
          · simp at h
            rcases h with h | h
            · exact Or.inl h
            · exact Or.inr (by simp [h])
        · exact Or.inr (by simp [h])

theorem filter_swap {α : Type} (p q : α → Bool) (l : List α) : (l.filter p).filter q = (l.filter q).filter p := by
  rw [List.filter_filter, List.filter_filter]; apply List.filter_congr; intro x _; simp [Bool.and_comm]

section hide
variable {unit : Key → Nat} {sys : Key → Bool}

theorem hideStep_skip {acc : Layout3 × List Key} {k : Key} (h : acc.1.sectionOf k ≠ some .visible) : hideStep unit sys acc k = acc := by
  unfold hideStep; rw [if_neg h]

theorem hideStep_move {acc : Layout3 × List Key} {k : Key} (h : acc.1.sectionOf k = some .visible) :
    hideStep unit sys acc k = (moveKey unit sys acc.1 k .hidden none, (movedKeys unit acc.1 k .hidden).foldl addMoved acc.2) := by
  unfold hideStep; rw [if_pos h]

/-- one step of hide-what-does-not-fit, in a duplicate-free layout whose units are all-or-nothing -/
theorem hideStep_spec {L : Layout3} {mv : List Key} {k : Key} (hnd : L.Nodup) (hn : UnitNormal unit L) :
    (hideStep unit sys (L, mv) k).1.Nodup ∧
    (∀ x, x ∈ (hideStep unit sys (L, mv) k).1.allKeys ↔ x ∈ L.allKeys) ∧
    UnitNormal unit (hideStep unit sys (L, mv) k).1 ∧
    (∀ x ∈ L.allKeys, unit x ≠ unit k → ∀ t, (x ∈ (hideStep unit sys (L, mv) k).1.keys t ↔ x ∈ L.keys t)) ∧
    (∀ t, ((hideStep unit sys (L, mv) k).1.keys t).filter (fun x => unit x != unit k) = (L.keys t).filter (fun x => unit x != unit k)) ∧
    (∀ x ∈ L.hidden, x ∈ (hideStep unit sys (L, mv) k).1.hidden) ∧
    (∀ x ∈ L.alwaysHidden, x ∈ (hideStep unit sys (L, mv) k).1.alwaysHidden) ∧
    (∀ x ∈ L.visible, x ∈ (hideStep unit sys (L, mv) k).1.visible ∨ x ∈ (hideStep unit sys (L, mv) k).1.hidden) := by
  by_cases hk : L.sectionOf k = some .visible
  · have hs := hideStep_move (unit := unit) (sys := sys) (acc := (L, mv)) hk
    rw [hs]
    simp only
    have hne : L.sectionOf k ≠ some .hidden := by rw [hk]; simp
    have hkv : k ∈ L.visible := sectionOf_eq_some hk
    have hka : k ∈ L.allKeys := mem_allKeys.mpr ⟨.visible, hkv⟩
    have hmem : ∀ x, x ∈ (moveKey unit sys L k .hidden none).allKeys ↔ x ∈ L.allKeys := by
      intro x
      rw [cross_mem hne]
      constructor
      · rintro (h | h); exact h; subst h; exact hka
      · exact Or.inl
    have hvis : (moveKey unit sys L k .hidden none).keys .visible = L.visible.filter (fun x => !(groupOf unit L k).contains x) :=
      cross_ne hne (t := .visible) (by simp)
    -- the unit mates of `k` are in Visible
    have hmate : ∀ x ∈ L.allKeys, unit x = unit k → x ∈ L.visible := fun x hx hu => (hn x k hx hka hu).mpr hkv
    refine ⟨moveKey_nodup hnd, hmem, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · intro x y hx hy hxy
      have hx' := (hmem x).mp hx
      have hy' := (hmem y).mp hy
      have e : ∀ z, z ∈ (moveKey unit sys L k .hidden none).visible ↔ z ∈ L.visible ∧ z ∉ groupOf unit L k := by
        intro z
        have := hvis
        simp only [Layout3.keys] at this
        rw [this, List.mem_filter]; simp
      show x ∈ (moveKey unit sys L k .hidden none).visible ↔ y ∈ (moveKey unit sys L k .hidden none).visible
      rw [e, e]
      by_cases hu : unit x = unit k
      · have hxg : x ∈ groupOf unit L k := (groupOf_iff hx').mpr hu
        have hyg : y ∈ groupOf unit L k := (groupOf_iff hy').mpr (hxy ▸ hu)
        simp [hxg, hyg]
      · have hxg : x ∉ groupOf unit L k := fun hm => hu (groupOf_unit hm)
        have hyg : y ∉ groupOf unit L k := fun hm => hu (hxy ▸ groupOf_unit hm)
        simp [hxg, hyg, hn x y hx' hy' hxy]
    · intro x hx hu t; exact cross_section hne hx hu t
    · intro t; exact cross_order hne t
    · intro x hx
      have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨.hidden, hx⟩
      by_cases hu : unit x = unit k
      · exact absurd (hmate x hxa hu) (fun hv => keys_disjoint (s := .visible) (s' := .hidden) hnd hv (by simp) (show x ∈ L.keys .hidden from hx))
      · exact (cross_section hne hxa hu .hidden).mpr hx
    · intro x hx
      have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨.alwaysHidden, hx⟩
      by_cases hu : unit x = unit k
      · exact absurd (hmate x hxa hu) (fun hv => keys_disjoint (s := .visible) (s' := .alwaysHidden) hnd hv (by simp) (show x ∈ L.keys .alwaysHidden from hx))
      · exact (cross_section hne hxa hu .alwaysHidden).mpr hx
    · intro x hx
      have hxa : x ∈ L.allKeys := mem_allKeys.mpr ⟨.visible, hx⟩
      by_cases hu : unit x = unit k
      · right; exact cross_unit_in hne (Or.inr hxa) hu
      · left; exact (cross_section hne hxa hu .visible).mpr hx
  · have hs := hideStep_skip (unit := unit) (sys := sys) (acc := (L, mv)) hk
    rw [hs]
    exact ⟨hnd, fun _ => Iff.rfl, hn, fun _ _ _ _ => Iff.rfl, fun _ => rfl, fun _ h => h, fun _ h => h, fun _ h => Or.inl h⟩

theorem hideStep_moved {L : Layout3} {mv : List Key} {k : Key} (hmv : mv.Nodup) :
    (hideStep unit sys (L, mv) k).2.Nodup ∧ (∀ m ∈ mv, m ∈ (hideStep unit sys (L, mv) k).2) ∧
    (∀ m ∈ (hideStep unit sys (L, mv) k).2, m ∈ mv ∨ m ∈ L.allKeys) := by
  by_cases hk : L.sectionOf k = some .visible
  · rw [hideStep_move (unit := unit) (sys := sys) (acc := (L, mv)) hk]
    simp only
    have hne : L.sectionOf k ≠ some .hidden := by rw [hk]; simp
    have hf := addMoved_foldl (movedKeys unit L k .hidden) mv hmv
    refine ⟨hf.1, hf.2.1, fun m hm => ?_⟩
    rcases hf.2.2 m hm with h | h
    · exact Or.inl h
    · right
      unfold movedKeys at h
      rw [if_neg hne] at h
      rcases mem_groupOf.mp h with h | ⟨h, _⟩
      · subst h; exact mem_allKeys.mpr ⟨.visible, sectionOf_eq_some hk⟩
      · exact h
  · rw [hideStep_skip (unit := unit) (sys := sys) (acc := (L, mv)) hk]
    exact ⟨hmv, fun _ h => h, fun _ h => Or.inl h⟩

/-- the whole of "hide what does not fit" -/
theorem hide_fold (ks : List Key) : ∀ (L : Layout3) (mv : List Key), L.Nodup → UnitNormal unit L → mv.Nodup →
    (ks.foldl (hideStep unit sys) (L, mv)).1.Nodup ∧
    (∀ x, x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.allKeys ↔ x ∈ L.allKeys) ∧
    UnitNormal unit (ks.foldl (hideStep unit sys) (L, mv)).1 ∧
    (∀ x ∈ L.allKeys, (∀ k ∈ ks, unit x ≠ unit k) → ∀ t, (x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.keys t ↔ x ∈ L.keys t)) ∧
    (∀ t, ((ks.foldl (hideStep unit sys) (L, mv)).1.keys t).filter (fun x => ks.all (fun k => unit x != unit k)) =
      (L.keys t).filter (fun x => ks.all (fun k => unit x != unit k))) ∧
    (∀ x ∈ L.hidden, x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.hidden) ∧
    (∀ x ∈ L.alwaysHidden, x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.alwaysHidden) ∧
    (∀ x ∈ L.visible, x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.visible ∨ x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.hidden) ∧
    (ks.foldl (hideStep unit sys) (L, mv)).2.Nodup ∧ (∀ m ∈ mv, m ∈ (ks.foldl (hideStep unit sys) (L, mv)).2) ∧
    (∀ m ∈ (ks.foldl (hideStep unit sys) (L, mv)).2, m ∈ mv ∨ m ∈ L.allKeys) := by
  induction ks with
  | nil =>
    intro L mv hnd hn hmv
    exact ⟨hnd, fun _ => Iff.rfl, hn, fun _ _ _ _ => Iff.rfl, fun _ => by simp, fun _ h => h, fun _ h => h, fun _ h => Or.inl h,
      hmv, fun _ h => h, fun _ h => Or.inl h⟩
  | cons k ks ih =>
    intro L mv hnd hn hmv
    obtain ⟨s1, s2, s3, s4, s5, s6, s7, s8⟩ := hideStep_spec (unit := unit) (sys := sys) (mv := mv) (k := k) hnd hn
    obtain ⟨m1, m2, m3⟩ := hideStep_moved (unit := unit) (sys := sys) (L := L) (mv := mv) (k := k) hmv
    simp only [List.foldl_cons]
    generalize hideStep unit sys (L, mv) k = A at *
    obtain ⟨L1, mv1⟩ := A
    obtain ⟨i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11⟩ := ih L1 mv1 s1 s3 m1
    refine ⟨i1, fun x => (i2 x).trans (s2 x), i3, ?_, ?_, ?_, ?_, ?_, i9, fun m hm => i10 m (m2 m hm), ?_⟩
    · intro x hx hu t
      have hu0 : unit x ≠ unit k := hu k (by simp)
      have hx1 : x ∈ L1.allKeys := (s2 x).mpr hx
      have := i4 x hx1 (fun k' hk' => hu k' (by simp [hk'])) t
      exact this.trans (s4 x hx hu0 t)
    · intro t
      simp only [List.all_cons]
      have key : ∀ l : List Key, l.filter (fun x => (unit x != unit k && ks.all (fun k' => unit x != unit k'))) =
          (l.filter (fun x => unit x != unit k)).filter (fun x => ks.all (fun k' => unit x != unit k')) := by
        intro l; rw [List.filter_filter]; apply List.filter_congr; intro x _; simp [Bool.and_comm]
      rw [key, key]
      rw [filter_swap, i5 t, ← filter_swap, s5 t]
    · intro x hx; exact i6 x (s6 x hx)
    · intro x hx; exact i7 x (s7 x hx)
    · intro x hx
      rcases s8 x hx with h | h
      · exact i8 x h
      · right; exact i6 x h
    · intro m hm
      rcases i11 m hm with h | h
      · exact m3 m h
      · exact Or.inr ((s2 m).mp h)

/-- (G3) without any assumption on the units: hide-what-does-not-fit loses and duplicates no key -/
theorem hide_fold_keys (ks : List Key) : ∀ (L : Layout3) (mv : List Key), L.Nodup →
    (ks.foldl (hideStep unit sys) (L, mv)).1.Nodup ∧
    (∀ x, x ∈ (ks.foldl (hideStep unit sys) (L, mv)).1.allKeys ↔ x ∈ L.allKeys) := by
  induction ks with
  | nil => intro L mv hnd; exact ⟨hnd, fun _ => Iff.rfl⟩
  | cons k ks ih =>
    intro L mv hnd
    simp only [List.foldl_cons]
    by_cases hk : L.sectionOf k = some .visible
    · have hs := hideStep_move (unit := unit) (sys := sys) (acc := (L, mv)) hk
      have hne : L.sectionOf k ≠ some .hidden := by rw [hk]; simp
      have hka : k ∈ L.allKeys := mem_allKeys.mpr ⟨.visible, sectionOf_eq_some hk⟩
      rw [hs]
      simp only
      obtain ⟨i1, i2⟩ := ih (moveKey unit sys L k .hidden none) _ (moveKey_nodup hnd)
      refine ⟨i1, fun x => (i2 x).trans ?_⟩
      rw [cross_mem hne]
      constructor
      · rintro (h | h); exact h; subst h; exact hka
      · exact Or.inl
    · rw [hideStep_skip (unit := unit) (sys := sys) (acc := (L, mv)) hk]
      exact ih L mv hnd

end hide

/-! ## The headline theorems, for `applyGesture` -/

section headline
variable {unit : Key → Nat} {sys : Key → Bool} {L : Layout3}

/-- the keys a gesture may add to the layout: the dropped key -/
def Gesture.dropped : Gesture → List Key
  | .drop k _ _ => [k]
  | .hideNotFitting _ => []

/-- (G1/G2) a drop reports exactly the dropped key as moved, and computes its layout by `moveKey` -/
theorem drop_moved (k : Key) (s : Section) (idx : Option Nat) :
    applyGesture unit sys L (.drop k s idx) = (moveKey unit sys L k s idx, [k]) := rfl

/-- (G3) NO GESTURE EVER DUPLICATES A KEY -/
theorem gesture_nodup (hnd : L.Nodup) (g : Gesture) : (applyGesture unit sys L g).1.Nodup := by
  cases g with
  | drop k s idx => exact moveKey_nodup hnd
  | hideNotFitting ks => exact (hide_fold_keys ks L [] hnd).1

/-- (G3) NO GESTURE EVER LOSES A KEY: the keys afterwards are the layout's keys and (for a drop) the dropped key -/
theorem gesture_mem (hnd : L.Nodup) (g : Gesture) {x : Key} :
    x ∈ (applyGesture unit sys L g).1.allKeys ↔ x ∈ L.allKeys ∨ x ∈ g.dropped := by
  cases g with
  | drop k s idx => simpa [Gesture.dropped, applyGesture] using (moveKey_mem (unit := unit) (sys := sys) (k := k) (s := s) (idx := idx) hnd)
  | hideNotFitting ks => simpa [Gesture.dropped, applyGesture] using (hide_fold_keys ks L [] hnd).2 x

/-- (G4) hide what does not fit.  In a layout with no duplicate whose hide units are all-or-nothing:
(a) a key outside the units of the named keys keeps its section;
(b) the relative order of everything outside those units is unchanged, section by section;
(c) Hidden and Always hidden keys stay where they are, and a Visible key stays Visible or goes to Hidden: the only change of section is Visible to Hidden;
(d) the moved keys are listed once each and are keys of the layout. -/
theorem hide_spec (hnd : L.Nodup) (hn : UnitNormal unit L) (ks : List Key) :
    (∀ x ∈ L.allKeys, (∀ k ∈ ks, unit x ≠ unit k) → ∀ t, (x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.keys t ↔ x ∈ L.keys t)) ∧
    (∀ t, ((applyGesture unit sys L (.hideNotFitting ks)).1.keys t).filter (fun x => ks.all (fun k => unit x != unit k)) =
      (L.keys t).filter (fun x => ks.all (fun k => unit x != unit k))) ∧
    (∀ x ∈ L.hidden, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.hidden) ∧
    (∀ x ∈ L.alwaysHidden, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.alwaysHidden) ∧
    (∀ x ∈ L.visible, x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.visible ∨ x ∈ (applyGesture unit sys L (.hideNotFitting ks)).1.hidden) ∧
    (applyGesture unit sys L (.hideNotFitting ks)).2.Nodup ∧
    (∀ m ∈ (applyGesture unit sys L (.hideNotFitting ks)).2, m ∈ L.allKeys) := by
  obtain ⟨_, _, _, a4, a5, a6, a7, a8, a9, _, a11⟩ := hide_fold (unit := unit) (sys := sys) ks L [] hnd hn (by simp)
  refine ⟨a4, a5, a6, a7, a8, a9, fun m hm => ?_⟩
  rcases a11 m hm with h | h
  · simp at h
  · exact h

end headline

end Sommelier
