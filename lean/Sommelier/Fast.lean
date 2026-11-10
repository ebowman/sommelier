import Sommelier.Honesty

/-!
# Fast versions of the decision functions, PROVED EQUAL to the specification

The specification (`Step.lean`, `Truth.lean`, `Status.lean`) is written to be read, not to be fast: `fallbackMove` scores about seventy candidate
drags by recounting every inversion (a call is about 22 ms on a 36-key record), and `rowLine` reaches it through `decideMove` for every row.
This file adds fast versions and proves them EQUAL to the specification, extensionally, for all states and reads (no hypothesis restricts
an input).  No definition or theorem of another file is changed; `Ffi.lean` exports the fast versions, and `stepTokF_eq` & co. say that the
exported functions compute the proved ones.

Two kinds of change, both covered by an equality theorem:
* hoisting: a value the specification recomputes inside a closure (`movable s r`, `r.pinOpen`, ...) is computed once (equal by `rfl`/unfolding);
* the fallback: the inversion count of the bar after dragging `k` is `invs M + cost i`, where `M` is the movable record keys without `k` and `i` the
  place the drag takes `k` to; `cost` is read off one scan.  When `r.drawn` has a repeated key the fast path is not taken (the specification runs),
  so the equality needs no hypothesis.
-/

namespace Sommelier

/-! ### Counting inversions of a list of positions -/

/-- Inversions of a list of positions: pairs `x ... y` with `y < x`. -/
def invN : List Nat → Nat
  | [] => 0
  | x :: xs => (xs.filter (fun y => decide (y < x))).length + invN xs

theorem invs_eq_invN (rec : List Key) : ∀ L : List Key, invs rec L = invN (L.map rec.idxOf)
  | [] => rfl
  | x :: xs => by
    have ih := invs_eq_invN rec xs
    simp only [invs, invN, List.map_cons, ih]
    congr 1
    rw [List.filter_map]
    simp [Function.comp_def]

/-! ### The cost of putting `k` at place `i` among the other keys -/

/-- Number of positions above / below `pk` in a list. -/
def gtN (pk : Nat) (P : List Nat) : Nat := (P.filter (fun y => decide (pk < y))).length
def ltN (pk : Nat) (P : List Nat) : Nat := (P.filter (fun y => decide (y < pk))).length

/-- `costScan pk P g l` lists, for `i = 0 .. |P|`, `g + gtN pk (P.take i) + ltN pk (P.drop i)` (when `l = ltN pk P`): the inversions `k` makes with the
others when put at place `i`.  One pass. -/
def costScan (pk : Nat) : List Nat → Nat → Nat → List Nat
  | [], g, l => [g + l]
  | y :: ys, g, l => (g + l) :: costScan pk ys (g + (if pk < y then 1 else 0)) (l - (if y < pk then 1 else 0))

theorem costScan_get (pk : Nat) : ∀ (P : List Nat) (g l : Nat), l = ltN pk P → ∀ i, i ≤ P.length →
    (costScan pk P g l).getD i 0 = g + gtN pk (P.take i) + ltN pk (P.drop i)
  | [], g, l, hl, i, hi => by
    have : i = 0 := by simpa using hi
    subst this
    simp [costScan, ltN, gtN] at hl ⊢
    omega
  | y :: ys, g, l, hl, i, hi => by
    cases i with
    | zero => simp [costScan, gtN, hl]
    | succ i =>
      have hl' : l - (if y < pk then 1 else 0) = ltN pk ys := by
        simp only [ltN, List.filter_cons] at hl ⊢
        by_cases h : y < pk <;> simp [h] at hl ⊢ <;> omega
      have ih := costScan_get pk ys (g + (if pk < y then 1 else 0)) _ hl' i (by simpa using hi)
      simp only [costScan, List.getD_cons_succ, ih, List.take_succ_cons, List.drop_succ_cons, gtN, List.filter_cons]
      by_cases h : pk < y <;> simp [h] <;> omega

theorem idxOf_split (t : Key) : ∀ (pre post : List Key), t ∉ pre → (pre ++ t :: post).idxOf t = pre.length
  | [], post, _ => by simp
  | x :: pre, post, h => by
    have hx : x ≠ t := fun e => h (by simp [e])
    have ih := idxOf_split t pre post (fun hh => h (List.mem_cons_of_mem _ hh))
    simp [List.idxOf_cons, hx, ih]

