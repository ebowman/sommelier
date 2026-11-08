import Sommelier.Step

namespace Sommelier

/-- A settled, complete pass read; `fold` are the pile keys. Trusted = everything shown. -/
def mkRead (c : ChevronRead) (drawn fold : List Key) : Read :=
  { kind := .pass, chevron := c, level := .complete, settled := true, stripOpen := false,
    drawn := drawn, pile := fold, folded := [], trusted := drawn ++ fold, nearFold := [] }

def ok (k : Key) : Event := .moveResult k .verified true
def bad (k : Key) : Event := .moveResult k .failed true

-- Keys: 1 Jump, 2 Network, 3 TimeMachine, 4 Clock, 5 Wifi.

/-! ## Required examples -/

/-! 1. The 10:29 Time Machine drop.  Full bar, TM (3) is folded; the user drops it at slot 0.
No drawn key precedes it in the record: left of the fold line, NO drag; the regular pass moves neither Jump nor Network. -/
def tm : List Event :=
  [ .read (mkRead .fresh [1, 2, 4, 5] [3]),
    .userEdit [3, 1, 2, 4, 5] [3],
    .read (mkRead .fresh [1, 2, 4, 5] [3]),
    .passBoundary,
    .read (mkRead .fresh [1, 2, 4, 5] [3]) ]
#eval (run (State.init [1, 2, 3, 4, 5]) tm).2   -- expected: []
example : (run (State.init [1, 2, 3, 4, 5]) tm).2 = [] := by decide

/-- The same with a drawn mismatch (Network before Jump): nothing moves in the user's pass (only owed keys may);
the regular pass makes ONE counted engine move, never one that names TM. -/
def tmMismatch : List Event :=
  [ .read (mkRead .fresh [2, 1, 4, 5] [3]),
    .userEdit [3, 1, 2, 4, 5] [3],
    .read (mkRead .fresh [2, 1, 4, 5] [3]),
    .passBoundary,
    .read (mkRead .fresh [2, 1, 4, 5] [3]) ]
#eval (run (State.init [1, 2, 3, 4, 5]) tmMismatch).2
example : (run (State.init [1, 2, 3, 4, 5]) tmMismatch).2 = [⟨1, .before 2, false, false⟩] := by decide

/-! 2. Launch on a full bar with a record that disagrees: ONE engine drag; it fails, the bar is held and
nothing else is dragged over ten more reads. -/
def launch : List Event :=
  [ .read (mkRead .fresh [2, 1, 4] [3, 5]), bad 1 ] ++
  (List.replicate 10 (.read (mkRead .fresh [2, 1, 4] [3, 5])))
#eval (run (State.init [3, 1, 2, 4, 5]) launch).2
example : (run (State.init [3, 1, 2, 4, 5]) launch).2 = [⟨1, .before 2, false, false⟩] := by decide

/-- Launch where every drag works: the bar converges in two drags and then stays quiet. -/
def launchGood : List Event :=
  [ .read (mkRead .fresh [3, 2, 1, 4] [5]), ok 1,
    .read (mkRead .fresh [1, 3, 2, 4] [5]), ok 2,
    .read (mkRead .fresh [1, 2, 3, 4] [5]) ]
#eval (run (State.init [1, 2, 3, 4, 5]) launchGood).2
example : (run (State.init [1, 2, 3, 4, 5]) launchGood).2 = [⟨1, .before 3, false, false⟩, ⟨2, .before 3, false, false⟩] := by decide

/-- Six posted drags on a full bar that never converge: the engine stops after `capFull` = 3. -/
def budget : List Event :=
  (List.replicate 6 [Event.read (mkRead .fresh [3, 2, 1, 4] [5]), ok 1]).flatten
#eval (run (State.init [1, 2, 3, 4, 5]) budget).2.length   -- expected: 3
example : (run (State.init [1, 2, 3, 4, 5]) budget).2.length = 3 := by decide

