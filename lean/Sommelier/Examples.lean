import Sommelier.Step
import Sommelier.Status

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

/-- Four posted drags of DIFFERENT keys on a full bar, each working: the engine stops after `capFull` = 3. -/
def budget : List Event :=
  [ .read (mkRead .fresh [2, 1, 3, 4, 5, 6, 7, 8] []), ok 1,
    .read (mkRead .fresh [1, 2, 4, 3, 5, 6, 7, 8] []), ok 3,
    .read (mkRead .fresh [1, 2, 3, 4, 6, 5, 7, 8] []), ok 5,
    .read (mkRead .fresh [1, 2, 3, 4, 5, 6, 8, 7] []) ]
#eval (run (State.init [1, 2, 3, 4, 5, 6, 7, 8]) budget).2.length   -- expected: 3
example : (run (State.init [1, 2, 3, 4, 5, 6, 7, 8]) budget).2.length = 3 := by decide

/-- ejb.17.  A drag the actuator calls verified but the next read still shows undone (macOS reverted it) takes a strike for its key, on a full bar as on
any other: the third strike gives the key up, so it is dragged exactly three times however many reads follow, and the bar is never held. -/
def reverted : List Event :=
  (List.replicate 12 [Event.read (mkRead .fresh [3, 2, 1, 4] [5]), ok 1]).flatten
example : (run (State.init [1, 2, 3, 4, 5]) reverted).2.length = 3 := by decide
example : (run (State.init [1, 2, 3, 4, 5]) reverted).1.hold = false := by decide
example : (run (State.init [1, 2, 3, 4, 5]) reverted).1.strikes = [1, 1, 1] := by decide
example : (run (State.init [1, 2, 3, 4, 5]) reverted).1.givenUp = [1] := by decide
/-- A user event gives the key back: the strikes and the pending mark go with it. -/
example : (run (State.init [1, 2, 3, 4, 5]) (reverted ++ [.retryKey 1])).1.strikes = [] := by decide
example : (run (State.init [1, 2, 3, 4, 5]) ([.read (mkRead .fresh [3, 2, 1, 4] [5]), ok 1, .retryKey 1])).1.verified = none := by decide
/-- A verified drag the next read confirms takes no strike. -/
example : (run (State.init [1, 2]) [.read (mkRead .fresh [2, 1] []), ok 1, .read (mkRead .fresh [1, 2] [])]).1.strikes = [] := by decide
example : (run (State.init [1, 2]) [.read (mkRead .fresh [2, 1] []), ok 1, .read (mkRead .fresh [1, 2] [])]).1.verified = none := by decide

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

/-- C3/C5: a stale read is not usable (gate): even the user's own move waits for a usable reading, so nothing leaves and nothing can
target a key of the last fresh pile. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .stale [1, 2, 3] []), .userEdit [3, 2, 1] [1],
     .read (mkRead .stale [1, 2, 3] [])]).2 = [] := by decide

/-- D (assumption, see docs): while a drag is in flight the core decides nothing; the actuator MUST answer it. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [2, 1, 3] []), .userEdit [3, 2, 1] [3], .read (mkRead .fresh [2, 1, 3] [])]).2
    = [⟨1, .before 2, false, false⟩] := by decide
/-- ... and once it is answered the user's drop is served. -/
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [2, 1, 3] []), ok 1, .userEdit [3, 2, 1] [3], .read (mkRead .fresh [2, 1, 3] [])]).2
    = [⟨1, .before 2, false, false⟩, ⟨3, .before 2, false, true⟩] := by decide

/-- E: drawn when the edit was made, folded when read (macOS folded it between): no fold request was made, but the key is OWED and THIS read lists it as
folded under a fresh chevron, so the first such good read pulls it out (after 1, with the strip): a drop gets its move on the next good reading. -/
example : (run (State.init [1, 2, 3, 4])
    [.read (mkRead .fresh [1, 2, 3, 4] [9]), .userEdit [1, 3, 2, 4] [3], .read (mkRead .fresh [1, 2, 4] [3, 9])]).2
    = [⟨3, .after 1, true, true⟩] := by decide
example : (run (State.init [1, 2, 3, 4])
    [.read (mkRead .fresh [1, 2, 3, 4] [9]), .userEdit [1, 3, 2, 4] [3], .read (mkRead .fresh [1, 2, 4] [3, 9])]).1.foldRequest = none := by decide

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

/-- N: with the strip open the reading is not usable (gate): neither the user's drawn move nor an engine move leaves. -/
def open_ : Read := { mkRead .fresh [1, 2, 3] [] with stripOpen := true }
example : (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2, 3] []), .userEdit [3, 1, 2] [3], .read open_]).2
    = [] := by decide
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

/-- B2: a busy result re-arms the fold request only if the dragged key WAS the fold request.  Here 3 was dragged as an ordinary drawn drop, so no request is
re-armed (`foldRequest = none`); the key is owed again, so the next read that lists it as folded pulls it out, once. -/
def nr : Read := { mkRead .fresh [1, 2, 3] [9] with nearFold := [3] }
example : (run (State.init [1, 2, 3])
    [.read nr, .userEdit [1, 3, 2] [3], .read nr, .read (mkRead .fresh [1, 2] [3, 9]), .moveResult 3 .busy false,
     .read (mkRead .fresh [1, 2] [3, 9])]).2 = [⟨3, .after 1, true, true⟩, ⟨3, .after 1, true, true⟩] := by decide