/-! ### `argmin` evaluated once per candidate, and independent of how the score is computed -/

/-- The first minimum of `f`, with its value; `f` is evaluated once per candidate. -/
def argminV (f : Rel → Nat) (l : List Rel) : Option (Rel × Nat) :=
  l.foldl (fun acc x =>
    let v := f x
    match acc with
    | none => some (x, v)
    | some (b, bv) => if v < bv then some (x, v) else acc) none

theorem argminV_aux (f : Rel → Nat) : ∀ (l : List Rel) (acc : Option Rel),
    l.foldl (fun acc x =>
      let v := f x
      match acc with
      | none => some (x, v)
      | some (b, bv) => if v < bv then some (x, v) else acc) (acc.map (fun b => (b, f b)))
    = (l.foldl (fun acc x => match acc with
        | none => some x
        | some b => if f x < f b then some x else acc) acc).map (fun b => (b, f b))
  | [], acc => rfl
  | x :: l, acc => by
    simp only [List.foldl_cons]
    cases acc with
    | none => exact argminV_aux f l (some x)
    | some b =>
      simp only [Option.map_some]
      by_cases h : f x < f b
      · simp only [h, ite_true]; exact argminV_aux f l (some x)
      · simp only [h, ite_false]; exact argminV_aux f l (some b)

theorem argminV_eq (f : Rel → Nat) (l : List Rel) : argminV f l = (argmin f l).map (fun b => (b, f b)) :=
  argminV_aux f l none

theorem argmin_congr (f g : Rel → Nat) : ∀ (l : List Rel) (acc : Option Rel), (∀ x ∈ l, f x = g x) →
    (∀ b, acc = some b → f b = g b) →
    l.foldl (fun acc x => match acc with
        | none => some x
        | some b => if f x < f b then some x else acc) acc
    = l.foldl (fun acc x => match acc with
        | none => some x
        | some b => if g x < g b then some x else acc) acc
  | [], acc, _, _ => rfl
  | x :: l, acc, hl, ha => by
    simp only [List.foldl_cons]
    have hx : f x = g x := hl x (List.mem_cons_self)
    have hl' : ∀ y ∈ l, f y = g y := fun y hy => hl y (List.mem_cons_of_mem _ hy)
    cases acc with
    | none => exact argmin_congr f g l (some x) hl' (fun b hb => by cases hb; exact hx)
    | some b =>
      have hb := ha b rfl
      simp only [hx, hb]
      by_cases h : g x < g b
      · simp only [h, ite_true]; exact argmin_congr f g l (some x) hl' (fun c hc => by cases hc; exact hx)
      · simp only [h, ite_false]; exact argmin_congr f g l (some b) hl' (fun c hc => by cases hc; exact hb)

theorem argmin_congr' (f g : Rel → Nat) (l : List Rel) (h : ∀ x ∈ l, f x = g x) : argmin f l = argmin g l :=
  argmin_congr f g l none h (fun b hb => by cases hb)

/-- 0 / 1: the place a drag puts `k` relative to the target's place among the others -/
def relOff : Rel → Nat | .before _ => 0 | .after _ => 1

/-! ### The inversion count after a drag of `k` -/

/-- the keys a drag may name: movable and in the record -/
def kp (hv rec : List Key) (x : Key) : Bool := hv.contains x && rec.contains x

/-- the movable record keys of the bar, without `k` -/
def mkM (hv rec D : List Key) (k : Key) : List Key := (D.filter (kp hv rec)).filter (fun x => x != k)

