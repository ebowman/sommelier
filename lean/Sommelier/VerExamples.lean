import Sommelier.Step

/-!
# ejb.17 / ejb.26: the verified-drag rule by MEANING, in a module that imports only `Step`

`Examples.lean` imports `Status` and so `Truth`: a mutant of `Step.lean` that breaks a Truth proof stops `Examples.lean` from building at all, and its examples never run
(the mutant is then "killed" only by a broken proof).  The examples here depend on nothing but `Step`, so they decide the semantics of `judge`, `result` and `userEdit`
whatever the proofs do.  `mutants.py` builds this module for every mutant and counts a failing example here as a semantic kill.
-/

namespace Sommelier

def vkRead (c : ChevronRead) (drawn fold : List Key) : Read :=
  { kind := .pass, chevron := c, level := .complete, settled := true, stripOpen := false,
    drawn := drawn, pile := fold, folded := [], trusted := drawn ++ fold, nearFold := [] }

def vok (k : Key) : Event := .moveResult k .verified true

/-- A bar macOS reverts every time: the key is struck at each read and given up at the third; the bar is never held. -/
def vReverted : List Event := (List.replicate 12 [Event.read (vkRead .fresh [3, 2, 1, 4] [5]), vok 1]).flatten
example : (run (State.init [1, 2, 3, 4, 5]) vReverted).2.length = 3 := by decide
example : (run (State.init [1, 2, 3, 4, 5]) vReverted).1.strikes = [1, 1, 1] := by decide
example : (run (State.init [1, 2, 3, 4, 5]) vReverted).1.givenUp = [1] := by decide
example : (run (State.init [1, 2, 3, 4, 5]) vReverted).1.hold = false := by decide

/-- The same on a bar proven not full (budget 20): still exactly three drags. -/
def vRevertedProven : List Event :=
  (List.replicate 3 (Event.read { vkRead .absent [2, 1] [] with kind := .poll })) ++ (List.replicate 12 [Event.read (vkRead .absent [2, 1] []), vok 1]).flatten
example : (run (State.init [1, 2]) vRevertedProven).2.length = 3 := by decide

/-- A drag the next read confirms: no strike, and the mark is CLEARED by that read (a second, unrelated read leaves nothing to judge). -/
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1, .read (vkRead .fresh [1, 2] [])]).1.strikes = [] := by decide
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1, .read (vkRead .fresh [1, 2] [])]).1.verified = none := by decide
/-- A confirmed mark is gone: a LATER read that shows the key out of place (macOS moved it on its own) is nothing to judge, so no strike. -/
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1, .read (vkRead .fresh [1, 2] []), .read (vkRead .fresh [2, 1] [])]).1.strikes = [] := by decide

/-- Only a verified drag of the ENGINE leaves a mark. -/
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), .moveResult 1 .failed true]).1.verified = none := by decide
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), .moveResult 1 .verified false]).1.verified = none := by decide
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1]).1.verified = some 1 := by decide
/-- A USER's drag answered verified leaves no mark. -/
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [2], .read (vkRead .fresh [1, 3, 2] []), vok 2]).1.verified = none := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [2], .read (vkRead .fresh [1, 3, 2] []), vok 2]).2.map (·.user) = [true] := by decide
/-- The mark remembers the place of the drag. -/
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1]).1.verRel = .before 2 := by decide

/-- Retry and Try again clear the mark. -/
example : (run (State.init [1, 2, 3, 4, 5]) [.read (vkRead .fresh [3, 2, 1, 4] [5]), vok 1, .retryKey 1]).1.verified = none := by decide
example : (run (State.init [1, 2, 3, 4, 5]) [.read (vkRead .fresh [3, 2, 1, 4] [5]), vok 1, .userRetry]).1.verified = none := by decide

/-- A read the gate refuses (a poll) leaves the mark and judges nothing. -/
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1, .read { vkRead .fresh [2, 1] [] with kind := .poll }]).1.verified = some 1 := by decide
example : (run (State.init [1, 2]) [.read (vkRead .fresh [2, 1] []), vok 1, .read { vkRead .fresh [2, 1] [] with kind := .poll }]).1.strikes = [] := by decide

/-- (a) Key 2 is dragged before 3 (verified); the user then drops 3 first (a record change that keeps 2's mark in ejb.17): no strike. -/
def vEdit : List Event :=
  [.read (vkRead .fresh [1, 3, 2] []), vok 2, .userEdit [3, 1, 2] [3], .read (vkRead .fresh [1, 2, 3] [])]
example : (run (State.init [1, 2, 3]) vEdit).1.strikes = [] := by decide
example : (run (State.init [1, 2, 3]) vEdit).1.verified = none := by decide
/-- ... an edit that moves no key clears the mark too ... -/
example : (run (State.init [1, 2, 3]) [.read (vkRead .fresh [1, 3, 2] []), vok 2, .userEdit [3, 1, 2] [], .read (vkRead .fresh [1, 2, 3] [])]).1.strikes = [] := by decide
/-- ... and three such coincidences never give the key up. -/
example : (run (State.init [1, 2, 3]) (List.replicate 3 [.read (vkRead .fresh [1, 3, 2] []), vok 2, .userEdit [3, 1, 2] [3], .read (vkRead .fresh [1, 2, 3] []), .userEdit [1, 2, 3] [1]]).flatten).1.givenUp = [] := by decide

/-- (b) Key 2 is dragged before 3 (verified); then macOS moves record key 1 across it (bar 2 1 3): key 2 is still before its anchor 3, no strike. -/
def vCrossed : List Event := [.read (vkRead .fresh [1, 3, 2] []), vok 2, .read (vkRead .fresh [2, 1, 3] [])]
example : (run (State.init [1, 2, 3]) vCrossed).1.strikes = [] := by decide
/-- The anchor itself back on the wrong side IS a revert: struck. -/
example : (run (State.init [1, 2, 3]) [.read (vkRead .fresh [1, 3, 2] []), vok 2, .read (vkRead .fresh [1, 3, 2] [])]).1.strikes = [2] := by decide

end Sommelier
