import Sommelier.Model
import Sommelier.Step
import Sommelier.Eqns

/-!
# Truth: what a reading says about the REAL menu bar (statements only)

Imported by `Sommelier.lean` and covered by `scripts/check-lean-axioms.sh`: every theorem here is proved.

**What this file is, and is not.**  The Swift app does NOT yet run this model: `step`, `statusLine` and `rowLine` are a specification written
beside the app, and nothing mechanical ties the Swift code to them yet (the mapping in docs/verified-core.md is a reading, to be tested at ejb.8).
The theorems are proved about the model, from the assumptions A1, A2, A3, A6, A7 and the leftmost-folding fact of T8; those assumptions are
UNPROVED FACTS ABOUT macOS and the adapter, believed from observation, and any one of them may turn out false on a device.  A theorem here says
"if macOS behaves so, the engine shows and does this", never more.

## Plain-language spec (approved; corrective pass 3 applies user decisions D1 and D2)

1. The real bar is `Bar`: the keys macOS draws in the open, left to right (`open_`; `open` is a Lean keyword), and the keys
   folded behind the chevron (`behind`).  A key in neither is not on the bar.  `Bar.WF`: no duplicates, nothing both open and behind.
2. `Honest r b` says what we ASSUME about macOS when a reading `r` was taken of the bar `b`.  It is a conjunction of separately
   named assumptions (A1, A2, A3, A6).  A4 and A5 are not predicates, see below.  A reading constrains the bar only as far as
   those assumptions say; everything it does not constrain may be anywhere (open at any position, behind, or absent).
3. `barMatches rec b`: looking only at keys that are on the bar and in the record `rec`, (1) the open keys stand in the record's
   relative order and (2) every behind key comes before every open key in the record (macOS folds from the left).
4. `verdict rec r` is computed from the record and the reading alone: `matches` (every bar the reading allows matches),
   `differs` (no allowed bar matches), `matchesExcept U` (every allowed bar matches once the keys U, whose position the reading
   cannot establish and could change the answer, are set aside) or `cannotTell`.  "Cannot tell" is a consequence of the
   definitions, never a special case.
5. Theorems T1..T9 tie the verdicts, the per-row verdicts and the engine's moves to the truth (every allowed bar).

## User decisions built in

* D1. "No chevron" is believed only after 3 complete readings in a row without one (`Read.notFullProven`; Swift
  `LayoutEngine.fullBar`/`notFullProven`, LayoutEngine.swift:1849-1881).  Until then a chevronless read says nothing (`usable` false:
  cannot tell).  With a FRESH chevron one reading suffices.  The verdict depends on the `Read` plus that proof.
* D2. Every move, the user's drop included, is gated on a usable reading (Step.lean `State.gate`).  The drop gets its move on the
  next usable reading.  If the attempt expires (`passBoundary`), no drop memory is needed to say so: the row of the key reads
  `outOfPlace` by `rowVerdict` alone, and "Try again" exists.
* THE DROP RULE (user-approved: "a user's drop gets its move on the next good reading").  The key the user dropped is OWED.  On a read where the gate is
  true the owed key is answered from THAT read, not from what was remembered when the edit was made: (a) if the read shows it drawn and trusted, it goes to
  its place among its anchors (`userMove`, drawn case); (b) if the read lists it as folded under a fresh chevron, it is pulled out to just after the
  rightmost movable key that precedes it in the record, whether or not a fold request was made at the edit (`userMove`, folded case: the licence is
  "owed or requested, fresh chevron, THIS read lists the key folded"; the pile memory alone never licenses a drag).  On a usable fresh-chevron read
  the folded set is the read's own and supersedes the memory (`foldedAll`), so a key the memory still lists but this read shows drawn is judged as drawn.
  A folded key the user did NOT drop never gets a pull-out: the engine cannot cross the fold.  One attempt per drop (emitting the move consumes it);
  a busy result re-arms it at most once.  Proved in `Honesty.lean`: `user_drop_answered` (both cases) and the converse `owed_unanswered_reason`.

## Field meanings relied on (docs/architecture.md "Overfull bars", Sources/SommelierCore/Reconciler.swift)

* `chevron = fresh`: the chevron is in this scan, not carried (Reconciler 80: `!stale`); only then are items hosted in its pile
  known to be folded.  `chevron = stale` is not usable.
* `level`: `complete` and `exceptSelfPositioning` are both usable.  `incomplete`, `kind = poll`, `settled = false`,
  `observed = false`, `stripOpen = true` are not.
* `unread`: keys the scan could not place (see A6).  `trusted`: the position of the key in `drawn` is corroborated.  `nearFold` is
  a churn-zone hint to the planner and says nothing about the bar.

## Assumptions about the adapter and the shape of the statements

* TRUST BOUNDARY (full list; nothing below is checked by proof): `Bar.WF` (a real bar has no duplicate key and no key both open and
  behind: assumed of every real bar `b` in T1..T9); A1, A2, A3, A6 (the conjuncts of `Honest`, assumptions about macOS and the adapter, not
  theorems); A3 means 3 COMPLETE chevronless readings IN A ROW, pass or quiet poll.  The counted POLLS include strip-open, unsettled and
  `exceptSelfPositioning` polls (Swift `notePollScan`, LayoutEngine.swift:1871-1883, counts them all); an unsettled complete PASS read neither counts nor
  resets, as Swift.  The ejb.8 soak must count exactly those reads, and has not yet been run; A4; A5; A7; and LEFTMOST FOLDING: that macOS folds the leftmost open key
  (`Bar.IsFold`) is an assumption, needed ONLY by `macOS_fold_preserves` (T8); no other theorem uses it.
* A4 (identity of trusted keys): a `Key` names the same menu bar item in the record, in the reading and on the bar.
* A5 (one moment): a reading describes one instant of the bar.  Every definition and theorem below is about ONE `Read` and ONE
  `Bar`; no statement relates two readings (except T6/T7, which relate the read to the move `step` decided on it).
* A7 (adapter obligations for the lists; see A6 and A2): `drawn` excludes the pile keys (Reconciler.swift:71-88 puts pile items in
  `onBar` AND `systemOverflow`; subtract them); stale pile items go to `unread`; `placementUnknown` keys (Reconciler.swift:86,
  set at MenuBarScanner.swift:993), apps whose read failed (MenuBarScanner.swift:510, :514, :527) and stale off-bar items
  (dropped by Reconciler.swift:71) go to `unread`; the inferred `foldedParked` (Reconciler.swift:87, :107) goes to `unread`.
  GAP found tracing this (reported, not fixed here): no field of `ObservedOrder` or `MenuBarSnapshot` carries the failed-read
  apps' keys, and an app with no cached items contributes no candidate at all, so today nothing in Swift can supply them.
  Two more obligations (`Model.lean` `unread`): the record has no duplicates (`rec.Nodup`), and `unread` is DISJOINT from the trusted drawn
  keys (a key the scan placed and corroborated is not unread).
-/

namespace Sommelier

/-! ### Step 1: the real bar -/

/-- The real bar: keys drawn in the open (left to right) and keys folded behind the chevron.  (`open` is a Lean keyword.) -/
structure Bar where
  open_  : List Key
  behind : List Key
  deriving Repr, DecidableEq

/-- Well formed: no duplicates and nothing both open and behind.  A key in neither is not on the bar. -/
def Bar.WF (b : Bar) : Prop := b.open_.Nodup ∧ b.behind.Nodup ∧ ∀ k ∈ b.open_, k ∉ b.behind

instance (b : Bar) : Decidable b.WF := by unfold Bar.WF; infer_instance

inductive Place where
  | open_ | behind | absent
  deriving DecidableEq, Repr

def Bar.place (b : Bar) (k : Key) : Place :=
  if k ∈ b.open_ then .open_ else if k ∈ b.behind then .behind else .absent

/-- The bar with key `k` taken off it. -/
def Bar.without (b : Bar) (k : Key) : Bar :=
  ⟨b.open_.filter (fun x => x ≠ k), b.behind.filter (fun x => x ≠ k)⟩

/-! ### Step 2: Honest -/

-- `Read.trustedDrawn`, `Read.usable`, `Read.pinOpen`, `Read.pinBehind`, `Read.consistent` live in `Step.lean` (the step's gate uses
-- the same definitions).  `usable`: pass, settled, not incomplete, observed, strip closed, and (FRESH chevron, or chevron
-- ABSENT with `notFullProven`).  A stale chevron is not usable.  Both levels `complete` and `exceptSelfPositioning` qualify.

/-- The reading lists `k` somewhere: drawn, in the pile, folded, or unread. -/
def Read.listed (r : Read) (k : Key) : Prop := k ∈ r.drawn ∨ k ∈ r.pile ∨ k ∈ r.folded ∨ k ∈ r.unread

instance (r : Read) (k : Key) : Decidable (r.listed k) := by unfold Read.listed; infer_instance

/-- A1: on a usable read, the trusted drawn keys really are open, and in the order the read shows them.  (A trusted drawn key that
the same read also puts in its pile or folded keys is self-contradictory: no honest bar.  The adapter subtracts the pile keys from
`drawn` (Reconciler.swift:71-88), so this only fires on a genuinely contradictory read.) -/
def HonestOpen (r : Read) (b : Bar) : Prop :=
  r.usable → (∀ k ∈ r.trustedDrawn, k ∈ b.open_) ∧ b.open_.filter (fun k => k ∈ r.trustedDrawn) = r.trustedDrawn

/-- A2: on a usable read with a FRESH chevron, the pile and the folded keys really are behind the chevron.
CAUTION (traced for this pass): Swift's `foldedParked` (Reconciler.swift:87, :107) is INFERRED ("parked, allowed by Control Center,
running, chevron fresh or recent => macOS folded it for width"), and a parked frame also appears after a respawn, so the inference is
NOT justified.  Conservative choice: inferred keys must be `unread`, never `pile`/`folded`.  A2 is then only about keys MEASURED
behind a fresh chevron (hosted in its pile: Reconciler `systemOverflow`; or left of its frame). -/
def HonestPile (r : Read) (b : Bar) : Prop :=
  r.usable → r.chevron = .fresh → ∀ k ∈ r.foldedSet, k ∈ b.behind

/-- A3: on a usable read with no chevron, nothing is folded.  For the proof's reason: three complete readings in a row without a
chevron (`notFullProven`) are taken to show the bar is not full.  THIS IS AN ASSUMPTION tested by a soak of the longest chevronless
run on a full bar (how many chevronless reads in a row can a full bar produce?); if one is ever seen the proof count is too short.  The counted
reads include quiet POLLS that are strip-open, unsettled or `exceptSelfPositioning` (Swift `notePollScan`): the soak (ejb.8) must count those too,
because they are what the engine counts. -/
def HonestNoChevron (r : Read) (b : Bar) : Prop :=
  r.usable → r.chevron = .absent → b.behind = []

/-- A6: on a usable read (either level), every key on the bar, open or behind, is drawn, in the pile, folded or unread.  So a
key listed NOWHERE (an app that is not running) really is not on the bar, and no verdict is held up by it.  An `unread` key may be
anywhere (open at any position, behind, or absent), EXCEPT that a key which is also in the pile or folded list of a usable fresh-chevron read is
pinned behind by A2.  Stale frames in the pile go to `unread` per the adapter (A7). -/
def HonestListed (r : Read) (b : Bar) : Prop :=
  r.usable → ∀ k ∈ b.open_ ++ b.behind, r.listed k

/-- The assumptions on macOS, for one reading of one bar.  Untrusted drawn keys, unread keys and every key on an unusable
reading are unconstrained. -/
def Honest (r : Read) (b : Bar) : Prop := HonestOpen r b ∧ HonestPile r b ∧ HonestNoChevron r b ∧ HonestListed r b

instance (r : Read) (b : Bar) : Decidable (HonestOpen r b) := by unfold HonestOpen; infer_instance
instance (r : Read) (b : Bar) : Decidable (HonestPile r b) := by unfold HonestPile; infer_instance
instance (r : Read) (b : Bar) : Decidable (HonestNoChevron r b) := by unfold HonestNoChevron; infer_instance
instance (r : Read) (b : Bar) : Decidable (HonestListed r b) := by unfold HonestListed; infer_instance
instance (r : Read) (b : Bar) : Decidable (Honest r b) := by unfold Honest; infer_instance

/-- A bar the reading could really have been taken of. -/
def Possible (r : Read) (b : Bar) : Prop := b.WF ∧ Honest r b

instance (r : Read) (b : Bar) : Decidable (Possible r b) := by unfold Possible; infer_instance

/-! ### Step 3: does the bar match the record? -/

/-- Considering only keys on the bar and in `rec`: (1) the open keys stand in `rec`'s relative order; (2) every behind key
precedes every open key in `rec`.  (For `rec` without duplicates.) -/
def barMatches (rec : List Key) (b : Bar) : Prop :=
  b.open_.filter (fun k => k ∈ rec) = rec.filter (fun k => k ∈ b.open_) ∧
  ∀ x ∈ b.behind, ∀ y ∈ b.open_, x ∈ rec → y ∈ rec → rec.idxOf x < rec.idxOf y

instance (rec : List Key) (b : Bar) : Decidable (barMatches rec b) := by unfold barMatches; infer_instance

/-- The same with the keys in `U` set aside. -/
def barMatchesExcept (U rec : List Key) (b : Bar) : Prop := barMatches (rec.filter (fun k => k ∉ U)) b

instance (U rec : List Key) (b : Bar) : Decidable (barMatchesExcept U rec b) := by unfold barMatchesExcept; infer_instance

/-! ### Step 4: the verdict (computable; proved against T1..T5 later) -/

inductive Verdict where
  | matches
  /-- `U` is nonempty: the record keys whose position this reading cannot establish and that could change the answer -/
  | matchesExcept (U : List Key)
  | differs
  | cannotTell
  deriving DecidableEq, Repr

inductive RowVerdict where
  | inOrder | behindChevron
  /-- `k` is behind the chevron although a record key that comes BEFORE `k` stands in the open (rule 2 broken, `k` named) -/
  | behindOutOfTurn
  | notOnBar | outOfPlace | cannotTell
  deriving DecidableEq, Repr

/-- A key not pinned either way. -/
def Read.free (r : Read) (k : Key) : Bool := !r.pinOpen.contains k && !r.pinBehind.contains k

/-- A key not pinned could be open: the read is not usable (nothing known), or the key is listed somewhere (A6). -/
def Read.openOK (r : Read) (k : Key) : Bool := !decide r.usable || decide (r.listed k)

/-- The pinned keys alone already break the match: the pinned open keys are not in the record's order, or a pinned behind key
follows a pinned open one in the record. -/
def forcedBad (rec : List Key) (r : Read) : Bool :=
  rec.filter (fun k => r.pinOpen.contains k) != r.pinOpen.filter (fun k => rec.contains k) ||
  rec.any (fun x => r.pinBehind.contains x && rec.any (fun y => r.pinOpen.contains y && rec.idxOf y < rec.idxOf x))

/-- A free listed record key `k` that can clash with a pinned record key: `k` open on the wrong side of a pinned open key (always
possible), or open before a pinned behind key that follows it in the record.  Every free listed key clashes with a pinned OPEN
record key; so with one in the record nothing is left over, and only pinned-behind-only reads leave free keys that clash with
nothing but each other. -/
def party (rec : List Key) (r : Read) (k : Key) : Bool :=
  r.free k && r.openOK k &&
    rec.any (fun y => r.pinOpen.contains y || (r.pinBehind.contains y && rec.idxOf k < rec.idxOf y))

/-- THE VERDICT.  Depends only on the record and the reading (no drop memory, no state).
* not usable or contradictory: cannot tell.
* the pinned keys alone break the match: differs.
* `U` = the free listed record keys that can clash with a pinned record key; `R` = the free listed record keys that cannot (they
  clash only with each other).  Two or more of `R` could stand in either order: cannot tell.  Otherwise matches (`U` empty) or
  matches except `U`. -/
def verdict (rec : List Key) (r : Read) : Verdict :=
  if !decide r.usable || !r.consistent then .cannotTell
  else if forcedBad rec r then .differs
  else
    let U := rec.filter (party rec r)
    let R := (rec.filter (fun k => r.free k && r.openOK k)).filter (fun k => !U.contains k)
    if R.length ≥ 2 then .cannotTell
    else if U.isEmpty then .matches
    else .matchesExcept U

/-- The verdict for one row (key `k` of the record).  Pinned keys only; a free key never makes ANOTHER row uncertain. -/
def rowVerdict (rec : List Key) (r : Read) (k : Key) : RowVerdict :=
  if !r.consistent then .cannotTell
  else if r.pinBehind.contains k then
    if rec.any (fun y => (rec.takeWhile (fun z => z != k)).contains y && r.pinOpen.contains y) then .behindOutOfTurn
    else .behindChevron
  else if r.pinOpen.contains k then
    if rec.any (fun x => x != k && r.pinOpen.contains x &&
          (decide (x ∈ rec.takeWhile (fun y => y != k)) != decide (r.pinOpen.idxOf x < r.pinOpen.idxOf k))) then .outOfPlace
    else .inOrder
  else if r.openOK k then .cannotTell
  else .notOnBar

/-! ### Semantic notions used by the theorems -/

/-- `k`'s place is the same on every allowed bar. -/
def Fixed (r : Read) (k : Key) : Prop := ∃ p : Place, ∀ b, Possible r b → b.place k = p

/-- ... and that place is on the bar. -/
def OnBarFixed (r : Read) (k : Key) : Prop := ∃ p : Place, p ≠ .absent ∧ ∀ b, Possible r b → b.place k = p

/-- `k` and `y` are in an inversion on `b` (the match fails when only these two record keys are considered). -/
def Inverted (rec : List Key) (b : Bar) (k y : Key) : Prop := ¬ barMatches (rec.filter (fun z => z = k ∨ z = y)) b

/-- `k` is a record key the reading cannot place and that matters: not fixed, and on some allowed bar in an inversion with a
record key whose place on the bar is fixed.  (There is no second layer: with a pinned OPEN record key every unplaced listed record
key clashes with it; keys that clash only with each other make the answer "cannot tell", see `ValidU` (2).) -/
def Party (rec : List Key) (r : Read) (k : Key) : Prop :=
  ¬ Fixed r k ∧ ∃ b, Possible r b ∧ ∃ y ∈ rec, y ≠ k ∧ OnBarFixed r y ∧ Inverted rec b k y

/-- Every allowed bar matches / no allowed bar matches (and some bar is allowed). -/
def AllMatch (rec : List Key) (r : Read) : Prop := (∃ b, Possible r b) ∧ ∀ b, Possible r b → barMatches rec b
def AllDiffer (rec : List Key) (r : Read) : Prop := (∃ b, Possible r b) ∧ ∀ b, Possible r b → ¬ barMatches rec b

/-- `U` is the exact set of keys the reading cannot place and that matter (independent of how the verdict computes it):
(1) nonempty, without duplicates, in the record, listed in the record's order (`U = rec.filter (· ∈ U)`);
(2) every allowed bar matches once `U` is set aside;
(3) `U` is EXACTLY `Party`: no padding (each member can change the answer, see `verdict_except`) and no omission;
(4) the reading establishes something: some record key outside `U` is fixed on the bar. -/
def ValidU (rec : List Key) (r : Read) (U : List Key) : Prop :=
  U ≠ [] ∧ U.Nodup ∧ (∀ k ∈ U, k ∈ rec) ∧ U = rec.filter (fun k => k ∈ U) ∧
  (∀ b, Possible r b → barMatchesExcept U rec b) ∧
  (∀ k ∈ rec, (k ∈ U ↔ Party rec r k)) ∧
  (∃ k ∈ rec, k ∉ U ∧ OnBarFixed r k)

set_option linter.unusedSimpArgs false
/-! ### Proof infrastructure (pass A): lists -/

theorem cons_tail {a x : Key} {L : List Key} (h : a ≠ x) (hx : x ∈ a :: L) : x ∈ L :=
  (List.mem_cons.mp hx).resolve_left (Ne.symm h)

theorem idx_cons (a x : Key) (l : List Key) :
    (a :: l).idxOf x = if a = x then 0 else l.idxOf x + 1 := by
  simp [List.idxOf_cons]

theorem idx_lt_len {x : Key} {L : List Key} (h : x ∈ L) : L.idxOf x < L.length :=
  List.idxOf_lt_length_iff.mpr h

theorem idx_inj : ∀ {L : List Key} {x y : Key}, x ∈ L → y ∈ L → L.idxOf x = L.idxOf y → x = y
  | [], x, y, hx, _, _ => by simp at hx
  | a :: L, x, y, hx, hy, h => by
    rw [idx_cons, idx_cons] at h
    by_cases hax : a = x
    · by_cases hay : a = y
      · exact hax ▸ hay ▸ rfl
      · simp [hax, hay] at h; exact h
    by_cases hay : a = y
    · simp [hax, hay] at h; exact h.symm
    · simp only [hax, hay, ite_false] at h
      have hx' : x ∈ L := cons_tail hax hx
      have hy' : y ∈ L := cons_tail hay hy
      exact idx_inj hx' hy' (by omega)

theorem idx_lt_or {L : List Key} {x y : Key} (hx : x ∈ L) (hy : y ∈ L) (hne : x ≠ y) :
    L.idxOf x < L.idxOf y ∨ L.idxOf y < L.idxOf x := by
  have : L.idxOf x ≠ L.idxOf y := fun h => hne (idx_inj hx hy h)
  omega

theorem idx_filter_iff (p : Key → Bool) : ∀ (L : List Key) (x y : Key), x ∈ L → y ∈ L → p x = true → p y = true →
    ((L.filter p).idxOf x < (L.filter p).idxOf y ↔ L.idxOf x < L.idxOf y)
  | [], x, y, hx, _, _, _ => by simp at hx
  | a :: L, x, y, hx, hy, px, py => by
    by_cases pa : p a = true
    · have e : (a :: L).filter p = a :: L.filter p := by simp [List.filter_cons, pa]
      rw [e, idx_cons, idx_cons, idx_cons, idx_cons]
      by_cases hax : a = x
      · subst hax
        by_cases hay : a = y
        · subst hay; simp
        · simp [hay]
      by_cases hay : a = y
      · subst hay; simp [hax]
      · have hx' : x ∈ L := cons_tail hax hx
        have hy' : y ∈ L := cons_tail hay hy
        have := idx_filter_iff p L x y hx' hy' px py
        simp only [hax, hay, ite_false]
        omega
    · have e : (a :: L).filter p = L.filter p := by simp [List.filter_cons, pa]
      have hax : a ≠ x := fun h => pa (h ▸ px)
      have hay : a ≠ y := fun h => pa (h ▸ py)
      have hx' : x ∈ L := cons_tail hax hx
      have hy' : y ∈ L := cons_tail hay hy
      rw [e, idx_cons, idx_cons]
      simp only [hax, hay, ite_false]
      have := idx_filter_iff p L x y hx' hy' px py
      omega