theorem afterCount_eq (s : State) (r : Read) (k : Key) (hnd : r.drawn.Nodup) (hkm : k ∈ movable s r) (hkr : k ∈ s.record)
    (rel : Rel) (ht1 : rel.target ∈ movable s r) (ht2 : rel.target ∈ s.record) (ht3 : rel.target ≠ k) :
    afterCount s r k rel =
      invN ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf)
      + (costScan (s.record.idxOf k) ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf) 0
          (ltN (s.record.idxOf k) ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf))).getD
        ((mkM (movable s r) s.record r.drawn k).idxOf rel.target + relOff rel) 0 := by
  have hkK : kp (movable s r) s.record k = true := by
    simp [kp, List.contains_iff_mem, hkm, hkr]
  have htK : kp (movable s r) s.record rel.target = true := by
    simp [kp, List.contains_iff_mem, ht1, ht2]
  have e1 : afterCount s r k rel = invs s.record ((applyMove r.drawn ⟨k, rel, false, true⟩).filter (kp (movable s r) s.record)) := rfl
  rw [e1, applyMove_filter (kp (movable s r) s.record) r.drawn ⟨k, rel, false, true⟩ hkK htK]
  generalize hLk : r.drawn.filter (kp (movable s r) s.record) = Lk
  have hM : mkM (movable s r) s.record r.drawn k = Lk.filter (fun x => x != k) := by
    rw [← hLk]; rfl
  rw [hM]
  have hLkn : Lk.Nodup := by rw [← hLk]; exact hnd.sublist List.filter_sublist
  have hMn : (Lk.filter (fun x => x != k)).Nodup := hLkn.sublist List.filter_sublist
  have htD : rel.target ∈ r.drawn := by unfold movable at ht1; exact (List.mem_filter.1 ht1).1
  have htmem : rel.target ∈ Lk.filter (fun x => x != k) := by
    rw [← hLk]
    simp only [List.mem_filter, bne_iff_ne, ne_eq, decide_eq_true_eq]
    exact ⟨⟨htD, htK⟩, ht3⟩
  obtain ⟨pre, post, hsplit⟩ := List.append_of_mem htmem
  have hn : (pre ++ rel.target :: post).Nodup := hsplit ▸ hMn
  have hnd' := List.nodup_append.1 hn
  have htpre : rel.target ∉ pre := fun h => hnd'.2.2 _ h _ (by simp) rfl
  have hL : Lk.filter (fun x => x != k) = pre ++ rel.target :: post := hsplit
  rw [hsplit]
  have hsp := applyMove_split Lk pre post rel.target k hL hn false true
  have hlen : (pre.map s.record.idxOf).length = pre.length := List.length_map ..
  have hP : (pre ++ rel.target :: post).map s.record.idxOf = pre.map s.record.idxOf ++ s.record.idxOf rel.target :: post.map s.record.idxOf := by
    simp
  have hbase : invs s.record (pre ++ rel.target :: post) = invN ((pre ++ rel.target :: post).map s.record.idxOf) := invs_eq_invN _ _
  rw [idxOf_split rel.target pre post htpre, hP]
  have hgt : ∀ L : List Key, (L.filter (fun y => decide (s.record.idxOf k < s.record.idxOf y))).length = gtN (s.record.idxOf k) (L.map s.record.idxOf) := by
    intro L; simp only [gtN, List.filter_map]; simp [Function.comp_def]
  have hlt : ∀ L : List Key, (L.filter (fun y => decide (s.record.idxOf y < s.record.idxOf k))).length = ltN (s.record.idxOf k) (L.map s.record.idxOf) := by
    intro L; simp only [ltN, List.filter_map]; simp [Function.comp_def]
  cases rel with
  | before t =>
    simp only [Rel.target] at *
    rw [hsp.1, invs_split, hbase, hP, hgt, hlt]
    have hcs := costScan_get (s.record.idxOf k) (pre.map s.record.idxOf ++ s.record.idxOf t :: post.map s.record.idxOf) 0
      (ltN (s.record.idxOf k) (pre.map s.record.idxOf ++ s.record.idxOf t :: post.map s.record.idxOf)) rfl pre.length
      (by simp)
    simp only [relOff, Nat.add_zero]
    rw [hcs, List.take_left' hlen, List.drop_left' hlen]
    simp only [List.map_cons]
    omega
  | after t =>
    simp only [Rel.target] at *
    have hP2 : (pre ++ t :: post).map s.record.idxOf = (pre.map s.record.idxOf ++ [s.record.idxOf t]) ++ post.map s.record.idxOf := by simp
    have hlen2 : (pre.map s.record.idxOf ++ [s.record.idxOf t]).length = pre.length + 1 := by simp
    have e2 : pre ++ t :: k :: post = (pre ++ [t]) ++ k :: post := by simp
    have e3 : pre ++ [t] ++ post = pre ++ t :: post := by simp
    rw [hsp.2, e2, invs_split, e3, hbase, hgt, hlt, hP]
    have hcs := costScan_get (s.record.idxOf k) (pre.map s.record.idxOf ++ s.record.idxOf t :: post.map s.record.idxOf) 0
      (ltN (s.record.idxOf k) (pre.map s.record.idxOf ++ s.record.idxOf t :: post.map s.record.idxOf)) rfl (pre.length + 1)
      (by simp)
    have hl : pre.map s.record.idxOf ++ s.record.idxOf t :: post.map s.record.idxOf
        = (pre.map s.record.idxOf ++ [s.record.idxOf t]) ++ post.map s.record.idxOf := by simp
    rw [hl] at hcs ⊢
    simp only [relOff]
    rw [hcs, List.take_left' hlen2, List.drop_left' hlen2]
    simp only [List.map_append, List.map_cons, List.map_nil]
    omega

