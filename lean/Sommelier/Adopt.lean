import Sommelier.Truth

/-!
# Adopt: "Use the bar's current order" (sommelier-ejb.9)

`adoptRecord rec r` is the record the user would get by taking the bar's own order as their record, computed from the record and ONE
reading, with no drags involved.

THE RULE (slots).  The keys the reading PINS (`Read.pinBehind`: the folded keys behind « of a usable fresh-chevron read, and
`Read.pinOpen`: the trusted drawn keys) and that are in the record are the record's *on-bar* keys.  Their order becomes the read's order:
the keys behind « first (in the read's order, each once), then the open keys left to right.  Every other record key (not running, unread,
drawn but not trusted, or not listed) is OFF-BAR for this purpose and stays in the very SLOT it has in the record: the slots of the
on-bar keys are refilled, in the record's slot order, with the on-bar keys in the read's order.  So the off-bar keys do not move at all
(their relative order is kept, and so is their position among the slots), no key is gained or lost, and a record that already agrees with
the read is returned unchanged.  On a read that pins nothing (not usable) the record is returned unchanged.

`adoptProposal s r` is what the button offers: only when the engine's own shown verdict of the read (`shownVerdict`, which judges
`s.view r`) is `differs` (which already implies the read is usable and consistent), the adopted record of that view; else `none`.

Proved (this file; all with the standard axioms only):
* `adoptRecord_perm`, `adoptRecord_nodup`: a permutation of the record: nothing gained or lost, duplicate-free if the record is;
* `adoptRecord_offbar`: the off-bar keys keep their order (and, by the slot rule, their places);
* `adoptRecord_okL`: the pinned keys alone are consistent with the adopted record (`OkL`), hence
* `adoptRecord_not_differs`: on a usable consistent read the verdict of the adopted record is never `differs`,
* `adoptRecord_matches_pinned`: it matches the bar the read pins (open = the trusted drawn keys, behind = the folded keys) which is the
  bar if nothing else is on it, and in general
* `adoptRecord_verdict`: the verdict is `matches`, or `matchesExcept U` (the unread/untrusted record keys that could clash), or
  `cannotTell` (two or more unread keys that clash only with each other); never `differs`;
* `adoptRecord_matches_of_no_free`: when every record key is pinned or off the bar by A6 (no free listed key), the verdict is `matches`,
  i.e. EVERY bar the read allows matches the adopted record.
-/

namespace Sommelier

/-- the keys the reading pins, as a predicate -/
def pinnedP (r : Read) (k : Key) : Bool := r.pinBehind.contains k || r.pinOpen.contains k

/-- the read's order of the pinned keys that are in the record: behind « first (once each), then the open keys left to right -/
def adoptSeq (rec : List Key) (r : Read) : List Key :=
  (dd r.pinBehind ++ r.pinOpen).filter (fun k => rec.contains k)

/-- refill the slots (positions of keys satisfying `P`) of the record, in order, from `S`; the other keys stay where they are.
(If `S` runs out the slot keeps its key: never happens when `S` is a permutation of the `P`-keys of the record.) -/
def fillSlots (P : Key → Bool) : List Key → List Key → List Key
  | [], _ => []
  | k :: ks, S =>
    if P k then
      match S with
      | s :: ss => s :: fillSlots P ks ss
      | [] => k :: fillSlots P ks []
    else k :: fillSlots P ks S

/-- THE ADOPTED RECORD. -/
def adoptRecord (rec : List Key) (r : Read) : List Key := fillSlots (pinnedP r) rec (adoptSeq rec r)

/-- What the button offers. -/
def adoptProposal (s : State) (r : Read) : Option (List Key) :=
  if shownVerdict s r = .differs then some (adoptRecord s.record (s.view r)) else none

/-! ### fillSlots -/