example : (run (State.init [1, 2, 3])
    [.read nr, .userEdit [1, 3, 2] [3], .read nr, .read (mkRead .fresh [1, 2] [3, 9]), .moveResult 3 .busy false]).1.foldRequest = none := by decide
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
example : (run (State.init [1, 2]) (bad1 ++ [abs_, abs_, abs_, abs_])).1.hold = false := by decide
example : (run (State.init [1, 2]) ([.read (mkRead .fresh [1, 2] [5])] ++ [abs_, abs_, abs_, abs_])).1.lastFreshPile = [] := by decide
def proven : List Event := [abs_, abs_, abs_]
def mism : Event := .read (mkRead .absent [2, 1] [])
example : (run (State.init [1, 2]) (proven ++ (List.replicate 30 [mism, ok 1]).flatten)).2.length = 3 := by decide
/-- On a bar proven not full the contradicted key takes strikes and is dragged exactly three times, however many reads follow. -/
def revertedProven : List Event :=
  [abs_, abs_, abs_] ++ (List.replicate 12 [Event.read (mkRead .absent [2, 1] []), ok 1]).flatten
example : (run (State.init [1, 2]) revertedProven).2.length = 3 := by decide
example : (run (State.init [1, 2]) revertedProven).1.strikes = [1, 1, 1] := by decide
example : (run (State.init [1, 2]) revertedProven).1.givenUp = [1] := by decide
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
def spent : List Event :=
  [ .read (mkRead .fresh [2, 1, 3, 4, 5, 6] []), ok 1,
    .read (mkRead .fresh [1, 2, 4, 3, 5, 6] []), ok 3,
    .read (mkRead .fresh [1, 2, 3, 4, 6, 5] []), ok 5 ]
example : (run (State.init [1, 2, 3, 4, 5, 6]) spent).1.moveCount = 3 := by decide
example : (run (State.init [1, 2, 3, 4, 5, 6]) (spent ++ [.userRetry])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2, 3, 4, 5, 6]) (spent ++ [.retryKey 1])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2, 3, 4, 5, 6]) (spent ++ [.userEdit [2, 1, 3, 4, 5, 6] [2]])).1.moveCount = 0 := by decide
example : (run (State.init [1, 2, 3, 4, 5, 6]) (spent ++ [.userEdit [2, 1, 3, 4, 5, 6] []])).1.moveCount = 3 := by decide
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
def strikeOne : List Event := proven ++ [abs_, mism, bad 1]
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
5 is owed but not re-armed as a fold request; it is owed, so the read that lists it folded pulls it out once. -/
def t6 : List Event :=
  [.read (mkRead .fresh [7] [5]), .userEdit [7, 5] [5], .read (mkRead .fresh [7] [5]),
   .read (mkRead .fresh [3] [5]), .retryKey 5, .moveResult 5 .busy false, .read (mkRead .fresh [7] [5])]
example : (run (State.init [7, 5]) t6).2 = [⟨5, .after 7, true, true⟩, ⟨5, .after 7, true, true⟩] := by decide
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

def rv (s : State) (r : Read) (k : Key) : RowVerdict := rowVerdict s.record (s.view r) k

/-- ejb.3 blocker 2 (restated on the verdict; there is no drop memory): the user drops folded 3 right of the fold with 1 drawn before it; the pull-out is refused before any mouse event.  Nothing is owed any more, yet 3 is behind « while 1, which comes before it in the record, is open: the bar DIFFERS and the row says "not where you put it" (`behindOutOfTurn`), never "matches". -/
def unmetStart : State := { State.init [1, 3] with lastFreshPile := [3], lastDrawn := [1, 2] }
def unmetTrace : List Event :=
  [.userEdit [1, 3] [3], .read (mkRead .fresh [1, 2] [3]), .moveResult 3 .refused false]
example : (run unmetStart unmetTrace).1.owedKeys = [] := by decide
example : (run unmetStart unmetTrace).1.foldRequest = none := by decide
example : rv (run unmetStart unmetTrace).1 (mkRead .fresh [1, 2] [3]) 3 = .behindOutOfTurn := by decide
example : shownVerdict (run unmetStart unmetTrace).1 (mkRead .fresh [1, 2] [3]) = .differs := by decide
/-- ... and Try again on 3 owes it again. -/
example : (run unmetStart (unmetTrace ++ [.retryKey 3])).1.owedKeys = [3] := by decide
/-- A poll is not a usable reading: cannot tell, never "matches"; the same bar as a proven pass read matches. -/
example : shownVerdict (State.init [1, 2]) { mkRead .fresh [1, 2] [] with kind := .poll } = .cannotTell := by decide
example : shownVerdict { State.init [1, 2] with provenNotFull := true } (mkRead .absent [1, 2] []) = .matches := by decide

/-! ### ejb.3 review 2: the UI never lies about the bar (F1 - F4), each trace with its corrected result on the verdict -/

def s3 : Read := mkRead .fresh [1, 2] [3]
/-- 1 drawn, 2 and 3 behind «. -/
def s3' : Read := mkRead .fresh [1, 3] [2]
def rwr : Read := mkRead .absent [1, 3, 2] []
/-- A bar proven not full, 3 dropped to the right of 2 and drawn wrongly. -/
def pf : State := { State.init [1, 2, 3] with provenNotFull := true, lastDrawn := [1, 3, 2] }

/-- F1: a FAILED posted drag leaves 3 behind «, never placed: the verdict is `differs` (the old window said "matches"). -/
def f1 : List Event := [.userEdit [1, 2, 3] [3], .read rwr, .moveResult 3 .failed true, .read s3, .passBoundary]
example : shownVerdict (run pf f1).1 s3 = .differs := by decide
example : rv (run pf f1).1 s3 3 = .behindOutOfTurn := by decide
/-- ... a posted REFUSED or BUSY result is no different ... -/
example : shownVerdict (run unmetStart [.userEdit [1, 3] [3], .read s3, .moveResult 3 .refused true, .read s3, .passBoundary, .read s3]).1 s3
    = .differs := by decide
example : shownVerdict (run unmetStart [.userEdit [1, 3] [3], .read s3, .moveResult 3 .busy true, .read s3, .passBoundary, .read s3]).1 s3
    = .differs := by decide