theorem tw_mem : ∀ {L : List Key} {x : Key}, x ∈ L → ∀ z, (z ∈ L.takeWhile (fun y => y != x) ↔ z ∈ L ∧ L.idxOf z < L.idxOf x)
  | [], x, hx, z => by simp at hx
  | a :: L, x, hx, z => by
    by_cases hax : a = x
    · subst hax
      simp [List.takeWhile_cons, idx_cons]
    · have hx' : x ∈ L := cons_tail hax hx
      have ih := tw_mem hx' z
      have h1 : (a != x) = true := by simpa using hax
      simp only [List.takeWhile_cons, h1, ite_true, List.mem_cons]
      rw [idx_cons, idx_cons]
      simp only [hax, ite_false]
      by_cases hza : a = z
      · subst hza; simp
      · simp only [hza, ite_false]
        constructor
        · rintro (h | h)
          · exact absurd h.symm hza
          · have := ih.mp h; refine ⟨Or.inr this.1, by omega⟩
        · rintro ⟨h | h, hlt⟩
          · exact absurd h.symm hza
          · exact Or.inr (ih.mpr ⟨h, by omega⟩)

theorem tw_sub {L : List Key} {x z : Key} (h : z ∈ L.takeWhile (fun y => y != x)) : z ∈ L :=
  (List.takeWhile_sublist _).subset h

theorem single_eq {A B : List Key} {c : Key} (hA : A.Nodup) (hB : B.Nodup) (ha : ∀ z ∈ A, z = c) (hb : ∀ z ∈ B, z = c)
    (hm : ∀ z, z ∈ A ↔ z ∈ B) : A = B := by
  have key : ∀ C : List Key, C.Nodup → (∀ z ∈ C, z = c) → C = [] ∨ C = [c] := by
    intro C hC h
    match C, hC, h with
    | [], _, _ => exact Or.inl rfl
    | [a], _, h => exact Or.inr (by rw [h a (by simp)])
    | a :: b :: t, hC, h =>
      exfalso
      have h1 := h a (by simp); have h2 := h b (by simp)
      simp [List.nodup_cons] at hC
      exact hC.1.1 (h1.trans h2.symm)
  rcases key A hA ha with h1 | h1 <;> rcases key B hB hb with h2 | h2
  · rw [h1, h2]
  · exfalso; have := (hm c).mpr (by simp [h2]); simp [h1] at this
  · exfalso; have := (hm c).mp (by simp [h1]); simp [h2] at this
  · rw [h1, h2]

theorem nodup_filter' (p : Key → Bool) {L : List Key} (h : L.Nodup) : (L.filter p).Nodup :=
  List.Nodup.sublist List.filter_sublist h

/-- order of two lists agreeing as sets, one is sorted by the other: equal. -/
theorem eq_of_order : ∀ (A B : List Key), A.Nodup → B.Nodup → (∀ x, x ∈ A ↔ x ∈ B) →
    (∀ x y, x ∈ A → y ∈ A → A.idxOf x < A.idxOf y → B.idxOf x < B.idxOf y) → A = B
  | [], B, _, _, hm, _ => by
    cases B with
    | nil => rfl
    | cons b t => exact absurd ((hm b).mpr (by simp)) (by simp)
  | a :: A, B, hA, hB, hm, ho => by
    have haB : a ∈ B := (hm a).mp (by simp)
    cases B with
    | nil => simp at haB
    | cons b t =>
      by_cases hab : a = b
      · subst hab
        simp [List.nodup_cons] at hA hB
        have : A = t := by
          refine eq_of_order A t hA.2 hB.2 ?_ ?_
          · intro x
            have := hm x
            simp at this
            constructor
            · intro hx
              have hxa : x ≠ a := fun h => hA.1 (h ▸ hx)
              exact (this.mp (Or.inr hx)).resolve_left hxa
            · intro hx
              have hxa : x ≠ a := fun h => hB.1 (h ▸ hx)
              exact (this.mpr (Or.inr hx)).resolve_left hxa
          · intro x y hx hy hxy
            have hxa : x ≠ a := fun h => hA.1 (h ▸ hx)
            have hya : y ≠ a := fun h => hA.1 (h ▸ hy)
            have := ho x y (by simp [hx]) (by simp [hy]) (by
              rw [idx_cons, idx_cons]; simp only [Ne.symm hxa, Ne.symm hya, ite_false]; omega)
            rw [idx_cons, idx_cons] at this
            simp only [Ne.symm hxa, Ne.symm hya, ite_false] at this
            omega
        rw [this]
      · exfalso
        have hbA : b ∈ a :: A := (hm b).mpr (by simp)
        have hbA' : b ∈ A := cons_tail hab hbA
        have := ho a b (by simp) hbA (by
          rw [idx_cons, idx_cons]; simp [hab, Ne.symm hab])
        have h0 : (b :: t).idxOf b = 0 := List.idxOf_cons_self
        omega

/-! ### Proof infrastructure: reads and possible bars -/

def dd : List Key → List Key
  | [] => []
  | a :: l => if a ∈ l then dd l else a :: dd l

theorem mem_dd : ∀ {l : List Key} {x : Key}, x ∈ dd l ↔ x ∈ l
  | [], x => by simp [dd]
  | a :: l, x => by
    unfold dd
    by_cases h : a ∈ l
    · simp only [h, ite_true, List.mem_cons]
      rw [mem_dd]
      constructor
      · intro hx; exact Or.inr hx
      · rintro (rfl | hx); exact h; exact hx
    · simp only [h, ite_false, List.mem_cons]
      rw [mem_dd]

theorem nodup_dd : ∀ l : List Key, (dd l).Nodup
  | [] => by simp [dd]
  | a :: l => by
    unfold dd
    by_cases h : a ∈ l
    · simp only [h, ite_true]; exact nodup_dd l
    · simp only [h, ite_false, List.nodup_cons]
      exact ⟨fun hm => h (mem_dd.mp hm), nodup_dd l⟩

theorem dd_nil : dd ([] : List Key) = [] := rfl

theorem pinOpen_def {r : Read} (hu : r.usable) : r.pinOpen = r.trustedDrawn := by
  simp [Read.pinOpen, hu]

theorem pinOpen_sub {r : Read} {k : Key} (h : k ∈ r.pinOpen) : r.usable ∧ k ∈ r.trustedDrawn := by
  unfold Read.pinOpen at h
  by_cases hu : r.usable
  · simp [hu] at h; exact ⟨hu, h⟩
  · simp [hu] at h

theorem pinOpen_unusable {r : Read} (hu : ¬ r.usable) : r.pinOpen = [] := by
  simp [Read.pinOpen, hu]

theorem pinBehind_unusable {r : Read} (hu : ¬ r.usable) : r.pinBehind = [] := by
  simp [Read.pinBehind, hu]

theorem pinBehind_sub {r : Read} {k : Key} (h : k ∈ r.pinBehind) :
    r.usable ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet := by
  unfold Read.pinBehind at h
  by_cases hu : r.usable ∧ r.chevron = .fresh
  · simp [hu] at h; exact ⟨hu.1, hu.2, h⟩
  · simp [hu] at h

theorem pinBehind_nf {r : Read} (hn : r.chevron ≠ .fresh) : r.pinBehind = [] := by
  simp [Read.pinBehind, hn]

theorem pinBehind_fresh {r : Read} (hu : r.usable) (hf : r.chevron = .fresh) : r.pinBehind = r.foldedSet := by
  simp [Read.pinBehind, hu, hf]

theorem usable_chev {r : Read} (hu : r.usable) : r.chevron = .fresh ∨ r.chevron = .absent := by
  obtain ⟨_, _, _, _, _, h⟩ := hu
  rcases h with h | h
  · exact Or.inl h
  · exact Or.inr h.1

/-- What usable MEANS, one named fact per condition (a poll, an unsettled read, an incomplete read, an unobserved read and an open strip are not witnesses
of the bar).  Each is a theorem so that a definition that drops a condition fails here by name, not only in a proof that happens to destructure it. -/
theorem usable_pass {r : Read} (hu : r.usable) : r.kind = .pass := hu.1
theorem usable_settled {r : Read} (hu : r.usable) : r.settled = true := hu.2.1
theorem usable_not_incomplete {r : Read} (hu : r.usable) : r.level ≠ .incomplete := hu.2.2.1
theorem usable_observed {r : Read} (hu : r.usable) : r.observed = true := hu.2.2.2.1
theorem usable_strip_closed {r : Read} (hu : r.usable) : r.stripOpen = false := hu.2.2.2.2.1
theorem usable_not_stale {r : Read} (hu : r.usable) : r.chevron ≠ .stale := by
  rcases usable_chev hu with h | h <;> simp [h]
theorem usable_absent_proven {r : Read} (hu : r.usable) (h : r.chevron = .absent) : r.notFullProven = true := by
  obtain ⟨_, _, _, _, _, h6⟩ := hu
  rcases h6 with h6 | h6
  · rw [h] at h6; cases h6
  · exact h6.2

theorem trusted_listed {r : Read} {k : Key} (h : k ∈ r.trustedDrawn) : r.listed k := by
  unfold Read.trustedDrawn at h
  exact Or.inl (List.mem_filter.mp h).1

theorem folded_listed {r : Read} {k : Key} (h : k ∈ r.foldedSet) : r.listed k := by
  unfold Read.foldedSet at h
  rcases List.mem_append.mp h with h | h
  · exact Or.inr (Or.inl h)
  · exact Or.inr (Or.inr (Or.inl h))

theorem pinOpen_listed {r : Read} {k : Key} (h : k ∈ r.pinOpen) : r.listed k := by
  obtain ⟨hu, h⟩ := pinOpen_sub h
  exact trusted_listed h

theorem pinBehind_listed {r : Read} {k : Key} (h : k ∈ r.pinBehind) : r.listed k :=
  folded_listed (pinBehind_sub h).2.2

theorem consistent_iff {r : Read} :
    r.consistent = true ↔ r.pinOpen.Nodup ∧ ∀ k ∈ r.pinOpen, k ∉ r.pinBehind := by
  simp [Read.consistent, List.all_eq_true]

theorem consistent_unusable {r : Read} (hu : ¬ r.usable) : r.consistent = true := by
  simp [Read.consistent, pinOpen_unusable hu]

theorem poss_unusable {r : Read} (hu : ¬ r.usable) (b : Bar) : Possible r b ↔ b.WF := by
  unfold Possible Honest HonestOpen HonestPile HonestNoChevron HonestListed
  simp [hu]

theorem poss_iff {r : Read} (hu : r.usable) (b : Bar) :
    Possible r b ↔ b.WF ∧ b.open_.filter (fun k => k ∈ r.pinOpen) = r.pinOpen ∧
      (∀ k ∈ r.pinBehind, k ∈ b.behind) ∧ (r.chevron = .absent → b.behind = []) ∧
      (∀ k ∈ b.open_ ++ b.behind, r.listed k) := by
  unfold Possible Honest HonestOpen HonestPile HonestNoChevron HonestListed
  rw [pinOpen_def hu]
  constructor
  · rintro ⟨hw, ⟨hO, hP, hN, hL⟩⟩
    refine ⟨hw, (hO hu).2, ?_, hN hu, hL hu⟩
    intro k hk
    obtain ⟨_, hf, hk'⟩ := pinBehind_sub hk
    exact hP hu hf k hk'
  · rintro ⟨hw, hf, hB, hN, hL⟩
    refine ⟨hw, ⟨fun _ => ⟨?_, hf⟩, fun _ hfr k hk => ?_, fun _ => hN, fun _ => hL⟩⟩
    · intro k hk
      have : k ∈ b.open_.filter (fun k => k ∈ r.trustedDrawn) := by rw [hf]; exact hk
      exact (List.mem_filter.mp this).1
    · exact hB k (by rw [pinBehind_fresh hu hfr]; exact hk)