theorem cands_target (s : State) (r : Read) (k : Key) {rel : Rel} (h : rel ∈ fallbackCands s r k) :
    rel.target ∈ movable s r ∧ rel.target ∈ s.record ∧ rel.target ≠ k := by
  unfold fallbackCands at h
  rcases List.mem_append.1 h with h | h
  · have : fallbackRel s r k = some rel := by
      cases hf : fallbackRel s r k with
      | none => simp [hf] at h
      | some q => simp [hf] at h; rw [h]
    exact fallbackRel_target this
  · simp only [List.mem_flatMap, List.mem_filter, Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem, decide_eq_true_eq] at h
    obtain ⟨t, ⟨ht1, ht3, ht2⟩, hr⟩ := h
    have : rel.target = t := by
      rcases List.mem_cons.1 hr with rfl | hr
      · rfl
      · rcases List.mem_cons.1 hr with rfl | hr
        · rfl
        · simp at hr
    rw [this]
    exact ⟨ht1, ht2, ht3⟩

theorem penalty_eq (s : State) (r : Read) (k : Key) (rel : Rel) :
    penalty s r k rel =
      if r.drawn.idxOf rel.target < r.drawn.idxOf k
      then ((freeKeys s r).filter (fun y => decide (s.record.idxOf y < s.record.idxOf k))).length
      else ((freeKeys s r).filter (fun y => decide (s.record.idxOf k < s.record.idxOf y))).length := by
  unfold penalty leftward
  by_cases h : r.drawn.idxOf rel.target < r.drawn.idxOf k <;> simp [h]

/-- `freeKeys` with `movable s r` and the folded set computed once (a `let` used once under a lambda is inlined back, so the lists are arguments). -/
@[noinline] def freeKeysH (rec hv D pile folded unread : List Key) (fresh : Bool) (fs : List Key) : List Key :=
  rec.filter (fun x => (D.contains x || pile.contains x || folded.contains x || unread.contains x) && !hv.contains x && !(fresh && fs.contains x))

def freeKeysF (s : State) (r : Read) : List Key :=
  freeKeysH s.record (movable s r) r.drawn r.pile r.folded r.unread (r.chevron == .fresh) r.foldedSet

theorem freeKeysF_eq (s : State) (r : Read) : freeKeysF s r = freeKeys s r := rfl

/-- the score of a candidate drag, from the precomputed pieces -/
def fbScore (base : Nat) (cs : List Nat) (M D : List Key) (kd pl pr : Nat) (rel : Rel) : Nat :=
  base + cs.getD (M.idxOf rel.target + relOff rel) 0 + (if D.idxOf rel.target < kd then pl else pr)

def pickF (k : Key) (st : Rel → Bool) (T : Nat) : Option (Rel × Nat) → Option Action
  | some (rel, v) => if v < T then some ⟨k, rel, st rel, true⟩ else none
  | none => none

theorem pickF_eq (k : Key) (st : Rel → Bool) (T : Nat) (f W : Rel → Nat) (opt : Option Rel)
    (h : ∀ b, opt = some b → f b = W b) :
    pickF k st T (opt.map (fun b => (b, f b))) =
      (opt.map (fun rel => (⟨k, rel, st rel, true⟩ : Action))).filter (fun a => decide (W a.rel < T)) := by
  cases opt with
  | none => rfl
  | some b =>
    have hb := h b rfl
    simp only [Option.map_some, pickF, Option.filter, hb]
    by_cases hl : W b < T <;> simp [hl]