/-- ... and an old drag that posts `verified` after the chain ended still leaves 3 behind «: differs. -/
example : shownVerdict (run { unmetStart with inFlight := some ⟨3, .after 1, true, true⟩ }
    [.userEdit [1, 3] [3], .passBoundary, .moveResult 3 .verified true, .read s3]).1 s3 = .differs := by decide
/-- A POSTED `verified` drag changes nothing about the verdict: only the read decides, and 3 is still behind «. -/
example : shownVerdict (run unmetStart [.userEdit [1, 3] [3], .read s3, .moveResult 3 .verified true, .read s3, .passBoundary, .read s3]).1 s3
    = .differs := by decide

/-- F2: 3 was dropped between 1 and 2 and the read is on a STALE chevron: a stale read is not usable, so the verdict is "cannot tell" ... -/
def f2s : State := { State.init [1, 3, 2] with lastFreshPile := [2], lastDrawn := [1, 3] }
def f2r : Read := mkRead .stale [1, 2, 3] []
def f2 : List Event := [.userEdit [1, 3, 2] [3], .read f2r, .passBoundary, .read f2r]
example : shownVerdict (run f2s f2).1 f2r = .cannotTell := by decide
/-- ... with no drop at all, a stale read of a reversed bar is "cannot tell", never "matches" ... -/
example : shownVerdict (run (State.init [1, 3, 2]) [.read (mkRead .fresh [] [1, 2, 3]), .read (mkRead .stale [2, 3, 1] [])]).1
    (mkRead .stale [2, 3, 1] []) = .cannotTell := by decide
/-- ... and so is a stale read of a bar in the right order: a stale chevron confirms nothing. -/
example : shownVerdict (State.init [1, 2]) (mkRead .stale [1, 2] []) = .cannotTell := by decide
/-- A read with the strip open is not usable: cannot tell, whatever the pile memory holds. -/
example : shownVerdict (run (State.init [1, 3, 2]) [.read (mkRead .fresh [1, 3] [2]),
    .read { mkRead .fresh [1, 2, 3] [] with stripOpen := true }]).1 { mkRead .fresh [1, 2, 3] [] with stripOpen := true } = .cannotTell := by decide