theorem poss_pin_open {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {k : Key} (hk : k ∈ r.pinOpen) :
    k ∈ b.open_ := by
  have := ((poss_iff hu b).mp hp).2.1
  have h2 : k ∈ b.open_.filter (fun k => k ∈ r.pinOpen) := by rw [this]; exact hk
  exact (List.mem_filter.mp h2).1

theorem poss_open_listed {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {k : Key} (hk : k ∈ b.open_) :
    r.listed k := ((poss_iff hu b).mp hp).2.2.2.2 k (List.mem_append.mpr (Or.inl hk))

theorem poss_behind_listed {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {k : Key} (hk : k ∈ b.behind) :
    r.listed k := ((poss_iff hu b).mp hp).2.2.2.2 k (List.mem_append.mpr (Or.inr hk))

theorem poss_pin_behind {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {k : Key} (hk : k ∈ r.pinBehind) :
    k ∈ b.behind := ((poss_iff hu b).mp hp).2.2.1 k hk

theorem poss_wf {r : Read} {b : Bar} (hp : Possible r b) : b.WF := hp.1

theorem wf_not_both {b : Bar} (hw : b.WF) {k : Key} (ho : k ∈ b.open_) (hb : k ∈ b.behind) : False :=
  hw.2.2 k ho hb

/-- A free key (neither pinned) that the read lists. -/
def FL (r : Read) (k : Key) : Prop := k ∉ r.pinOpen ∧ k ∉ r.pinBehind ∧ r.listed k

theorem free_listed {r : Read} (hu : r.usable) (k : Key) :
    (r.free k && r.openOK k) = true ↔ FL r k := by
  simp [Read.free, Read.openOK, FL, hu, List.contains_iff_mem]
  exact and_assoc

/-- General witness: the open list `X` and the behind list `dd pinBehind`. -/
theorem mk_poss {r : Read} (hu : r.usable) (X : List Key) (hX : X.Nodup)
    (hf : X.filter (fun k => k ∈ r.pinOpen) = r.pinOpen) (hXB : ∀ k ∈ X, k ∉ r.pinBehind)
    (hl : ∀ k ∈ X, r.listed k) : Possible r ⟨X, dd r.pinBehind⟩ := by
  rw [poss_iff hu]
  refine ⟨⟨hX, nodup_dd _, fun k hk hb => hXB k hk (mem_dd.mp hb)⟩, hf, fun k hk => mem_dd.mpr hk, ?_, ?_⟩
  · intro ha
    have : r.chevron ≠ .fresh := by rw [ha]; decide
    simp [pinBehind_nf this, dd_nil]
  · intro k hk
    rcases List.mem_append.mp hk with h | h
    · exact hl k h
    · exact pinBehind_listed (mem_dd.mp h)

theorem filter_pin_self (P : List Key) : P.filter (fun k => k ∈ P) = P := by
  rw [List.filter_eq_self]; intro a ha; simpa using ha

theorem poss_P {r : Read} (hu : r.usable) (hc : r.consistent = true) : Possible r ⟨r.pinOpen, dd r.pinBehind⟩ := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  exact mk_poss hu _ hn (filter_pin_self _) hd (fun k hk => pinOpen_listed hk)

theorem filter_pre {P E : List Key} (h : ∀ k ∈ E, k ∉ P) : (E ++ P).filter (fun k => k ∈ P) = P := by
  rw [List.filter_append, filter_pin_self]
  have : E.filter (fun k => k ∈ P) = [] := by
    rw [List.filter_eq_nil_iff]; intro a ha; simpa using h a ha
  rw [this]; rfl

theorem filter_post {P E : List Key} (h : ∀ k ∈ E, k ∉ P) : (P ++ E).filter (fun k => k ∈ P) = P := by
  rw [List.filter_append, filter_pin_self]
  have : E.filter (fun k => k ∈ P) = [] := by
    rw [List.filter_eq_nil_iff]; intro a ha; simpa using h a ha
  rw [this]; simp

theorem poss_pre {r : Read} (hu : r.usable) (hc : r.consistent = true) (E : List Key) (hE : E.Nodup)
    (h : ∀ k ∈ E, FL r k) : Possible r ⟨E ++ r.pinOpen, dd r.pinBehind⟩ := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  refine mk_poss hu _ ?_ (filter_pre (fun k hk => (h k hk).1)) ?_ ?_
  · rw [List.nodup_append]
    exact ⟨hE, hn, fun a ha b hb hab => (h a ha).1 (hab ▸ hb)⟩
  · intro k hk
    rcases List.mem_append.mp hk with hk | hk
    · exact (h k hk).2.1
    · exact hd k hk
  · intro k hk
    rcases List.mem_append.mp hk with hk | hk
    · exact (h k hk).2.2
    · exact pinOpen_listed hk

theorem poss_post {r : Read} (hu : r.usable) (hc : r.consistent = true) (E : List Key) (hE : E.Nodup)
    (h : ∀ k ∈ E, FL r k) : Possible r ⟨r.pinOpen ++ E, dd r.pinBehind⟩ := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  refine mk_poss hu _ ?_ (filter_post (fun k hk => (h k hk).1)) ?_ ?_
  · rw [List.nodup_append]
    exact ⟨hn, hE, fun a ha b hb hab => (h b hb).1 (hab ▸ ha)⟩
  · intro k hk
    rcases List.mem_append.mp hk with hk | hk
    · exact hd k hk
    · exact (h k hk).2.1
  · intro k hk
    rcases List.mem_append.mp hk with hk | hk
    · exact pinOpen_listed hk
    · exact (h k hk).2.2

/-- classification of the keys on a possible bar -/
theorem open_cls {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {z : Key} (hz : z ∈ b.open_) :
    z ∈ r.pinOpen ∨ FL r z := by
  by_cases h : z ∈ r.pinOpen
  · exact Or.inl h
  · refine Or.inr ⟨h, fun hb => wf_not_both hp.1 hz (poss_pin_behind hu hp hb), poss_open_listed hu hp hz⟩

theorem behind_cls {r : Read} {b : Bar} (hu : r.usable) (hp : Possible r b) {z : Key} (hz : z ∈ b.behind) :
    z ∈ r.pinBehind ∨ FL r z := by
  by_cases h : z ∈ r.pinBehind
  · exact Or.inl h
  · refine Or.inr ⟨fun ho => wf_not_both hp.1 (poss_pin_open hu hp ho) hz, h, poss_behind_listed hu hp hz⟩

/-- consistent usable reads have a possible bar -/
theorem exists_poss_iff (r : Read) : (∃ b, Possible r b) ↔ (r.usable → r.consistent = true) := by
  constructor
  · rintro ⟨b, hb⟩ hu
    rw [consistent_iff]
    refine ⟨?_, fun k hk hkb => wf_not_both hb.1 (poss_pin_open hu hb hk) (poss_pin_behind hu hb hkb)⟩
    have h1 := ((poss_iff hu b).mp hb).2.1
    have hn : (b.open_.filter (fun k => k ∈ r.pinOpen)).Nodup := nodup_filter' _ hb.1.1
    rwa [h1] at hn
  · intro h
    by_cases hu : r.usable
    · exact ⟨_, poss_P hu (h hu)⟩
    · exact ⟨⟨[], []⟩, (poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩⟩

/-! ### Proof infrastructure: matching -/

theorem match_order {L : List Key} {b : Bar} (hm : barMatches L b) {x y : Key} (hx : x ∈ b.open_) (hy : y ∈ b.open_)
    (hxL : x ∈ L) (hyL : y ∈ L) (hlt : b.open_.idxOf x < b.open_.idxOf y) : L.idxOf x < L.idxOf y := by
  have h1 := hm.1
  have h2 := (idx_filter_iff (fun k => decide (k ∈ L)) b.open_ x y hx hy (by simp [hxL]) (by simp [hyL])).mpr hlt
  rw [h1] at h2
  exact (idx_filter_iff (fun k => decide (k ∈ b.open_)) L x y hxL hyL (by simp [hx]) (by simp [hy])).mp h2

theorem nm_order {L : List Key} {b : Bar} {x y : Key} (hx : x ∈ b.open_) (hy : y ∈ b.open_)
    (hxL : x ∈ L) (hyL : y ∈ L) (hlt : b.open_.idxOf x < b.open_.idxOf y) (hL : L.idxOf y < L.idxOf x) :
    ¬ barMatches L b := fun hm => by
  have := match_order hm hx hy hxL hyL hlt
  omega

theorem nm_behind {L : List Key} {b : Bar} {x y : Key} (hx : x ∈ b.behind) (hy : y ∈ b.open_)
    (hxL : x ∈ L) (hyL : y ∈ L) (hL : L.idxOf y < L.idxOf x) : ¬ barMatches L b := fun hm => by
  have := hm.2 x hx y hy hxL hyL
  omega

/-- The pinned keys alone are consistent with the list `L`. -/
def OkL (r : Read) (L : List Key) : Prop :=
  L.filter (fun z => z ∈ r.pinOpen) = r.pinOpen.filter (fun z => z ∈ L) ∧
  ∀ x ∈ r.pinBehind, ∀ y ∈ r.pinOpen, x ∈ L → y ∈ L → L.idxOf x < L.idxOf y

theorem match_pinned {r : Read} {L : List Key} {b : Bar} (hu : r.usable) (hp : Possible r b) (hok : OkL r L)
    (hO : ∀ z ∈ b.open_, z ∈ L → z ∈ r.pinOpen) (hB : ∀ x ∈ b.behind, x ∈ L → x ∈ r.pinBehind) :
    barMatches L b := by
  have hf := ((poss_iff hu b).mp hp).2.1
  refine ⟨?_, fun x hx y hy hxL hyL => hok.2 x (hB x hx hxL) y (hO y hy hyL) hxL hyL⟩
  have e1 : b.open_.filter (fun z => z ∈ L) = r.pinOpen.filter (fun z => z ∈ L) := by
    calc b.open_.filter (fun z => z ∈ L) = (b.open_.filter (fun z => z ∈ r.pinOpen)).filter (fun z => z ∈ L) := by
          rw [List.filter_filter]; apply List.filter_congr
          intro z hz
          by_cases hzL : z ∈ L
          · have := hO z hz hzL; simp [this, hzL]
          · simp [hzL]
      _ = _ := by rw [hf]
  have e2 : L.filter (fun z => z ∈ b.open_) = L.filter (fun z => z ∈ r.pinOpen) := by
    apply List.filter_congr
    intro z hz
    by_cases h : z ∈ b.open_
    · have := hO z h hz; simp [h, this]
    · have : z ∉ r.pinOpen := fun h' => h (poss_pin_open hu hp h')
      simp [h, this]
  rw [e1, e2]; exact hok.1.symm

theorem match_single {L : List Key} {b : Bar} {c : Key} (hnd : L.Nodup) (hbo : b.open_.Nodup)
    (hO : ∀ z ∈ b.open_, z ∈ L → z = c)
    (hB : ∀ x ∈ b.behind, ∀ y ∈ b.open_, x ∈ L → y ∈ L → L.idxOf x < L.idxOf y) : barMatches L b := by
  refine ⟨?_, fun x hx y hy hxL hyL => hB x hx y hy hxL hyL⟩
  refine single_eq (c := c) (nodup_filter' _ hbo) (nodup_filter' _ hnd) ?_ ?_ ?_
  · intro z hz; simp [List.mem_filter] at hz; exact hO z hz.1 hz.2
  · intro z hz; simp [List.mem_filter] at hz; exact hO z hz.2 hz.1
  · intro z; simp [List.mem_filter, and_comm]

theorem forcedBad_iff {r : Read} {rec : List Key} (hc : r.consistent = true) (hnd : rec.Nodup) :
    forcedBad rec r = false ↔ OkL r rec := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  unfold forcedBad OkL
  simp only [Bool.or_eq_false_iff, bne_eq_false_iff_eq, Bool.not_eq_true]
  have e : ∀ L : List Key, (fun k => L.contains k) = (fun k => decide (k ∈ L)) := by
    intro L; funext k; simp
  rw [e, e]
  apply and_congr Iff.rfl
  constructor
  · intro h x hx y hy hxr hyr
    refine Classical.byContradiction fun hnot => ?_
    have hne : x ≠ y := fun h' => hd y hy (h' ▸ hx)
    have hlt : rec.idxOf y < rec.idxOf x := by
      rcases idx_lt_or hxr hyr hne with h' | h'
      · exact absurd h' hnot
      · exact h'
    have : (rec.any fun x => r.pinBehind.contains x &&
        rec.any fun y => r.pinOpen.contains y && decide (List.idxOf y rec < List.idxOf x rec)) = true := by
      rw [List.any_eq_true]
      refine ⟨x, hxr, ?_⟩
      simp only [Bool.and_eq_true, List.contains_iff_mem, List.any_eq_true]
      exact ⟨hx, y, hyr, by simp [hy, hlt]⟩
    rw [h] at this; exact absurd this (by decide)
  · intro h
    rw [Bool.eq_false_iff]
    intro hany
    rw [List.any_eq_true] at hany
    obtain ⟨x, hxr, hx⟩ := hany
    simp only [Bool.and_eq_true, List.contains_iff_mem, List.any_eq_true, decide_eq_true_eq] at hx
    obtain ⟨hxb, y, hyr, hy, hlt⟩ := hx
    have := h x hxb y hy hxr hyr
    omega

theorem okL_of_match {r : Read} {L : List Key} {b : Bar} (hu : r.usable) (hp : Possible r b) (hm : barMatches L b) :
    OkL r L := by
  have hf := ((poss_iff hu b).mp hp).2.1
  refine ⟨?_, fun x hx y hy hxL hyL => hm.2 x (poss_pin_behind hu hp hx) y (poss_pin_open hu hp hy) hxL hyL⟩
  have h := congrArg (List.filter (fun z => decide (z ∈ r.pinOpen))) hm.1
  rw [List.filter_filter, List.filter_filter] at h
  calc L.filter (fun z => z ∈ r.pinOpen)
      = L.filter (fun a => decide (a ∈ r.pinOpen) && decide (a ∈ b.open_)) := by
        apply List.filter_congr; intro z _
        by_cases hz : z ∈ r.pinOpen
        · simp [hz, poss_pin_open hu hp hz]
        · simp [hz]
    _ = b.open_.filter (fun a => decide (a ∈ r.pinOpen) && decide (a ∈ L)) := h.symm
    _ = (b.open_.filter (fun z => z ∈ r.pinOpen)).filter (fun z => z ∈ L) := by
        rw [List.filter_filter]; apply List.filter_congr; intro z _; exact Bool.and_comm _ _
    _ = r.pinOpen.filter (fun z => z ∈ L) := by rw [hf]

theorem idx_append_left : ∀ {A C : List Key} {x : Key}, x ∈ A → (A ++ C).idxOf x = A.idxOf x
  | [], C, x, h => by simp at h
  | a :: A, C, x, h => by
    rw [List.cons_append, idx_cons, idx_cons]
    by_cases hax : a = x
    · simp [hax]
    · simp only [hax, ite_false]
      rw [idx_append_left (cons_tail hax h)]

theorem idx_append_right : ∀ {A C : List Key} {x : Key}, x ∉ A → (A ++ C).idxOf x = A.length + C.idxOf x
  | [], C, x, h => by simp
  | a :: A, C, x, h => by
    have hax : a ≠ x := fun e => h (e ▸ List.mem_cons_self)
    have hA : x ∉ A := fun e => h (List.mem_cons_of_mem _ e)
    rw [List.cons_append, idx_cons]
    simp only [hax, ite_false]
    rw [idx_append_right hA]
    simp; omega

/-! ### Proof infrastructure: parties, clashes, fixed keys -/

/-- `k` is a free listed key that clashes with a pinned record key. -/
def PartyB (rec : List Key) (r : Read) (k : Key) : Prop :=
  FL r k ∧ ∃ y ∈ rec, y ∈ r.pinOpen ∨ (y ∈ r.pinBehind ∧ rec.idxOf k < rec.idxOf y)

theorem party_iff {r : Read} (hu : r.usable) (rec : List Key) (k : Key) :
    party rec r k = true ↔ PartyB rec r k := by
  unfold party PartyB
  simp only [Bool.and_eq_true, free_listed hu, List.any_eq_true, Bool.or_eq_true, List.contains_iff_mem,
    decide_eq_true_eq]

def Ucomp (rec : List Key) (r : Read) : List Key := rec.filter (party rec r)
def Rcomp (rec : List Key) (r : Read) : List Key :=
  (rec.filter (fun k => r.free k && r.openOK k)).filter (fun k => !(Ucomp rec r).contains k)

theorem mem_U {r : Read} (hu : r.usable) {rec : List Key} {k : Key} :
    k ∈ Ucomp rec r ↔ k ∈ rec ∧ PartyB rec r k := by
  unfold Ucomp; rw [List.mem_filter, party_iff hu]

theorem mem_R {r : Read} (hu : r.usable) {rec : List Key} {k : Key} :
    k ∈ Rcomp rec r ↔ k ∈ rec ∧ FL r k ∧ ¬ PartyB rec r k := by
  unfold Rcomp
  simp only [List.mem_filter, Bool.not_eq_true', List.contains_iff_mem, free_listed hu]
  have : (Ucomp rec r).contains k = false ↔ ¬ k ∈ Ucomp rec r := by
    rw [← Bool.not_eq_true, List.contains_iff_mem]
  rw [this, mem_U hu]
  constructor
  · rintro ⟨⟨h1, h2⟩, h3⟩; exact ⟨h1, h2, fun h => h3 ⟨h1, h⟩⟩
  · rintro ⟨h1, h2, h3⟩; exact ⟨⟨h1, h2⟩, fun h => h3 h.2⟩

theorem verdict_unusable {r : Read} (rec : List Key) (hu : ¬ r.usable) : verdict rec r = .cannotTell := by
  unfold verdict; simp [hu]

theorem verdict_incons {r : Read} (rec : List Key) (hc : r.consistent = false) : verdict rec r = .cannotTell := by
  unfold verdict; simp [hc]

theorem verdict_forced {r : Read} (rec : List Key) (hu : r.usable) (hc : r.consistent = true)
    (hf : forcedBad rec r = true) : verdict rec r = .differs := by
  unfold verdict; simp [hu, hc, hf]

theorem verdict_else {r : Read} (rec : List Key) (hu : r.usable) (hc : r.consistent = true)
    (hf : forcedBad rec r = false) :
    verdict rec r = if (Rcomp rec r).length ≥ 2 then .cannotTell
      else if (Ucomp rec r).isEmpty then .matches else .matchesExcept (Ucomp rec r) := by
  unfold verdict; simp [hu, hc, hf, Rcomp, Ucomp]

/-! clash bars -/

theorem clash {r : Read} (hu : r.usable) (hc : r.consistent = true) {L : List Key} {k y : Key}
    (hk : FL r k) (hkL : k ∈ L) (hyL : y ∈ L)
    (hy : y ∈ r.pinOpen ∨ (y ∈ r.pinBehind ∧ L.idxOf k < L.idxOf y)) :
    ∃ X : List Key, (X = [k] ++ r.pinOpen ∨ X = r.pinOpen ++ [k]) ∧ Possible r ⟨X, dd r.pinBehind⟩ ∧
      ¬ barMatches L ⟨X, dd r.pinBehind⟩ := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  have hE : ∀ z ∈ [k], FL r z := by intro z hz; simp at hz; subst hz; exact hk
  have hkP : k ∉ r.pinOpen := hk.1
  have hkB : k ∉ r.pinBehind := hk.2.1
  rcases hy with hyP | ⟨hyB, hlt⟩
  · have hne : k ≠ y := fun e => hkP (e ▸ hyP)
    rcases idx_lt_or hkL hyL hne with h | h
    · refine ⟨r.pinOpen ++ [k], Or.inr rfl, poss_post hu hc [k] (by simp) hE, ?_⟩
      refine nm_order (x := y) (y := k) ?_ ?_ hyL hkL ?_ h
      · exact List.mem_append.mpr (Or.inl hyP)
      · exact List.mem_append.mpr (Or.inr (by simp))
      · show (r.pinOpen ++ [k]).idxOf y < (r.pinOpen ++ [k]).idxOf k
        rw [idx_append_left hyP, idx_append_right hkP]
        have := idx_lt_len hyP
        simp; omega
    · refine ⟨[k] ++ r.pinOpen, Or.inl rfl, poss_pre hu hc [k] (by simp) hE, ?_⟩
      refine nm_order (x := k) (y := y) ?_ ?_ hkL hyL ?_ h
      · exact List.mem_append.mpr (Or.inl (by simp))
      · exact List.mem_append.mpr (Or.inr hyP)
      · show ([k] ++ r.pinOpen).idxOf k < ([k] ++ r.pinOpen).idxOf y
        have hyk : y ∉ [k] := by simp; exact fun e => hne e.symm
        rw [idx_append_left (by simp), idx_append_right hyk]
        simp; omega
  · refine ⟨r.pinOpen ++ [k], Or.inr rfl, poss_post hu hc [k] (by simp) hE, ?_⟩
    exact nm_behind (x := y) (y := k) (mem_dd.mpr hyB) (List.mem_append.mpr (Or.inr (by simp))) hyL hkL hlt

theorem clash2 {r : Read} (hu : r.usable) (hc : r.consistent = true) {L : List Key} {k1 k2 : Key}
    (h1 : FL r k1) (h2 : FL r k2) (h1L : k1 ∈ L) (h2L : k2 ∈ L) (hlt : L.idxOf k1 < L.idxOf k2) :
    Possible r ⟨[k2, k1] ++ r.pinOpen, dd r.pinBehind⟩ ∧ ¬ barMatches L ⟨[k2, k1] ++ r.pinOpen, dd r.pinBehind⟩ := by
  have hne : k2 ≠ k1 := fun e => by subst e; omega
  have hE : ∀ z ∈ [k2, k1], FL r z := by
    intro z hz; simp at hz; rcases hz with rfl | rfl; exact h2; exact h1
  refine ⟨poss_pre hu hc [k2, k1] (by simp [hne]) hE, ?_⟩
  refine nm_order (x := k2) (y := k1) ?_ ?_ h2L h1L ?_ hlt
  · exact List.mem_append.mpr (Or.inl (by simp))
  · exact List.mem_append.mpr (Or.inl (by simp))
  · show ([k2, k1] ++ r.pinOpen).idxOf k2 < ([k2, k1] ++ r.pinOpen).idxOf k1
    rw [idx_append_left (by simp), idx_append_left (by simp)]
    simp [idx_cons, hne]

/-! fixed keys -/

theorem place_W0_FL {r : Read} (k : Key) (hk : FL r k) : (Bar.place ⟨r.pinOpen, dd r.pinBehind⟩ k) = .absent := by
  unfold Bar.place
  simp [hk.1, hk.2.1, mem_dd]

theorem place_open (k : Key) (X : List Key) (hX : k ∈ X) (B : List Key) : (Bar.place ⟨X, B⟩ k) = .open_ := by
  unfold Bar.place; simp [hX]

theorem not_fixed_of_FL {r : Read} (hu : r.usable) (hc : r.consistent = true) {k : Key} (hk : FL r k) :
    ¬ Fixed r k := by
  rintro ⟨p, hp⟩
  have h1 := hp _ (poss_P hu hc)
  have h2 := hp _ (poss_pre hu hc [k] (by simp) (by intro z hz; simp at hz; subst hz; exact hk))
  rw [place_W0_FL k hk] at h1
  rw [place_open k _ (by simp)] at h2
  rw [← h1] at h2; exact absurd h2 (by decide)

theorem fixed_of_not_FL {r : Read} (hu : r.usable) (hc : r.consistent = true) {k : Key} (hk : ¬ FL r k) :
    Fixed r k := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  by_cases hP : k ∈ r.pinOpen
  · refine ⟨.open_, fun b hb => ?_⟩
    exact place_open k _ (poss_pin_open hu hb hP) _
  by_cases hB : k ∈ r.pinBehind
  · refine ⟨.behind, fun b hb => ?_⟩
    have h1 := poss_pin_behind hu hb hB
    have h2 : k ∉ b.open_ := fun h => wf_not_both hb.1 h h1
    unfold Bar.place; simp [h1, h2]
  · have hl : ¬ r.listed k := fun hl => hk ⟨hP, hB, hl⟩
    refine ⟨.absent, fun b hb => ?_⟩
    have h2 : k ∉ b.open_ := fun h => hl (poss_open_listed hu hb h)
    have h1 : k ∉ b.behind := fun h => hl (poss_behind_listed hu hb h)
    unfold Bar.place; simp [h1, h2]

theorem pinned_of_onBarFixed {r : Read} (hu : r.usable) (hc : r.consistent = true) {y : Key}
    (h : OnBarFixed r y) : y ∈ r.pinOpen ∨ y ∈ r.pinBehind := by
  obtain ⟨p, hp, hall⟩ := h
  refine Classical.byContradiction fun hne => ?_
  have hne' : y ∉ r.pinOpen ∧ y ∉ r.pinBehind := ⟨fun h => hne (Or.inl h), fun h => hne (Or.inr h)⟩
  by_cases hl : r.listed y
  · exact not_fixed_of_FL hu hc ⟨hne'.1, hne'.2, hl⟩ ⟨p, hall⟩
  · have := hall _ (poss_P hu hc)
    have h2 : y ∉ r.pinOpen := hne'.1
    have h3 : y ∉ dd r.pinBehind := fun h => hne'.2 (mem_dd.mp h)
    unfold Bar.place at this
    simp [h2, h3] at this
    exact hp this.symm

/-! ### Party <-> computed party -/

theorem onBarFixed_P {r : Read} (hu : r.usable) {y : Key} (hy : y ∈ r.pinOpen) : OnBarFixed r y :=
  ⟨.open_, by decide, fun b hb => place_open y _ (poss_pin_open hu hb hy) _⟩

theorem onBarFixed_B {r : Read} (hu : r.usable) {y : Key} (hy : y ∈ r.pinBehind) : OnBarFixed r y := by
  refine ⟨.behind, by decide, fun b hb => ?_⟩
  have h1 := poss_pin_behind hu hb hy
  have h2 : y ∉ b.open_ := fun h => wf_not_both hb.1 h h1
  unfold Bar.place; simp [h1, h2]

theorem two_elems {l : List Key} (hn : l.Nodup) (h : 2 ≤ l.length) : ∃ a b, a ∈ l ∧ b ∈ l ∧ a ≠ b := by
  match l, hn, h with
  | a :: b :: t, hn, _ =>
    refine ⟨a, b, by simp, by simp, ?_⟩
    simp [List.nodup_cons] at hn
    exact fun e => hn.1.1 e

theorem lt_two {l : List Key} (h : l.length < 2) {a b : Key} (ha : a ∈ l) (hb : b ∈ l) : a = b := by
  match l, h, ha, hb with
  | [], _, ha, _ => simp at ha
  | [c], _, ha, hb => simp at ha hb; rw [ha, hb]
  | c :: d :: t, h, _, _ => exact absurd h (by simp)

theorem party_Party {r : Read} (hu : r.usable) (hc : r.consistent = true) {rec : List Key} (hnd : rec.Nodup)
    {k : Key} (hk : k ∈ rec) : Party rec r k ↔ PartyB rec r k := by
  constructor
  · rintro ⟨hnf, b, hb, y, hy, hyk, hfix, hinv⟩
    have hFL : FL r k := Classical.byContradiction fun h => hnf (fixed_of_not_FL hu hc h)
    refine ⟨hFL, ?_⟩
    rcases pinned_of_onBarFixed hu hc hfix with hyP | hyB
    · exact ⟨y, hy, Or.inl hyP⟩
    · refine ⟨y, hy, Or.inr ⟨hyB, ?_⟩⟩
      refine Classical.byContradiction fun hnot => ?_
      have hlt : rec.idxOf y < rec.idxOf k := by
        rcases idx_lt_or hk hy (Ne.symm hyk) with h | h
        · exact absurd h hnot
        · exact h
      apply hinv
      have hyO : y ∉ b.open_ := fun h => wf_not_both hb.1 h (poss_pin_behind hu hb hyB)
      have hkO : ∀ z ∈ b.open_, z ∈ rec.filter (fun z => z = k ∨ z = y) → z = k := by
        intro z hz hz2
        have := (List.mem_filter.mp hz2).2
        simp at this
        rcases this with h | h
        · exact h
        · exact absurd (h ▸ hz) hyO
      refine match_single (c := k) (nodup_filter' _ hnd) hb.1.1 hkO ?_
      intro x hx z hz hxL hzL
      have hzk := hkO z hz hzL
      have hxL' := (List.mem_filter.mp hxL).2
      simp at hxL'
      rcases hxL' with h | h
      · exact absurd (h ▸ hx) (fun hh => wf_not_both hb.1 (hzk ▸ hz) hh)
      · rw [h, hzk]
        exact (idx_filter_iff (fun z => decide (z = k ∨ z = y)) rec y k hy hk (by simp) (by simp)).mpr hlt
  · rintro ⟨hFL, y, hy, h⟩
    have hyk : y ≠ k := by
      rintro rfl
      rcases h with h | ⟨h, _⟩
      · exact hFL.1 h
      · exact hFL.2.1 h
    have hkL : k ∈ rec.filter (fun z => z = k ∨ z = y) := List.mem_filter.mpr ⟨hk, by simp⟩
    have hyL : y ∈ rec.filter (fun z => z = k ∨ z = y) := List.mem_filter.mpr ⟨hy, by simp⟩
    have h' : y ∈ r.pinOpen ∨ (y ∈ r.pinBehind ∧
        (rec.filter (fun z => z = k ∨ z = y)).idxOf k < (rec.filter (fun z => z = k ∨ z = y)).idxOf y) := by
      rcases h with h | ⟨h, hlt⟩
      · exact Or.inl h
      · refine Or.inr ⟨h, ?_⟩
        exact (idx_filter_iff (fun z => decide (z = k ∨ z = y)) rec k y hk hy (by simp) (by simp)).mpr hlt
    obtain ⟨X, _, hX, hnm⟩ := clash hu hc hFL hkL hyL h'
    refine ⟨not_fixed_of_FL hu hc hFL, _, hX, y, hy, hyk, ?_, hnm⟩
    rcases h with h | ⟨h, _⟩
    · exact onBarFixed_P hu h
    · exact onBarFixed_B hu h

/-! ### The general all-match lemma -/

theorem allmatch_gen {r : Read} (hu : r.usable) {L : List Key} (hnd : L.Nodup) (hok : OkL r L)
    (hsingle : ∀ c1 c2, c1 ∈ L → c2 ∈ L → FL r c1 → FL r c2 → c1 = c2)
    (hclash : ∀ c ∈ L, FL r c → ∀ y ∈ L, y ∉ r.pinOpen ∧ (y ∈ r.pinBehind → L.idxOf y < L.idxOf c)) :
    ∀ b, Possible r b → barMatches L b := by
  intro b hb
  by_cases hex : ∃ c ∈ L, FL r c
  · obtain ⟨c, hcL, hcF⟩ := hex
    have hO : ∀ z ∈ b.open_, z ∈ L → z = c := by
      intro z hz hzL
      rcases open_cls hu hb hz with h | h
      · exact absurd h (hclash c hcL hcF z hzL).1
      · exact hsingle z c hzL hcL h hcF
    refine match_single hnd hb.1.1 hO ?_
    intro x hx z hz hxL hzL
    have hzc := hO z hz hzL
    rcases behind_cls hu hb hx with h | h
    · rw [hzc]; exact (hclash c hcL hcF x hxL).2 h
    · have := hsingle x c hxL hcL h hcF
      exact absurd (hzc ▸ hz) (fun hh => wf_not_both hb.1 hh (this ▸ hx))
  · refine match_pinned hu hb hok ?_ ?_
    · intro z hz hzL
      rcases open_cls hu hb hz with h | h
      · exact h
      · exact absurd ⟨z, hzL, h⟩ hex
    · intro x hx hxL
      rcases behind_cls hu hb hx with h | h
      · exact h
      · exact absurd ⟨x, hxL, h⟩ hex

theorem okL_filter {r : Read} {rec U : List Key} (hpin : ∀ k ∈ U, k ∉ r.pinOpen ∧ k ∉ r.pinBehind) :
    OkL r (rec.filter (fun k => k ∉ U)) ↔ OkL r rec := by
  unfold OkL
  have e1 : (rec.filter (fun k => k ∉ U)).filter (fun z => z ∈ r.pinOpen) = rec.filter (fun z => z ∈ r.pinOpen) := by
    rw [List.filter_filter]; apply List.filter_congr; intro z _
    by_cases hz : z ∈ r.pinOpen
    · have : z ∉ U := fun h => (hpin z h).1 hz
      simp [hz, this]
    · simp [hz]
  have e2 : r.pinOpen.filter (fun z => z ∈ rec.filter (fun k => k ∉ U)) = r.pinOpen.filter (fun z => z ∈ rec) := by
    apply List.filter_congr; intro z hz
    have : z ∉ U := fun h => (hpin z h).1 hz
    simp [List.mem_filter, this]
  rw [e1, e2]
  apply and_congr Iff.rfl
  constructor
  · intro h x hx y hy hxL hyL
    have hxU : x ∉ U := fun h => (hpin x h).2 hx
    have hyU : y ∉ U := fun h => (hpin y h).1 hy
    have := h x hx y hy (List.mem_filter.mpr ⟨hxL, by simp [hxU]⟩) (List.mem_filter.mpr ⟨hyL, by simp [hyU]⟩)
    exact (idx_filter_iff (fun k => decide (k ∉ U)) rec x y hxL hyL (by simp [hxU]) (by simp [hyU])).mp this
  · intro h x hx y hy hxL hyL
    have hxU : x ∉ U := fun h => (hpin x h).2 hx
    have hyU : y ∉ U := fun h => (hpin y h).1 hy
    have hxL' := (List.mem_filter.mp hxL).1
    have hyL' := (List.mem_filter.mp hyL).1
    exact (idx_filter_iff (fun k => decide (k ∉ U)) rec x y hxL' hyL' (by simp [hxU]) (by simp [hyU])).mpr
      (h x hx y hy hxL' hyL')

/-! ### The verdict on a usable, consistent read -/

section UC
variable {r : Read} {rec : List Key}

theorem forced_nomatch (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup)
    (hf : forcedBad rec r = true) : ∀ b, Possible r b → ¬ barMatches rec b := by
  intro b hb hm
  have := (forcedBad_iff hc hnd).mpr (okL_of_match hu hb hm)
  rw [this] at hf; exact absurd hf (by decide)

theorem unforced_match (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup)
    (hf : forcedBad rec r = false) : barMatches rec ⟨r.pinOpen, dd r.pinBehind⟩ :=
  match_pinned hu (poss_P hu hc) ((forcedBad_iff hc hnd).mp hf) (fun z hz _ => hz) (fun x hx _ => mem_dd.mp hx)

theorem nodup_Rcomp (hnd : rec.Nodup) : (Rcomp rec r).Nodup :=
  nodup_filter' _ (nodup_filter' _ hnd)

theorem nodup_Ucomp (hnd : rec.Nodup) : (Ucomp rec r).Nodup := nodup_filter' _ hnd

theorem uc_matches (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    verdict rec r = .matches ↔ ∀ b, Possible r b → barMatches rec b := by
  constructor
  · intro hv
    by_cases hf : forcedBad rec r = true
    · rw [verdict_forced rec hu hc hf] at hv; cases hv
    have hf' : forcedBad rec r = false := by simpa using hf
    rw [verdict_else rec hu hc hf'] at hv
    by_cases hR : (Rcomp rec r).length ≥ 2
    · simp [hR] at hv
    by_cases hU : (Ucomp rec r).isEmpty = true
    · have hU' : Ucomp rec r = [] := List.isEmpty_iff.mp hU
      have hnoP : ∀ k ∈ rec, ¬ PartyB rec r k := by
        intro k hk hp
        have : k ∈ Ucomp rec r := (mem_U hu).mpr ⟨hk, hp⟩
        rw [hU'] at this; simp at this
      refine allmatch_gen hu hnd ((forcedBad_iff hc hnd).mp hf') ?_ ?_
      · intro c1 c2 h1 h2 f1 f2
        exact lt_two (by omega) ((mem_R hu).mpr ⟨h1, f1, hnoP c1 h1⟩) ((mem_R hu).mpr ⟨h2, f2, hnoP c2 h2⟩)
      · intro c hcL hcF y hy
        have hn : ¬ (y ∈ r.pinOpen ∨ (y ∈ r.pinBehind ∧ rec.idxOf c < rec.idxOf y)) := fun h => hnoP c hcL ⟨hcF, y, hy, h⟩
        refine ⟨fun h => hn (Or.inl h), fun hB => ?_⟩
        have hne : y ≠ c := fun e => hcF.2.1 (e ▸ hB)
        rcases idx_lt_or hy hcL hne with h | h
        · exact h
        · exact absurd (Or.inr ⟨hB, h⟩) hn
    · simp [hR, hU] at hv
  · intro hall
    have hf : forcedBad rec r = false := by
      refine Classical.byContradiction fun h => ?_
      have h' : forcedBad rec r = true := by simpa using h
      exact forced_nomatch hu hc hnd h' _ (poss_P hu hc) (hall _ (poss_P hu hc))
    rw [verdict_else rec hu hc hf]
    by_cases hR : (Rcomp rec r).length ≥ 2
    · exfalso
      obtain ⟨a, b, ha, hb, hab⟩ := two_elems (nodup_Rcomp hnd) hR
      obtain ⟨ha1, ha2, _⟩ := (mem_R hu).mp ha
      obtain ⟨hb1, hb2, _⟩ := (mem_R hu).mp hb
      rcases idx_lt_or ha1 hb1 hab with h | h
      · exact (clash2 hu hc ha2 hb2 ha1 hb1 h).2 (hall _ (clash2 hu hc ha2 hb2 ha1 hb1 h).1)
      · exact (clash2 hu hc hb2 ha2 hb1 ha1 h).2 (hall _ (clash2 hu hc hb2 ha2 hb1 ha1 h).1)
    by_cases hU : (Ucomp rec r).isEmpty = true
    · simp [hR, hU]
    · exfalso
      have : ∃ u, u ∈ Ucomp rec r := by
        cases h : Ucomp rec r with
        | nil => simp [h] at hU
        | cons u t => exact ⟨u, by simp⟩
      obtain ⟨u, hu'⟩ := this
      obtain ⟨huR, hFL, y, hy, hyc⟩ := (mem_U hu).mp hu'
      obtain ⟨X, _, hX, hnm⟩ := clash hu hc hFL huR hy hyc
      exact hnm (hall _ hX)

theorem uc_differs (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    verdict rec r = .differs ↔ ∀ b, Possible r b → ¬ barMatches rec b := by
  constructor
  · intro hv
    by_cases hf : forcedBad rec r = true
    · exact forced_nomatch hu hc hnd hf
    · have hf' : forcedBad rec r = false := by simpa using hf
      rw [verdict_else rec hu hc hf'] at hv
      by_cases h1 : (Rcomp rec r).length ≥ 2
      · simp [h1] at hv
      · by_cases h2 : (Ucomp rec r).isEmpty = true
        · simp [h1, h2] at hv
        · simp [h1, h2] at hv
  · intro hall
    by_cases hf : forcedBad rec r = true
    · exact verdict_forced rec hu hc hf
    · have hf' : forcedBad rec r = false := by simpa using hf
      exact absurd (unforced_match hu hc hnd hf') (hall _ (poss_P hu hc))

theorem pin_not_U (hu : r.usable) {k : Key} (hk : k ∈ Ucomp rec r) : k ∉ r.pinOpen ∧ k ∉ r.pinBehind :=
  ((mem_U hu).mp hk).2.1 |> fun h => ⟨h.1, h.2.1⟩

theorem Ucomp_fix (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) :
    rec.filter (fun k => k ∈ Ucomp rec r) = Ucomp rec r := by
  unfold Ucomp
  apply List.filter_congr
  intro k hk
  have : (k ∈ rec.filter (party rec r)) ↔ party rec r k = true := by simp [List.mem_filter, hk]
  by_cases h : party rec r k = true
  · simp [this.mpr h, h]
  · have : ¬ (k ∈ rec.filter (party rec r)) := fun h' => h (this.mp h')
    simp [this]; simpa using h

theorem uc_except_fwd (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) (U : List Key)
    (hv : verdict rec r = .matchesExcept U) : ValidU rec r U ∧ forcedBad rec r = false ∧ U = Ucomp rec r := by
  have hf : forcedBad rec r = false := by
    refine Classical.byContradiction fun h => ?_
    have h' : forcedBad rec r = true := by simpa using h
    rw [verdict_forced rec hu hc h'] at hv; cases hv
  rw [verdict_else rec hu hc hf] at hv
  by_cases hR : (Rcomp rec r).length ≥ 2
  · simp [hR] at hv
  by_cases hU : (Ucomp rec r).isEmpty = true
  · simp [hR, hU] at hv
  simp only [hR, hU, if_false, Verdict.matchesExcept.injEq, ge_iff_le, Bool.false_eq_true] at hv
  subst hv
  have hne : Ucomp rec r ≠ [] := fun h => hU (by simp [h])
  have hpin : ∀ k ∈ Ucomp rec r, k ∉ r.pinOpen ∧ k ∉ r.pinBehind := fun k hk => pin_not_U hu hk
  refine ⟨⟨hne, nodup_Ucomp hnd, fun k hk => ((mem_U hu).mp hk).1, (Ucomp_fix hu hc hnd).symm, ?_, ?_, ?_⟩, hf, rfl⟩
  · -- every possible bar matches once U is set aside
    intro b hb
    unfold barMatchesExcept
    have hRlt : (Rcomp rec r).length < 2 := by omega
    refine allmatch_gen hu (nodup_filter' _ hnd) ((okL_filter hpin).mpr ((forcedBad_iff hc hnd).mp hf)) ?_ ?_ b hb
    · intro c1 c2 h1 h2 f1 f2
      obtain ⟨h1', h1u⟩ := List.mem_filter.mp h1
      obtain ⟨h2', h2u⟩ := List.mem_filter.mp h2
      have g1 : ¬ PartyB rec r c1 := fun h => by simp [mem_U hu] at h1u; exact h1u h1' h
      have g2 : ¬ PartyB rec r c2 := fun h => by simp [mem_U hu] at h2u; exact h2u h2' h
      exact lt_two hRlt ((mem_R hu).mpr ⟨h1', f1, g1⟩) ((mem_R hu).mpr ⟨h2', f2, g2⟩)
    · intro c hcL hcF y hy
      obtain ⟨hc', hcu⟩ := List.mem_filter.mp hcL
      obtain ⟨hy', hyu⟩ := List.mem_filter.mp hy
      have g : ¬ PartyB rec r c := fun h => by simp [mem_U hu] at hcu; exact hcu hc' h
      have hn : ¬ (y ∈ r.pinOpen ∨ (y ∈ r.pinBehind ∧ rec.idxOf c < rec.idxOf y)) := fun h => g ⟨hcF, y, hy', h⟩
      refine ⟨fun h => hn (Or.inl h), fun hB => ?_⟩
      have hne : y ≠ c := fun e => hcF.2.1 (e ▸ hB)
      have hyU : y ∉ Ucomp rec r := by simpa using hyu
      have hcU : c ∉ Ucomp rec r := by simpa using hcu
      rcases idx_lt_or hy' hc' hne with h | h
      · exact (idx_filter_iff (fun k => decide (k ∉ Ucomp rec r)) rec y c hy' hc' (by simp [hyU]) (by simp [hcU])).mpr h
      · exact absurd (Or.inr ⟨hB, h⟩) hn
  · intro k hk
    rw [mem_U hu, party_Party hu hc hnd hk]
    simp [hk]
  · obtain ⟨u, hu'⟩ : ∃ u, u ∈ Ucomp rec r := by
      cases h : Ucomp rec r with
      | nil => exact absurd h hne
      | cons u t => exact ⟨u, by simp⟩
    obtain ⟨huR, hFL, y, hy, hyc⟩ := (mem_U hu).mp hu'
    refine ⟨y, hy, ?_, ?_⟩
    · intro hyU
      have := ((mem_U hu).mp hyU).2.1
      rcases hyc with h | ⟨h, _⟩
      · exact this.1 h
      · exact this.2.1 h
    · rcases hyc with h | ⟨h, _⟩
      · exact onBarFixed_P hu h
      · exact onBarFixed_B hu h

theorem uc_except_bwd (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup) (U : List Key)
    (hv : ValidU rec r U) : verdict rec r = .matchesExcept U := by
  obtain ⟨hne, hnd', hsub, hfil, hall, hiff, hfix⟩ := hv
  have hUe : U = Ucomp rec r := by
    calc U = rec.filter (fun k => k ∈ U) := hfil
      _ = Ucomp rec r := by
        unfold Ucomp
        apply List.filter_congr
        intro k hk
        have h1 := hiff k hk
        rw [party_Party hu hc hnd hk, ← party_iff hu] at h1
        by_cases h : k ∈ U
        · simp [h, h1.mp h]
        · have : party rec r k ≠ true := fun h' => h (h1.mpr h')
          simp [h]; simpa using this
  subst hUe
  have hpin : ∀ k ∈ Ucomp rec r, k ∉ r.pinOpen ∧ k ∉ r.pinBehind := fun k hk => pin_not_U hu hk
  have hf : forcedBad rec r = false := by
    have h1 := hall _ (poss_P hu hc)
    have h2 := okL_of_match hu (poss_P hu hc) h1
    exact (forcedBad_iff hc hnd).mpr ((okL_filter hpin).mp h2)
  rw [verdict_else rec hu hc hf]
  by_cases hR : (Rcomp rec r).length ≥ 2
  · exfalso
    obtain ⟨a, b, ha, hb, hab⟩ := two_elems (nodup_Rcomp hnd) hR
    obtain ⟨ha1, ha2, ha3⟩ := (mem_R hu).mp ha
    obtain ⟨hb1, hb2, hb3⟩ := (mem_R hu).mp hb
    have haU : a ∉ Ucomp rec r := fun h => ha3 ((mem_U hu).mp h).2
    have hbU : b ∉ Ucomp rec r := fun h => hb3 ((mem_U hu).mp h).2
    have haL : a ∈ rec.filter (fun k => k ∉ Ucomp rec r) := List.mem_filter.mpr ⟨ha1, by simp [haU]⟩
    have hbL : b ∈ rec.filter (fun k => k ∉ Ucomp rec r) := List.mem_filter.mpr ⟨hb1, by simp [hbU]⟩
    rcases idx_lt_or ha1 hb1 hab with h | h
    · have h' := (idx_filter_iff (fun k => decide (k ∉ Ucomp rec r)) rec a b ha1 hb1 (by simp [haU]) (by simp [hbU])).mpr h
      exact (clash2 hu hc ha2 hb2 haL hbL h').2 (hall _ (clash2 hu hc ha2 hb2 haL hbL h').1)
    · have h' := (idx_filter_iff (fun k => decide (k ∉ Ucomp rec r)) rec b a hb1 ha1 (by simp [hbU]) (by simp [haU])).mpr h
      exact (clash2 hu hc hb2 ha2 hbL haL h').2 (hall _ (clash2 hu hc hb2 ha2 hbL haL h').1)
  · have : (Ucomp rec r).isEmpty = false := by
      cases h : Ucomp rec r with
      | nil => exact absurd h hne
      | cons u t => rfl
    simp [hR, this]

end UC

theorem bar_empty_matches (L : List Key) : barMatches L ⟨[], []⟩ := by
  refine ⟨by simp, by simp⟩

theorem place_empty (k : Key) : Bar.place ⟨[], []⟩ k = .absent := by
  unfold Bar.place; simp

theorem no_poss_unusable_fixed {r : Read} (hu : ¬ r.usable) {k : Key} : ¬ OnBarFixed r k := by
  rintro ⟨p, hp, hall⟩
  have := hall ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩)
  rw [place_empty] at this
  exact hp this.symm

theorem not_exists_of_incons {r : Read} (hu : r.usable) (hc : ¬ r.consistent = true) : ¬ ∃ b, Possible r b :=
  fun he => hc ((exists_poss_iff r).mp he hu)

/-! ### Step 5: the theorems (statements only; proofs come after approval) -/

/-- T1. `matches` means: the read is usable, some bar is allowed, and every allowed bar matches.  The `∃` keeps "every bar
matches" from being vacuous for a reading no bar could have produced.  The `usable` conjunct: on an unusable read with 0 or 1
record keys every allowed bar trivially matches, which would be true but empty (the adapter shows "Checking" before a good read). -/
theorem verdict_matches_iff (rec : List Key) (r : Read) (h : rec.Nodup) :
    verdict rec r = .matches ↔ r.usable ∧ (∃ b, Possible r b) ∧ ∀ b, Possible r b → barMatches rec b := by
  
  by_cases hu : r.usable
  · by_cases hc : r.consistent = true
    · rw [uc_matches hu hc h]
      exact ⟨fun hall => ⟨hu, ⟨_, poss_P hu hc⟩, hall⟩, fun hh => hh.2.2⟩
    · have hc' : r.consistent = false := by simpa using hc
      rw [verdict_incons rec hc']
      have := not_exists_of_incons hu hc
      simp [this]
  · rw [verdict_unusable rec hu]; simp [hu]

/-- T2. `differs` means: some bar is allowed, and no allowed bar matches. -/
theorem verdict_differs_iff (rec : List Key) (r : Read) (h : rec.Nodup) :
    verdict rec r = .differs ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → ¬ barMatches rec b := by
  
  by_cases hu : r.usable
  · by_cases hc : r.consistent = true
    · rw [uc_differs hu hc h]
      exact ⟨fun hall => ⟨⟨_, poss_P hu hc⟩, hall⟩, fun hh => hh.2⟩
    · have hc' : r.consistent = false := by simpa using hc
      rw [verdict_incons rec hc']
      have := not_exists_of_incons hu hc
      simp [this]
  · rw [verdict_unusable rec hu]
    simp only [reduceCtorEq, false_iff]
    rintro ⟨_, hall⟩
    exact hall ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩) (bar_empty_matches rec)

/-- T3. `matchesExcept U` means: some bar is allowed and `U` is valid (see `ValidU`). -/
theorem verdict_except_iff (rec : List Key) (r : Read) (U : List Key) (h : rec.Nodup) :
    verdict rec r = .matchesExcept U ↔ (∃ b, Possible r b) ∧ ValidU rec r U := by
  
  by_cases hu : r.usable
  · by_cases hc : r.consistent = true
    · exact ⟨fun hv => ⟨⟨_, poss_P hu hc⟩, (uc_except_fwd hu hc h U hv).1⟩, fun hh => uc_except_bwd hu hc h U hh.2⟩
    · have hc' : r.consistent = false := by simpa using hc
      rw [verdict_incons rec hc']
      have := not_exists_of_incons hu hc
      simp [this]
  · rw [verdict_unusable rec hu]
    simp only [reduceCtorEq, false_iff]
    rintro ⟨_, _, _, _, _, _, _, k, _, _, hk⟩
    exact no_poss_unusable_fixed hu hk

/-- T3 (consequences, stated for reading): `U` is nonempty and in the record, every allowed bar matches without `U`, and every
member is not padding: there are allowed bars `b1`, `b2` that differ only in where `k` stands, `b1` matching and `b2` not. -/
theorem verdict_except (rec : List Key) (r : Read) (U : List Key) (h : rec.Nodup)
    (hv : verdict rec r = .matchesExcept U) :
    U ≠ [] ∧ (∀ k ∈ U, k ∈ rec) ∧ (∃ b, Possible r b) ∧
    (∀ b, Possible r b → barMatchesExcept U rec b) ∧
    (∀ k ∈ U, ∃ b2, Possible r b2 ∧ ¬ barMatches rec b2 ∧ Possible r (b2.without k) ∧ barMatches rec (b2.without k)) := by
  
  obtain ⟨he, hvu⟩ := (verdict_except_iff rec r U h).mp hv
  have hu : r.usable := Classical.byContradiction fun hu => by
    rw [verdict_unusable rec hu] at hv; cases hv
  have hc : r.consistent = true := Classical.byContradiction fun hc => by
    have hc' : r.consistent = false := by simpa using hc
    rw [verdict_incons rec hc'] at hv; cases hv
  obtain ⟨hV, hf, hUe⟩ := uc_except_fwd hu hc h U hv
  refine ⟨hV.1, hV.2.2.1, he, hV.2.2.2.2.1, ?_⟩
  intro k hk
  have hk' : k ∈ Ucomp rec r := hUe ▸ hk
  obtain ⟨hkr, hFL, y, hy, hyc⟩ := (mem_U hu).mp hk'
  obtain ⟨X, hX, hposs, hnm⟩ := clash hu hc hFL hkr hy hyc
  refine ⟨⟨X, dd r.pinBehind⟩, hposs, hnm, ?_⟩
  have h1 : r.pinOpen.filter (fun x => x ≠ k) = r.pinOpen :=
    List.filter_eq_self.mpr (fun a ha => by simp; exact fun e => hFL.1 (e ▸ ha))
  have h2 : (dd r.pinBehind).filter (fun x => x ≠ k) = dd r.pinBehind :=
    List.filter_eq_self.mpr (fun a ha => by simp; exact fun e => hFL.2.1 (e ▸ mem_dd.mp ha))
  have hw : Bar.without ⟨X, dd r.pinBehind⟩ k = ⟨r.pinOpen, dd r.pinBehind⟩ := by
    have h3 : [k].filter (fun x => decide (x ≠ k)) = [] := by simp
    unfold Bar.without
    rcases hX with rfl | rfl
    · simp only [List.filter_append, h1, h2, h3, List.nil_append]
    · simp only [List.filter_append, h1, h2, h3, List.append_nil]
  rw [hw]
  exact ⟨poss_P hu hc, unforced_match hu hc h hf⟩

/-- T4. `cannotTell` is exactly the rest: the read is not usable, or no bar is allowed, or the allowed bars disagree and there is
no valid `U`.  So `cannotTell` is never an escape hatch: it is reached only when the truth is not determined (or the read is no
witness of the bar). -/
theorem verdict_cannotTell_iff (rec : List Key) (r : Read) (h : rec.Nodup) :
    verdict rec r = .cannotTell ↔
      ¬ r.usable ∨ ¬ (∃ b, Possible r b) ∨
      ((∃ b, Possible r b) ∧ ¬ AllMatch rec r ∧ ¬ AllDiffer rec r ∧ ¬ ∃ U, ValidU rec r U) := by
  
  constructor
  · intro hv
    by_cases hu : r.usable
    · by_cases he : ∃ b, Possible r b
      · refine Or.inr (Or.inr ⟨he, ?_, ?_, ?_⟩)
        · rintro ⟨_, hm⟩
          have := (verdict_matches_iff rec r h).mpr ⟨hu, he, hm⟩
          rw [hv] at this; cases this
        · rintro ⟨_, hd⟩
          have := (verdict_differs_iff rec r h).mpr ⟨he, hd⟩
          rw [hv] at this; cases this
        · rintro ⟨U, hU⟩
          have := (verdict_except_iff rec r U h).mpr ⟨he, hU⟩
          rw [hv] at this; cases this
      · exact Or.inr (Or.inl he)
    · exact Or.inl hu
  · intro hr
    cases hv : verdict rec r with
    | cannotTell => rfl
    | «matches» =>
      have := (verdict_matches_iff rec r h).mp hv
      rcases hr with hr | hr | ⟨_, hn1, _, _⟩
      · exact absurd this.1 hr
      · exact absurd this.2.1 hr
      · exact absurd ⟨this.2.1, this.2.2⟩ hn1
    | differs =>
      have := (verdict_differs_iff rec r h).mp hv
      rcases hr with hr | hr | ⟨_, _, hn2, _⟩
      · exfalso
        by_cases hu : r.usable
        · exact hr hu
        · rw [verdict_unusable rec hu] at hv; cases hv
      · exact absurd this.1 hr
      · exact absurd this hn2
    | matchesExcept U =>
      have := (verdict_except_iff rec r U h).mp hv
      rcases hr with hr | hr | ⟨_, _, _, hn3⟩
      · exfalso
        by_cases hu : r.usable
        · exact hr hu
        · rw [verdict_unusable rec hu] at hv; cases hv
      · exact absurd this.1 hr
      · exact absurd ⟨U, this.2⟩ hn3

/-! #### T5: rows

What a tick (`inOrder`) CLAIMS under unknown keys: on every honest bar `k` is open, and among the keys whose place the reading
establishes (`Fixed`), exactly `k`'s record predecessors stand to its left.  Keys the reading cannot place are not counted either
way, so one unknown key never turns the other rows to "can't tell"; but a tick says nothing about where the unknown keys are. -/

/-- Row order for `k` on `b`, relative to the keys the reading fixes: for every other record key `x` whose place is the same on every
allowed bar, `x` is a record predecessor of `k` and open iff `x` stands left of `k` in the open keys. -/
def RowOrderOK (r : Read) (rec : List Key) (b : Bar) (k : Key) : Prop :=
  ∀ x ∈ rec, x ≠ k → Fixed r x → ((x ∈ rec.takeWhile (fun y => y != k) ∧ x ∈ b.open_) ↔ x ∈ b.open_.takeWhile (fun y => y != k))

/-- `k` is open and in order (relative to the fixed keys). -/
def RowPlaced (r : Read) (rec : List Key) (b : Bar) (k : Key) : Prop := k ∈ b.open_ ∧ RowOrderOK r rec b k
/-- `k` is open and out of order. -/
def RowMisplaced (r : Read) (rec : List Key) (b : Bar) (k : Key) : Prop := k ∈ b.open_ ∧ ¬ RowOrderOK r rec b k
/-- `k` is behind the chevron although a record key before it is open (rule 2, `k` is the one folded out of turn). -/
def OutOfTurn (rec : List Key) (b : Bar) (k : Key) : Prop := k ∈ b.behind ∧ ∃ y ∈ rec.takeWhile (fun z => z != k), y ∈ b.open_


/-! ### Proof infrastructure: rows -/

section Rows
variable {r : Read} {rec : List Key} {k : Key}

/-- a record key before `k` is pinned open -/
def QOT (rec : List Key) (r : Read) (k : Key) : Prop := ∃ y ∈ rec.takeWhile (fun z => z != k), y ∈ r.pinOpen

/-- among pinned open record keys, the order relative to `k` agrees with the read -/
def RO (rec : List Key) (r : Read) (k : Key) : Prop :=
  ∀ x ∈ rec, x ≠ k → x ∈ r.pinOpen →
    (x ∈ rec.takeWhile (fun y => y != k) ↔ r.pinOpen.idxOf x < r.pinOpen.idxOf k)

theorem rv_incons (hc : r.consistent = false) : rowVerdict rec r k = .cannotTell := by
  unfold rowVerdict; simp [hc]

theorem rv_unusable (hu : ¬ r.usable) : rowVerdict rec r k = .cannotTell := by
  unfold rowVerdict
  simp [consistent_unusable hu, pinOpen_unusable hu, pinBehind_unusable hu, Read.openOK, hu]

theorem any_QOT : (rec.any fun y => (rec.takeWhile fun z => z != k).contains y && r.pinOpen.contains y) = true ↔
    QOT rec r k := by
  unfold QOT
  simp only [List.any_eq_true, Bool.and_eq_true, List.contains_iff_mem]
  constructor
  · rintro ⟨y, _, h1, h2⟩; exact ⟨y, h1, h2⟩
  · rintro ⟨y, h1, h2⟩; exact ⟨y, tw_sub h1, h1, h2⟩

theorem rv_B1 (hc : r.consistent = true) (hk : k ∈ r.pinBehind) (hq : QOT rec r k) :
    rowVerdict rec r k = .behindOutOfTurn := by
  unfold rowVerdict
  have := any_QOT.mpr hq
  have hb : r.pinBehind.contains k = true := List.contains_iff_mem.mpr hk
  simp only [hc, Bool.not_true, Bool.false_eq_true, ite_false, hb, this, ite_true]

theorem rv_B2 (hc : r.consistent = true) (hk : k ∈ r.pinBehind) (hq : ¬ QOT rec r k) :
    rowVerdict rec r k = .behindChevron := by
  unfold rowVerdict
  have : ¬ ((rec.any fun y => (rec.takeWhile fun z => z != k).contains y && r.pinOpen.contains y) = true) :=
    fun h => hq (any_QOT.mp h)
  have hb : r.pinBehind.contains k = true := List.contains_iff_mem.mpr hk
  simp only [hc, Bool.not_true, Bool.false_eq_true, ite_false, hb, ite_true, this]

theorem bne_dec_iff (a b : Prop) [Decidable a] [Decidable b] : (decide a != decide b) = true ↔ ¬ (a ↔ b) := by
  by_cases ha : a <;> by_cases hb : b <;> simp [ha, hb]

theorem any_RO : (rec.any fun x => x != k && r.pinOpen.contains x &&
      (decide (x ∈ rec.takeWhile fun y => y != k) != decide (r.pinOpen.idxOf x < r.pinOpen.idxOf k))) = true ↔
    ¬ RO rec r k := by
  constructor
  · intro h hro
    rw [List.any_eq_true] at h
    obtain ⟨x, hx, hb⟩ := h
    simp only [Bool.and_eq_true, List.contains_iff_mem, bne_iff_ne, ne_eq] at hb
    obtain ⟨⟨hxk, hxP⟩, hne⟩ := hb
    have := hro x hx (by simpa using hxk) hxP
    exact (bne_dec_iff _ _).mp (by simpa using hne) this
  · intro hnro
    refine Classical.byContradiction fun hany => hnro ?_
    intro x hx hxk hxP
    refine Classical.byContradiction fun hnot => hany ?_
    rw [List.any_eq_true]
    refine ⟨x, hx, ?_⟩
    simp only [Bool.and_eq_true, List.contains_iff_mem]
    refine ⟨⟨by simpa using hxk, hxP⟩, (bne_dec_iff _ _).mpr hnot⟩

theorem rv_P1 (hc : r.consistent = true) (hk : k ∈ r.pinOpen) (hq : RO rec r k) : rowVerdict rec r k = .inOrder := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  have hkB : k ∉ r.pinBehind := hd k hk
  unfold rowVerdict
  have : ¬ ((rec.any fun x => x != k && r.pinOpen.contains x &&
      (decide (x ∈ rec.takeWhile fun y => y != k) != decide (r.pinOpen.idxOf x < r.pinOpen.idxOf k))) = true) :=
    fun h => (any_RO.mp h) hq
  have hb : r.pinBehind.contains k = false := by simpa [List.contains_iff_mem] using hkB
  have hp : r.pinOpen.contains k = true := List.contains_iff_mem.mpr hk
  simp only [hc, Bool.not_true, Bool.false_eq_true, ite_false, hb, hp, ite_true, this]

theorem rv_P2 (hc : r.consistent = true) (hk : k ∈ r.pinOpen) (hq : ¬ RO rec r k) : rowVerdict rec r k = .outOfPlace := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  have hkB : k ∉ r.pinBehind := hd k hk
  unfold rowVerdict
  have := any_RO.mpr hq
  have hb : r.pinBehind.contains k = false := by simpa [List.contains_iff_mem] using hkB
  have hp : r.pinOpen.contains k = true := List.contains_iff_mem.mpr hk
  simp only [hc, Bool.not_true, Bool.false_eq_true, ite_false, hb, hp, ite_true, this]

theorem rv_F (hu : r.usable) (hc : r.consistent = true) (hk : FL r k) : rowVerdict rec r k = .cannotTell := by
  unfold rowVerdict
  simp [hc, List.contains_iff_mem, hk.1, hk.2.1, Read.openOK, hu, hk.2.2]

theorem rv_N (hu : r.usable) (hc : r.consistent = true) (h1 : k ∉ r.pinOpen) (h2 : k ∉ r.pinBehind)
    (h3 : ¬ r.listed k) : rowVerdict rec r k = .notOnBar := by
  unfold rowVerdict
  simp [hc, List.contains_iff_mem, h1, h2, Read.openOK, hu, h3]

theorem idxP_iff (hu : r.usable) {b : Bar} (hp : Possible r b) {x y : Key} (hx : x ∈ r.pinOpen) (hy : y ∈ r.pinOpen) :
    b.open_.idxOf x < b.open_.idxOf y ↔ r.pinOpen.idxOf x < r.pinOpen.idxOf y := by
  have hf := ((poss_iff hu b).mp hp).2.1
  have := idx_filter_iff (fun z => decide (z ∈ r.pinOpen)) b.open_ x y (poss_pin_open hu hp hx) (poss_pin_open hu hp hy)
    (by simp [hx]) (by simp [hy])
  rw [hf] at this
  exact this.symm

theorem not_open_of_fixed (hu : r.usable) (hc : r.consistent = true) {b : Bar} (hp : Possible r b) {x : Key}
    (hx : Fixed r x) (hxP : x ∉ r.pinOpen) : x ∉ b.open_ := by
  intro ho
  rcases open_cls hu hp ho with h | h
  · exact hxP h
  · exact not_fixed_of_FL hu hc h hx

theorem rowOK_iff (hu : r.usable) (hc : r.consistent = true) (hk : k ∈ r.pinOpen) {b : Bar} (hp : Possible r b) :
    RowOrderOK r rec b k ↔ RO rec r k := by
  have hko := poss_pin_open hu hp hk
  constructor
  · intro h x hx hxk hxP
    obtain ⟨pp, _, hpp⟩ := onBarFixed_P hu hxP
    have := h x hx hxk ⟨pp, hpp⟩
    have hxo := poss_pin_open hu hp hxP
    rw [tw_mem hko x] at this
    rw [← idxP_iff hu hp hxP hk]
    constructor
    · intro hh; exact (this.mp ⟨hh, hxo⟩).2
    · intro hh; exact (this.mpr ⟨hxo, hh⟩).1
  · intro h x hx hxk hfx
    rw [tw_mem hko x]
    by_cases hxP : x ∈ r.pinOpen
    · have hxo := poss_pin_open hu hp hxP
      have := h x hx hxk hxP
      rw [← idxP_iff hu hp hxP hk] at this
      constructor
      · rintro ⟨hh, _⟩; exact ⟨hxo, this.mp hh⟩
      · rintro ⟨_, hh⟩; exact ⟨this.mpr hh, hxo⟩
    · have := not_open_of_fixed hu hc hp hfx hxP
      constructor
      · rintro ⟨_, hh⟩; exact absurd hh this
      · rintro ⟨hh, _⟩; exact absurd hh this

abbrev RE (r : Read) : Prop := ∃ b, Possible r b
abbrev RA (r : Read) (rec : List Key) (k : Key) : Prop := ∀ b, Possible r b → RowPlaced r rec b k
abbrev RM (r : Read) (rec : List Key) (k : Key) : Prop := ∀ b, Possible r b → RowMisplaced r rec b k
abbrev RH (r : Read) (k : Key) : Prop := ∀ b, Possible r b → k ∈ b.behind
abbrev RT (r : Read) (rec : List Key) (k : Key) : Prop := ∀ b, Possible r b → OutOfTurn rec b k
abbrev RN (r : Read) (k : Key) : Prop := ∀ b, Possible r b → k ∉ b.open_ ∧ k ∉ b.behind

theorem row_master (rec : List Key) (r : Read) (k : Key) :
    (rowVerdict rec r k = .cannotTell ∧ RE r ∧ ¬ RA r rec k ∧ ¬ RM r rec k ∧ ¬ RH r k ∧ ¬ RT r rec k ∧ ¬ RN r k) ∨
    (rowVerdict rec r k = .cannotTell ∧ ¬ RE r) ∨
    (rowVerdict rec r k = .behindChevron ∧ RE r ∧ RH r k ∧ ¬ RT r rec k ∧ ¬ RA r rec k ∧ ¬ RM r rec k ∧ ¬ RN r k) ∨
    (rowVerdict rec r k = .behindOutOfTurn ∧ RE r ∧ RH r k ∧ RT r rec k ∧ ¬ RA r rec k ∧ ¬ RM r rec k ∧ ¬ RN r k) ∨
    (rowVerdict rec r k = .outOfPlace ∧ RE r ∧ RM r rec k ∧ ¬ RA r rec k ∧ ¬ RH r k ∧ ¬ RT r rec k ∧ ¬ RN r k) ∨
    (rowVerdict rec r k = .inOrder ∧ RE r ∧ RA r rec k ∧ ¬ RM r rec k ∧ ¬ RH r k ∧ ¬ RT r rec k ∧ ¬ RN r k) ∨
    (rowVerdict rec r k = .notOnBar ∧ RE r ∧ RN r k ∧ ¬ RA r rec k ∧ ¬ RM r rec k ∧ ¬ RH r k ∧ ¬ RT r rec k) := by
  by_cases hu' : ¬ r.usable
  · have hu := hu'
    refine Or.inl ⟨rv_unusable hu, ?_, ?_, ?_, ?_, ?_, ?_⟩
    · exact ⟨⟨[], []⟩, (poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩⟩
    · intro h; have := (h ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩)).1; simp at this
    · intro h; have := (h ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩)).1; simp at this
    · intro h; have := h ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩); simp at this
    · intro h; have := (h ⟨[], []⟩ ((poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩)).1; simp at this
    · intro h
      have hp : Possible r ⟨[k], []⟩ := (poss_unusable hu _).mpr ⟨by simp, by simp, by simp⟩
      have := (h _ hp).1; simp at this
  have hu : r.usable := Classical.byContradiction hu'
  by_cases hc' : ¬ r.consistent = true
  · have hc := hc'
    have hc' : r.consistent = false := by simpa using hc
    exact Or.inr (Or.inl ⟨rv_incons hc', not_exists_of_incons hu hc⟩)
  have hc : r.consistent = true := Classical.byContradiction hc'
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  have hW := poss_P hu hc
  have hE : RE r := ⟨_, hW⟩
  by_cases hB : k ∈ r.pinBehind
  · have hkP : k ∉ r.pinOpen := fun h => hd k h hB
    have hH : RH r k := fun b hb => poss_pin_behind hu hb hB
    have hkW : k ∈ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).behind := mem_dd.mpr hB
    have hnW : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).open_ := hkP
    have nA : ¬ RA r rec k := fun h => hnW (h _ hW).1
    have nM : ¬ RM r rec k := fun h => hnW (h _ hW).1
    have nN : ¬ RN r k := fun h => (h _ hW).2 hkW
    have hiff : QOT rec r k ↔ RT r rec k := by
      constructor
      · rintro ⟨y, hy1, hy2⟩ b hb
        exact ⟨poss_pin_behind hu hb hB, y, hy1, poss_pin_open hu hb hy2⟩
      · intro h
        obtain ⟨_, y, hy1, hy2⟩ := h _ hW
        exact ⟨y, hy1, hy2⟩
    by_cases hq : QOT rec r k
    · rw [rv_B1 hc hB hq]
      exact Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, hE, hH, hiff.mp hq, nA, nM, nN⟩)))
    · rw [rv_B2 hc hB hq]
      exact Or.inr (Or.inr (Or.inl ⟨rfl, hE, hH, fun h => hq (hiff.mpr h), nA, nM, nN⟩))
  by_cases hP : k ∈ r.pinOpen
  · have hnW : k ∈ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).open_ := hP
    have hnb : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).behind := fun h => hB (mem_dd.mp h)
    have nH : ¬ RH r k := fun h => hnb (h _ hW)
    have nT : ¬ RT r rec k := fun h => hnb (h _ hW).1
    have nN : ¬ RN r k := fun h => (h _ hW).1 hnW
    by_cases hq : RO rec r k
    · rw [rv_P1 hc hP hq]
      have hA : RA r rec k := fun b hb => ⟨poss_pin_open hu hb hP, (rowOK_iff hu hc hP hb).mpr hq⟩
      have nM : ¬ RM r rec k := fun h => (h _ hW).2 ((rowOK_iff hu hc hP hW).mpr hq)
      exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, hE, hA, nM, nH, nT, nN⟩)))))
    · rw [rv_P2 hc hP hq]
      have hM : RM r rec k := fun b hb => ⟨poss_pin_open hu hb hP, fun h => hq ((rowOK_iff hu hc hP hb).mp h)⟩
      have nA : ¬ RA r rec k := fun h => hq ((rowOK_iff hu hc hP hW).mp (h _ hW).2)
      exact Or.inr (Or.inr (Or.inr (Or.inr (Or.inl ⟨rfl, hE, hM, nA, nH, nT, nN⟩))))
  by_cases hL : r.listed k
  · have hFL : FL r k := ⟨hP, hB, hL⟩
    have hnW : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).open_ := hP
    have hnb : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).behind := fun h => hB (mem_dd.mp h)
    have hp2 := poss_pre hu hc [k] (by simp) (by intro z hz; simp at hz; subst hz; exact hFL)
    refine Or.inl ⟨rv_F hu hc hFL, hE, fun h => hnW (h _ hW).1, fun h => hnW (h _ hW).1, fun h => hnb (h _ hW),
      fun h => hnb (h _ hW).1, fun h => (h _ hp2).1 (by simp)⟩
  · have hnW : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).open_ := hP
    have hnb : k ∉ (⟨r.pinOpen, dd r.pinBehind⟩ : Bar).behind := fun h => hB (mem_dd.mp h)
    have hN : RN r k := by
      intro b hb
      refine ⟨fun h => ?_, fun h => ?_⟩
      · rcases open_cls hu hb h with h' | h'
        · exact hP h'
        · exact hL h'.2.2
      · rcases behind_cls hu hb h with h' | h'
        · exact hB h'
        · exact hL h'.2.2
    refine Or.inr <| Or.inr <| Or.inr <| Or.inr <| Or.inr <| Or.inr <| ⟨rv_N hu hc hP hB hL, hE, hN, ?_, ?_, ?_, ?_⟩
    · exact fun h => hnW (h _ hW).1
    · exact fun h => hnW (h _ hW).1
    · exact fun h => hnb (h _ hW)
    · exact fun h => hnb (h _ hW).1