/-! 3. Resume after a chain.  The user drops folded Wifi (5) right of the fold line: one strip drag, which
fails.  The chain ends; a later regular pass (Resume) makes no strip move and no other drag. -/
def resume : List Event :=
  [ .read (mkRead .fresh [1, 2, 4] [5]),
    .userEdit [1, 5, 2, 4] [5],
    .read (mkRead .fresh [1, 2, 4] [5]),
    bad 5,
    .passBoundary ] ++
  (List.replicate 5 (.read (mkRead .fresh [1, 2, 4] [5])))
#eval (run (State.init [1, 2, 4, 5]) resume).2
example : (run (State.init [1, 2, 4, 5]) resume).2 = [⟨5, .after 1, true, true⟩] := by decide

/-- The chain ends before the owed pull-out was ever read: it is gone, a later pass never fires it. -/
def resumeUnserved : List Event :=
  [ .read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5], .passBoundary,
    .read (mkRead .fresh [1, 2, 4] [5]) ]
example : (run (State.init [1, 2, 4, 5]) resumeUnserved).2 = [] := by decide

/-! ## Reviewer counterexamples (R.lean, R2.lean), with the corrected outcomes -/

/-- A: a key hosted in the pile, dropped at the far left and read as folded: no duplicate owed attempt, no drag. -/
example : (run (State.init [1, 2, 5])
    [.read (mkRead .fresh [1, 2] [5]), .read (mkRead .absent [1, 2, 5] []), .userEdit [5, 1, 2] [5],
     .read (mkRead .absent [1, 2, 5] []), bad 5, .read (mkRead .absent [1, 2, 5] [])]).2 = [] := by decide

/-- B: a second edit ADDS to the first's owed attempts (owed 2 and 4), it does not overwrite them. -/
example : (run (State.init [1, 2, 3, 4])
    [.read (mkRead .fresh [1, 2, 3, 4] [9]), .userEdit [2, 1, 3, 4] [2], .userEdit [2, 1, 4, 3] [4]]).1.owedKeys
    = [2, 4] := by decide

/-- C, C4: the last fresh pile stays folded through chevronless reads: never a subject or a target. -/
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .absent [1, 3, 2] [])]).2 = [] := by decide
example : (run (State.init [1, 3, 2]) [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .absent [3, 1, 2] [])]).2 = [] := by decide

/-- C3/C5: a user move never targets a key of the last fresh pile, even on a stale read. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .stale [1, 2, 3] []), .userEdit [3, 2, 1] [1],
     .read (mkRead .stale [1, 2, 3] [])]).2 = [⟨1, .after 2, false, true⟩] := by decide

/-- D (assumption, see docs): while a drag is in flight the core decides nothing; the actuator MUST answer it. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [2, 1, 3] []), .userEdit [3, 2, 1] [3], .read (mkRead .fresh [2, 1, 3] [])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
/-- ... and once it is answered the user's drop is served. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [2, 1, 3] []), ok 1, .userEdit [3, 2, 1] [3], .read (mkRead .fresh [2, 1, 3] [])]).2
    = [⟨1, .before 2, false, false⟩, ⟨3, .before 2, false, true⟩] := by decide

/-- E: drawn when the edit was made, folded when read: no fold request, so NO strip pull-out. -/
example : (run (State.init [1, 2, 3, 4])
    [.read (mkRead .fresh [1, 2, 3, 4] [9]), .userEdit [1, 3, 2, 4] [3], .read (mkRead .fresh [1, 2, 4] [3, 9])]).2 = [] := by decide

/-- F: an edit before the first read is not lost. -/
example : (run (State.init [1, 2]) [.userEdit [2, 1] [2], .read (mkRead .fresh [1, 2] [])]).2 = [⟨2, .before 1, false, true⟩] := by decide

/-- G: a hidden key dropped to Visible on a HELD bar still gets its one (exempt) attempt. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [2, 1, 3] []), bad 1, .userEdit [7, 1, 2, 3] [7], .read (mkRead .fresh [1, 2, 3, 7] []),
     ok 7, .passBoundary, .read (mkRead .fresh [7, 1, 2, 3] [])]).2
    = [⟨1, .before 2, false, false⟩, ⟨7, .before 1, false, true⟩] := by decide