/-- F3: the tmMismatch trace.  3 (folded) is dropped at the front; nothing precedes it.  1 and 2 are inverted on the bar and 3 is behind «: the verdict is `differs` (the engine moves 1: status "Moving"), and the row of 3 says `behindChevron`, never "not where you put it". -/
def tmS : State := State.init [1, 2, 3, 4, 5]
def tmR : Read := mkRead .fresh [2, 1, 4, 5] [3]
def tmT : List Event := [.read tmR, ok 1, .userEdit [3, 1, 2, 4, 5] [3], .read tmR, .passBoundary]
example : rv (run tmS tmT).1 tmR 3 = .behindChevron := by decide
example : shownVerdict (run tmS (tmT ++ [.moveResult 1 .verified true, .read tmR])).1 tmR = .differs := by decide
/-- ... and with a spent budget the verdict is still `differs`; the status adds `stopped` (`stopped_true`). -/
example : shownVerdict { (run tmS tmT).1 with moveCount := 3, inFlight := none } tmR = .differs := by decide
/-- A drop of 2, already right, with no drag: the verdict is read from the bar alone; a later fold by macOS changes the reading, not the past. -/
def p2 : State := { State.init [1, 2, 3] with provenNotFull := true, lastDrawn := [1, 2, 3] }
def ro : Read := mkRead .absent [1, 2, 3] []
example : shownVerdict (run p2 [.userEdit [1, 2, 3] [2], .read ro, .passBoundary, .read ro, .read s3']).1 s3' = .differs := by decide
/-- F4: the refused pull-out, then Re-apply, then a read: 3 is still behind « with 1 open before it: differs, never "matches". -/
example : shownVerdict (run unmetStart (unmetTrace ++ [.userRetry, .read s3])).1 s3 = .differs := by decide
/-- Re-apply while the drop is still owed (never attempted): the same. -/
example : shownVerdict (run unmetStart [.userEdit [1, 3] [3], .userRetry, .read s3]).1 s3 = .differs := by decide
/-- D-D: a dropped key that is listed nowhere in a usable read is not on the bar: its row says "not on the bar" (`notOnBar`), the record matches without it, and it comes back with the key. -/
def gone : Read := mkRead .absent [1, 2] []
example : rv (run pf [.userEdit [1, 2, 3] [3], .read rwr, .moveResult 3 .failed true, .read gone, .passBoundary]).1 gone 3 = .notOnBar := by decide
example : shownVerdict (run pf [.userEdit [1, 2, 3] [3], .read rwr, .moveResult 3 .failed true, .read gone, .passBoundary]).1 gone = .matches := by decide
example : shownVerdict (run pf [.userEdit [1, 2, 3] [3], .read rwr, .moveResult 3 .failed true, .read gone, .passBoundary]).1 s3 = .differs := by decide

/-- T1 restated: no drop is ever "silently lost" because the verdict never remembers a drop.  A key already right matches; a key that left the record, or that is not on the bar, does not hold the verdict up. -/
example : shownVerdict (run p2 [.userEdit [1, 2, 3] [2], .read ro, .passBoundary]).1 ro = .matches := by decide
example : (run unmetStart (unmetTrace ++ [.userEdit [1] []])).1.record = [1] := by decide
example : shownVerdict (run unmetStart (unmetTrace ++ [.userEdit [1] [], .read (mkRead .fresh [1, 2] [])])).1 (mkRead .fresh [1, 2] []) = .matches := by decide

/-! ### ejb.3 review 2: EVERY trace the reviewer evaluated (`Attack.lean`, `Attack2.lean`), restated on `shownVerdict` and `rowVerdict`
(`rv`) with its CORRECTED result.  The verdict is read from the record and the latest reading alone: a failed, refused or busy
posted drag, Re-apply, a stale chevron, pile memory and a drop that needs nothing leave nothing behind that could make the UI lie. -/
namespace Review2
def R := mkRead .fresh [1,2] [3]
def S := unmetStart
def E : Event := .userEdit [1,3] [3]
-- proven bar, drawn wrong, drag posted failed, then k folds or vanishes
def P : State := { State.init [1,2,3] with provenNotFull := true, lastDrawn := [1,3,2] }
def Rw := mkRead .absent [1,3,2] []
def Rf := mkRead .fresh [1,2] [3]
def Rg := mkRead .absent [1,2] []
def E2 : Event := .userEdit [1,2,3] [3]
-- unposted then fold
-- stale read follows
def Rs := mkRead .stale [1,2] [3]
-- old in-flight drag posts after the drop was discarded
def F : State := { S with inFlight := some ⟨3, .after 1, true, true⟩ }
-- multi key
def S4 : State := { State.init [1,3,4] with lastFreshPile := [3,4], lastDrawn := [1,2] }
def R4 := mkRead .fresh [1,2] [3,4]
-- retry events
-- later edits
-- second pull replaces request
def S5 : State := { State.init [1,3,4] with lastFreshPile := [3,4], lastDrawn := [1] }
def R5 := mkRead .fresh [1] [3,4]
-- unmet of a key placed: no-drag drop then false claims
def Tm0 := State.init [1,2,3,4,5]
def Rm := mkRead .fresh [2,1,4,5] [3]
-- the same with a spent budget (moveCount := 3 below)
def J3s := run Tm0 [.read Rm, .userEdit [3,1,2,4,5] [3], .read Rm, .passBoundary]
-- TM drop where the app quits: 3 gone, proof
def Rq := mkRead .absent [1,2,4,5] []
-- drop already right then folds by macOS / another drop inverts
def P2 : State := { State.init [1,2,3] with provenNotFull := true, lastDrawn := [1,2,3] }
def Ro := mkRead .absent [1,2,3] []
-- placed folded with preceding drawn-untrusted or drawn-folded
def Ru : Read := { mkRead .fresh [1,2] [3] with trusted := [2,3] }
-- predecessor drawn but in lastFreshPile
def S6 : State := { State.init [1,3] with lastFreshPile := [1,3], lastDrawn := [1] }
def R6 := mkRead .stale [1] [3]
-- order violated by a memory-folded drawn key
def S7 : State := { State.init [1,3,2] with lastFreshPile := [2], lastDrawn := [1,2,3] }
def R7 := mkRead .stale [1,2,3] []
-- wrong final-read: status against other read than last
-- granted engine strip move refused: unmet naming a key user never dropped
def S8 : State := { State.init [1,2] with lastDrawn := [2,1], provenNotFull := true }
def R8 : Read := { mkRead .absent [2,1] [] with nearFold := [1] }
-- r.observed = false
-- reachable from init: stale chevron + pile memory hides a visibly wrong drawn order
def rF := mkRead .fresh [1,3] [2]
def rS := mkRead .stale [1,2,3] []
def tr : List Event := [.read rF, .userEdit [1,3,2] [3], .read rS, .passBoundary, .read rS]
-- without a drop too, and with drawn order clearly reversed (full reversal)
def rS2 := mkRead .stale [2,3,1] []
-- status on a stale chevron with order fine
/-- A posted verified, still folded -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .verified true, .read R, .passBoundary, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .verified true, .read R, .passBoundary, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- A2 posted failed unproven -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .failed true, .read R, .passBoundary, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .failed true, .read R, .passBoundary, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- A3 posted refused(true) -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused true, .read R, .passBoundary, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused true, .read R, .passBoundary, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- A4 posted busy(true) -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .busy true, .read R, .passBoundary, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .busy true, .read R, .passBoundary, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- B failed proven, then folds -/
example : shownVerdict (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rf, .passBoundary, .read Rf]).1 Rf = .differs := by decide
example : rv (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rf, .passBoundary, .read Rf]).1 Rf 3 = .behindOutOfTurn := by decide
/-- B2 failed proven, vanishes -/
example : shownVerdict (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rg, .passBoundary, .read Rg]).1 Rg = .matches := by decide
example : rv (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rg, .passBoundary, .read Rg]).1 Rg 3 = .notOnBar := by decide
/-- B3 failed proven, wrong place -/
example : shownVerdict (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rw]).1 Rw = .differs := by decide
example : rv (run P [E2, .read Rw, .moveResult 3 .failed true, .read Rw]).1 Rw 3 = .outOfPlace := by decide
/-- B4 verified, folds after -/
example : shownVerdict (run P [E2, .read Rw, .moveResult 3 .verified true, .read Rf, .passBoundary, .read Rf]).1 Rf = .differs := by decide
example : rv (run P [E2, .read Rw, .moveResult 3 .verified true, .read Rf, .passBoundary, .read Rf]).1 Rf 3 = .behindOutOfTurn := by decide
/-- C refused unposted, folded -/
example : shownVerdict (run P [E2, .read Rw, .moveResult 3 .refused false, .read Rf, .passBoundary, .read Rf]).1 Rf = .differs := by decide
example : rv (run P [E2, .read Rw, .moveResult 3 .refused false, .read Rf, .passBoundary, .read Rf]).1 Rf 3 = .behindOutOfTurn := by decide
/-- D posted verified stale -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .verified true, .read Rs]).1 Rs = .cannotTell := by decide
example : rv (run S [E, .read R, .moveResult 3 .verified true, .read Rs]).1 Rs 3 = .cannotTell := by decide
/-- D2 refused then stale -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .read Rs]).1 Rs = .cannotTell := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .read Rs]).1 Rs 3 = .cannotTell := by decide
/-- E old flight posts after boundary -/
example : shownVerdict (run F [E, .passBoundary, .moveResult 3 .verified true, .read R]).1 R = .differs := by decide
example : rv (run F [E, .passBoundary, .moveResult 3 .verified true, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- F multi k=4 -/
example : shownVerdict (run S4 [.userEdit [1,3,4] [3,4], .read R4, .moveResult 3 .verified true, .read R4, .passBoundary, .read R4]).1 R4 = .differs := by decide
example : rv (run S4 [.userEdit [1,3,4] [3,4], .read R4, .moveResult 3 .verified true, .read R4, .passBoundary, .read R4]).1 R4 4 = .behindOutOfTurn := by decide
/-- F2 multi k=3 -/
example : shownVerdict (run S4 [.userEdit [1,3,4] [3,4], .read R4, .moveResult 3 .refused false, .read R4, .passBoundary, .read R4]).1 R4 = .differs := by decide
example : rv (run S4 [.userEdit [1,3,4] [3,4], .read R4, .moveResult 3 .refused false, .read R4, .passBoundary, .read R4]).1 R4 3 = .behindOutOfTurn := by decide
/-- G userRetry after refused -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userRetry, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userRetry, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- G2 userRetry while owed, no attempt -/
example : shownVerdict (run S [E, .userRetry, .read R]).1 R = .differs := by decide
example : rv (run S [E, .userRetry, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- G3 retryKey -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .retryKey 3, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .retryKey 3, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- G4 retryKey then refused -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .retryKey 3, .read R, .moveResult 3 .refused false, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .retryKey 3, .read R, .moveResult 3 .refused false, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- H empty edit same rec -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1,3] []]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1,3] []]).1 R 3 = .behindOutOfTurn := by decide
/-- H2 empty edit removes 3 -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1] []]).1 R = .matches := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1] []]).1 R 3 = .behindOutOfTurn := by decide
/-- H3 re-add by empty edit -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1] [], .userEdit [1,3] []]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1] [], .userEdit [1,3] []]).1 R 3 = .behindOutOfTurn := by decide
/-- H4 edit naming other j=1 -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1,3] [1], .read R, .passBoundary, .read R]).1 R = .differs := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userEdit [1,3] [1], .read R, .passBoundary, .read R]).1 R 3 = .behindOutOfTurn := by decide
/-- H5 edit moves 3 left of 1: new want -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false, .userEdit [3,1] [3], .passBoundary, .read R]).1 R = .matches := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false, .userEdit [3,1] [3], .passBoundary, .read R]).1 R 3 = .behindChevron := by decide
/-- I replaced request k=3 -/
example : shownVerdict (run S5 [.userEdit [1,3,4] [3], .userEdit [1,3,4] [4], .read R5, .moveResult 4 .verified true, .passBoundary, .read R5]).1 R5 = .differs := by decide
example : rv (run S5 [.userEdit [1,3,4] [3], .userEdit [1,3,4] [4], .read R5, .moveResult 4 .verified true, .passBoundary, .read R5]).1 R5 3 = .behindOutOfTurn := by decide
/-- J tmMismatch after boundary -/
example : shownVerdict (run Tm0 [.read Rm, .userEdit [3,1,2,4,5] [3], .read Rm, .passBoundary]).1 Rm = .differs := by decide
example : rv (run Tm0 [.read Rm, .userEdit [3,1,2,4,5] [3], .read Rm, .passBoundary]).1 Rm 3 = .behindChevron := by decide
/-- J2 tmMismatch next read -/
example : shownVerdict (run Tm0 [.read Rm, .userEdit [3,1,2,4,5] [3], .read Rm, .passBoundary, .read Rm]).1 Rm = .differs := by decide
example : rv (run Tm0 [.read Rm, .userEdit [3,1,2,4,5] [3], .read Rm, .passBoundary, .read Rm]).1 Rm 3 = .behindChevron := by decide
/-- J3 budget spent -/
example : shownVerdict (run { J3s.1 with moveCount := 3 } [.read Rm]).1 Rm = .differs := by decide
example : rv (run { J3s.1 with moveCount := 3 } [.read Rm]).1 Rm 3 = .behindChevron := by decide
/-- K tm then gone, proof -/
example : shownVerdict (run Tm0 [.read (mkRead .fresh [1,2,4,5] [3]), .userEdit [3,1,2,4,5] [3], .read (mkRead .fresh [1,2,4,5] [3]), .passBoundary, .read Rq, .read Rq, .read Rq, .read Rq]).1 Rq = .matches := by decide
example : rv (run Tm0 [.read (mkRead .fresh [1,2,4,5] [3]), .userEdit [3,1,2,4,5] [3], .read (mkRead .fresh [1,2,4,5] [3]), .passBoundary, .read Rq, .read Rq, .read Rq, .read Rq]).1 Rq 3 = .notOnBar := by decide
/-- K2 same, retryKey then boundary -/
example : shownVerdict (run Tm0 [.read (mkRead .fresh [1,2,4,5] [3]), .userEdit [3,1,2,4,5] [3], .read (mkRead .fresh [1,2,4,5] [3]), .passBoundary, .read Rq, .read Rq, .read Rq, .retryKey 3, .read Rq, .passBoundary, .read Rq]).1 Rq = .matches := by decide
example : rv (run Tm0 [.read (mkRead .fresh [1,2,4,5] [3]), .userEdit [3,1,2,4,5] [3], .read (mkRead .fresh [1,2,4,5] [3]), .passBoundary, .read Rq, .read Rq, .read Rq, .retryKey 3, .read Rq, .passBoundary, .read Rq]).1 Rq 3 = .notOnBar := by decide
/-- L right, no drag, boundary -/
example : shownVerdict (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro]).1 Ro = .matches := by decide
example : rv (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro]).1 Ro 2 = .inOrder := by decide
/-- L2 then macOS folds it -/
example : shownVerdict (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .read (mkRead .fresh [1,3] [2])]).1 (mkRead .fresh [1,3] [2]) = .differs := by decide
example : rv (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .read (mkRead .fresh [1,3] [2])]).1 (mkRead .fresh [1,3] [2]) 2 = .behindOutOfTurn := by decide
/-- L3 then another drop inverts -/
example : shownVerdict (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .userEdit [3,1,2] [3]]).1 Ro = .differs := by decide
example : rv (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .userEdit [3,1,2] [3]]).1 Ro 2 = .outOfPlace := by decide
/-- L4 L3 key 3 row -/
example : shownVerdict (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .userEdit [3,1,2] [3]]).1 Ro = .differs := by decide
example : rv (run P2 [.userEdit [1,2,3] [2], .read Ro, .passBoundary, .read Ro, .userEdit [3,1,2] [3]]).1 Ro 3 = .outOfPlace := by decide
/-- M predecessor untrusted -/
example : shownVerdict (run S [E, .read Ru, .passBoundary]).1 Ru = .matchesExcept [1] := by decide
example : rv (run S [E, .read Ru, .passBoundary]).1 Ru 3 = .behindChevron := by decide
/-- M2 predecessor drawn & memory-folded -/
example : shownVerdict (run S6 [.userEdit [1,3] [3], .read R6, .passBoundary, .read R6]).1 R6 = .cannotTell := by decide
example : rv (run S6 [.userEdit [1,3] [3], .read R6, .passBoundary, .read R6]).1 R6 3 = .cannotTell := by decide
/-- M3 drawn wrong via stale pile memory -/
example : shownVerdict (run S7 [.userEdit [1,3,2] [3], .read R7, .passBoundary, .read R7]).1 R7 = .cannotTell := by decide
example : rv (run S7 [.userEdit [1,3,2] [3], .read R7, .passBoundary, .read R7]).1 R7 3 = .cannotTell := by decide
/-- N evaluated on read that never happened -/
example : shownVerdict (run S [E, .read R, .moveResult 3 .refused false]).1 (mkRead .absent [1,3] []) = .cannotTell := by decide
example : rv (run S [E, .read R, .moveResult 3 .refused false]).1 (mkRead .absent [1,3] []) 3 = .cannotTell := by decide
/-- O grant refused -/
example : shownVerdict (run S8 [.userRetry, .read R8, .moveResult 1 .refused false]).1 R8 = .differs := by decide
example : rv (run S8 [.userRetry, .read R8, .moveResult 1 .refused false]).1 R8 1 = .outOfPlace := by decide
/-- Q unobserved -/
example : shownVerdict (run S [E]).1 { R with observed := false } = .cannotTell := by decide
example : rv (run S [E]).1 { R with observed := false } 3 = .cannotTell := by decide
/-- Attack2: stale chevron + pile memory hides a visibly wrong drawn order (reachable from init) ... -/
example : shownVerdict (run (State.init [1,3,2]) tr).1 rS = .cannotTell := by decide
/-- ... without a drop, a stale read of a full reversal ... -/
example : shownVerdict (run (State.init [1,3,2]) [.read (mkRead .fresh [] [1,2,3]), .read (mkRead .stale [2,3,1] [])]).1 (mkRead .stale [2,3,1] []) = .cannotTell := by decide
/-- ... and a stale read whose order is fine is "Checking", never "matches". -/
example : shownVerdict (run (State.init [1,2]) [.read (mkRead .stale [1,2] [])]).1 (mkRead .stale [1,2] []) = .cannotTell := by decide
end Review2