theorem fillSlots_spec (P : Key → Bool) : ∀ (rec S : List Key), (∀ s ∈ S, P s = true) → S.length = (rec.filter P).length →
    (fillSlots P rec S).filter P = S ∧ (fillSlots P rec S).filter (fun k => !P k) = rec.filter (fun k => !P k)
  | [], S, _, hl => by
    simp at hl; subst hl; simp [fillSlots]
  | k :: ks, S, hS, hl => by
    by_cases hk : P k = true
    · cases S with
      | nil => simp [hk] at hl
      | cons s ss =>
        have hs : P s = true := hS s List.mem_cons_self
        have hl' : ss.length = (ks.filter P).length := by simp [hk] at hl; exact hl
        have ih := fillSlots_spec P ks ss (fun x hx => hS x (List.mem_cons_of_mem _ hx)) hl'
        simp [fillSlots, hk, hs, ih.1, ih.2]
    · have hk' : P k = false := by simpa using hk
      have hl' : S.length = (ks.filter P).length := by simp [hk'] at hl; exact hl
      have ih := fillSlots_spec P ks S hS hl'
      simp [fillSlots, hk', ih.1, ih.2]

/-- membership-preserving permutation: `S` is a permutation of the `P`-keys of `rec` -/
theorem fillSlots_perm (P : Key → Bool) (rec S : List Key) (hS : ∀ s ∈ S, P s = true)
    (hp : S.Perm (rec.filter P)) : (fillSlots P rec S).Perm rec := by
  have hsp := fillSlots_spec P rec S hS hp.length_eq
  have h1 := List.filter_append_perm P (fillSlots P rec S)
  have h2 := List.filter_append_perm P rec
  rw [hsp.1] at h1
  have h3 : (List.filter (fun k => !P k) (fillSlots P rec S)) = rec.filter (fun k => !P k) := hsp.2
  rw [h3] at h1
  exact (h1.symm.trans ((hp.append_right _).trans h2))


/-! ### order of pinned keys is read off the filtered list -/

theorem idx_filter_lt (P : Key → Bool) : ∀ (L : List Key) {x y : Key}, P x = true → P y = true → x ∈ L → y ∈ L →
    (L.idxOf x < L.idxOf y ↔ (L.filter P).idxOf x < (L.filter P).idxOf y)
  | [], x, y, _, _, hx, _ => by simp at hx
  | a :: t, x, y, hPx, hPy, hx, hy => by
    by_cases hax : a = x
    · subst hax
      by_cases hay : a = y
      · subst hay; simp
      · have hy' : y ∈ t := cons_tail hay hy
        have hy'' : y ∈ t.filter P := List.mem_filter.mpr ⟨hy', hPy⟩
        simp [hPx, idx_cons, hay]
    · have hx' : x ∈ t := cons_tail hax hx
      have hx'' : x ∈ t.filter P := List.mem_filter.mpr ⟨hx', hPx⟩
      by_cases hay : a = y
      · subst hay
        simp [hPy, idx_cons, hax]
      · have hy' : y ∈ t := cons_tail hay hy
        have ih := idx_filter_lt P t hPx hPy hx' hy'
        by_cases hPa : P a = true
        · simp [hPa, idx_cons, hax, hay]; omega
        · have : P a = false := by simpa using hPa
          simp [this, idx_cons, hax, hay]; omega

/-! ### the adopted record -/

section
variable {rec : List Key} {r : Read}

theorem mem_adoptSeq {k : Key} : k ∈ adoptSeq rec r ↔ (k ∈ r.pinBehind ∨ k ∈ r.pinOpen) ∧ k ∈ rec := by
  unfold adoptSeq
  simp [List.mem_filter, List.mem_append, mem_dd]
  exact or_and_right.symm

theorem adoptSeq_pinned : ∀ s ∈ adoptSeq rec r, pinnedP r s = true := by
  intro s hs
  have := (mem_adoptSeq.mp hs).1
  simp [pinnedP]; exact this

theorem adoptSeq_nodup (hc : r.consistent = true) : (adoptSeq rec r).Nodup := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  unfold adoptSeq
  apply nodup_filter'
  rw [List.nodup_append]
  refine ⟨nodup_dd _, hn, ?_⟩
  intro a ha b hb hab
  subst hab
  exact hd a hb (mem_dd.mp ha)

theorem adoptSeq_perm (hc : r.consistent = true) (hnd : rec.Nodup) :
    (adoptSeq rec r).Perm (rec.filter (pinnedP r)) := by
  rw [List.perm_ext_iff_of_nodup (adoptSeq_nodup hc) (nodup_filter' _ hnd)]
  intro k
  rw [mem_adoptSeq, List.mem_filter]
  simp [pinnedP]
  exact and_comm

theorem adoptRecord_perm (hc : r.consistent = true) (hnd : rec.Nodup) : (adoptRecord rec r).Perm rec :=
  fillSlots_perm _ rec _ adoptSeq_pinned (adoptSeq_perm hc hnd)

/-- (b) no key gained or lost -/
theorem adoptRecord_mem (hc : r.consistent = true) (hnd : rec.Nodup) {k : Key} : k ∈ adoptRecord rec r ↔ k ∈ rec :=
  (adoptRecord_perm hc hnd).mem_iff

/-- (c) -/
theorem adoptRecord_nodup (hc : r.consistent = true) (hnd : rec.Nodup) : (adoptRecord rec r).Nodup :=
  (adoptRecord_perm hc hnd).nodup_iff.mpr hnd

/-- the off-bar keys keep their order -/
theorem adoptRecord_offbar (hc : r.consistent = true) (hnd : rec.Nodup) :
    (adoptRecord rec r).filter (fun k => !pinnedP r k) = rec.filter (fun k => !pinnedP r k) :=
  (fillSlots_spec (pinnedP r) rec _ adoptSeq_pinned (adoptSeq_perm hc hnd).length_eq).2

/-- the on-bar keys of the adopted record are in the read's order -/
theorem adoptRecord_onbar (hc : r.consistent = true) (hnd : rec.Nodup) :
    (adoptRecord rec r).filter (pinnedP r) = adoptSeq rec r :=
  (fillSlots_spec (pinnedP r) rec _ adoptSeq_pinned (adoptSeq_perm hc hnd).length_eq).1

/-- a read that pins nothing leaves the record as it is -/
theorem adoptRecord_unusable (hu : ¬ r.usable) : adoptRecord rec r = rec := by
  have h1 : r.pinOpen = [] := pinOpen_unusable hu
  have h2 : r.pinBehind = [] := pinBehind_unusable hu
  have hP : ∀ k, pinnedP r k = false := by intro k; simp [pinnedP, h1, h2]
  have : ∀ S : List Key, ∀ L : List Key, fillSlots (pinnedP r) L S = L := by
    intro S L
    induction L generalizing S with
    | nil => rfl
    | cons k ks ih => simp [fillSlots, hP, ih]
  exact this _ _

/-- (a) the pinned keys alone are consistent with the adopted record -/
theorem adoptRecord_okL (hc : r.consistent = true) (hnd : rec.Nodup) : OkL r (adoptRecord rec r) := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  have hmem : ∀ {k : Key}, k ∈ adoptRecord rec r ↔ k ∈ rec := adoptRecord_mem hc hnd
  have honbar := adoptRecord_onbar hc hnd
  constructor
  · -- the open keys of the adopted record are the pinned open keys that are in the record, in the read's order
    have h1 : (adoptRecord rec r).filter (fun z => z ∈ r.pinOpen) =
        ((adoptRecord rec r).filter (pinnedP r)).filter (fun z => z ∈ r.pinOpen) := by
      rw [List.filter_filter]; apply List.filter_congr
      intro z _
      by_cases h : z ∈ r.pinOpen <;> simp [pinnedP, h]
    rw [h1, honbar]
    unfold adoptSeq
    rw [List.filter_filter, List.filter_append]
    have h2 : (dd r.pinBehind).filter (fun a => decide (a ∈ r.pinOpen) && rec.contains a) = [] := by
      rw [List.filter_eq_nil_iff]
      intro a ha
      have : a ∉ r.pinOpen := fun h => hd a h (mem_dd.mp ha)
      simp [this]
    rw [h2, List.nil_append]
    apply List.filter_congr
    intro a ha
    have : a ∈ adoptRecord rec r ↔ a ∈ rec := hmem
    simp [ha, this]
  · intro x hx y hy hxL hyL
    have hPx : pinnedP r x = true := by simp [pinnedP, hx]
    have hPy : pinnedP r y = true := by simp [pinnedP, hy]
    rw [idx_filter_lt (pinnedP r) _ hPx hPy hxL hyL, honbar]
    have hxr : x ∈ rec := hmem.mp hxL
    have hyr : y ∈ rec := hmem.mp hyL
    have hxD : x ∈ dd r.pinBehind ++ r.pinOpen := List.mem_append.mpr (Or.inl (mem_dd.mpr hx))
    have hyD : y ∈ dd r.pinBehind ++ r.pinOpen := List.mem_append.mpr (Or.inr hy)
    unfold adoptSeq
    rw [← idx_filter_lt (fun k => rec.contains k) _ (by simpa using hxr) (by simpa using hyr) hxD hyD]
    rw [idx_append_left (mem_dd.mpr hx), idx_append_right (fun h => hd y hy (mem_dd.mp h))]
    have := idx_lt_len (mem_dd.mpr hx)
    omega


/-- (a) on a usable consistent read the pinned keys never force a mismatch: the adopted record is never judged `differs` -/
theorem adoptRecord_not_differs (_hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    forcedBad (adoptRecord rec r) r = false :=
  (forcedBad_iff hc (adoptRecord_nodup hc hnd)).mpr (adoptRecord_okL hc hnd)

/-- (a) the bar the reading pins (open = the trusted drawn keys left to right, behind = the folded keys), which is the bar if
nothing else is on it, matches the adopted record -/
theorem adoptRecord_matches_pinned (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    barMatches (adoptRecord rec r) ⟨r.pinOpen, dd r.pinBehind⟩ :=
  unforced_match hu hc (adoptRecord_nodup hc hnd) (adoptRecord_not_differs hu hc hnd)

/-- (a) exactly what the verdict of the adopted record is: `matches`, `matchesExcept U` or `cannotTell`, never `differs`; `U` are the free
(unread/untrusted) record keys that could clash with a pinned one, `Rcomp` those that clash only with each other. -/
theorem adoptRecord_verdict (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    verdict (adoptRecord rec r) r =
      if (Rcomp (adoptRecord rec r) r).length ≥ 2 then .cannotTell
      else if (Ucomp (adoptRecord rec r) r).isEmpty then .matches else .matchesExcept (Ucomp (adoptRecord rec r) r) :=
  verdict_else _ hu hc (adoptRecord_not_differs hu hc hnd)

theorem adoptRecord_verdict_ne_differs (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    verdict (adoptRecord rec r) r ≠ .differs := by
  rw [adoptRecord_verdict hu hc hnd]
  split <;> (try split) <;> simp

/-- (a) when no record key is a free listed key (every record key is pinned, or the read rules it off the bar), the adopted record
matches: EVERY bar the reading allows matches it (`verdict_matches_iff`) -/
theorem adoptRecord_matches_of_no_free (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup)
    (hfree : ∀ k ∈ rec, ¬ (r.free k = true ∧ r.openOK k = true)) :
    verdict (adoptRecord rec r) r = .matches ∧ ∀ b, Possible r b → barMatches (adoptRecord rec r) b := by
  have hv : verdict (adoptRecord rec r) r = .matches := by
    rw [adoptRecord_verdict hu hc hnd]
    have hR : Rcomp (adoptRecord rec r) r = [] := by
      unfold Rcomp
      rw [List.filter_eq_nil_iff]
      intro k hk
      have hk' := (List.mem_filter.mp hk)
      have hkr : k ∈ rec := (adoptRecord_mem hc hnd).mp hk'.1
      have hb := hk'.2
      simp only [Bool.and_eq_true] at hb
      exact absurd hb (hfree k hkr)
    have hU : Ucomp (adoptRecord rec r) r = [] := by
      unfold Ucomp
      rw [List.filter_eq_nil_iff]
      intro k hk
      have hkr : k ∈ rec := (adoptRecord_mem hc hnd).mp hk
      intro hp
      simp only [party, Bool.and_eq_true] at hp
      exact hfree k hkr ⟨hp.1.1, hp.1.2⟩
    simp [hR, hU]
  exact ⟨hv, ((uc_matches hu hc (adoptRecord_nodup hc hnd)).mp hv)⟩

/-! ### The proposal -/

theorem adoptProposal_some {s : State} {r : Read} {L : List Key} (h : adoptProposal s r = some L) :
    shownVerdict s r = .differs ∧ L = adoptRecord s.record (s.view r) := by
  unfold adoptProposal at h
  by_cases hd : shownVerdict s r = .differs
  · simp [hd] at h; exact ⟨hd, h.symm⟩
  · simp [hd] at h

theorem adoptProposal_none {s : State} {r : Read} (h : shownVerdict s r ≠ .differs) : adoptProposal s r = none := by
  unfold adoptProposal; simp [h]

theorem adoptProposal_iff {s : State} {r : Read} :
    (adoptProposal s r).isSome ↔ shownVerdict s r = .differs := by
  unfold adoptProposal; by_cases hd : shownVerdict s r = .differs <;> simp [hd]

/-- a `differs` verdict means the view is usable and consistent -/
theorem differs_usable {rec : List Key} {r : Read} (h : verdict rec r = .differs) : r.usable ∧ r.consistent = true := by
  by_cases hu : r.usable
  · by_cases hc : r.consistent = true
    · exact ⟨hu, hc⟩
    · have hc' : r.consistent = false := by simpa using hc
      rw [verdict_incons rec hc'] at h; cases h
  · rw [verdict_unusable rec hu] at h; cases h

/-- THE CONTRACT of the button.  The proposal exists only when the shown verdict is `differs` (so the view is usable and consistent);
it is a permutation of the record (nothing gained or lost, no duplicate); the off-bar keys keep their order; judged against the same
view it is never `differs`, and it matches the bar that view pins. -/
theorem adoptProposal_spec {s : State} {r : Read} {L : List Key} (hnd : s.record.Nodup) (h : adoptProposal s r = some L) :
    shownVerdict s r = .differs ∧ (s.view r).usable ∧ (s.view r).consistent = true ∧
    L.Perm s.record ∧ L.Nodup ∧ verdict L (s.view r) ≠ .differs ∧
    barMatches L ⟨(s.view r).pinOpen, dd (s.view r).pinBehind⟩ := by
  obtain ⟨hd, hL⟩ := adoptProposal_some h
  have hv : verdict s.record (s.view r) = .differs := hd
  obtain ⟨hu, hc⟩ := differs_usable hv
  subst hL
  exact ⟨hd, hu, hc, adoptRecord_perm hc hnd, adoptRecord_nodup hc hnd, adoptRecord_verdict_ne_differs hu hc hnd,
    adoptRecord_matches_pinned hu hc hnd⟩

/-- a forced mismatch needs a pinned OPEN key in the record (without one both comparisons are empty) -/
theorem forcedBad_open {rec : List Key} {r : Read} (h : forcedBad rec r = true) : ∃ y ∈ rec, r.pinOpen.contains y = true := by
  refine Classical.byContradiction fun hno => ?_
  have hn : ∀ y ∈ rec, r.pinOpen.contains y = false := fun y hy => by
    cases hc : r.pinOpen.contains y
    · rfl
    · exact absurd ⟨y, hy, hc⟩ hno
  have h1 : rec.filter (fun k => r.pinOpen.contains k) = [] := by
    rw [List.filter_eq_nil_iff]; intro k hk hh; rw [hn k hk] at hh; exact absurd hh (by decide)
  have h2 : r.pinOpen.filter (fun k => rec.contains k) = [] := by
    rw [List.filter_eq_nil_iff]; intro k hk hck
    have hk' : k ∈ rec := List.contains_iff_mem.mp hck
    have := hn k hk'
    simp [List.contains_iff_mem, hk] at this
  have h3 : rec.any (fun x => r.pinBehind.contains x && rec.any (fun y => r.pinOpen.contains y && rec.idxOf y < rec.idxOf x)) = false := by
    rw [List.any_eq_false]; intro x hx hh
    rw [Bool.and_eq_true] at hh
    have h4 := hh.2
    rw [List.any_eq_true] at h4
    obtain ⟨y, hy, hy2⟩ := h4
    rw [Bool.and_eq_true, hn y hy] at hy2
    exact absurd hy2.1 (by decide)
  unfold forcedBad at h
  rw [h1, h2, h3] at h
  simp at h

/-- THE HONEST ANSWER (no "can't tell"). Whenever the button offers a proposal, the verdict of the adopted record against the same view is
`matches` or `matchesExcept U`: never `differs` and never `cannotTell`.  (A `differs` needs a pinned open key in the record, which makes every
free listed key a possible clash, so no two keys are left that clash only with each other.) -/
theorem adoptProposal_no_cannotTell {s : State} {r : Read} {L : List Key} (hnd : s.record.Nodup) (h : adoptProposal s r = some L) :
    verdict L (s.view r) = .matches ∨ ∃ U, verdict L (s.view r) = .matchesExcept U := by
  obtain ⟨hd, hL⟩ := adoptProposal_some h
  have hv : verdict s.record (s.view r) = .differs := hd
  obtain ⟨hu, hc⟩ := differs_usable hv
  have hfb : forcedBad s.record (s.view r) = true := by
    refine Classical.byContradiction fun hf => ?_
    have hf' : forcedBad s.record (s.view r) = false := by simpa using hf
    rw [verdict_else _ hu hc hf'] at hv
    split at hv <;> (try split at hv) <;> simp at hv
  obtain ⟨y, hy, hyo⟩ := forcedBad_open hfb
  subst hL
  have hym : y ∈ adoptRecord s.record (s.view r) := (adoptRecord_mem hc hnd).mpr hy
  have hR : Rcomp (adoptRecord s.record (s.view r)) (s.view r) = [] := by
    unfold Rcomp
    rw [List.filter_eq_nil_iff]
    intro k hk
    have hk' := List.mem_filter.mp hk
    have hb := hk'.2
    have hpart : (Ucomp (adoptRecord s.record (s.view r)) (s.view r)).contains k = true := by
      rw [List.contains_iff_mem]
      unfold Ucomp
      rw [List.mem_filter]
      refine ⟨hk'.1, ?_⟩
      have hf := hk'.2
      simp only [Bool.and_eq_true] at hf
      simp only [party, Bool.and_eq_true, List.any_eq_true]
      exact ⟨hf, y, hym, by rw [hyo]; rfl⟩
    rw [hpart]; decide
  rw [adoptRecord_verdict hu hc hnd, hR]
  simp only [List.length_nil]
  by_cases hU : (Ucomp (adoptRecord s.record (s.view r)) (s.view r)).isEmpty = true
  · left; simp [hU]
  · right; exact ⟨Ucomp (adoptRecord s.record (s.view r)) (s.view r), by simp [hU]⟩

end

/-! ### Examples -/

/-- keys 4, 2 behind «; 5, 3, 1 open; 6 and 7 not on the bar -/
def adoptExRead : Read :=
  { kind := .pass, chevron := .fresh, level := .complete, settled := true, stripOpen := false, drawn := [5, 3, 1], pile := [],
    folded := [4, 2], trusted := [5, 3, 1], nearFold := [], observed := true, unread := [], notFullProven := false }

example : adoptRecord [1, 2, 7, 3, 4, 5, 6] adoptExRead = [4, 2, 7, 5, 3, 1, 6] := by decide
example : verdict [1, 2, 7, 3, 4, 5, 6] adoptExRead = .differs := by decide
example : verdict (adoptRecord [1, 2, 7, 3, 4, 5, 6] adoptExRead) adoptExRead = .matches := by decide
/-- an unread key set aside: matches except it -/
example : verdict (adoptRecord [1, 2, 7, 3, 4, 5, 6] { adoptExRead with unread := [6] }) { adoptExRead with unread := [6] }
    = .matchesExcept [6] := by decide
/-- a record that already agrees is returned unchanged -/
example : adoptRecord [4, 2, 5, 3, 1] adoptExRead = [4, 2, 5, 3, 1] := by decide

end Sommelier