/-- H: two moved keys near the fold: only the first may use the edit's one strip session; the second waits. -/
def near : Read := { mkRead .fresh [1, 2, 3, 4] [9] with nearFold := [2, 3] }
example : (run (State.init [1, 2, 3, 4])
    [.read near, .userEdit [3, 2, 1, 4] [3, 1], .read near, ok 3, .read { mkRead .fresh [3, 1, 2, 4] [9] with nearFold := [2, 3] }]).2
    = [⟨3, .before 2, true, true⟩] := by decide

/-- I: a moved key already in order with a served moved key is not moved again, and no unmoved key moves. -/
example : (run (State.init [2, 3, 1])
    [.read (mkRead .fresh [2, 3, 1] []), .userEdit [3, 2, 1] [2, 1], .read (mkRead .fresh [2, 3, 1] []), bad 2,
     .read (mkRead .fresh [2, 3, 1] [])]).2 = [⟨2, .after 3, false, true⟩] := by decide

/-- J: refused drags with no mouse event are not budget: one refusal, the key is skipped, nothing loops, no hold. -/
def refusedLoop : List Event :=
  (List.replicate 4 [Event.read (mkRead .fresh [2, 1, 3] [9]), .moveResult 1 .refused false]).flatten
example : (run (State.init [1, 2, 3]) refusedLoop).2.length = 1 := by decide
example : (run (State.init [1, 2, 3]) refusedLoop).1.hold = false := by decide
example : (run (State.init [1, 2, 3]) refusedLoop).1.moveCount = 0 := by decide

/-- K: a refused user drag is consumed; an interrupted one (busy, no mouse event) is re-armed ONCE. -/
def kReads : List Event := [.read (mkRead .fresh [1, 2, 3] [9]), .userEdit [3, 1, 2] [3], .read (mkRead .fresh [1, 2, 3] [9])]
example : (run (State.init [1, 2, 3]) (kReads ++ [.moveResult 3 .refused false, .read (mkRead .fresh [1, 2, 3] [9])])).2
    = [⟨3, .before 1, false, true⟩] := by decide
example : (run (State.init [1, 2, 3]) (kReads ++ [.moveResult 3 .busy false, .read (mkRead .fresh [1, 2, 3] [9]),
      .moveResult 3 .busy false, .read (mkRead .fresh [1, 2, 3] [9])])).2
    = [⟨3, .before 1, false, true⟩, ⟨3, .before 1, false, true⟩] := by decide

/-- L: three chevronless complete polls prove the bar not full even when unsettled; a poll never plans. -/
def poll (settled : Bool) : Read := { mkRead .absent [1, 2] [] with settled := settled, kind := .poll }
example : (run (State.init [1, 2]) (List.replicate 3 (.read (poll false)))).1.provenNotFull = true := by decide
example : (run (State.init [2, 1]) [.read (poll true)]).2 = [] := by decide

/-- M: the hold remembers the folded set at hold time; an edit touching it releases the hold. -/
example : (run (State.init [1, 2])
    [.read (mkRead .fresh [2, 1] [3]), bad 1, .read (mkRead .fresh [2, 1] [5]), .userEdit [1, 3, 2] [3]]).1.hold = false := by decide

/-- N: a user's drawn move proceeds with the strip open; engine moves never do. -/
def open_ : Read := { mkRead .fresh [1, 2, 3] [] with stripOpen := true }
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2, 3] []), .userEdit [3, 1, 2] [3], .read open_]).2
    = [⟨3, .before 1, false, true⟩] := by decide
example : (run (State.init [1, 2]) [.read { open_ with drawn := [2, 1], trusted := [2, 1] }]).2 = [] := by decide

/-- P: an engine move that needs the strip (churn zone) is withheld and not counted. -/
example : (run (State.init [1, 2, 3]) [.read { mkRead .fresh [2, 1, 3] [9] with nearFold := [2] }]).2 = [] := by decide
/-- R: Re-apply grants ONE strip session: the same move is made once, as the user's. -/
def churn : Read := { mkRead .fresh [2, 1, 3] [9] with nearFold := [2] }
example : (run (State.init [1, 2, 3])
    [.read churn, .userRetry, .read churn, .moveResult 1 .refused false, .read churn]).2
    = [⟨1, .before 2, true, true⟩] := by decide