#print axioms step

/-! ## A drop gets its move on the next good reading (`userMove`: owed AND this read lists the key as folded)

The review traces W2 and W, and the edge cases of the rule. -/

/-- W2: the record is [1, 2, 3], the bar shows all three; the user drops 3 after 1; macOS then folds 3 and the next good reading shows 1, 2 open and 3 in the
pile.  No fold request was ever made (3 was drawn at the drop), yet the first such read pulls 3 out: exactly one move of 3, after 1, with the strip, the user's. -/
def w2Trace : List Event :=
  [.read (mkRead .fresh [1, 2, 3] []), .userEdit [1, 3, 2] [3], .read (mkRead .fresh [1, 2] [3])]
example : (run (State.init [1, 2, 3]) w2Trace).2 = [⟨3, .after 1, true, true⟩] := by decide
example : (run (State.init [1, 2, 3]) (w2Trace.take 2)).1.foldRequest = none := by decide
/-- ... one attempt per drop: the move consumed the owed key, and later good readings do not repeat it. -/
example : (run (State.init [1, 2, 3]) w2Trace).1.owedKeys = [] := by decide
example : (run (State.init [1, 2, 3]) (w2Trace ++ [ok 3, .read (mkRead .fresh [1, 2] [3]), .read (mkRead .fresh [1, 2] [3])])).2.length = 1 := by decide