/-- THE FAST FALLBACK.  Same rule as `fallbackMove`; the score of a candidate is read off one scan (`costScan`) instead of recounting the bar, and is
evaluated once.  A bar that lists a key twice takes the specification's own path (the fast path needs each key once). -/
def fallbackMoveF (s : State) (r : Read) (k : Key) : Option Action :=
  let hv := movable s r
  if s.owedKeys.contains k && s.record.contains k && hv.contains k && misplaced s r k then
    if r.drawn.Nodup then
      let M := mkM hv s.record r.drawn k
      let P := M.map s.record.idxOf
      let pk := s.record.idxOf k
      let fr := freeKeysF s r
      pickF k (needsStrip s r k) (invN ((r.drawn.filter (kp hv s.record)).map s.record.idxOf))
        (argminV (fbScore (invN P) (costScan pk P 0 (ltN pk P)) M r.drawn (r.drawn.idxOf k)
          ((fr.filter (fun y => decide (s.record.idxOf y < pk))).length)
          ((fr.filter (fun y => decide (pk < s.record.idxOf y))).length)) (fallbackCands s r k))
    else
      ((argmin (worstCount s r k) (fallbackCands s r k)).map (fun rel => (⟨k, rel, needsStrip s r k rel, true⟩ : Action))).filter
        (fun a => decide (worstCount s r k a.rel < invCount s r r.drawn))
  else none

theorem fallbackMoveF_eq (s : State) (r : Read) (k : Key) : fallbackMoveF s r k = fallbackMove s r k := by
  unfold fallbackMoveF fallbackMove
  by_cases hc : (s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k) = true
  · rw [if_pos hc, if_pos hc]
    by_cases hn : r.drawn.Nodup
    · rw [if_pos hn]
      have hc' := hc
      simp only [Bool.and_eq_true, List.contains_iff_mem] at hc'
      obtain ⟨⟨⟨_, hkr⟩, hkm⟩, _⟩ := hc'
      have hf : ∀ rel ∈ fallbackCands s r k, worstCount s r k rel =
          fbScore (invN ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf))
            (costScan (s.record.idxOf k) ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf) 0
              (ltN (s.record.idxOf k) ((mkM (movable s r) s.record r.drawn k).map s.record.idxOf)))
            (mkM (movable s r) s.record r.drawn k) r.drawn (r.drawn.idxOf k)
            (((freeKeys s r).filter (fun y => decide (s.record.idxOf y < s.record.idxOf k))).length)
            (((freeKeys s r).filter (fun y => decide (s.record.idxOf k < s.record.idxOf y))).length) rel := by
        intro rel hrel
        obtain ⟨h1, h2, h3⟩ := cands_target s r k hrel
        unfold worstCount
        rw [afterCount_eq s r k hn hkm hkr rel h1 h2 h3, penalty_eq]
        rfl
      have hcg := argmin_congr' (worstCount s r k) _ (fallbackCands s r k) hf
      have htot : invCount s r r.drawn = invN ((r.drawn.filter (kp (movable s r) s.record)).map s.record.idxOf) := by
        rw [← invs_eq_invN]; rfl
      dsimp only
      simp only [freeKeysF_eq]
      rw [argminV_eq, ← hcg, htot]
      refine pickF_eq k (needsStrip s r k) _ _ (worstCount s r k) _ ?_
      intro b hb
      exact (hf b (argmin_spec hb).1).symm
    · rw [if_neg hn]
  · rw [if_neg hc, if_neg hc]

/-! ### The gate, the verdicts: the same definitions with the shared values computed once

The specification recomputes `r.pinBehind`, `movable s r`, ... inside the closure it filters with, once per element.  A value bound by `let` and used
once under a lambda is inlined back by the compiler, so the shared lists are passed as arguments to `@[noinline]` helpers (the lists are then
computed once by the caller).  Each helper is the specification's expression with the lists as parameters; the equalities are `rfl` except `nodupB`. -/

/-- `decide l.Nodup`, without the generic decision procedure. -/
@[noinline] def nodupB : List Key → Bool
  | [] => true
  | x :: xs => !xs.contains x && nodupB xs

theorem nodupB_eq : ∀ l : List Key, nodupB l = decide l.Nodup
  | [] => by simp [nodupB]
  | x :: xs => by
    have ih := nodupB_eq xs
    by_cases h : x ∈ xs <;> simp [nodupB, ih, List.nodup_cons, h]

/-- no pinned-open key is also pinned behind -/
@[noinline] def allNotIn (po pb : List Key) : Bool := po.all (fun k => !pb.contains k)