end Rows

theorem differs_forced {r : Read} {rec : List Key} (hu : r.usable) (hc : r.consistent = true)
    (hv : verdict rec r = .differs) : forcedBad rec r = true := by
  refine Classical.byContradiction fun h => ?_
  have hf : forcedBad rec r = false := by simpa using h
  rw [verdict_else rec hu hc hf] at hv
  by_cases h1 : (Rcomp rec r).length ≥ 2
  · simp [h1] at hv
  · by_cases h2 : (Ucomp rec r).isEmpty = true
    · simp [h1, h2] at hv
    · simp [h1, h2] at hv

theorem okL_cause {r : Read} {rec : List Key} (hu : r.usable) (hc : r.consistent = true) (hnd : rec.Nodup)
    (hno : ¬ OkL r rec) :
    ∃ k ∈ rec, rowVerdict rec r k = .outOfPlace ∨ rowVerdict rec r k = .behindOutOfTurn := by
  obtain ⟨hn, hd⟩ := consistent_iff.mp hc
  by_cases hA : rec.filter (fun z => z ∈ r.pinOpen) = r.pinOpen.filter (fun z => z ∈ rec)
  · -- the behind part fails
    have hB : ¬ ∀ x ∈ r.pinBehind, ∀ y ∈ r.pinOpen, x ∈ rec → y ∈ rec → rec.idxOf x < rec.idxOf y :=
      fun hB => hno ⟨hA, hB⟩
    obtain ⟨x, hx⟩ := Classical.not_forall.mp hB
    obtain ⟨hxB, hx⟩ := Classical.not_imp.mp hx
    obtain ⟨y, hy⟩ := Classical.not_forall.mp hx
    obtain ⟨hyP, hy⟩ := Classical.not_imp.mp hy
    obtain ⟨hxr, hy⟩ := Classical.not_imp.mp hy
    obtain ⟨hyr, hlt⟩ := Classical.not_imp.mp hy
    have hne : x ≠ y := fun e => hd y hyP (e ▸ hxB)
    have hlt' : rec.idxOf y < rec.idxOf x := by
      rcases idx_lt_or hxr hyr hne with h | h
      · exact absurd h hlt
      · exact h
    refine ⟨x, hxr, Or.inr (rv_B1 hc hxB ⟨y, ?_, hyP⟩)⟩
    exact (tw_mem hxr y).mpr ⟨hyr, hlt'⟩
  · -- the order of the pinned open keys fails
    have hmem : ∀ z, z ∈ r.pinOpen.filter (fun z => z ∈ rec) ↔ z ∈ rec.filter (fun z => z ∈ r.pinOpen) := by
      intro z; simp [List.mem_filter, and_comm]
    have hord : ¬ ∀ x y, x ∈ r.pinOpen.filter (fun z => z ∈ rec) → y ∈ r.pinOpen.filter (fun z => z ∈ rec) →
        (r.pinOpen.filter (fun z => z ∈ rec)).idxOf x < (r.pinOpen.filter (fun z => z ∈ rec)).idxOf y →
        (rec.filter (fun z => z ∈ r.pinOpen)).idxOf x < (rec.filter (fun z => z ∈ r.pinOpen)).idxOf y := by
      intro hord
      exact hA (eq_of_order _ _ (nodup_filter' _ hn) (nodup_filter' _ hnd) hmem hord).symm
    obtain ⟨x, hx⟩ := Classical.not_forall.mp hord
    obtain ⟨y, hy⟩ := Classical.not_forall.mp hx
    obtain ⟨hxC, hy⟩ := Classical.not_imp.mp hy
    obtain ⟨hyC, hy⟩ := Classical.not_imp.mp hy
    obtain ⟨hlt, hnlt⟩ := Classical.not_imp.mp hy
    obtain ⟨hxP, hxr⟩ : x ∈ r.pinOpen ∧ x ∈ rec := by simpa [List.mem_filter] using hxC
    obtain ⟨hyP, hyr⟩ : y ∈ r.pinOpen ∧ y ∈ rec := by simpa [List.mem_filter] using hyC
    have hPlt : r.pinOpen.idxOf x < r.pinOpen.idxOf y :=
      (idx_filter_iff (fun z => decide (z ∈ rec)) r.pinOpen x y hxP hyP (by simp [hxr]) (by simp [hyr])).mp hlt
    have hnrec : ¬ rec.idxOf x < rec.idxOf y := fun h =>
      hnlt ((idx_filter_iff (fun z => decide (z ∈ r.pinOpen)) rec x y hxr hyr (by simp [hxP]) (by simp [hyP])).mpr h)
    have hne : x ≠ y := fun e => by subst e; omega
    refine ⟨y, hyr, Or.inl (rv_P2 hc hyP ?_)⟩
    intro hro
    have := hro x hxr hne hxP
    rw [tw_mem hyr x] at this
    exact hnrec ((this.mpr hPlt).2)