/-- Q: a drop to the leftmost slot on a full bar goes before the first drawn key. -/
example : (run (State.init [1, 2, 3]) kReads).2 = [⟨3, .before 1, false, true⟩] := by decide

/-- An incomplete read never plans. -/
example : (run (State.init [1, 2]) [.read { mkRead .fresh [2, 1] [] with level := .incomplete }]).2 = [] := by decide

/-! ## Corrective pass 2 -/

/-- Bug 1: only a settled, readable, strip-closed fresh read REPLACES the pile; any other read adds to it, so key 3 stays folded. -/
def pilePoll : Read := { mkRead .fresh [3, 1, 2] [] with kind := .poll, stripOpen := true }
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read pilePoll, .read (mkRead .absent [1, 3, 2] [])]).2 = [] := by decide
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read { pilePoll with stripOpen := false, settled := false },
    .read (mkRead .absent [1, 3, 2] [])]).2 = [] := by decide
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read { pilePoll with stripOpen := false, level := .incomplete },
    .read (mkRead .absent [1, 3, 2] [])]).2 = [] := by decide

/-- Bug 2, A1: a granted move is never re-armed by a later busy. -/
example : (run (State.init [1, 2, 3])
    [.read churn, .userRetry, .read churn, .userEdit [1, 2, 3] [3], .moveResult 1 .busy false, .read churn]).2
    = [⟨1, .before 2, true, true⟩] := by decide
/-- Bug 2, A2: a drag owed by an earlier chain is not re-armed by a later chain. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2, 3] [9]), .userEdit [3, 1, 2] [3], .read (mkRead .fresh [1, 2, 3] [9]), .passBoundary,
     .userEdit [3, 1, 2] [1], .moveResult 3 .busy false, .read (mkRead .fresh [1, 2, 3] [9])]).2
    = [⟨3, .before 1, false, true⟩] := by decide

/-- Bug 3: owed keys and the fold request follow the current record. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3], .userEdit [1, 2] [], .read (mkRead .fresh [1, 2] [3])]).2 = [] := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [1, 2] [9]), .retryKey 9, .read (mkRead .fresh [1, 2] [9])]).2 = [] := by decide

/-- Bug 4: a drawn key absent from the record cannot force a drag. -/
example : (run (State.init [1, 3, 2])
    [.read (mkRead .fresh [1, 3, 2] []), .userEdit [1, 3, 2] [3], .read (mkRead .fresh [1, 9, 3, 2] [])]).2 = [] := by decide

/-- Bug 5: a "verified" result with no mouse event does not loop. -/
example : (run (State.init [1, 2]) (List.replicate 4 [Event.read (mkRead .fresh [2, 1] []), .moveResult 1 .verified false]).flatten).2.length = 1 := by decide

/-! ## Corrective pass 3 -/

/-- B1: the target is chosen by DRAWN order; a drag that would change nothing is never made. -/
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .read (mkRead .fresh [2, 3, 1] [9])]).2
    = [⟨3, .after 1, false, true⟩] := by decide
example : (run (State.init [2, 1, 3]) [.userEdit [2, 1, 3] [2], .read (mkRead .fresh [3, 2, 1] [9])]).2
    = [⟨2, .before 3, false, true⟩] := by decide
