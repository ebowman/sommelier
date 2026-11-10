import Sommelier.Model

/-!
# Gestures: what the user's drop DID to the layout, computed by the proved core (sommelier-ejb.32)

Why.  On 2026-11-10 one Arrange drop of one item was turned by Swift code into "the user moved nine items", and the proved core
faithfully made four drags (gdu.149).  The core proved everything about what it was TOLD; what the gesture changed was computed
outside it.  This file moves that computation inside: a drop is an INPUT (`Gesture`), and `applyGesture` returns the new layout and the
keys the user moved.

The model.  `Layout3` has the three sections of the Swift `Layout` (`visible`, `hidden`, `alwaysHidden`).  Two pieces of data are
passed in, because they are facts about the world and not decisions:
* `unit : Key → Nat`: the hide unit of a key (Control Center hides per app: keys with the same unit hide and show together);
* `sys : Key → Bool`: the trailing-system-block keys (Control Center modules, Clock): an insertion with no index goes before the
  maximal run of `sys` keys at the end of Visible (anything right of it is unreachable on macOS 26).

The semantics is the FIXED Swift semantics of gdu.149 (`Layout.move`, `Layout.hideNotFitting`, `ArrangeDrop.outcome`):
* a drop of `k` into the section it already sits in is a REORDER: exactly `k` is lifted out and re-inserted at the index (clamped, taken
  after `k` alone is lifted); the siblings of its unit stay where they are; `moved = [k]`;
* a drop of `k` into another section (or of a key the layout does not list) moves its WHOLE hide unit: `k` and every key of the layout
  with the same unit are lifted out; `k` lands at the index (taken after the unit is lifted) and the siblings follow it immediately, in
  their previous layout order (visible, hidden, alwaysHidden); `moved = [k]` all the same (the siblings are not the user's order moves);
* the index `none` appends, except in Visible where it inserts before the trailing `sys` run;
* `hideNotFitting ks` moves each key of `ks` that is in Visible, with its unit, to the end of Hidden, in the order given; `moved` lists
  every key that moved (siblings included), each once, in the order moved.

This file holds the DEFINITIONS only (no proofs), like `Step.lean`: the examples (`GestureExamples.lean`) and the fuzz (`Fuzz.lean`) import it alone, so a mutant of a
definition is judged by meaning even when it breaks a proof.  The proofs are in `Gesture.lean`, the composition with `step` in `GestureProv.lean`.

Proved in `Gesture.lean` (standard axioms only):
* G1 `same_*`: a same-section drop: permutation; only `k`'s place changes (every other key keeps its section and the relative order of all
  keys other than `k`); `k` lands at the clamped index; `moved = [k]`;
* G2 `cross_*`: a cross-section drop: every key of `k`'s unit that is in the layout is in the target section afterwards, `k` at the index
  and the siblings right behind it in their previous order; every key outside the unit keeps its section and its relative order with every
  other non-unit key; `moved = [k]`;
* G3 `gesture_nodup`, `gesture_mem`: no gesture loses or duplicates a key;
* G4 `hide_*`: `hideNotFitting`: only keys of the named keys' units change section, and (in a layout whose units are all-or-nothing,
  which `normalizedHideUnits` guarantees) only from Visible to Hidden; the relative order of everything else is unchanged.
-/

set_option linter.deprecated false
set_option linter.unusedSimpArgs false
set_option linter.unusedVariables false

namespace Sommelier

inductive Section where
  | visible | hidden | alwaysHidden
  deriving DecidableEq, Repr

/-- the three ordered sections of the Swift `Layout` -/
structure Layout3 where
  visible : List Key
  hidden : List Key
  alwaysHidden : List Key
  deriving DecidableEq, Repr

namespace Layout3

def keys (L : Layout3) : Section → List Key
  | .visible => L.visible
  | .hidden => L.hidden
  | .alwaysHidden => L.alwaysHidden

def set (L : Layout3) : Section → List Key → Layout3
  | .visible, ks => { L with visible := ks }
  | .hidden, ks => { L with hidden := ks }
  | .alwaysHidden, ks => { L with alwaysHidden := ks }

def allKeys (L : Layout3) : List Key := L.visible ++ L.hidden ++ L.alwaysHidden

/-- the first section that lists `k` (Swift `section(of:)`) -/
def sectionOf (L : Layout3) (k : Key) : Option Section :=
  if k ∈ L.visible then some .visible else if k ∈ L.hidden then some .hidden
  else if k ∈ L.alwaysHidden then some .alwaysHidden else none

