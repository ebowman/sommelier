import Sommelier.Ffi
import Sommelier.Fuzz
import Sommelier.Examples
/-!
# Fixture generator for the Swift `DecisionCoreTests`

`lake exe fixture [traces] [seed]` prints, to stdout, the expected values of the PROVED functions (`step`, `statusLine`, `shownVerdict`,
`rowLine`, `rowVerdict`, `rowNote`), run by Lean itself, on (1) the named traces of `Sommelier/Examples.lean` and the review traces and (2) random
traces from the fuzz generator (`Sommelier/Fuzz.lean`).  Swift replays the same inputs through the linked C and must get the same values.
Nothing here is hand-copied: every expectation is computed by the Lean functions.  Inputs are the token encoding of `Sommelier/Ffi.lean` (round trips are theorems); every OUTPUT is printed by NAME (the `name…` functions
of `Ffi.lean`), never as a code, so the Swift tests do not depend on the Swift decoder they test.

Format (one record per line; ` ; ` separates groups; groups may be empty):
  CASE <name>
  INIT <record keys>
  EV <event tokens> ; <actions by name, " | " separated>                (the actions `step` returned for this event)
  PROBE <read tokens> ; <status name> ; <verdict name> ; <k rowName rowVerdictName noteName> ; ...     (against the state after the preceding events)
-/
open Sommelier Sommelier.Ffi

def toks (l : List Nat) : String := " ".intercalate (l.map toString)

def probeLine (s : State) (r : Read) (keys : List Key) : String :=
  let rows := keys.map fun k => s!"{k} {nameRow (rowLine s r k)} {nameRowVerdict (rowVerdict s.record (s.view r) k)} {nameNote (rowNote s r k)}"
  s!"PROBE {toks (encRead r)} ; {nameStatus (statusLine s r)} ; {nameVerdict (shownVerdict s r)} ; " ++ " ; ".intercalate rows

def lastRead : List Event → Option Read
  | [] => none
  | es => (es.reverse.filterMap fun | .read r => some r | _ => none).head?

/-- reads probed against every state: the last read seen, plus fixed variants over the record's keys (stale chevron, poll, incomplete) -/
def cannedReads (rec : List Key) (seen : Option Read) : List Read :=
  let n := rec.length
  let drawn := rec.take (n - 1)
  let pile := rec.drop (n - 1)
  let base : Read := mkRead .fresh drawn pile
  seen.toList ++ [base, { base with chevron := .stale }, { base with kind := .poll }, { base with level := .incomplete },
    { base with chevron := .absent, pile := [], drawn := rec }, { base with drawn := drawn.reverse }]

def probeKeys (rec : List Key) : List Key := rec.take 5 ++ [99]