/-- ... and when anchors are out of record order so no gap satisfies the rule: no move, the attempt is not spent. -/
example : (run (State.init [1, 2, 4, 5])
    [.read (mkRead .fresh [2, 1, 4, 5] [9]), bad 1, .userEdit [1, 4, 2, 5] [4], .read (mkRead .fresh [2, 1, 4, 5] [9])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
example : (run (State.init [1, 2, 4, 5])
    [.read (mkRead .fresh [2, 1, 4, 5] [9]), bad 1, .userEdit [1, 4, 2, 5] [4], .read (mkRead .fresh [2, 1, 4, 5] [9])]).1.owedKeys
    = [4] := by decide

/-- B2: a busy result re-arms the fold request only if the dragged key WAS the fold request. -/
def nr : Read := { mkRead .fresh [1, 2, 3] [9] with nearFold := [3] }
example : (run (State.init [1, 2, 3])
    [.read nr, .userEdit [1, 3, 2] [3], .read nr, .read (mkRead .fresh [1, 2] [3, 9]), .moveResult 3 .busy false,
     .read (mkRead .fresh [1, 2] [3, 9])]).2 = [⟨3, .after 1, true, true⟩] := by decide
/-- ... and when it was, the pull-out is re-armed once. -/
example : (run (State.init [1, 2, 4, 5])
    [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5], .read (mkRead .fresh [1, 2, 4] [5]),
     .moveResult 5 .busy false, .read (mkRead .fresh [1, 2, 4] [5]), .moveResult 5 .busy false,
     .read (mkRead .fresh [1, 2, 4] [5])]).2 = [⟨5, .after 1, true, true⟩, ⟨5, .after 1, true, true⟩] := by decide

/-- B3: `lastDrawn` comes only from reads that may plan: a partial poll just before the drop does not lose the pull-out. -/
def p0 : Read := { mkRead .fresh [2] [5] with kind := .poll, settled := false }
example : (run (State.init [1, 2, 5])
    [.read (mkRead .fresh [1, 2] [5]), .read p0, .userEdit [1, 5, 2] [5], .read (mkRead .fresh [1, 2] [5])]).2
    = [⟨5, .after 1, true, true⟩] := by decide
example : (run (State.init [1, 2, 5])
    [.read (mkRead .fresh [1, 2] [5]), .read { mkRead .fresh [] [] with level := .incomplete, kind := .poll },
     .userEdit [1, 5, 2] [5], .read (mkRead .fresh [1, 2] [5])]).2 = [⟨5, .after 1, true, true⟩] := by decide
example : (run (State.init [1, 5, 2]) [.read (mkRead .fresh [1, 2] [5]), .read p0, .retryKey 5, .read (mkRead .fresh [1, 2] [5])]).2
    = [⟨5, .after 1, true, true⟩] := by decide

/-! ### Directed examples: one per behaviour the mutation run showed was otherwise untested -/

def bad1 : List Event := [.read (mkRead .fresh [2, 1] []), bad 1]
/-- A failed posted drag on a full bar holds the bar and gives the key up, and the hold alone (not the give-up) stops a different key. -/
example : (run (State.init [1, 2]) bad1).1.hold = true := by decide
example : (run (State.init [1, 2]) bad1).1.givenUp = [1] := by decide
example : (run (State.init [1, 2, 3, 4]) [.read (mkRead .fresh [2, 1, 3, 4] []), bad 1, .read (mkRead .fresh [1, 2, 4, 3] [])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
/-- A drawn-only edit keeps the hold; an edit touching the current pile releases it. -/
example : (run (State.init [1, 2]) (bad1 ++ [.userEdit [1, 2] [2]])).1.hold = true := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [2, 1] []), bad 1, .read (mkRead .fresh [2, 1] [5]),
    .userEdit [1, 5, 2] [5]]).1.hold = false := by decide
/-- Planning on an unsettled read, a stale read, or in the user's pass is refused. -/
example : (run (State.init [1, 2]) [.read { mkRead .fresh [2, 1] [] with settled := false }]).2 = [] := by decide
example : (run (State.init [1, 2]) [.read (mkRead .stale [2, 1] [])]).2 = [] := by decide
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [2, 1, 3] []), ok 1, .userEdit [1, 2, 3] [3],
    .read (mkRead .fresh [2, 1, 3] [])]).2 = [⟨1, .before 2, false, false⟩] := by decide