/-- W: the pile memory still lists 2, but THIS usable read shows 2 drawn: it is judged as drawn, and the drop of 2 before 1 is answered (not skipped as folded). -/
example : (run { State.init [1, 2] with lastFreshPile := [2] } [.userEdit [2, 1] [2], .read (mkRead .fresh [1, 2] [])]).2
    = [⟨2, .before 1, false, true⟩] := by decide
/-- ... on a read that is not a usable fresh-chevron read the memory still counts as folded (a stale chevron: the gate refuses anyway). -/
example : (run { State.init [1, 2] with lastFreshPile := [2] } [.userEdit [2, 1] [2], .read (mkRead .stale [1, 2] [])]).2 = [] := by decide

/-- Edge: rec [3, 1, 2] with 3 folded and 1, 2 open in order: no movable key precedes 3, so no move; the verdict matches (T6) and the row is the verdict's
`behind`, not `waiting` (the read is good and the drop needs no move). -/
def e3 : State := (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [3, 1, 2] [3]]).1
example : (step e3 (.read (mkRead .fresh [1, 2] [3]))).2 = [] := by decide
example : shownVerdict e3 (mkRead .fresh [1, 2] [3]) = .matches := by decide
example : statusLine e3 (mkRead .fresh [1, 2] [3]) = .matches := by decide
example : rowLine e3 (mkRead .fresh [1, 2] [3]) 3 = .behind := by decide