/-- `Read.consistent` with `pinOpen` and `pinBehind` computed once. -/
def Read.consistentF (r : Read) : Bool :=
  let po := r.pinOpen
  let pb := r.pinBehind
  nodupB po && allNotIn po pb

theorem consistentF_eq (r : Read) : r.consistentF = r.consistent := by
  unfold Read.consistentF Read.consistent allNotIn
  simp only [nodupB_eq]

def State.gateF (s : State) (r : Read) : Bool := decide (s.view r).usable && (s.view r).consistentF

theorem gateF_eq (s : State) (r : Read) : s.gateF r = s.gate r := by
  unfold State.gateF State.gate; rw [consistentF_eq]

/-- a record key `y` before `k` and pinned open -/
@[noinline] def anyBefore (rec bef po : List Key) : Bool := rec.any (fun y => bef.contains y && po.contains y)

/-- some other pinned open key stands on the other side of `k` in the record than on the bar -/
@[noinline] def anyCrossed (rec bef po : List Key) (k : Key) (pk : Nat) : Bool :=
  rec.any (fun x => x != k && po.contains x && (decide (x ∈ bef) != decide (po.idxOf x < pk)))

/-- `rowVerdict` with the pinned lists, the record prefix before `k` and `k`'s place computed once. -/
def rowVerdictF (rec : List Key) (r : Read) (k : Key) : RowVerdict :=
  let po := r.pinOpen
  let pb := r.pinBehind
  if !(nodupB po && allNotIn po pb) then .cannotTell
  else if pb.contains k then
    if anyBefore rec (rec.takeWhile (fun z => z != k)) po then .behindOutOfTurn
    else .behindChevron
  else if po.contains k then
    if anyCrossed rec (rec.takeWhile (fun z => z != k)) po k (po.idxOf k) then .outOfPlace
    else .inOrder
  else if r.openOK k then .cannotTell
  else .notOnBar

theorem rowVerdictF_eq (rec : List Key) (r : Read) (k : Key) : rowVerdictF rec r k = rowVerdict rec r k := by
  unfold rowVerdictF rowVerdict Read.consistent anyBefore anyCrossed allNotIn
  simp only [nodupB_eq]

/-- the pinned keys alone break the match -/
@[noinline] def forcedBadB (rec po pb : List Key) : Bool :=
  rec.filter (fun k => po.contains k) != po.filter (fun k => rec.contains k) ||
    rec.any (fun x => pb.contains x && (let ix := rec.idxOf x; rec.any (fun y => po.contains y && decide (rec.idxOf y < ix))))

/-- `r.free k && r.openOK k` -/
@[noinline] def freeOpen (po pb : List Key) (us : Bool) (r : Read) (k : Key) : Bool :=
  (!po.contains k && !pb.contains k) && (!us || decide (r.listed k))

/-- the free listed record keys that can clash with a pinned record key -/
@[noinline] def partyU (rec po pb : List Key) (us : Bool) (r : Read) : List Key :=
  rec.filter (fun k => freeOpen po pb us r k && (let ik := rec.idxOf k; rec.any (fun y => po.contains y || (pb.contains y && decide (ik < rec.idxOf y)))))

/-- the free listed record keys that clash with nothing else -/
@[noinline] def partyR (rec po pb : List Key) (us : Bool) (r : Read) (U : List Key) : List Key :=
  (rec.filter (fun k => freeOpen po pb us r k)).filter (fun k => !U.contains k)

/-- `verdict` with the pinned lists, `r.usable` and the record places computed once. -/
def verdictF (rec : List Key) (r : Read) : Verdict :=
  let po := r.pinOpen
  let pb := r.pinBehind
  let us := decide r.usable
  if !us || !(nodupB po && allNotIn po pb) then .cannotTell
  else if forcedBadB rec po pb then .differs
  else
    let U := partyU rec po pb us r
    let R := partyR rec po pb us r U
    if R.length ≥ 2 then .cannotTell
    else if U.isEmpty then .matches
    else .matchesExcept U

theorem verdictF_eq (rec : List Key) (r : Read) : verdictF rec r = verdict rec r := by
  unfold verdictF verdict Read.consistent forcedBadB forcedBad partyU partyR freeOpen allNotIn
  simp only [nodupB_eq]
  rfl