/-- An incomplete read, a fresh chevron and a stale one each reset the proof count. -/
def abs_ : Event := .read (mkRead .absent [1, 2] [])
example : (run (State.init [1, 2]) [abs_, abs_, .read { mkRead .absent [1, 2] [] with level := .incomplete }, abs_]).1.provenNotFull = false := by decide
example : (run (State.init [1, 2]) [abs_, abs_, .read (mkRead .stale [1, 2] []), abs_]).1.noChevronReads = 1 := by decide
example : (run (State.init [1, 2]) [abs_, abs_, .read (mkRead .fresh [1, 2] []), abs_]).1.noChevronReads = 1 := by decide
/-- The proof releases the hold, forgets the pile, and a later chevron makes the bar full (cap 3) again. -/
example : (run (State.init [1, 2]) (bad1 ++ [abs_, abs_, abs_])).1.hold = false := by decide
example : (run (State.init [1, 2]) ([.read (mkRead .fresh [1, 2] [5])] ++ [abs_, abs_, abs_])).1.lastFreshPile = [] := by decide
def proven : List Event := [abs_, abs_, abs_]
def mism : Event := .read (mkRead .absent [2, 1] [])
example : (run (State.init [1, 2]) (proven ++ (List.replicate 30 [mism, ok 1]).flatten)).2.length = 20 := by decide
example : (run (State.init [1, 2]) (proven ++ (List.replicate 3 [mism, ok 1]).flatten ++ [.read (mkRead .fresh [2, 1] [])])).2.length = 3 := by decide
/-- Three strikes on a bar proven not full give a key up (a full bar gives it up at once). -/
example : (run (State.init [1, 2]) (proven ++ (List.replicate 5 [mism, bad 1]).flatten)).2.length = 3 := by decide
example : (run (State.init [1, 2]) (proven ++ [mism, bad 1])).1.hold = false := by decide
/-- Folded and untrusted keys are not movable; keys absent from the record force nothing. -/
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 3, 2] [3])]).2 = [] := by decide
example : (run (State.init [1, 2]) [.read { mkRead .fresh [2, 1] [] with trusted := [2] }]).2 = [] := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [9, 1, 2] [])]).2 = [] := by decide
/-- Pile bookkeeping. -/
example : (run (State.init [1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .fresh [1, 2] [4])]).1.lastFreshPile = [4] := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .stale [1, 2] [4])]).1.lastFreshPile = [3, 4] := by decide
/-- Budget, hold and session reset by user events. -/
def spent : List Event := (List.replicate 3 [Event.read (mkRead .fresh [2, 1] [5]), ok 1]).flatten
example : (run (State.init [1, 2]) spent).1.moveCount = 3 := by decide
example : (run (State.init [1, 2]) (spent ++ [.userRetry])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2]) (spent ++ [.retryKey 1])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2]) (spent ++ [.userEdit [2, 1] [2]])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2]) (spent ++ [.userEdit [2, 1] []])).1.moveCount = 3 := by decide
def pulled : List Event := [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5], .read (mkRead .fresh [1, 2, 4] [5])]
example : (run (State.init [1, 2, 4, 5]) pulled).1.editSessionUsed = true := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.userRetry])).1.editSessionUsed = false := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.retryKey 5])).1.editSessionUsed = false := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.userEdit [1, 5, 2, 4] [5]])).1.editSessionUsed = false := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.moveResult 5 .refused false])).1.editSessionUsed = false := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.moveResult 5 .failed true])).1.editSessionUsed = true := by decide
example : (run (State.init [1, 2, 4, 5]) pulled).1.foldRequest = none := by decide
example : (run (State.init [1, 2, 4, 5]) (pulled ++ [.moveResult 5 .busy false])).1.foldRequest = some 5 := by decide
/-- Hold, give-up, strikes and skipped are cleared by the right user events only. -/
def failedPlus : List Event := [.read (mkRead .fresh [2, 1, 4, 3] []), bad 1]
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.retryKey 1])).1.givenUp = [] := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.retryKey 1])).1.hold = false := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.userRetry])).1.hold = false := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.userEdit [1, 2, 3, 4] [2]])).1.givenUp = [1] := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.userEdit [1, 2, 3, 4] [1]])).1.givenUp = [] := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.retryKey 2])).1.givenUp = [1] := by decide
example : (run (State.init [1, 2, 3, 4]) (failedPlus ++ [.userRetry])).1.givenUp = [] := by decide
def refusedOne : List Event := [.read (mkRead .fresh [2, 1] []), .moveResult 1 .refused false]
example : (run (State.init [1, 2]) refusedOne).1.skipped = [1] := by decide
example : (run (State.init [1, 2]) (refusedOne ++ [.retryKey 1])).1.skipped = [] := by decide
example : (run (State.init [1, 2]) (refusedOne ++ [.userRetry])).1.skipped = [] := by decide
example : (run (State.init [1, 2]) (refusedOne ++ [.userEdit [1, 2] [2]])).1.skipped = [] := by decide
def strikeOne : List Event := proven ++ [mism, bad 1]
example : (run (State.init [1, 2]) strikeOne).1.strikes = [1] := by decide
example : (run (State.init [1, 2]) (strikeOne ++ [.retryKey 1])).1.strikes = [] := by decide
example : (run (State.init [1, 2]) (strikeOne ++ [.retryKey 2])).1.strikes = [1] := by decide
example : (run (State.init [1, 2]) (strikeOne ++ [.userRetry])).1.strikes = [] := by decide
example : (run (State.init [1, 2]) (strikeOne ++ [.userEdit [1, 2] [1]])).1.strikes = [] := by decide
example : (run (State.init [1, 2]) (strikeOne ++ [.userEdit [1, 2] [2]])).1.strikes = [1] := by decide
/-- Owed keys and the fold request follow the record and the edit. -/
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .userEdit [1, 2] [2]]).1.owedKeys = [2] := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .userEdit [1, 2] []]).1.owedKeys = [] := by decide
example : (run (State.init [1, 2]) [.retryKey 9]).1.owedKeys = [] := by decide
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3]]).1.foldRequest = some 3 := by decide
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3], .userEdit [3, 1, 2] [3]]).1.foldRequest = none := by decide
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3], .userEdit [1, 2] [1]]).1.foldRequest = none := by decide
example : (run (State.init [1, 3, 2]) [.read (mkRead .fresh [1, 2] [3]), .retryKey 3]).1.foldRequest = some 3 := by decide
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .retryKey 3]).1.foldRequest = none := by decide
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [3, 1, 2] [3]]).1.foldRequest = none := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3], .userRetry]).1.foldRequest = none := by decide
/-- The fold request is planned before the other owed keys; a pull-out needs a fresh chevron and a closed strip. -/
example : (run (State.init [1, 2, 4, 5])
    [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [4, 1, 5, 2] [4, 5], .read (mkRead .fresh [1, 2, 4] [5])]).2
    = [⟨5, .after 4, true, true⟩] := by decide