/-- Edge: the only predecessor of the dropped key is untrusted: no drag past it.  The verdict is `matchesExcept [1]` and the row says what the verdict
says (3 is behind the chevron on every bar the read allows). -/
def eU : State := (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2] [3]), .userEdit [1, 3, 2] [3]]).1
def rU : Read := { mkRead .fresh [1, 2] [3] with trusted := [2, 3] }
example : (step eU (.read rU)).2 = [] := by decide
example : statusLine eU rU = .matchesExcept [1] := by decide
example : rowLine eU rU 3 = .behind := by decide

/-- Edge: a move exists but the strip session of this edit is used: it waits (the row says `waiting`), and does NOT leave. -/
def eA : State := (run (State.init [1, 2, 3]) [.read (mkRead .fresh [1, 2, 3] []), .userEdit [1, 3, 2] [3]]).1
def eB : State := { eA with editSessionUsed := true }
example : (step eB (.read (mkRead .fresh [1, 2] [3]))).2 = [] := by decide
example : rowLine eB (mkRead .fresh [1, 2] [3]) 3 = .waiting := by decide
/-- ... the pass boundary expires the drop: the row reads `notWherePut` (the verdict), and "Try again" on the key still works (a new session). -/
example : rowLine (step eB .passBoundary).1 (mkRead .fresh [1, 2] [3]) 3 = .notWherePut := by decide
example : (step (step (step eB .passBoundary).1 (.retryKey 3)).1 (.read (mkRead .fresh [1, 2] [3]))).2 = [⟨3, .after 1, true, true⟩] := by decide
/-- Edge: the strip is open (the read is not good): nothing leaves and the row waits; a poll likewise. -/
example : (step eA (.read { mkRead .fresh [1, 2] [3] with stripOpen := true })).2 = [] := by decide
example : rowLine eA { mkRead .fresh [1, 2] [3] with stripOpen := true } 3 = .waiting := by decide
example : rowLine eA { mkRead .fresh [1, 2] [3] with kind := .poll } 3 = .waiting := by decide

/-- Edge: a busy result is re-armed at most once (two busy results, three good readings, two pulls). -/
example : (run (State.init [1, 2, 4, 5])
    [.read (mkRead .fresh [1, 2, 4] [5]), .userEdit [1, 5, 2, 4] [5], .read (mkRead .fresh [1, 2, 4] [5]),
     .moveResult 5 .busy false, .read (mkRead .fresh [1, 2, 4] [5]), .moveResult 5 .busy false,
     .read (mkRead .fresh [1, 2, 4] [5]), .read (mkRead .fresh [1, 2, 4] [5])]).2.length = 2 := by decide

/-- Edge: a folded key the user did NOT drop never gets a pull-out; the engine cannot cross the fold. -/
example : (run (State.init [3, 1, 2]) [.read (mkRead .fresh [1, 2] [3]), .read (mkRead .fresh [1, 2] [3])]).2 = [] := by decide
example : (run (State.init [1, 2, 3])
    [.read (mkRead .fresh [1, 2] [3]), .userEdit [2, 1, 3] [2], .read (mkRead .fresh [1, 2] [3]), ok 2,
     .read (mkRead .fresh [2, 1] [3]), .read (mkRead .fresh [2, 1] [3])]).2.all (fun a => a.subject != 3) = true := by decide

/-- The `waiting` row: on a good read where the dropped key is already right, the row is its verdict (a check mark), not `waiting`; before a good read it waits. -/
def w1 : State := (run (State.init [1, 2]) [.read (mkRead .fresh [1, 2] []), .userEdit [1, 2] [2]]).1
example : rowLine w1 (mkRead .fresh [1, 2] []) 2 = .tick := by decide
example : statusLine w1 (mkRead .fresh [1, 2] []) = .matches := by decide
example : rowLine w1 { mkRead .fresh [1, 2] [] with kind := .poll } 2 = .waiting := by decide

/-! ## What makes a reading usable: a poll and an unsettled read are not witnesses (each fact has its own example) -/
example : ¬ ({ mkRead .fresh [1, 2] [] with kind := .poll } : Read).usable := by decide
example : ¬ ({ mkRead .fresh [1, 2] [] with settled := false } : Read).usable := by decide
example : (mkRead .fresh [1, 2] []).usable := by decide
example : verdict [1, 2] { mkRead .fresh [2, 1] [] with kind := .poll } = .cannotTell := by decide
example : verdict [1, 2] { mkRead .fresh [2, 1] [] with settled := false } = .cannotTell := by decide
example : verdict [1, 2] (mkRead .fresh [2, 1] []) = .differs := by decide
example : rowVerdict [1, 2] { mkRead .fresh [2, 1] [] with kind := .poll } 1 = .cannotTell := by decide
example : rowVerdict [1, 2] { mkRead .fresh [2, 1] [] with settled := false } 1 = .cannotTell := by decide


/-! ## ejb.10: the fallback's queue order, phases, tie-break and the whole-bar condition (semantic pins for their mutants) -/

-- phase TWO is taken in queue order: owed [1,2] moves 1, owed [2,1] moves 2 (a head-only or reversed scan changes the subject)
example : (run (State.init [1, 2, 3, 4]) [.userEdit [1, 2, 3, 4] [1], .userEdit [1, 2, 3, 4] [2], .read (mkRead .fresh [2, 1, 3, 4] [9])]).2
    = [⟨1, .before 2, false, true⟩] := by decide
example : (run (State.init [1, 2, 3, 4]) [.userEdit [1, 2, 3, 4] [2], .userEdit [1, 2, 3, 4] [1], .read (mkRead .fresh [2, 1, 3, 4] [9])]).2
    = [⟨2, .after 1, false, true⟩] := by decide