/-- T5a. `inOrder`: on every allowed bar `k` is open with exactly its record predecessors (among the fixed keys) on its left. -/
theorem rowVerdict_inOrder_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .inOrder ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → RowPlaced r rec b k := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- T5b. `outOfPlace`: on every allowed bar `k` is open and not so placed. -/
theorem rowVerdict_outOfPlace_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .outOfPlace ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → RowMisplaced r rec b k := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- T5c. `behindChevron`: `k` is behind on every allowed bar, and not shown to be out of turn. -/
theorem rowVerdict_behind_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .behindChevron ↔
      (∃ b, Possible r b) ∧ (∀ b, Possible r b → k ∈ b.behind) ∧ ¬ (∀ b, Possible r b → OutOfTurn rec b k) := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- T5g. `behindOutOfTurn`: on every allowed bar `k` is behind and a record key before `k` is open. -/
theorem rowVerdict_behindOutOfTurn_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .behindOutOfTurn ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → OutOfTurn rec b k := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- T5d. `notOnBar`: `k` is on no allowed bar. -/
theorem rowVerdict_notOnBar_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .notOnBar ↔ (∃ b, Possible r b) ∧ ∀ b, Possible r b → k ∉ b.open_ ∧ k ∉ b.behind := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- T5e. `cannotTell` for a row: none of the five holds. -/
theorem rowVerdict_cannotTell_iff (rec : List Key) (r : Read) (k : Key) (h : rec.Nodup) (hk : k ∈ rec) :
    rowVerdict rec r k = .cannotTell ↔
      ¬ (∃ b, Possible r b) ∨
      ((∃ b, Possible r b) ∧ ¬ (∀ b, Possible r b → RowPlaced r rec b k) ∧ ¬ (∀ b, Possible r b → RowMisplaced r rec b k) ∧
        ¬ (∀ b, Possible r b → k ∈ b.behind) ∧ ¬ (∀ b, Possible r b → k ∉ b.open_ ∧ k ∉ b.behind)) := by
  
  rcases row_master rec r k with ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ | ⟨hv, h1, h2, h3, h4, h5, h6⟩ |
    ⟨hv, h1, h2, h3, h4, h5, h6⟩ <;> rw [hv] <;> simp_all