def shownVerdictF (s : State) (r : Read) : Verdict := verdictF s.record (s.view r)

theorem shownVerdictF_eq (s : State) (r : Read) : shownVerdictF s r = shownVerdict s r := by
  unfold shownVerdictF shownVerdict; rw [verdictF_eq]

/-! ### The decision chain: `userMove`, `userPick`, `decideMove`, `step`, the status and the rows, on the fast fallback and gate -/

def userMoveF (s : State) (r : Read) (k : Key) : Option Action :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩
  if (foldedAll s r).contains k then
    if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then
      (((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))).filter
        (fun a => applyMove r.drawn a != r.drawn)
    else none
  else if hv.contains k then
    match anchorMove s r k with
    | some a => some a
    | none => fallbackMoveF s r k
  else none

theorem userMoveF_eq (s : State) (r : Read) (k : Key) : userMoveF s r k = userMove s r k := by
  unfold userMoveF userMove
  simp only [fallbackMoveF_eq]
  rfl

def userMove2F (s : State) (r : Read) (k : Key) : Option Action :=
  if (userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k then fallbackMoveF s r k else none

theorem userMove2F_eq (s : State) (r : Read) (k : Key) : userMove2F s r k = userMove2 s r k := by
  unfold userMove2F userMove2
  simp only [fallbackMoveF_eq]

def userPickF (s : State) (r : Read) : Option Action :=
  match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove1 s r k).filter (userAllowed s r)) with
  | some a => some a
  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2F s r k).filter (userAllowed s r))

theorem userPickF_eq (s : State) (r : Read) : userPickF s r = userPick s r := by
  unfold userPickF userPick
  simp only [userMove2F_eq]
  rfl

def decideMove0F (s : State) (r : Read) : Option Action :=
  if r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gateF r then none
  else
    match userPickF s r with
    | some a => some a
    | none =>
      if !engineAllowed s r then none
      else match planOrderMoves s r with
        | some a =>
            if a.strip then
              (if s.stripGrant then some { a with user := true } else none)
            else some a
        | none => none

theorem decideMove0F_eq (s : State) (r : Read) : decideMove0F s r = decideMove0 s r := by
  unfold decideMove0F decideMove0
  simp only [gateF_eq, userPickF_eq]
  rfl

/-- `judge` with the fast gate. -/
def judgeF (s : State) (r : Read) : State :=
  match s.verified with
  | none => s
  | some k =>
      if s.inFlight.isNone && s.gateF r then
        (if verFailed s r k then markStrike { s with verified := none } k else { s with verified := none })
      else s

theorem judgeF_eq (s : State) (r : Read) : judgeF s r = judge s r := by
  unfold judgeF judge
  cases hv : s.verified with
  | none => rfl
  | some k => simp only [gateF_eq]

def decideMoveF (s : State) (r : Read) : Option Action := decideMove0F (judgeF s r) r

theorem decideMoveF_eq (s : State) (r : Read) : decideMoveF s r = decideMove s r := by
  unfold decideMoveF decideMove
  rw [judgeF_eq, decideMove0F_eq]