example : (run (State.init [1, 2, 4, 5]) [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5], .read (mkRead .stale [1, 2, 4] [5])]).2 = [] := by decide
example : (run (State.init [1, 2, 4, 5]) [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5],
    .read { mkRead .fresh [1, 2, 4] [5] with stripOpen := true }]).2 = [] := by decide
/-- Other owed keys are pinned (not anchors); the user's pass moves only owed keys; Re-apply ends it. -/
example : (run (State.init [1, 2, 3]) [.userEdit [3, 2, 1] [1, 3], .read (mkRead .fresh [1, 2, 3] [9])]).2
    = [⟨3, .before 2, false, true⟩] := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .read (mkRead .fresh [2, 1, 3] [9])]).2 = [] := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .userRetry, .read (mkRead .fresh [2, 1, 3] [9])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [1, 2, 3] [3], .passBoundary, .read (mkRead .fresh [2, 1, 3] [9])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
/-- A result for a key that is not in flight is ignored; a user's move is not budget. -/
example : (run (State.init [1, 2]) [.read (mkRead .fresh [2, 1] []), ok 2]).1.inFlight.isSome = true := by decide
example : (run (State.init [1, 2, 3]) [.userEdit [3, 1, 2] [3], .read (mkRead .fresh [1, 2, 3] []), ok 3]).1.moveCount = 0 := by decide
/-- A re-armed key that left the record is not re-armed. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2, 3] []), .userEdit [3, 1, 2] [3], .read (mkRead .fresh [1, 2, 3] []), .userEdit [1, 2] [2],
     .moveResult 3 .busy false, .read (mkRead .fresh [3, 1, 2] [])]).2 = [⟨3, .before 1, false, true⟩] := by decide