def emitCase (name : String) (rec : List Key) (evs : List Event) (probeEvery : Nat) (out : IO.FS.Stream) : IO Unit := do
  out.putStrLn s!"CASE {name}"
  out.putStrLn s!"INIT {toks rec}"
  let mut s := State.init rec
  let mut seen : List Event := []
  let mut i := 0
  for e in evs do
    let (s', as) := step s e
    out.putStrLn s!"EV {toks (encEvent e)} ; {nameActions as}"
    s := s'; seen := seen ++ [e]; i := i + 1
    if i % probeEvery == 0 || i == evs.length then
      for r in cannedReads rec (lastRead seen) do out.putStrLn (probeLine s r (probeKeys rec))
  if evs.isEmpty then
    for r in cannedReads rec none do out.putStrLn (probeLine s r (probeKeys rec))

def r12 : List Key := [1, 2]
def r123 : List Key := [1, 2, 3]
def r12345 : List Key := [1, 2, 3, 4, 5]
def r1245 : List Key := [1, 2, 4, 5]
def r123456 : List Key := [1, 2, 3, 4, 5, 6]

/-- The named example traces (initial record, events).  Same inputs as the `example`s of Examples.lean, whose expected values are checked there by `decide`. -/
def namedCases : List (String × List Key × List Event) :=
  [ ("tm", r12345, tm), ("tmMismatch", r12345, tmMismatch), ("launch", [3, 1, 2, 4, 5], launch), ("launchGood", r12345, launchGood),
    ("budget", [1, 2, 3, 4, 5, 6, 7, 8], budget), ("resume", r1245, resume), ("resumeUnserved", r1245, resumeUnserved),
    ("refusedLoop", r123, refusedLoop), ("kReads", r123, kReads), ("bad1", r12, bad1), ("proven", r12, proven),
    ("provenBudget20", r12, proven ++ (List.replicate 30 [mism, ok 1]).flatten),
    ("spentRetry", r123456, spent ++ [.userRetry]), ("spentEdit", r123456, spent ++ [.userEdit [2, 1, 3, 4, 5, 6] [2]]),
    ("reverted", r12345, reverted), ("revertedProven", r12, revertedProven), ("revertedRetryKey", r12345, reverted ++ [.retryKey 1, .read (mkRead .fresh [3, 2, 1, 4] [5])]),
    ("pulled", r1245, pulled), ("pulledBusy", r1245, pulled ++ [.moveResult 5 .busy false]),
    ("failedPlusRetryKey", [1, 2, 3, 4], failedPlus ++ [.retryKey 1]), ("strikeOne", r12, strikeOne),
    ("t4", [1, 2, 5, 6], t4), ("t5", [1, 2, 5, 6, 9], t5), ("t6", [7, 5], t6),
    ("W2", r123, w2Trace), ("W", r12, [.userEdit [2, 1] [2], .read (mkRead .fresh [1, 2] [])]),
    ("W-stale", r12, [.userEdit [2, 1] [2], .read (mkRead .stale [1, 2] [])]),
    ("e3", [3, 1, 2], [.read (mkRead .fresh [1, 2] [3]), .userEdit [3, 1, 2] [3], .read (mkRead .fresh [1, 2] [3])]),
    ("eA-waiting", r123, [.read (mkRead .fresh [1, 2, 3] []), .userEdit [1, 3, 2] [3], .read { mkRead .fresh [1, 2] [3] with stripOpen := true }]),
    -- (b) mutual inversion and (c) no gap (ejb.10): both get a move now
    ("drop-b-mutual", r123, [.userEdit r123 [1, 2], .read (mkRead .fresh [2, 1, 3] [9])]),
    ("drop-c-nogap", [1, 2, 4, 3], [.userEdit [1, 2, 4, 3] [1], .read (mkRead .fresh [2, 3, 4, 1] [9])]),
    ("drop-multi", [1, 2, 3, 4], [.userEdit [1, 2, 3, 4] [4], .userEdit [1, 2, 3, 4] [1], .read (mkRead .fresh [2, 3, 4, 1] [9])]),
    ("untrusted-fallback", r12345, [.userEdit r12345 [2], .read { mkRead .fresh [3, 2, 4, 5, 1] [9] with trusted := [3, 2, 1, 9] }]),
    ("rec18-unlisted", rec18, [.userEdit rec18 [2], .read (mkRead .fresh [3, 2, 4, 1] [9])]),
    ("stale-chevron-pile-memory", [1, 3, 2], [.read (mkRead .fresh [1, 3] [2]), .userEdit [1, 3, 2] [3], .read (mkRead .stale [1, 2, 3] []),
                                              .passBoundary, .read (mkRead .stale [1, 2, 3] [])]),
    ("incomplete-read", r12, [.read { mkRead .fresh [2, 1] [] with level := .incomplete }, .read (mkRead .fresh [2, 1] [])]),
    ("incomplete-poll", r12, [.read { mkRead .absent [2, 1] [] with level := .incomplete, kind := .poll }]),
    ("poll-read", r12, [.read (poll true), .read (poll false)]),
    ("unread-keys", r123, [.read { mkRead .fresh [1, 2] [] with unread := [3] }, .userEdit [3, 1, 2] [3], .read { mkRead .fresh [1, 2] [] with unread := [3] }]),
    -- row notes (ejb.14): noMoveHelps (verified bar, no single drag of 2 helps), cantJudge (review-10b T1, T2), none (a moving row, in-order rows)
    ("note-noMoveHelps", r123, [.userEdit r123 [2], .read (mkRead .fresh [3, 1, 2] [9])]),
    ("note-cantJudge-T2", [1, 2, 3, 4], [.userEdit [1, 2, 3, 4] [3], .read { mkRead .fresh [3, 2, 4, 1] [9] with trusted := [3, 4, 1, 9] }]),
    ("note-cantJudge-T1", r12345, [.userEdit r12345 [3], .read { mkRead .fresh [4, 3, 5, 2, 1] [9] with trusted := [4, 3, 5, 2, 9] }]),
    ("note-none-moving", r123, [.userEdit r123 [1], .read (mkRead .fresh [2, 3, 1] [9])]),
    ("notFullProven-flag", r12, [.read { mkRead .absent [2, 1] [] with notFullProven := true }])
  ]

def main (args : List String) : IO UInt32 := do
  let traces := (args.getD 0 "2000").toNat!
  let seed0 := (args.getD 1 "20260509").toNat!
  let out ← IO.getStdout
  for (name, rec, evs) in namedCases do
    emitCase name rec evs (if evs.length ≤ 12 then 1 else 1000) out
  let mut seed := seed0
  for i in [0:traces] do
    let (t, seed') := (Sommelier.Fuzz.genTrace 30 true).run seed
    seed := seed'
    emitCase s!"fuzz{i}" t.record t.evs 10 out
  return 0