-- a queue head with no move does not hide the fallback of the next key
example : (run (State.init [1, 2, 3, 4]) [.userEdit [1, 2, 3, 4] [4], .userEdit [1, 2, 3, 4] [2], .read (mkRead .fresh [3, 2, 1, 4] [9])]).2
    = [⟨2, .after 1, false, true⟩] := by decide
-- the two PHASES: key 4 (first in the queue) has only a fallback move (4 after 1); key 1 has an anchor move, which goes first
example : (run (State.init [1, 2, 3, 4]) [.userEdit [1, 2, 3, 4] [4], .userEdit [1, 2, 3, 4] [1], .read (mkRead .fresh [2, 3, 4, 1] [9])]).2
    = [⟨1, .before 2, false, true⟩] := by decide
-- the tie-break: 2 after its record predecessor 1 (not before the first key, which leaves the same count)
example : (run (State.init [1, 2, 3, 4]) [.userEdit [1, 2, 3, 4] [2], .read (mkRead .fresh [3, 2, 1, 4] [9])]).2
    = [⟨2, .after 1, false, true⟩] := by decide
-- reviewer trace 1: record [1..5], read [3,2,4,5,1] with 4 and 5 untrusted, drop 2: the bar is not verified.  `2 after 1` (which makes the real bar worse when 4 or 5 sits between them) is NOT made; `2 before 3` is:
-- it crosses only 3 and, possibly, the untrusted 4 and 5, which belong after 2, so it lowers the inversions on every possible bar (ejb.11)
example : (run (State.init [1, 2, 3, 4, 5]) [.userEdit [1, 2, 3, 4, 5] [2], .read { mkRead .fresh [3, 2, 4, 5, 1] [9] with trusted := [3, 2, 1, 9] }]).2
    = [⟨2, .before 3, false, true⟩] := by decide
-- reviewer trace 2: record [1,2,3,4], read [3,2,4,1] with 2 untrusted, drop 3: no `noMoveHelps`, the row says it cannot judge
example : rowNote (step (State.init [1, 2, 3, 4]) (.userEdit [1, 2, 3, 4] [3])).1 { mkRead .fresh [3, 2, 4, 1] [9] with trusted := [3, 4, 1, 9] } 3
    = some .cantJudge := by decide


/-! ## ejb.11: unlisted record keys, and the fallback that holds on every possible bar -/

-- an 18-key record, the read lists 4 of them (drawn 3,2,4,1) and the pile hosts the 9: the other 14 record keys are listed nowhere (apps not running), the bar is still verified, and the drop of 2 gets its fallback move
-- (`wholeBar_unlisted` is the theorem; this is the witness, and it is what kills a `wholeBar` that counts an unlisted key as unverified)
def rec18 : List Key := (List.range 18).map (· + 1)
example : wholeBar (step (State.init rec18) (.userEdit rec18 [2])).1 (mkRead .fresh [3, 2, 4, 1] [9]) = true := by decide
example : (freeKeys (step (State.init rec18) (.userEdit rec18 [2])).1 (mkRead .fresh [3, 2, 4, 1] [9])).length = 0 := by decide
example : (run (State.init rec18) [.userEdit rec18 [2], .read (mkRead .fresh [3, 2, 4, 1] [9])]).2
    = [⟨2, .before 3, false, true⟩] := by decide
-- the same read with key 5 listed unread: the bar is no longer verified (5 is free), and the fallback still finds a drag that cannot make a possible bar worse
example : wholeBar (step (State.init rec18) (.userEdit rec18 [2])).1 { mkRead .fresh [3, 2, 4, 1] [9] with unread := [5] } = false := by decide
example : (freeKeys (step (State.init rec18) (.userEdit rec18 [2])).1 { mkRead .fresh [3, 2, 4, 1] [9] with unread := [5] }) = [5] := by decide
-- a free key AFTER the item in the record cannot cost a forward drag: key 4 is untrusted in [3,2,4,5,1] and belongs after 2, so `2 before 3` is safe on every possible bar
example : (run (State.init [1, 2, 3, 4, 5]) [.userEdit [1, 2, 3, 4, 5] [2], .read { mkRead .fresh [3, 2, 4, 5, 1] [9] with trusted := [3, 2, 1, 9] }]).2
    = [⟨2, .before 3, false, true⟩] := by decide
-- the penalty: a free key BEFORE the item in the record (key 1, untrusted, last) can sit between the item and the place a drag takes it, so a drag across the movable keys alone is not safe.  Record [1..5],
-- read [4,3,5,2,1] with 1 untrusted, drop 3: the corroborated keys alone show a drag (3 before 4: 4 inversions become 3) but on a bar with 1 between 4 and 3 it adds an inversion, so there is NO move and the row cannot judge
example : (run (State.init [1, 2, 3, 4, 5]) [.userEdit [1, 2, 3, 4, 5] [3], .read { mkRead .fresh [4, 3, 5, 2, 1] [9] with trusted := [4, 3, 5, 2, 9] }]).2 = [] := by decide
example : rowNote (step (State.init [1, 2, 3, 4, 5]) (.userEdit [1, 2, 3, 4, 5] [3])).1 { mkRead .fresh [4, 3, 5, 2, 1] [9] with trusted := [4, 3, 5, 2, 9] } 3
    = some .cantJudge := by decide
-- the worst case counts only the keys that can cost: the same read with the free key AFTER the item (record [1..5] with 5 untrusted, drop 3, read [4,3,1,2,5]) is answered
example : (run (State.init [1, 2, 3, 4, 5]) [.userEdit [1, 2, 3, 4, 5] [3], .read { mkRead .fresh [4, 3, 1, 2, 5] [9] with trusted := [4, 3, 1, 2, 9] }]).2 ≠ [] := by decide

end Sommelier