/-- Swap two keys of the record. -/
def swapKeys (rec : List Key) (x y : Key) : List Key :=
  rec.map (fun z => if z = x then y else if z = y then x else z)


theorem swap_self (rec : List Key) (x : Key) : swapKeys rec x x = rec := by
  unfold swapKeys
  have : (fun z => if z = x then x else if z = x then x else z) = fun z => z := by
    funext z; by_cases h : z = x <;> simp [h]
  rw [this]; simp

theorem swap_mem (rec : List Key) (x y z : Key) (hx : x ∈ rec) (hy : y ∈ rec) :
    z ∈ swapKeys rec x y ↔ z ∈ rec := by
  by_cases hxy : x = y
  · subst hxy; rw [swap_self]
  unfold swapKeys
  rw [List.mem_map]
  constructor
  · rintro ⟨w, hw, rfl⟩
    by_cases h1 : w = x
    · simp [h1, hy]
    · by_cases h2 : w = y
      · simp [h1, h2, hx, Ne.symm hxy]
      · simp [h1, h2, hw]
  · intro hz
    by_cases h1 : z = x
    · refine ⟨y, hy, ?_⟩
      simp [h1, Ne.symm hxy]
    · by_cases h2 : z = y
      · exact ⟨x, hx, by simp [h2, hxy]⟩
      · exact ⟨z, hz, by simp [h1, h2]⟩

theorem swap_tw (rec : List Key) (x y k z : Key) (hxk : x ≠ k) (hyk : y ≠ k) (hx : x ∈ rec) (hy : y ∈ rec)
    (hside : x ∈ rec.takeWhile (fun z => z != k) ↔ y ∈ rec.takeWhile (fun z => z != k)) :
    z ∈ (swapKeys rec x y).takeWhile (fun z => z != k) ↔ z ∈ rec.takeWhile (fun z => z != k) := by
  by_cases hxy : x = y
  · subst hxy; rw [swap_self]
  unfold swapKeys
  rw [List.takeWhile_map, List.mem_map]
  have hp : ((fun z => z != k) ∘ (fun z => if z = x then y else if z = y then x else z)) = (fun z => z != k) := by
    funext w
    have ex : (x != k) = true := by simpa using hxk
    have ey : (y != k) = true := by simpa using hyk
    by_cases h1 : w = x
    · simp [h1, ex, ey, hxy, Ne.symm hxy]
    · by_cases h2 : w = y
      · simp [h1, h2, ex, ey, hxy, Ne.symm hxy]
      · simp [h1, h2]
  rw [hp]
  have hy' : y ≠ x := Ne.symm hxy
  constructor
  · rintro ⟨w, hw, rfl⟩
    by_cases h1 : w = x
    · subst h1; simpa [hxy] using hside.mp hw
    · by_cases h2 : w = y
      · simp [h1, h2, hxy, hy']; exact hside.mpr (h2 ▸ hw)
      · simp [h1, h2, hw]
  · intro hz
    by_cases h1 : z = x
    · refine ⟨y, hside.mp (h1 ▸ hz), ?_⟩
      simp [h1, Ne.symm hxy]
    · by_cases h2 : z = y
      · exact ⟨x, hside.mpr (h2 ▸ hz), by simp [h2, hxy]⟩
      · exact ⟨z, hz, by simp [h1, h2]⟩

/-- T5f. Trouble elsewhere does not change `k`'s row: swapping two other record keys that stand on the same side of `k` in the
record leaves the row verdict alone. -/
theorem rowVerdict_swap_elsewhere (rec : List Key) (r : Read) (k x y : Key) (h : rec.Nodup)
    (hx : x ∈ rec) (hy : y ∈ rec) (hxk : x ≠ k) (hyk : y ≠ k)
    (hside : x ∈ rec.takeWhile (fun z => z != k) ↔ y ∈ rec.takeWhile (fun z => z != k)) :
    rowVerdict (swapKeys rec x y) r k = rowVerdict rec r k := by
  
  have hmem := fun z => swap_mem rec x y z hx hy
  have htw := fun z => swap_tw rec x y k z hxk hyk hx hy hside
  have e1 : ((swapKeys rec x y).any fun y' => ((swapKeys rec x y).takeWhile fun z => z != k).contains y' && r.pinOpen.contains y') =
      (rec.any fun y' => (rec.takeWhile fun z => z != k).contains y' && r.pinOpen.contains y') := by
    rw [Bool.eq_iff_iff]
    simp only [List.any_eq_true, Bool.and_eq_true, List.contains_iff_mem, hmem, htw]
  have e2 : ((swapKeys rec x y).any fun x' => x' != k && r.pinOpen.contains x' &&
      (decide (x' ∈ (swapKeys rec x y).takeWhile fun y' => y' != k) != decide (r.pinOpen.idxOf x' < r.pinOpen.idxOf k))) =
      (rec.any fun x' => x' != k && r.pinOpen.contains x' &&
      (decide (x' ∈ rec.takeWhile fun y' => y' != k) != decide (r.pinOpen.idxOf x' < r.pinOpen.idxOf k))) := by
    rw [Bool.eq_iff_iff]
    simp only [List.any_eq_true, Bool.and_eq_true, hmem, htw]
  unfold rowVerdict
  rw [e1, e2]

/-- T5h. A `differs` verdict always names a cause: some record row is out of place or behind out of turn. -/
theorem differs_names_cause (rec : List Key) (r : Read) (h : rec.Nodup) (hv : verdict rec r = .differs) :
    ∃ k ∈ rec, rowVerdict rec r k = .outOfPlace ∨ rowVerdict rec r k = .behindOutOfTurn := by
  
  have hu : r.usable := Classical.byContradiction fun hu => by
    rw [verdict_unusable rec hu] at hv; cases hv
  have hc : r.consistent = true := Classical.byContradiction fun hc => by
    have hc' : r.consistent = false := by simpa using hc
    rw [verdict_incons rec hc'] at hv; cases hv
  have hf := differs_forced hu hc hv
  refine okL_cause hu hc h (fun hok => ?_)
  have := (forcedBad_iff hc h).mpr hok
  rw [this] at hf; exact absurd hf (by decide)

/-! #### The gate and the view (what ties `step` to the statements) -/

/-- Design: the statements read the proof from `Read.notFullProven`; `step` keeps its own `provenNotFull` (it counts the reads) and
judges every read through `s.view r`, the read with the ENGINE's proof AS OF BEFORE this read in the field (Swift: the proof takes effect from the NEXT pass).  So T6/T7 are about
`s.view r`.  When the adapter's field is the engine's proof, `view` is the identity. -/
theorem view_of_agree (s : State) (r : Read) (h : r.notFullProven = s.provenNotFull) : s.view r = r := by
  unfold State.view; rw [← h]

/-- A decision implies the gate: usable and consistent on the view (no move on an unusable or contradictory read, the user's own
included). -/
theorem decideMove_gated (s : State) (r : Read) (a : Action) (h : decideMove s r = some a) :
    (s.view r).usable ∧ (s.view r).consistent = true := by
  unfold decideMove at h
  by_cases hg : s.gate r = true
  · unfold State.gate at hg
    simpa [Bool.and_eq_true] using hg
  · simp [hg] at h

/-! #### Proof infrastructure (pass B): what a decided move is made of -/



theorem step_read_decide (s s' : State) (r : Read) (a : Action) (hs : step s (.read r) = (s', [a])) :
    decideMove s r = some a := by
  unfold step at hs
  cases h : decideMove s r with
  | none => simp [h] at hs
  | some b => simp [h] at hs; rw [hs.2]

theorem decide_anatomy (s : State) (r : Read) (a : Action) (h : decideMove s r = some a) :
    (∃ k, userMove s r k = some a) ∨
    (∃ a0, planOrderMoves s r = some a0 ∧ (a = a0 ∨ a = { a0 with user := true })) := by
  unfold decideMove at h
  split at h
  · simp at h
  · split at h
    · rename_i b hb
      left
      simp at h; subst h
      obtain ⟨k, _, hk⟩ := userPick_exists hb
      refine ⟨k, ?_⟩
      cases hu : userMove s r k with
      | none => simp [hu] at hk
      | some c => simp [hu] at hk; rw [← hk.1]
    · split at h
      · simp at h
      · split at h
        · rename_i a0 ha0
          split at h
          · split at h
            · right; refine ⟨a0, ha0, Or.inr ?_⟩; simp at h; exact h.symm
            · simp at h
          · right; refine ⟨a0, ha0, Or.inl ?_⟩; simp at h; exact h.symm
        · simp at h


theorem tw_all : ∀ (L : List Key) (x : Key), (∀ a ∈ L, a ≠ x) → L.takeWhile (fun y => y != x) = L
  | [], _, _ => rfl
  | a :: L, x, h => by
    have h1 : (a != x) = true := by simpa using h a (by simp)
    simp [List.takeWhile_cons, h1]
    exact tw_all L x (fun b hb => h b (by simp [hb]))

theorem tw_mem2 (L : List Key) (x z : Key) : (z ∈ L.takeWhile (fun y => y != x) ↔ z ∈ L ∧ L.idxOf z < L.idxOf x) := by
  by_cases hx : x ∈ L
  · exact tw_mem hx z
  · have e : L.takeWhile (fun y => y != x) = L := by
      exact tw_all L x (fun a ha h => hx (h ▸ ha))
    rw [e, List.idxOf_eq_length hx]
    constructor
    · intro h; exact ⟨h, idx_lt_len h⟩
    · exact fun h => h.1

theorem userMove_pull (s : State) (r : Read) (k : Key) (a : Action) (h : userMove s r k = some a)
    (hf : k ∈ foldedAll s r) :
    a.subject = k ∧ a.user = true ∧ (s.foldRequest = some k ∨ k ∈ s.owedKeys) ∧ r.chevron = .fresh ∧ k ∈ r.foldedSet ∧
      ∃ p, p ∈ movable s r ∧ p ∈ s.record ∧ a.rel = .after p := by
  unfold userMove at h
  simp [hf] at h
  obtain ⟨⟨⟨h1, h2⟩, h3⟩, ⟨p, hp, hpa⟩, _⟩ := h
  have hpm := List.mem_of_find?_eq_some hp
  have hps := List.find?_some hp
  simp only [decide_eq_true_eq] at hps
  rw [List.mem_reverse] at hpm
  refine ⟨?_, ?_, h1, h2, h3, p, hpm, tw_sub hps, ?_⟩
  · rw [← hpa]
  · rw [← hpa]
  · rw [← hpa]

theorem anchorMove_drawn (s : State) (r : Read) (k : Key) (a : Action) (hkm : k ∈ movable s r) (h : anchorMove s r k = some a) :
    a.subject = k ∧ a.user = true ∧ k ∈ movable s r ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    ∃ x ∈ movable s r, x ≠ k ∧ x ∈ s.record ∧
      ¬ (x ∈ s.record.takeWhile (fun y => y != k) ↔ (movable s r).idxOf x < (movable s r).idxOf k) := by
  simp only [anchorMove] at h
  split at h
  · simp at h
  · rename_i hcond
    split at h
    · simp at h
    · rename_i i hi
      have hANmem : ∀ x, x ∈ (movable s r).filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a) ↔
          (x ∈ movable s r ∧ x ≠ k ∧ x ∈ s.record ∧ x ∉ s.owedKeys) := by
        intro x; simp [List.mem_filter, and_assoc]
      generalize hAN : (movable s r).filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a) = AN at *
      have key : a.subject = k ∧ a.user = true ∧ a.rel.target ∈ AN := by
        cases hl : (AN.take i).getLast? with
        | some p =>
          rw [hl] at h
          simp at h; subst h
          exact ⟨rfl, rfl, List.mem_of_mem_take (List.mem_of_getLast? hl)⟩
        | none =>
          rw [hl] at h
          cases hh : AN.head? with
          | none => rw [hh] at h; simp at h
          | some t =>
            rw [hh] at h; simp at h; subst h
            exact ⟨rfl, rfl, List.mem_of_mem_head? hh⟩
      obtain ⟨hsub, huser, htar⟩ := key
      have hA := (hANmem _).mp htar
      refine ⟨hsub, huser, hkm, hA.1, hA.2.2.1, hA.2.1, ?_⟩
      refine Classical.byContradiction (fun hno => ?_)
      apply hcond
      have hqk : (k == k || AN.contains k) = true := by simp
      simp only [Bool.and_eq_true, List.all_eq_true]
      constructor
      · intro x hx
        rw [tw_mem2] at hx
        obtain ⟨hxf, hlt⟩ := hx
        rw [List.mem_filter] at hxf
        obtain ⟨hxv, hxq⟩ := hxf
        have hxk : x ≠ k := by
          intro e; subst e; omega
        have hxAN : x ∈ AN := by
          have : AN.contains x = true := by simpa [hxk] using hxq
          simpa using this
        have hA2 := (hANmem x).mp hxAN
        have hlt2 : (movable s r).idxOf x < (movable s r).idxOf k := by
          have := idx_filter_iff (fun a => a == k || AN.contains a) (movable s r) x k hxv hkm hxq hqk
          exact this.mp hlt
        refine Classical.byContradiction (fun hnw => ?_)
        apply hno
        refine ⟨x, hxv, hxk, hA2.2.2.1, ?_⟩
        intro hiff
        have hxt : x ∈ s.record.takeWhile (fun y => y != k) := hiff.mpr hlt2
        apply hnw
        simp only [List.contains_iff_mem, List.mem_filter, decide_eq_true_eq]
        exact ⟨hxt, hxAN⟩
      · intro x hx
        simp only [List.mem_filter, List.contains_iff_mem] at hx
        obtain ⟨hxt, hxAN⟩ := hx
        have hA2 := (hANmem x).mp hxAN
        have hxq : (x == k || AN.contains x) = true := by simp [hxAN]
        refine Classical.byContradiction (fun hns => ?_)
        apply hno
        refine ⟨x, hA2.1, hA2.2.1, hA2.2.2.1, ?_⟩
        intro hiff
        have hlt2 := hiff.mp hxt
        apply hns
        simp only [List.contains_iff_mem]
        rw [tw_mem2]
        refine ⟨List.mem_filter.mpr ⟨hA2.1, hxq⟩, ?_⟩
        exact (idx_filter_iff (fun a => a == k || AN.contains a) (movable s r) x k hA2.1 hkm hxq hqk).mpr hlt2

theorem fallbackMove_drawn (s : State) (r : Read) (k : Key) (a : Action) (hkm : k ∈ movable s r) (h : fallbackMove s r k = some a) :
    a.subject = k ∧ a.user = true ∧ k ∈ movable s r ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    ∃ x ∈ movable s r, x ≠ k ∧ x ∈ s.record ∧
      ¬ (x ∈ s.record.takeWhile (fun y => y != k) ↔ (movable s r).idxOf x < (movable s r).idxOf k) := by
  obtain ⟨hu, hsub, htm, htr, htk, _, _, _, _, _, hmis, _⟩ := fallbackMove_basic h
  refine ⟨hsub, hu, hkm, htm, htr, htk, ?_⟩
  unfold misplaced at hmis
  obtain ⟨x, hx, hxd⟩ := List.any_eq_true.1 hmis
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, List.contains_iff_mem] at hxd
  obtain ⟨⟨hxk, hxr⟩, hxne⟩ := hxd
  refine ⟨x, hx, hxk, hxr, fun hiff => hxne ?_⟩
  have e := tw_mem hkm x
  apply Bool.eq_iff_iff.mpr
  rw [List.contains_iff_mem, List.contains_iff_mem, e]
  simp only [hx, true_and]
  exact hiff