/-- keep only the keys satisfying `f`, in every section (Swift `remove`, for one key or a whole group) -/
def keep (L : Layout3) (f : Key → Bool) : Layout3 :=
  ⟨L.visible.filter f, L.hidden.filter f, L.alwaysHidden.filter f⟩

/-- the layout is duplicate-free: no key twice, in one section or across sections -/
def Nodup (L : Layout3) : Prop := L.allKeys.Nodup

end Layout3

/-- where the maximal trailing run of `sys` keys of `ks` starts -/
def trailStart (sys : Key → Bool) (ks : List Key) : Nat := ks.length - (ks.reverse.takeWhile sys).length

/-- the index a group is inserted at: an explicit index is clamped to the section's length; none appends, except in Visible, where
it is the start of the trailing system block -/
def insIdx (sys : Key → Bool) (ks : List Key) (s : Section) : Option Nat → Nat
  | some n => min n ks.length
  | none => if s = .visible then trailStart sys ks else ks.length

/-- insert `g` into section `s` at the index (Swift `insert(_:into:at:)`) -/
def insertGroup (sys : Key → Bool) (L : Layout3) (g : List Key) (s : Section) (idx : Option Nat) : Layout3 :=
  let ks := L.keys s
  let i := insIdx sys ks s idx
  L.set s (ks.take i ++ g ++ ks.drop i)

/-- the keys that travel with `k` when it changes section: `k` first, then every other key of the layout with its unit, in layout order -/
def groupOf (unit : Key → Nat) (L : Layout3) (k : Key) : List Key :=
  k :: L.allKeys.filter (fun x => x != k && unit x == unit k)

/-- the layout after dropping `k` into `s` at `idx` (Swift `Layout.move`) -/
def moveKey (unit : Key → Nat) (sys : Key → Bool) (L : Layout3) (k : Key) (s : Section) (idx : Option Nat) : Layout3 :=
  if L.sectionOf k = some s then insertGroup sys (L.keep (fun x => x != k)) [k] s idx
  else insertGroup sys (L.keep (fun x => !(groupOf unit L k).contains x)) (groupOf unit L k) s idx

/-- every key `moveKey` moves (Swift `Layout.move`'s result): `k` alone for a reorder, the whole group otherwise -/
def movedKeys (unit : Key → Nat) (L : Layout3) (k : Key) (s : Section) : List Key :=
  if L.sectionOf k = some s then [k] else groupOf unit L k

/-- the key `m` is added to the moved list unless it is there -/
def addMoved (mv : List Key) (m : Key) : List Key := if mv.contains m then mv else mv ++ [m]

/-- one key of "hide what does not fit": a key in Visible goes to the end of Hidden with its unit; the moved keys are collected once each -/
def hideStep (unit : Key → Nat) (sys : Key → Bool) (acc : Layout3 × List Key) (k : Key) : Layout3 × List Key :=
  if acc.1.sectionOf k = some .visible then
    (moveKey unit sys acc.1 k .hidden none,
     (movedKeys unit acc.1 k .hidden).foldl addMoved acc.2)
  else acc

inductive Gesture where
  /-- drop `k` into section `to` at the index `index` (none = after everything / before the trailing system block); a Move left / right
  is a drop with the computed index -/
  | drop (k : Key) (to : Section) (index : Option Nat)
  /-- "Hide what does not fit": these overflowed Visible keys, with their units, to the end of Hidden -/
  | hideNotFitting (ks : List Key)
  deriving Repr

/-- THE GESTURE: the new layout and the keys the user moved.  A drop moves exactly the dropped key; `hideNotFitting` lists every key it moved. -/
def applyGesture (unit : Key → Nat) (sys : Key → Bool) (L : Layout3) : Gesture → Layout3 × List Key
  | .drop k s idx => (moveKey unit sys L k s idx, [k])
  | .hideNotFitting ks => ks.foldl (hideStep unit sys) (L, [])

/-- hide units are all-or-nothing: of two keys with the same unit, either both or neither are in Visible (what `normalizedHideUnits` guarantees) -/
def UnitNormal (unit : Key → Nat) (L : Layout3) : Prop :=
  ∀ x y, x ∈ L.allKeys → y ∈ L.allKeys → unit x = unit y → (x ∈ L.visible ↔ y ∈ L.visible)

end Sommelier