def stepF (s : State) : Event → State × List Action
  | .read r =>
      let s' := noteRead (judgeF s r) r
      match decideMoveF s r with
      | none => (s', [])
      | some a => (emit s' a, [a])
  | e => step s e

theorem stepF_eq (s : State) (e : Event) : stepF s e = step s e := by
  cases e with
  | read r => simp only [stepF, step, decideMoveF_eq, judgeF_eq]; rfl
  | userEdit rec moved => rfl
  | userRetry => rfl
  | retryKey k => rfl
  | moveResult k o p => rfl
  | passBoundary => rfl

def pendingF (s : State) (r : Read) : Bool := s.inFlight.isSome || (decideMoveF s r).isSome

theorem pendingF_eq (s : State) (r : Read) : pendingF s r = pending s r := by
  unfold pendingF pending; rw [decideMoveF_eq]

/-- `enginePlan` with the fast gate, `judge` and queue pick. -/
def enginePlanF (s : State) (r : Read) : Option Action :=
  let j := judgeF s r
  if r.kind != .pass || !r.settled || r.level == .incomplete || j.inFlight.isSome || !j.gateF r then none
  else match userPickF j r with
    | some _ => none
    | none => if !engineAllowed j r then none else planOrderMoves j r

theorem enginePlanF_eq (s : State) (r : Read) : enginePlanF s r = enginePlan s r := by
  unfold enginePlanF enginePlan
  simp only [judgeF_eq, gateF_eq, userPickF_eq]
  rfl

def withheldStripF (s : State) (r : Read) : Option Key :=
  match enginePlanF s r with
  | some a => if a.strip && !s.stripGrant then some a.subject else none
  | none => none

theorem withheldStripF_eq (s : State) (r : Read) : withheldStripF s r = withheldStrip s r := by
  unfold withheldStripF withheldStrip
  rw [enginePlanF_eq]
  rfl

def whyDiffersF (s : State) (r : Read) : Why :=
  if budgetSpent s r then .stopped else if s.hold then .barFull
  else match withheldStripF s r with
    | some k => .needsReapply k
    | none => .plain

theorem whyDiffersF_eq (s : State) (r : Read) : whyDiffersF s r = whyDiffers s r := by
  unfold whyDiffersF whyDiffers
  rw [withheldStripF_eq]
  rfl

def statusLineF (s : State) (r : Read) : Status :=
  if pendingF s r then .moving
  else match shownVerdictF s r with
    | .matches => .matches
    | .matchesExcept U => .matchesExcept U
    | .differs => .differs (whyDiffersF s r)
    | .cannotTell => .checking

theorem statusLineF_eq (s : State) (r : Read) : statusLineF s r = statusLine s r := by
  unfold statusLineF statusLine
  rw [pendingF_eq, shownVerdictF_eq, whyDiffersF_eq]
  rfl

def movingKeyF (s : State) (r : Read) (k : Key) : Bool :=
  s.inFlight.any (fun a => a.subject == k) || (decideMoveF s r).any (fun a => a.subject == k)

theorem movingKeyF_eq (s : State) (r : Read) (k : Key) : movingKeyF s r k = movingKey s r k := by
  unfold movingKeyF movingKey; rw [decideMoveF_eq]

def waitingKeyF (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (!s.gateF r || (userMoveF s r k).isSome)

theorem waitingKeyF_eq (s : State) (r : Read) (k : Key) : waitingKeyF s r k = waitingKey s r k := by
  unfold waitingKeyF waitingKey; rw [gateF_eq, userMoveF_eq]

def rowLineF (s : State) (r : Read) (k : Key) : RowLine :=
  if movingKeyF s r k then .moving
  else if waitingKeyF s r k then .waiting
  else (rowVerdictF s.record (s.view r) k).line

theorem rowLineF_eq (s : State) (r : Read) (k : Key) : rowLineF s r k = rowLine s r k := by
  unfold rowLineF rowLine
  rw [movingKeyF_eq, waitingKeyF_eq, rowVerdictF_eq]

/-- The note beside a row, from the fast versions of everything `rowNote` calls that is costly (`rowLineF`, `fallbackMoveF`, `userPickF`, `decideMoveF`). -/
def rowNoteF (s : State) (r : Read) (k : Key) : Option RowNote :=
  if rowLineF s r k == .notWherePut && owedNow s k then
    if (movable s r).contains k && s.owedKeys.contains k && s.record.contains k && wholeBar s r && misplaced s r k
        && (fallbackMoveF s r k).isNone && (userPickF s r).isNone then
      some .noMoveHelps
    else if (movable s r).contains k && s.owedKeys.contains k && s.record.contains k && !wholeBar s r && misplaced s r k
        && (fallbackMoveF s r k).isNone && (decideMoveF s r).isNone then
      some .cantJudge
    else some .noMoveHere
  else none

theorem rowNoteF_eq (s : State) (r : Read) (k : Key) : rowNoteF s r k = rowNote s r k := by
  unfold rowNoteF rowNote
  rw [rowLineF_eq, fallbackMoveF_eq, userPickF_eq, decideMoveF_eq]

/-- The fast row signal "needs Re-apply" (no hypotheses). -/
def rowReapplyF (s : State) (r : Read) (k : Key) : Bool :=
  decide (statusLineF s r = .differs (.needsReapply k)) && rowLineF s r k == .notWherePut

theorem rowReapplyF_eq (s : State) (r : Read) (k : Key) : rowReapplyF s r k = rowReapply s r k := by
  unfold rowReapplyF rowReapply
  rw [statusLineF_eq, rowLineF_eq]

end Sommelier