theorem userMove_drawn (s : State) (r : Read) (k : Key) (a : Action) (h : userMove s r k = some a)
    (hf : k ∉ foldedAll s r) :
    a.subject = k ∧ a.user = true ∧ k ∈ movable s r ∧ a.rel.target ∈ movable s r ∧ a.rel.target ∈ s.record ∧ a.rel.target ≠ k ∧
    ∃ x ∈ movable s r, x ≠ k ∧ x ∈ s.record ∧
      ¬ (x ∈ s.record.takeWhile (fun y => y != k) ↔ (movable s r).idxOf x < (movable s r).idxOf k) := by
  unfold userMove at h
  have hf' : (foldedAll s r).contains k = false := by simpa using hf
  simp only [hf', Bool.false_eq_true, ite_false] at h
  by_cases hk : (movable s r).contains k = true
  · simp only [hk, ↓reduceIte] at h
    have hkm : k ∈ movable s r := by simpa using hk
    cases ha : anchorMove s r k with
    | some a' =>
      rw [ha] at h
      simp only [Option.some.injEq] at h; subst h
      exact anchorMove_drawn s r k _ hkm ha
    | none =>
      rw [ha] at h
      exact fallbackMove_drawn s r k a hkm h
  · simp at hk
    simp [hk] at h



theorem fi_self : ∀ A : List Key, firstInversion A A = none
  | [] => rfl
  | a :: A => by simp [firstInversion, fi_self A]

theorem fi_spec : ∀ (A B : List Key) (w h : Key), firstInversion A B = some (w, h) →
    ∃ c A' B', A = c ++ w :: A' ∧ B = c ++ h :: B' ∧ w ≠ h
  | [], B, w, h, hh => by simp [firstInversion] at hh
  | a :: A, [], w, h, hh => by simp [firstInversion] at hh
  | a :: A, b :: B, w, h, hh => by
    unfold firstInversion at hh
    by_cases hab : (a == b) = true
    · simp only [hab, ite_true] at hh
      obtain ⟨c, A', B', h1, h2, h3⟩ := fi_spec A B w h hh
      have e : a = b := by simpa using hab
      exact ⟨a :: c, A', B', by simp [h1], by simp [h2, e], h3⟩
    · simp only [hab] at hh
      simp at hh
      obtain ⟨rfl, rfl⟩ := hh
      refine ⟨[], A, B, by simp, by simp, ?_⟩
      simpa using hab

theorem fi_order (A B c A' B' : List Key) (w h : Key) (hA : A = c ++ w :: A') (hB : B = c ++ h :: B') (hne : w ≠ h)
    (hAn : A.Nodup) (hBn : B.Nodup) (hsame : ∀ x, x ∈ A ↔ x ∈ B) :
    B.idxOf h < B.idxOf w ∧ A.idxOf w < A.idxOf h := by
  have hwA : w ∈ A := by rw [hA]; simp
  have hhB : h ∈ B := by rw [hB]; simp
  have hwB := (hsame w).mp hwA
  have hhA := (hsame h).mpr hhB
  have hwc : w ∉ c := by
    rw [hA, List.nodup_append] at hAn
    intro hw; exact hAn.2.2 w hw w (by simp) rfl
  have hhc : h ∉ c := by
    rw [hB, List.nodup_append] at hBn
    intro hw; exact hBn.2.2 h hw h (by simp) rfl
  constructor
  · rw [hB] at hwB ⊢
    rw [idx_append_right hhc, idx_append_right (by
      intro hm; exact hwc hm), idx_cons, idx_cons]
    simp only [ite_true, hne.symm, ite_false]
    omega
  · rw [hA] at hhA ⊢
    rw [idx_append_right hwc, idx_append_right hhc, idx_cons, idx_cons]
    simp only [ite_true, hne, ite_false]
    omega


theorem plan_spec_t (s : State) (r : Read) (a : Action) (h : planOrderMoves s r = some a)
    (hrn : s.record.Nodup) (hmn : (movable s r).Nodup) :
    ∃ w h', a.subject = w ∧ a.rel.target = h' ∧ w ∈ movable s r ∧ h' ∈ movable s r ∧ w ∈ s.record ∧ h' ∈ s.record ∧
      s.record.idxOf w < s.record.idxOf h' ∧ (movable s r).idxOf h' < (movable s r).idxOf w := by
  unfold planOrderMoves at h
  simp only at h
  cases hfi : firstInversion (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k))
      ((movable s r).filter (fun k => s.record.contains k)) with
  | none => rw [hfi] at h; simp at h
  | some p =>
    obtain ⟨w, h'⟩ := p
    rw [hfi] at h
    simp only at h
    split at h
    · simp at h
    · simp at h
      subst h
      obtain ⟨c, A', B', h1, h2, h3⟩ := fi_spec _ _ _ _ hfi
      have hBn : ((movable s r).filter (fun k => s.record.contains k)).Nodup := nodup_filter' _ hmn
      have hAn : (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k)).Nodup :=
        nodup_filter' _ hrn
      have hsame : ∀ x, x ∈ (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k)) ↔
          x ∈ ((movable s r).filter (fun k => s.record.contains k)) := by
        intro x
        simp only [List.mem_filter, List.contains_iff_mem, decide_eq_true_eq]
        constructor
        · intro hx; exact hx.2
        · intro hx; exact ⟨hx.2, hx⟩
      have hord := fi_order _ _ c A' B' w h' h1 h2 h3 hAn hBn hsame
      have hwA : w ∈ (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k)) := by rw [h1]; simp
      have hhB : h' ∈ ((movable s r).filter (fun k => s.record.contains k)) := by rw [h2]; simp
      have hwB := (hsame w).mp hwA
      have hhA := (hsame h').mpr hhB
      simp only [List.mem_filter, List.contains_iff_mem, decide_eq_true_eq] at hwB hhB hwA hhA
      refine ⟨w, h', rfl, rfl, hwB.1, hhB.1, hwB.2, hhB.2, ?_, ?_⟩
      · have := idx_filter_iff (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k) s.record w h' hwB.2 hhB.2
          (by simpa using hwB) (by simpa using hhB)
        exact this.mp hord.2
      · have := idx_filter_iff (fun k => s.record.contains k) (movable s r) h' w hhB.1 hwB.1 (by simpa using hhB.2) (by simpa using hwB.2)
        exact this.mp hord.1

theorem view_usable_pin {s : State} {r : Read} (hu : (s.view r).usable) :
    (s.view r).pinOpen = r.drawn.filter (fun k => r.trusted.contains k) := by
  rw [pinOpen_def hu]; rfl

theorem mov_eq {s : State} {r : Read} (hu : (s.view r).usable) :
    movable s r = (s.view r).pinOpen.filter (fun k => !(foldedAll s r).contains k) := by
  rw [view_usable_pin hu]
  unfold movable
  rw [List.filter_filter]
  apply List.filter_congr
  intro x _
  simp [Bool.and_comm]

theorem mov_mem {s : State} {r : Read} (hu : (s.view r).usable) (x : Key) :
    x ∈ movable s r ↔ x ∈ (s.view r).pinOpen ∧ x ∉ foldedAll s r := by
  rw [mov_eq hu]; simp [List.mem_filter]

theorem mov_idx {s : State} {r : Read} (hu : (s.view r).usable) {x y : Key} (hx : x ∈ movable s r) (hy : y ∈ movable s r) :
    (movable s r).idxOf x < (movable s r).idxOf y ↔ (s.view r).pinOpen.idxOf x < (s.view r).pinOpen.idxOf y := by
  have hx' := (mov_mem hu x).mp hx
  have hy' := (mov_mem hu y).mp hy
  have := idx_filter_iff (fun k => !(foldedAll s r).contains k) (s.view r).pinOpen x y hx'.1 hy'.1
    (by simpa using hx'.2) (by simpa using hy'.2)
  rw [mov_eq hu]; exact this

theorem plan_mem (s : State) (r : Read) (a : Action) (h : planOrderMoves s r = some a) :
    ∃ w h', a.subject = w ∧ a.rel.target = h' ∧ w ∈ movable s r ∧ h' ∈ movable s r ∧ w ∈ s.record ∧ h' ∈ s.record := by
  unfold planOrderMoves at h
  simp only at h
  cases hfi : firstInversion (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k))
      ((movable s r).filter (fun k => s.record.contains k)) with
  | none => rw [hfi] at h; simp at h
  | some p =>
    obtain ⟨w, h'⟩ := p
    rw [hfi] at h
    simp only at h
    split at h
    · simp at h
    · simp at h
      subst h
      obtain ⟨c, A', B', h1, h2, h3⟩ := fi_spec _ _ _ _ hfi
      have hwA : w ∈ (s.record.filter (fun k => ((movable s r).filter (fun k => s.record.contains k)).contains k)) := by rw [h1]; simp
      have hhB : h' ∈ ((movable s r).filter (fun k => s.record.contains k)) := by rw [h2]; simp
      simp only [List.mem_filter, List.contains_iff_mem, decide_eq_true_eq] at hwA hhB
      exact ⟨w, h', rfl, rfl, hwA.2.1, hhB.1, hwA.1, by simpa using hhB.2⟩

