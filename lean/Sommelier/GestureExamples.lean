import Sommelier.GestureDef

/-!
# Gestures: concrete examples (sommelier-ejb.32)

Decided by `decide` on the definitions alone (this module imports `GestureDef` only, no proofs), so a mutant of a gesture definition is
noticed BY MEANING here even when it also breaks a proof in `Gesture.lean`.  Keys: 10-18 are one nine-key hide unit (the
iStat Menus case of gdu.149), 90-91 are the trailing system modules.
-/

namespace Sommelier

/-- the nine keys 10..18 are one unit (unit 7); every other key is its own unit -/
def exUnit (k : Key) : Nat := if 10 ≤ k ∧ k ≤ 18 then 7 else k
/-- keys 90 and up are system modules -/
def exSys (k : Key) : Bool := decide (90 ≤ k)

def exL : Layout3 := ⟨[1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 2, 90, 91], [3, 4], [5]⟩

/-- THE INCIDENT: one drop of one key of a nine-key unit inside Visible moves only that key; the other eight stay where they are -/
example : applyGesture exUnit exSys exL (.drop 12 .visible (some 0)) =
    (⟨[12, 1, 10, 11, 13, 14, 15, 16, 17, 18, 2, 90, 91], [3, 4], [5]⟩, [12]) := by decide

/-- the index is taken after only the key is lifted: dropping `12` at index 3 puts it after `10, 11` (and after `1`) -/
example : applyGesture exUnit exSys exL (.drop 12 .visible (some 3)) =
    (⟨[1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 2, 90, 91], [3, 4], [5]⟩, [12]) := by decide
example : applyGesture exUnit exSys exL (.drop 12 .visible (some 6)) =
    (⟨[1, 10, 11, 13, 14, 15, 12, 16, 17, 18, 2, 90, 91], [3, 4], [5]⟩, [12]) := by decide

/-- an index past the end is clamped to the end of the section (here: right of the system block, as taken literally) -/
example : applyGesture exUnit exSys exL (.drop 12 .visible (some 99)) =
    (⟨[1, 10, 11, 13, 14, 15, 16, 17, 18, 2, 90, 91, 12], [3, 4], [5]⟩, [12]) := by decide

/-- no index in Visible: before the trailing system block -/
example : applyGesture exUnit exSys exL (.drop 12 .visible none) =
    (⟨[1, 10, 11, 13, 14, 15, 16, 17, 18, 2, 12, 90, 91], [3, 4], [5]⟩, [12]) := by decide
/-- no index in Hidden: the end -/
example : applyGesture exUnit exSys exL (.drop 3 .hidden none) = (⟨[1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 2, 90, 91], [4, 3], [5]⟩, [3]) := by decide

/-- a cross-section drop moves the whole unit: the dropped key first, its siblings right behind it in their previous order; moved is the dropped key only -/
example : applyGesture exUnit exSys exL (.drop 12 .hidden none) =
    (⟨[1, 2, 90, 91], [3, 4, 12, 10, 11, 13, 14, 15, 16, 17, 18], [5]⟩, [12]) := by decide
example : applyGesture exUnit exSys exL (.drop 12 .alwaysHidden (some 0)) =
    (⟨[1, 2, 90, 91], [3, 4], [12, 10, 11, 13, 14, 15, 16, 17, 18, 5]⟩, [12]) := by decide
/-- Hidden to Visible without an index: before the system block -/
example : applyGesture exUnit exSys exL (.drop 3 .visible none) =
    (⟨[1, 10, 11, 12, 13, 14, 15, 16, 17, 18, 2, 3, 90, 91], [4], [5]⟩, [3]) := by decide
/-- a key the layout does not list is inserted with its siblings that are listed -/
example : applyGesture exUnit exSys ⟨[1, 10, 11, 2], [3], []⟩ (.drop 12 .hidden none) =
    (⟨[1, 2], [3, 12, 10, 11], []⟩, [12]) := by decide
/-- a lone key not in the layout is simply added -/
example : applyGesture exUnit exSys ⟨[1, 2], [3], []⟩ (.drop 50 .visible (some 1)) = (⟨[1, 50, 2], [3], []⟩, [50]) := by decide

/-- the siblings of a unit split across sections come along in layout order (Visible, Hidden, Always hidden) -/
example : applyGesture exUnit exSys ⟨[10, 1], [11], [12]⟩ (.drop 13 .visible (some 0)) = (⟨[13, 10, 11, 12, 1], [], []⟩, [13]) := by decide

/-- a same-section drop of a key whose unit is split: the others are not touched -/
example : applyGesture exUnit exSys ⟨[10, 1], [11], [12]⟩ (.drop 10 .visible (some 1)) = (⟨[1, 10], [11], [12]⟩, [10]) := by decide

/-- hide what does not fit: each named visible key with its unit to the end of Hidden; moved lists every key moved once -/
example : applyGesture exUnit exSys exL (.hideNotFitting [11, 2]) =
    (⟨[1, 90, 91], [3, 4, 11, 10, 12, 13, 14, 15, 16, 17, 18, 2], [5]⟩, [11, 10, 12, 13, 14, 15, 16, 17, 18, 2]) := by decide
/-- naming two keys of one unit moves the unit once; a key that is not visible is ignored -/
example : applyGesture exUnit exSys exL (.hideNotFitting [10, 12, 3, 77]) =
    (⟨[1, 2, 90, 91], [3, 4, 10, 11, 12, 13, 14, 15, 16, 17, 18], [5]⟩, [10, 11, 12, 13, 14, 15, 16, 17, 18]) := by decide
example : applyGesture exUnit exSys exL (.hideNotFitting []) = (exL, []) := by decide

end Sommelier