/-- T3: a later edit that pulls out another folded key REPLACES the fold request (5 stays owed, but no pull-out is planned for it). -/
example : (run (State.init [1, 2, 5, 6])
    [.read (mkRead .fresh [1, 2] [5, 6]), .userEdit [1, 5, 2, 6] [5], .userEdit [1, 6, 2, 5] [6]]).1.foldRequest = some 6 := by decide
example : (run (State.init [1, 2, 5, 6])
    [.read (mkRead .fresh [1, 2] [5, 6]), .userEdit [1, 5, 2, 6] [5], .userEdit [1, 6, 2, 5] [6]]).1.owedKeys = [5, 6] := by decide
/-- T4: the pull of 5 is in flight, an edit asks for 6, the result of 5 is busy: the request for 6 is not lost. -/
def t4 : List Event :=
  [.read (mkRead .fresh [1, 2] [5, 6]), .userEdit [1, 5, 2, 6] [5], .read (mkRead .fresh [1, 2] [5, 6]),
   .userEdit [1, 6, 5, 2] [6], .moveResult 5 .busy false]
example : (run (State.init [1, 2, 5, 6]) t4).1.foldRequest = some 6 := by decide
example : (run (State.init [1, 2, 5, 6]) t4).1.owedKeys.contains 5 = true := by decide
/-- T5: the pull of 5 is in flight, an edit puts 5 before every drawn key (no pull-out), the result is busy, 9 becomes drawn:
5 is not pulled out after 9. -/
def t5 : List Event :=
  [.read (mkRead .fresh [1, 2] [5, 6]), .userEdit [1, 5, 2, 6] [5], .read (mkRead .fresh [1, 2] [5, 6]),
   .userEdit [5, 1, 2, 6] [5], .moveResult 5 .busy false, .read (mkRead .fresh [1, 2, 9] [5, 6])]
example : (run (State.init [1, 2, 5, 6, 9]) t5).1.foldRequest = none := by decide
example : (run (State.init [1, 2, 5, 6, 9]) t5).2.length = 1 := by decide

/-- T6: the pull of 5 is in flight, the drawn keys change, Try again on 5 recomputes the pull (no longer valid), busy:
5 is owed but not re-armed as a fold request, so no strip pull follows. -/
def t6 : List Event :=
  [.read (mkRead .fresh [7] [5]), .userEdit [7, 5] [5], .read (mkRead .fresh [7] [5]),
   .read (mkRead .fresh [3] [5]), .retryKey 5, .moveResult 5 .busy false, .read (mkRead .fresh [7] [5])]
example : (run (State.init [7, 5]) t6).2 = [⟨5, .after 7, true, true⟩] := by decide
example : (run (State.init [7, 5]) (t6.take 6)).1.foldRequest = none := by decide
/-- T7: the same with a record-reordering edit that moved nothing. -/
def t7 : List Event :=
  [.read (mkRead .fresh [7] [5]), .userEdit [7, 5] [5], .read (mkRead .fresh [7] [5]),
   .userEdit [5, 7] [], .moveResult 5 .busy false]
example : (run (State.init [7, 5]) t7).1.foldRequest = none := by decide
example : (run (State.init [7, 5]) t7).1.owedKeys = [5] := by decide

/-- B3 (settled pass read at level `incomplete` must not become `lastDrawn`). -/
example : (run (State.init [1, 2, 5])
    [.read (mkRead .fresh [1, 2] [5]), .read { mkRead .fresh [] [] with level := .incomplete },
     .userEdit [1, 5, 2] [5], .read (mkRead .fresh [1, 2] [5])]).2 = [⟨5, .after 1, true, true⟩] := by decide

#print axioms step

end Sommelier