/-- M1: the target of a decided move is a pinned open record key; the subject is a pinned open key or a pull-out of a key this read
lists as folded.  No hypothesis on the record. -/
theorem move_anatomy1 (s : State) (r : Read) (a : Action) (h : decideMove s r = some a) :
    (s.view r).usable ∧ (s.view r).consistent = true ∧
    (a.rel.target ∈ (s.view r).pinOpen ∧ a.rel.target ∈ s.record ∧
      ((a.subject ∈ (s.view r).pinOpen ∧ a.subject ∉ foldedAll s r) ∨
        (a.subject ∈ foldedAll s r ∧ a.subject ∈ r.foldedSet ∧ r.chevron = .fresh))) := by
  obtain ⟨hu, hc⟩ := decideMove_gated s r a h
  refine ⟨hu, hc, ?_⟩
  rcases decide_anatomy s r a h with ⟨k, hk⟩ | ⟨a0, ha0, hav⟩
  · by_cases hf : k ∈ foldedAll s r
    · obtain ⟨hsub, huser, _, hch, hfs, p, hpm, hpr, hrel⟩ := userMove_pull s r k a hk hf
      have hp := (mov_mem hu p).mp hpm
      have ht : a.rel.target = p := by rw [hrel]; rfl
      exact ⟨by rw [ht]; exact hp.1, by rw [ht]; exact hpr, Or.inr ⟨by rw [hsub]; exact hf, by rw [hsub]; exact hfs, hch⟩⟩
    · obtain ⟨hsub, huser, hkm, htm, htr, htk, x, hxm, hxk, hxr, hxn⟩ := userMove_drawn s r k a hk hf
      have hkp := (mov_mem hu k).mp hkm
      have htp := (mov_mem hu _).mp htm
      exact ⟨htp.1, htr, Or.inl ⟨by rw [hsub]; exact hkp.1, by rw [hsub]; exact hkp.2⟩⟩
  · obtain ⟨w, h', hsub, htar, hwm, hhm, hwr, hhr⟩ := plan_mem s r a0 ha0
    have hwp := (mov_mem hu w).mp hwm
    have hhp := (mov_mem hu h').mp hhm
    have hsub' : a.subject = w := by rcases hav with e | e <;> rw [e] <;> exact hsub
    have htar' : a.rel.target = h' := by rcases hav with e | e <;> rw [e] <;> exact htar
    exact ⟨by rw [htar']; exact hhp.1, by rw [htar']; exact hhr, Or.inl ⟨by rw [hsub']; exact hwp.1, by rw [hsub']; exact hwp.2⟩⟩

/-- M2, M3 (record without duplicates): an engine move is an inversion of two pinned open record keys; a user move of an open key
has a pinned open record key out of its place. -/
theorem move_anatomy2 (s : State) (r : Read) (a : Action) (h : decideMove s r = some a) (hnd : s.record.Nodup) :
    (a.user = false → ∃ w h', a.subject = w ∧ w ∈ (s.view r).pinOpen ∧ h' ∈ (s.view r).pinOpen ∧ w ∈ s.record ∧ h' ∈ s.record ∧
        s.record.idxOf w < s.record.idxOf h' ∧ (s.view r).pinOpen.idxOf h' < (s.view r).pinOpen.idxOf w) ∧
    (a.user = true → a.subject ∉ foldedAll s r → a.subject ∈ (s.view r).pinOpen ∧
        ∃ x ∈ s.record, x ≠ a.subject ∧ x ∈ (s.view r).pinOpen ∧
          ¬ (x ∈ s.record.takeWhile (fun y => y != a.subject) ↔
              (s.view r).pinOpen.idxOf x < (s.view r).pinOpen.idxOf a.subject)) := by
  obtain ⟨hu, hc⟩ := decideMove_gated s r a h
  have hpn : (s.view r).pinOpen.Nodup := (consistent_iff.mp hc).1
  have hmn : (movable s r).Nodup := by rw [mov_eq hu]; exact nodup_filter' _ hpn
  rcases decide_anatomy s r a h with ⟨k, hk⟩ | ⟨a0, ha0, hav⟩
  · by_cases hf : k ∈ foldedAll s r
    · obtain ⟨hsub, huser, _, hch, hfs, p, hpm, hpr, hrel⟩ := userMove_pull s r k a hk hf
      refine ⟨?_, ?_⟩
      · intro hh; rw [huser] at hh; cases hh
      · intro _ hh; exact absurd (hsub ▸ hf) hh
    · obtain ⟨hsub, huser, hkm, htm, htr, htk, x, hxm, hxk, hxr, hxn⟩ := userMove_drawn s r k a hk hf
      have hkp := (mov_mem hu k).mp hkm
      refine ⟨?_, ?_⟩
      · intro hh; rw [huser] at hh; cases hh
      · intro _ _
        rw [hsub]
        refine ⟨hkp.1, x, hxr, hxk, ((mov_mem hu x).mp hxm).1, ?_⟩
        intro hiff
        exact hxn (by rw [mov_idx hu hxm hkm]; exact hiff)
  · obtain ⟨w, h', hsub, htar, hwm, hhm, hwr, hhr, hrec, hmov⟩ := plan_spec_t s r a0 ha0 hnd hmn
    have hwp := (mov_mem hu w).mp hwm
    have hhp := (mov_mem hu h').mp hhm
    have hmovP : (s.view r).pinOpen.idxOf h' < (s.view r).pinOpen.idxOf w := (mov_idx hu hhm hwm).mp hmov
    have hsub' : a.subject = w := by rcases hav with e | e <;> rw [e] <;> exact hsub
    refine ⟨?_, ?_⟩
    · intro _; exact ⟨w, h', hsub', hwp.1, hhp.1, hwr, hhr, hrec, hmovP⟩
    · intro _ _
      rw [hsub']
      refine ⟨hwp.1, h', hhr, ?_, hhp.1, ?_⟩
      · intro e; rw [e] at hrec; omega
      · intro hiff
        have := (hiff.mpr hmovP)
        rw [tw_mem2] at this
        omega

theorem forcedBad_of_inv (rec : List Key) (R : Read) (w h' : Key) (hw : w ∈ R.pinOpen) (hh : h' ∈ R.pinOpen)
    (hwr : w ∈ rec) (hhr : h' ∈ rec) (h1 : rec.idxOf w < rec.idxOf h') (h2 : R.pinOpen.idxOf h' < R.pinOpen.idxOf w) :
    forcedBad rec R = true := by
  unfold forcedBad
  by_cases heq : rec.filter (fun k => R.pinOpen.contains k) = R.pinOpen.filter (fun k => rec.contains k)
  · exfalso
    have e1 := idx_filter_iff (fun k => R.pinOpen.contains k) rec w h' hwr hhr (by simpa using hw) (by simpa using hh)
    have e2 := idx_filter_iff (fun k => rec.contains k) R.pinOpen h' w hh hw (by simpa using hhr) (by simpa using hwr)
    rw [heq] at e1
    have := e1.mpr h1
    have := e2.mpr h2
    omega
  · rw [Bool.or_eq_true]; exact Or.inl (bne_iff_ne.mpr heq)

theorem verdict_not_cannotTell_of_pin (rec : List Key) (R : Read) (hu : R.usable) (hc : R.consistent = true)
    (p : Key) (hp : p ∈ rec) (hpp : p ∈ R.pinOpen) : verdict rec R ≠ .cannotTell := by
  unfold verdict
  rw [if_neg (by simp [hu, hc])]
  split
  · simp
  · have hR : ((rec.filter (fun k => R.free k && R.openOK k)).filter (fun k => !(rec.filter (party rec R)).contains k)) = [] := by
      apply List.filter_eq_nil_iff.mpr
      intro y hy
      simp only [List.mem_filter] at hy
      have : (rec.filter (party rec R)).contains y = true := by
        simp only [List.contains_iff_mem, List.mem_filter]
        refine ⟨hy.1, ?_⟩
        have hy2 := hy.2
        unfold party
        simp only [Bool.and_eq_true, List.any_eq_true] at hy2 ⊢
        refine ⟨hy2, p, hp, ?_⟩
        simp [hpp]
      rw [this]; decide
    simp only [hR]
    simp only [List.length_nil]
    split
    · omega
    · split <;> simp

/-! #### T6, T7: the engine's moves against the truth

No hypothesis `observed` or `usable` any more: `step` only moves on a usable, consistent read (`decideMove_gated`). -/

/-- The verdict the app shows for the read `r` of state `s`: the verdict of the record against the read AS THE ENGINE JUDGES IT (`s.view r`).

BRIDGE TO SWIFT (verified in LayoutEngine.swift:1849-1889, :1810, :2259-2263): `Read.notFullProven` must be fed from `!fullBarState`, NOT
from Swift's `notFullProven` variable.  A pass read that is the third chevronless one only ARMS the proof (Swift `notFullProven`, :1864); the
bar stays full and `checkingBar = fullBarState && !hasChevron` (:1810) still shows "Checking the menu bar" until the NEXT pass's
`noteChevronEvidence` flips `fullBarState` (:1857-1858), and a chevron or an incomplete read before then cancels the proof (:1856, :2262).
A quiet poll that is the third flips at once (:1876-1883).  Lean's `provenNotFull` is `!fullBarState`: it turns true on that flipping
read, and `s.view` judges a read by the state BEFORE it, so the flipping pass still decides under the old state (more conservative than
Swift, which plans that pass under the flipped state).  With the adapter feeding `!fullBarState` the field and `view` agree. -/
def shownVerdict (s : State) (r : Read) : Verdict := verdict s.record (s.view r)

/-- The status line and the rows judge `s.view r`: nothing else is shown.  (When the adapter's field is the engine's proof, that is
`verdict s.record r`.) -/
theorem status_judges_view (s : State) (r : Read) :
    shownVerdict s r = verdict s.record (s.view r) ∧
    (r.notFullProven = s.provenNotFull → shownVerdict s r = verdict s.record r) := by
  refine ⟨rfl, fun h => ?_⟩
  unfold shownVerdict; rw [view_of_agree s r h]

/-- T6 (engine). An engine-initiated order move is never needless: the shown verdict of the reading is `differs`.  (Conclusion is `differs`,
not "no allowed bar matches", which is vacuous on a contradictory read.)  Holds whatever is unread: the planner needs two PINNED keys
inverted, and then no `matchesExcept` verdict is possible. -/
theorem no_needless_move_engine (s s' : State) (r : Read) (a : Action) (h : s.record.Nodup)
    (hs : step s (.read r) = (s', [a])) (hn : a.user = false) :
    shownVerdict s r = .differs := by
  have hd := step_read_decide s s' r a hs
  obtain ⟨hu, hc, _⟩ := move_anatomy1 s r a hd
  obtain ⟨w, h', _, hwp, hhp, hwr, hhr, h1, h2⟩ := (move_anatomy2 s r a hd h).1 hn
  have hfb := forcedBad_of_inv s.record (s.view r) w h' hwp hhp hwr hhr h1 h2
  unfold shownVerdict verdict
  rw [if_neg (by simp [hu, hc]), if_pos hfb]

/-- T6 (user, or a move Re-apply authorised). The moved drawn key is open and out of its place on every allowed bar (relative to the
keys the reading fixes). -/
theorem no_needless_move_user (s s' : State) (r : Read) (a : Action) (h : s.record.Nodup)
    (hs : step s (.read r) = (s', [a])) (hy : a.user = true)
    (hk : a.subject ∉ foldedAll s r) :
    ∀ b, Possible (s.view r) b → RowMisplaced (s.view r) s.record b a.subject := by
  have hd := step_read_decide s s' r a hs
  obtain ⟨hu, hc, _⟩ := move_anatomy1 s r a hd
  obtain ⟨hkp, x, hxr, hxk, hxp, hxn⟩ := (move_anatomy2 s r a hd h).2 hy hk
  intro b hb
  refine ⟨poss_pin_open hu hb hkp, fun hok => ?_⟩
  exact hxn ((rowOK_iff hu hc hkp hb).mp hok x hxr hxk hxp)

/-- T7. No move names a folded key as its target, nor as its subject except a pull-out, whose subject IS behind the « on every honest
bar.  No hypothesis on the pile memory: a pull-out needs THIS read to list the subject as folded (`userMove`: `r.foldedSet.contains k`),
so the memory alone never licenses a drag (`memOnly_no_drag`, `memOnly_late_no_drag` below). -/
theorem no_folded_target_truth (s s' : State) (r : Read) (a : Action)
    (hs : step s (.read r) = (s', [a])) :
    ∀ b, Possible (s.view r) b →
      a.rel.target ∉ b.behind ∧
      (a.subject ∉ foldedAll s r → a.subject ∈ b.open_) ∧
      (a.subject ∈ foldedAll s r → a.subject ∈ r.foldedSet ∧ a.subject ∈ b.behind) := by
  have hd := step_read_decide s s' r a hs
  obtain ⟨hu, hc, htp, _, hsub⟩ := move_anatomy1 s r a hd
  intro b hb
  refine ⟨fun hbeh => wf_not_both (poss_wf hb) (poss_pin_open hu hb htp) hbeh, ?_, ?_⟩
  · intro hnf
    rcases hsub with ⟨hp, _⟩ | ⟨hf, _⟩
    · exact poss_pin_open hu hb hp
    · exact absurd hf hnf
  · intro hf
    rcases hsub with ⟨_, hn⟩ | ⟨_, hfs, hch⟩
    · exact absurd hf hn
    · refine ⟨hfs, poss_pin_behind hu hb ?_⟩
      rw [pinBehind_fresh hu hch]
      exact hfs

/-- T9. No move of any kind, the user's drop included, accompanies a `cannotTell` verdict: the status and the rows say "can't tell"
whenever a move is made.  NOT "exactly when": the converse fails, and a move can coexist with a `cannotTell` ROW for another key (the status
and a row are judged on the same `s.view r`; T9 is about the shown verdict of the whole read). -/
theorem no_move_on_cannotTell (s s' : State) (r : Read) (a : Action)
    (hs : step s (.read r) = (s', [a])) :
    shownVerdict s r ≠ .cannotTell := by
  have hd := step_read_decide s s' r a hs
  obtain ⟨hu, hc, htp, htr, _⟩ := move_anatomy1 s r a hd
  exact verdict_not_cannotTell_of_pin s.record (s.view r) hu hc _ htr htp

/-! #### T8: macOS folds from the left -/

/-- `b'` is `b` after macOS folds its leftmost open key behind the chevron. -/
def Bar.IsFold (b b' : Bar) : Prop :=
  ∃ x rest, b.open_ = x :: rest ∧ b'.open_ = rest ∧ b'.behind = b.behind ++ [x]

/-- The leftmost-fold fact, about the bar alone (no reading): folding the leftmost open key keeps the bar well formed. -/
theorem fold_leftmost_wf (b b' : Bar) (hw : b.WF) (hf : b.IsFold b') : b'.WF ∧ b'.open_ = b.open_.tail := by
  
  obtain ⟨x, rest, h1, h2, h3⟩ := hf
  obtain ⟨hn, hbn, hd⟩ := hw
  rw [h1] at hn hd
  have hxr : x ∉ rest := (List.nodup_cons.mp hn).1
  have hxb : x ∉ b.behind := hd x (by simp)
  refine ⟨⟨?_, ?_, ?_⟩, ?_⟩
  · rw [h2]; exact (List.nodup_cons.mp hn).2
  · rw [h3, List.nodup_append]
    refine ⟨hbn, by simp, ?_⟩
    intro a ha c hc
    simp at hc; subst hc
    exact fun e => hxb (e ▸ ha)
  · intro k hk
    rw [h2] at hk
    rw [h3]
    intro hm
    rcases List.mem_append.mp hm with hm | hm
    · exact hd k (List.mem_cons_of_mem _ hk) hm
    · simp at hm; subst hm; exact hxr hk
  · rw [h2, h1]; rfl

/-- T8. If the bar matches the record and macOS folds its leftmost open key, the bar still matches: rule (2) of `barMatches` is
exactly what a fold from the left preserves. -/
theorem macOS_fold_preserves (rec : List Key) (b b' : Bar) (hr : rec.Nodup) (hw : b.WF)
    (hm : barMatches rec b) (hf : b.IsFold b') : barMatches rec b' := by
  
  obtain ⟨x, rest, h1, h2, h3⟩ := hf
  obtain ⟨hn, hbn, hd⟩ := hw
  rw [h1] at hn
  have hxr : x ∉ rest := (List.nodup_cons.mp hn).1
  obtain ⟨hm1, hm2⟩ := hm
  rw [h1] at hm1 hm2
  refine ⟨?_, ?_⟩
  · rw [h2]
    have e1 : ((x :: rest).filter (fun k => decide (k ∈ rec))).filter (fun z => decide (z ≠ x)) =
        rest.filter (fun k => decide (k ∈ rec)) := by
      rw [List.filter_filter, List.filter_cons]
      simp only [ne_eq, not_true_eq_false, decide_false, Bool.false_and, Bool.false_eq_true, ite_false]
      apply List.filter_congr
      intro a ha
      have : a ≠ x := fun e => hxr (e ▸ ha)
      simp [this]
    have e2 : (rec.filter (fun k => decide (k ∈ x :: rest))).filter (fun z => decide (z ≠ x)) =
        rec.filter (fun k => decide (k ∈ rest)) := by
      rw [List.filter_filter]
      apply List.filter_congr
      intro a ha
      by_cases hax : a = x
      · subst hax; simp [hxr]
      · simp [hax]
    rw [← e1, ← e2, hm1]
  · rw [h2, h3]
    intro a ha y hy har hyr
    have hyO : y ∈ x :: rest := List.mem_cons_of_mem _ hy
    rcases List.mem_append.mp ha with ha | ha
    · exact hm2 a ha y hyO har hyr
    · simp at ha; subst ha
      have hxrec : a ∈ rec := har
      have hyx : y ≠ a := fun e => hxr (e ▸ hy)
      have := match_order (L := rec) (b := ⟨a :: rest, b.behind⟩) ⟨hm1, hm2⟩ (x := a) (y := y) (by simp) hyO har hyr
        (by rw [idx_cons, idx_cons]; simp [hyx, Ne.symm hyx])
      exact this

/-! ### Step 6: witnesses (evaluated) -/

/-- A settled, closed-strip pass read of the given level and chevron; `folded = []`.  A chevronless read carries the proof
(`notFullProven`); `rdU` is the same read without it. -/
def rd (c : ChevronRead) (lv : ReadLevel) (drawn pile trusted : List Key) : Read :=
  { kind := .pass, chevron := c, level := lv, settled := true, stripOpen := false, drawn := drawn, pile := pile,
    folded := [], trusted := trusted, nearFold := [], notFullProven := decide (c = .absent) }

def rdU (c : ChevronRead) (lv : ReadLevel) (drawn pile trusted : List Key) : Read :=
  { rd c lv drawn pile trusted with notFullProven := false }

/-- matches, open only: complete, no chevron (proven), in order; with a bar that really matches. -/
example : verdict [1, 2, 3] (rd .absent .complete [1, 2, 3] [] [1, 2, 3]) = .matches := by decide
example : Possible (rd .absent .complete [1, 2, 3] [] [1, 2, 3]) ⟨[1, 2, 3], []⟩ ∧
    barMatches [1, 2, 3] ⟨[1, 2, 3], []⟩ := by decide

/-- matches, with folds: 4 folded, 1 2 3 open, record puts 4 first. -/
example : verdict [4, 1, 2, 3] (rd .fresh .complete [1, 2, 3] [4] [1, 2, 3, 4]) = .matches := by decide
example : Possible (rd .fresh .complete [1, 2, 3] [4] [1, 2, 3, 4]) ⟨[1, 2, 3], [4]⟩ ∧
    barMatches [4, 1, 2, 3] ⟨[1, 2, 3], [4]⟩ := by decide

/-- matchesExcept: key 1 is drawn but untrusted; the rest is pinned and in order. -/
example : verdict [1, 2, 3] (rd .absent .complete [1, 2, 3] [] [2, 3]) = .matchesExcept [1] := by decide
/-- (the trusted keys 2 and 3 are open in the record's order, so only 1 is unknown) -/
example : verdict [1, 3, 2] (rd .fresh .complete [1, 2] [3] [2, 3]) = .matchesExcept [1] := by decide

/-- differs. -/
example : verdict [2, 1] (rd .absent .complete [1, 2] [] [1, 2]) = .differs := by decide

/-- cannotTell: stale chevron, and a read that is not a witness of the bar. -/
example : verdict [1, 3, 2] (rd .stale .complete [1, 2, 3] [] [1, 2, 3]) = .cannotTell := by decide
example : verdict [1, 2] (rd .absent .incomplete [1, 2] [] [1, 2]) = .cannotTell := by decide
/-- no chevron, the tree read only to `exceptSelfPositioning`, nothing trusted: 2 and 3 are listed and unpinned and could stand in
either order (key 1 is listed nowhere, so it is not on the bar). -/
example : verdict [1, 2, 3] (rd .absent .exceptSelfPositioning [3, 2] [] []) = .cannotTell := by decide

/-! The traces from the reviews. -/

/-- rec [1,2,3], drawn [1,2], pile [3], fresh, all trusted: 3 folded out of turn: differs. -/
example : verdict [1, 2, 3] (rd .fresh .complete [1, 2] [3] [1, 2, 3]) = .differs := by decide
/-- rec [3,1,2], same read: matches. -/
example : verdict [3, 1, 2] (rd .fresh .complete [1, 2] [3] [1, 2, 3]) = .matches := by decide
/-- rec [1,2,3,4], drawn [3,2,1,4], all trusted, no chevron: differs, and row 4 is in order. -/
example : verdict [1, 2, 3, 4] (rd .absent .complete [3, 2, 1, 4] [] [1, 2, 3, 4]) = .differs := by decide
example : rowVerdict [1, 2, 3, 4] (rd .absent .complete [3, 2, 1, 4] [] [1, 2, 3, 4]) 4 = .inOrder := by decide
/-- rec [1,3,2], stale chevron, drawn [1,2,3]: cannotTell. -/
example : verdict [1, 3, 2] (rd .stale .complete [1, 2, 3] [] [1, 2, 3]) = .cannotTell := by decide
/-- rec [1,3,2], drawn [1,2], pile [3], trusted [2,3], fresh: 1's position is unknown; matchesExcept [1]. -/
example : verdict [1, 3, 2] (rd .fresh .complete [1, 2] [3] [2, 3]) = .matchesExcept [1] := by decide
/-- rec [1,2,3], drawn [2,3], no chevron, complete: 1 is not on the bar: matches. -/
example : verdict [1, 2, 3] (rd .absent .complete [2, 3] [] [2, 3]) = .matches := by decide
/-- drawn item left of the fold: rec [9,1,2], drawn [9,2], pile [1], fresh: differs. -/
example : verdict [9, 1, 2] (rd .fresh .complete [9, 2] [1] [9, 1, 2]) = .differs := by decide
/-- self-contradictory reads have no honest bar: cannotTell. -/
example : verdict [1, 2] (rd .absent .complete [1, 1] [] [1]) = .cannotTell := by decide
example : verdict [1, 2] (rd .fresh .complete [1, 2] [1] [1, 2]) = .cannotTell := by decide

/-! New in this pass. -/

/-- 10 keys, 7 8 9 not running (listed nowhere), `exceptSelfPositioning`, key 6 unread: matchesExcept [6]; the other rows mean
something (ticks for 0..5, not on the bar for 7..9, can't tell only for 6). -/
def ten : List Key := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
def tenRead : Read := { rd .absent .exceptSelfPositioning [0, 1, 2, 3, 4, 5] [] [0, 1, 2, 3, 4, 5] with unread := [6] }
example : verdict ten tenRead = .matchesExcept [6] := by decide
example : ten.map (rowVerdict ten tenRead) =
    [.inOrder, .inOrder, .inOrder, .inOrder, .inOrder, .inOrder, .cannotTell, .notOnBar, .notOnBar, .notOnBar] := by decide

/-- A chevronless complete read is not believed until the proof (D1): cannot tell; with the proof: matches. -/
example : verdict [1, 2, 3] (rdU .absent .complete [1, 2, 3] [] [1, 2, 3]) = .cannotTell := by decide
example : verdict [1, 2, 3] (rd .absent .complete [1, 2, 3] [] [1, 2, 3]) = .matches := by decide
/-- Real bar open [3,4,5], behind [1], record [3,1,4,5], read chevronless and not proven: cannot tell (and that bar is allowed). -/
example : verdict [3, 1, 4, 5] (rdU .absent .complete [3, 4, 5] [] [3, 4, 5]) = .cannotTell := by decide
example : Possible (rdU .absent .complete [3, 4, 5] [] [3, 4, 5]) ⟨[3, 4, 5], [1]⟩ := by decide

/-- rec [1,2,3], all drawn, 1 and 3 trusted: matchesExcept [2]; rows tick, can't tell, tick. -/
example : verdict [1, 2, 3] (rd .absent .complete [1, 2, 3] [] [1, 3]) = .matchesExcept [2] := by decide
example : [1, 2, 3].map (rowVerdict [1, 2, 3] (rd .absent .complete [1, 2, 3] [] [1, 3])) = [.inOrder, .cannotTell, .inOrder] := by decide
/-- behindOutOfTurn: rec [1,9,2,3], drawn [1,2,3], pile [9]: differs, row 9 is behind out of turn. -/
example : verdict [1, 9, 2, 3] (rd .fresh .complete [1, 2, 3] [9] [1, 2, 3]) = .differs := by decide
example : rowVerdict [1, 9, 2, 3] (rd .fresh .complete [1, 2, 3] [9] [1, 2, 3]) 9 = .behindOutOfTurn := by decide

/-- A contradictory read (9 trusted-drawn and in the pile): cannot tell, and the engine does not drag. -/
def contra : Read := rd .fresh .complete [2, 1, 9] [9] [1, 2, 9]
example : verdict [1, 2, 9] contra = .cannotTell := by decide
example : (step (State.init [1, 2, 9]) (.read contra)).2 = [] := by decide

/-! The user's drop under the gate (D2).  rec [2,1] after the drop of 2; the bar is drawn [1,2]. -/

def dropped : State := (step (State.init [1, 2]) (.userEdit [2, 1] [2])).1
def staleR : Read := rd .stale .complete [1, 2] [] [1, 2]
def goodR : Read := rd .fresh .complete [1, 2] [] [1, 2]

/-- drop, stale read: no move, and the drop is still owed. -/
example : (step dropped (.read staleR)).2 = [] ∧ (step dropped (.read staleR)).1.owedKeys = [2] := by decide
/-- ... a non-usable read of any other kind does not move it either (poll, unsettled, strip open, unobserved, incomplete). -/
example : (step dropped (.read { goodR with kind := .poll })).2 = [] ∧ (step dropped (.read { goodR with settled := false })).2 = []
    ∧ (step dropped (.read { goodR with stripOpen := true })).2 = [] ∧ (step dropped (.read { goodR with observed := false })).2 = []
    ∧ (step dropped (.read { goodR with level := .incomplete })).2 = [] := by decide
/-- drop, stale read, then a usable read: the move is emitted (key 2, the user's own). -/
example : (run dropped [.read staleR, .read goodR]).2 = [⟨2, .before 1, false, true⟩] := by decide
/-- drop, stale read, boundary: the owed drop is gone (the chain expired without ever moving).  A later usable read shows the key
is not where the user put it, by `verdict`/`rowVerdict` alone: no drop memory.  (A regular pass may then reorder it as the ENGINE;
that is a separate, budgeted decision.) -/
example : (run dropped [.read staleR, .passBoundary]).1.owedKeys = [] ∧ (run dropped [.read staleR, .passBoundary]).2 = [] := by decide
example : verdict [2, 1] goodR = .differs ∧ rowVerdict [2, 1] goodR 2 = .outOfPlace := by decide

/-! Findings against `Step` (T6/T7 needed hypotheses `step` did not enforce) -- now closed by the gate. -/

/-- `step` used to plan an engine move on a read with `observed = false`; the gate now stops it. -/
def unobservedRead : Read :=
  { rd .fresh .complete [2, 1] [] [1, 2] with observed := false }

example : (step (State.init [1, 2]) (.read unobservedRead)).2 = [] := by decide

/-- the user's own drag used to be planned on a STALE chevron read; now it waits (see `dropped` above). -/
def staleOwed : State :=
  { State.init [1, 2] with owedKeys := [1], restricted := true }

example : (step staleOwed (.read (rd .stale .complete [2, 1] [] [1, 2]))).2 = [] := by decide

/-- a pull-out of a key that is only in the pile MEMORY (`lastFreshPile`), not in this read: formerly planned (T7 needed `hmem`), now withheld. -/
def memState : State :=
  { State.init [1, 3] with lastFreshPile := [3], lastDrawn := [1], foldRequest := some 3, owedKeys := [3], restricted := true }

-- (FIXED in the corrective pass: with `userMove` requiring `r.foldedSet.contains k` this read no longer drags; see `memOnly_no_drag`.)
example : (step memState (.read (rd .fresh .complete [1] [] [1]))).2 = [] := by decide

/-- The reachable trace behind the fix: rec [1,2,3]; a fresh read puts 3 in the pile (memory [3]); the user drops 3 (rec [1,3,2]; a
pull-out of 3 is requested); the NEXT read draws [1,9,3,2], all trusted, no pile: 3 is open and in order (verdict matches, row 3 ✓).
Before the fix `step` dragged 3 with `strip`. -/
def memS0 : State := (step (State.init [1, 2, 3]) (.read (rd .fresh .complete [1, 2] [3] [1, 2, 3]))).1
def memS1 : State := (step memS0 (.userEdit [1, 3, 2] [3])).1
def memLate : Read := rd .fresh .complete [1, 9, 3, 2] [] [1, 2, 3, 9]
example : memS1.foldRequest = some 3 ∧ memS1.lastFreshPile = [3] := by decide
example : (step memS1 (.read memLate)).2 = [] := by decide
example : shownVerdict memS1 memLate = .matches ∧ rowVerdict [1, 3, 2] (memS1.view memLate) 3 = .inOrder := by decide
/-- ... and when the key is simply absent from the read (listed nowhere): no drag either. -/
def memGone : Read := rd .fresh .complete [1, 2] [] [1, 2]
example : (step memS1 (.read memGone)).2 = [] := by decide
theorem memOnly_no_drag : (step memS1 (.read memGone)).2 = [] := by decide
theorem memOnly_late_no_drag : (step memS1 (.read memLate)).2 = [] := by decide
/-- Consequence: the drop of a key that is in the memory only gets no pull-out on that read.  The drop stays owed until the pass
boundary, when the attempt expires and nothing is owed any more ("Try again" can re-request it).  The row of the key says, by `rowVerdict` alone:
`notOnBar` when the read lists it nowhere, `cannotTell` when it is unread. -/
example : rowVerdict [1, 3, 2] (memS1.view memGone) 3 = .notOnBar := by decide
example : rowVerdict [1, 3, 2] (memS1.view { memGone with unread := [3] }) 3 = .cannotTell := by decide
example : (run memS1 [.read memGone, .passBoundary]).1.owedKeys = [] := by decide

/-! A non-observation is no evidence of a missing chevron: three `observed = false` reads do not prove the bar not full. -/
def unobs : Read := { rd .absent .complete [1, 2] [] [1, 2] with observed := false }
example : (run (State.init [1, 2]) [.read unobs, .read unobs, .read unobs]).1.provenNotFull = false := by decide
example : (run (State.init [1, 2]) [.read unobs, .read unobs, .read unobs]).1.noChevronReads = 0 := by decide
/-- ... and an observed read between them restarts the count: unobserved, 2 observed, unobserved, 2 observed: not yet proven. -/
def obsR : Read := rd .absent .complete [2, 1] [] [1, 2]
example : (run (State.init [1, 2]) [.read obsR, .read obsR, .read unobs, .read obsR, .read obsR]).1.provenNotFull = false := by decide
/-- the third pass read only ARMS the proof (count 3, bar still full); the fourth settled chevronless pass read takes effect. -/
example : (run (State.init [1, 2]) [.read obsR, .read obsR, .read obsR]).1.provenNotFull = false ∧
    (run (State.init [1, 2]) [.read obsR, .read obsR, .read obsR]).1.noChevronReads = 3 := by decide
example : (run (State.init [1, 2]) [.read obsR, .read obsR, .read obsR, .read obsR]).1.provenNotFull = true := by decide
/-- no engine drag while the bar is only "proven" by non-observations. -/
example : (run (State.init [1, 2]) [.read unobs, .read unobs, .read unobs, .read obsR]).2 = [] := by decide

/-- The proof takes effect from the NEXT pass read (Swift :1856-1865): the third chevronless read arms it, the fourth flips it and decides
under the old state (nothing moves, the verdict is `cannotTell`), the fifth judges the proven view: `differs`, and the engine drags. -/
def threeS : State := (run (State.init [1, 2]) [.read obsR, .read obsR, .read obsR]).1
def fourS : State := (run (State.init [1, 2]) [.read obsR, .read obsR, .read obsR, .read obsR]).1
example : shownVerdict (State.init [1, 2]) obsR = .cannotTell ∧ (step (State.init [1, 2]) (.read obsR)).2 = [] := by decide
example : (run (State.init [1, 2]) [.read obsR, .read obsR]).1.provenNotFull = false := by decide
example : shownVerdict threeS obsR = .cannotTell ∧ (step threeS (.read obsR)).2 = [] := by decide
example : shownVerdict fourS obsR = .differs ∧ (step fourS (.read obsR)).2 ≠ [] := by decide

/-! Review trace 1 (Swift :1856): held, three chevronless pass reads, then a fresh-chevron inverted read.  The three reads clear neither
hold nor pile (the proof is only armed); the chevron cancels it (count 0), so the bar stays held and nothing moves.  Control: without the
hold the same read moves. -/
def qR : Read := rd .absent .complete [1, 2, 3] [] [1, 2, 3]
def invFresh : Read := rd .fresh .complete [2, 1, 3] [] [1, 2, 3]
def hS : State := { State.init [1, 2, 3] with hold := true, lastFreshPile := [9] }
example : (run hS [.read qR, .read qR, .read qR]).1.hold = true ∧ (run hS [.read qR, .read qR, .read qR]).1.lastFreshPile = [9] ∧
    (run hS [.read qR, .read qR, .read qR]).1.noChevronReads = 3 := by decide
example : (run hS [.read qR, .read qR, .read qR, .read invFresh]).2 = [] ∧
    (run hS [.read qR, .read qR, .read qR, .read invFresh]).1.hold = true ∧
    (run hS [.read qR, .read qR, .read qR, .read invFresh]).1.provenNotFull = false ∧
    (run hS [.read qR, .read qR, .read qR, .read invFresh]).1.noChevronReads = 0 := by decide
example : (step (State.init [1, 2, 3]) (.read invFresh)).2 ≠ [] := by decide

/-! Review trace 2 (Swift :2262): three chevronless reads, an incomplete read, one more: the incomplete read reset the armed proof, the
count is 1, the bar is still full and an inverted chevronless read does not move.  Control: with a fourth plain read the fifth moves. -/
def obsR3 : Read := rd .absent .complete [2, 1, 3] [] [1, 2, 3]
def incR : Read := { qR with level := .incomplete }
example : (run (State.init [1, 2, 3]) [.read qR, .read qR, .read qR, .read incR, .read qR]).1.provenNotFull = false ∧
    (run (State.init [1, 2, 3]) [.read qR, .read qR, .read qR, .read incR, .read qR]).1.noChevronReads = 1 := by decide
example : (run (State.init [1, 2, 3]) [.read qR, .read qR, .read qR, .read incR, .read qR, .read obsR3]).2 = [] := by decide
example : (run (State.init [1, 2, 3]) [.read qR, .read qR, .read qR, .read qR, .read obsR3]).2 ≠ [] := by decide

/-! A quiet poll takes effect AT ONCE (docs/architecture.md rule 2, `notePollScan`): the third poll, a poll after two pass reads, and a poll
that finds the count armed at 3 each prove the bar not full and release hold and pile. -/
def pollR : Read := { qR with kind := .poll }
example : (run hS [.read pollR, .read pollR, .read pollR]).1.provenNotFull = true ∧
    (run hS [.read pollR, .read pollR, .read pollR]).1.hold = false ∧ (run hS [.read pollR, .read pollR, .read pollR]).1.lastFreshPile = [] := by decide
example : (run hS [.read qR, .read qR, .read pollR]).1.provenNotFull = true := by decide
example : (run hS [.read qR, .read qR, .read qR, .read pollR]).1.provenNotFull = true := by decide
example : (run hS [.read pollR, .read pollR, .read incR, .read pollR]).1.provenNotFull = false := by decide

/-! Unsettled chevronless pass reads neither count nor reset (Swift LayoutEngine.swift:2508, :2595): three of them prove nothing.
Real bar open [3,4,5], behind [1], record [3,1,4,5]; hold and pile memory set. -/
def unsettledR : Read := { rd .absent .complete [3, 4, 5] [] [3, 4, 5] with settled := false }
def settledR : Read := rd .absent .complete [3, 4, 5] [] [3, 4, 5]
def heldS : State := { State.init [3, 1, 4, 5] with hold := true, lastFreshPile := [1] }
example : (run heldS [.read unsettledR, .read unsettledR, .read unsettledR]).1.noChevronReads = 0 := by decide
example : shownVerdict (run heldS [.read unsettledR, .read unsettledR, .read unsettledR]).1 settledR = .cannotTell := by decide
example : (run heldS [.read unsettledR, .read unsettledR, .read unsettledR, .read settledR]).1.provenNotFull = false
    ∧ (run heldS [.read unsettledR, .read unsettledR, .read unsettledR, .read settledR]).1.hold = true
    ∧ (run heldS [.read unsettledR, .read unsettledR, .read unsettledR, .read settledR]).1.lastFreshPile = [1] := by decide

/-! ### Step 7: Honest is satisfiable (not vacuous) for a real read -/

example : ∃ b, Possible (rd .fresh .complete [1, 2] [3] [1, 2, 3]) b := ⟨⟨[1, 2], [3]⟩, by decide⟩
example : ∃ b, Possible (rd .absent .complete [2, 3] [] [2]) b := ⟨⟨[2, 3], []⟩, by decide⟩

end Sommelier
