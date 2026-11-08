import Sommelier.Step

/-!
# Fuzz harness

Seeded random event traces against computable versions of the invariants the later beads will prove.
`lake exe fuzz [mixedTraces] [noUserTraces] [seed]` (defaults 20000, 5000, 1).  Exit code 1 if any invariant fails.
Use it to catch a FALSE theorem before spending a proof on it.
-/

namespace Sommelier.Fuzz

/-! ### Generators (an LCG threaded through `StateM`) -/

abbrev G := StateM Nat

def next : G Nat :=
  modifyGet fun x => let y := (x * 6364136223846793005 + 1442695040888963407) % 18446744073709551616; (y / 65536, y)
def rnd (n : Nat) : G Nat := do let v ← next; pure (v % n)
def coin (pct : Nat) : G Bool := do pure ((← rnd 100) < pct)
def subset (l : List Key) (pct : Nat) : G (List Key) := l.filterM (fun _ => coin pct)
def insertAt (x : Key) (l : List Key) (i : Nat) : List Key := l.take i ++ x :: l.drop i
def shuffle (l : List Key) : G (List Key) := l.foldlM (fun acc x => do pure (insertAt x acc (← rnd (acc.length + 1)))) []

def allKeys : List Key := [1, 2, 3, 4, 5, 6, 7]

def genRead : G Read := do
  let c ← rnd 10
  let l ← rnd 20
  let settled ← coin 80
  let so ← coin 10
  let pass ← coin 70
  let all ← shuffle allKeys
  let nd ← rnd 8
  let drawn := all.take nd
  let rest := all.drop nd
  let pile ← subset rest 40
  let folded ← subset (rest.filter (fun k => !pile.contains k)) 30
  let trusted ← subset all 85
  let near ← subset all 15
  pure { kind := if pass then .pass else .poll,
         chevron := if c < 4 then .fresh else if c < 8 then .absent else .stale,
         level := if l < 12 then .complete else if l < 15 then .exceptSelfPositioning else .incomplete,
         settled := settled, stripOpen := so, drawn := drawn, pile := pile, folded := folded,
         trusted := trusted, nearFold := near }

def genEvent (s : State) : G Event := do
  let p ← rnd 100
  let ans ← coin 60
  match s.inFlight with
  | some a =>
      if ans then
        let o ← rnd 4
        let posted ← coin 75
        return .moveResult a.subject (match o with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) posted
  | none => pure ()
  if p < 52 then return .read (← genRead)
  else if p < 62 then
    let o ← rnd 4
    let posted ← coin 75
    return .moveResult (1 + (← rnd 7)) (match o with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) posted
  else if p < 72 then
    let rec_ ← shuffle (← subset allKeys 85)
    let moved ← subset rec_ 30
    return .userEdit rec_ moved
  else if p < 76 then return .userRetry
  else if p < 80 then return .retryKey (1 + (← rnd 7))
  else return .passBoundary

def isUserEvent : Event → Bool
  | .userEdit _ m => !m.isEmpty
  | .userRetry | .retryKey _ => true
  | _ => false
def noEdit : Event → Bool | .userEdit _ _ => false | _ => true

/-- a trace: its initial record, events and the state before each event -/
structure Trace where
  record : List Key
  evs : List Event
  states : List State

def genTrace (n : Nat) (users : Bool) : G Trace := do
  let rec_ ← shuffle (← subset allKeys 90)
  let mut s := State.init rec_
  let mut evs : List Event := []
  let mut sts : List State := []
  for _ in List.range n do
    let mut e ← genEvent s
    if !users && isUserEvent e then e := .passBoundary
    sts := sts ++ [s]
    evs := evs ++ [e]
    s := (step s e).1
  pure ⟨rec_, evs, sts⟩

/-! ### Invariants (computable forms of the ejb.2 / ejb.3 statements) -/

def postedEngine (s : State) : List Event → Nat
  | [] => 0
  | e :: es =>
    let n := match e, s.inFlight with
      | .moveResult k _ true, some a => if a.subject == k && !a.user then 1 else 0
      | _, _ => 0
    n + postedEngine (step s e).1 es

def fullThroughout (s : State) : List Event → Bool
  | [] => true
  | e :: es => (match e with | .read r => fullBar s r | _ => true) && fullThroughout (step s e).1 es

/-- Per-step invariants: (name, holds). Only instances whose premise holds are listed. -/
def stepChecks (s : State) (e : Event) : List (String × Bool) :=
  let (s', acts) := step s e
  let base :=
    [ ("oneActionPerStep", decide (acts.length ≤ 1)) ]
    ++ (if s.inFlight.isSome then [("noActionWhileInFlight", acts.isEmpty)] else [])
    ++ (if s.hold && !s'.hold then
          [("holdRelease", isUserEvent e || (s'.provenNotFull && !s.provenNotFull))] else [])
    ++ (if !s.hold && s'.hold then
          [("holdSetOnlyByFailedPostedDrag",
            (match e with | .moveResult _ .failed true => !s.provenNotFull && s.inFlight.isSome | _ => false))] else [])
    ++ (if !s.restricted && s.owedKeys.isEmpty && s.foldRequest.isNone && !isUserEvent e && noEdit e then
          [("owedStaysExpired", s'.owedKeys.isEmpty && s'.foldRequest.isNone)] else [])
    ++ (match e with
        | .passBoundary =>
            [("owedExpires", s'.owedKeys.isEmpty && s'.foldRequest.isNone && !s'.stripGrant)]
        | .userRetry => [("userRetryClears", !s'.hold && s'.givenUp.isEmpty && s'.moveCount == 0)]
        | .read r =>
            [ ("chevronRevokes", r.chevron == .absent || !s'.provenNotFull) ]
            ++ acts.flatMap (fun a =>
                [ ("noFoldedTarget",
                    !r.pile.contains a.rel.target && !r.folded.contains a.rel.target
                    && !s.lastFreshPile.contains a.rel.target && !s'.lastFreshPile.contains a.rel.target) ]
                ++ (if !a.user then
                    [("noFoldedEngineSubject",
                      !r.pile.contains a.subject && !r.folded.contains a.subject && !s.lastFreshPile.contains a.subject)] else []))
        | _ => [])
  base

/-- Quiescence (true form): after the budget is spent or a hold is set on a bar not proven not-full, with no edit or user
event, only the user's own moves can leave while every read sees a full bar with a chevron. -/
def quiescenceCheck (s : State) (evs : List Event) : List (String × Bool) :=
  let es := evs.takeWhile (fun e => noEdit e && !isUserEvent e)
  if !s.provenNotFull && (s.hold || s.moveCount ≥ capFull) && fullThroughout s es
     && es.all (fun e => match e with | .read r => r.chevron != .absent | _ => true) then
    [("quiescence_true", (run s es).2.all (fun a => a.user))]
  else []

/-- userAlwaysAnswered on a state with nothing owed and nothing in flight. -/
def answeredCheck (s : State) (r : Read) (rec_ : List Key) (k : Key) : List (String × Bool) :=
  if s.inFlight.isNone && s.owedKeys.isEmpty && s.foldRequest.isNone && r.kind == .pass && r.settled
     && r.level != .incomplete && rec_.contains k && (movable s r).contains k then
    let s1 := (step s (.userEdit rec_ [k])).1
    match userMove s1 r k with
    | some a =>
        if a.strip && r.stripOpen then []
        else [("userAlwaysAnswered", (step s1 (.read r)).2 == [a] && a.subject == k && a.user)]
    | none => []
  else []


def extraStep (s : State) (e : Event) : List (String × Bool) :=
  let (s', acts) := step s e
  [ ("proven_pile_empty", !s'.provenNotFull || s'.lastFreshPile.isEmpty),
    ("proven_no_hold", !s'.provenNotFull || !s'.hold),
    ("req_in_owed", s'.foldRequest.all (fun k => s'.owedKeys.contains k)),
    ("owed_in_record", s'.owedKeys.all (fun k => s'.record.contains k)),
    ("owed_nodup", s'.owedKeys.eraseDups == s'.owedKeys),
    ("owed_implies_restricted", s'.owedKeys.isEmpty || s'.restricted),
    ("replacing_clears", let r : Read := { kind := .poll, chevron := .fresh, level := .complete, settled := true, stripOpen := false, drawn := [1,2], pile := [9], folded := [], trusted := [1,2], nearFold := [] }
        (noteRead s r).lastFreshPile == [9]),
    ("three_absent_clears", let r : Read := { kind := .poll, chevron := .absent, level := .complete, settled := false, stripOpen := false, drawn := [1,2], pile := [], folded := [], trusted := [1,2], nearFold := [] }
        ((noteRead (noteRead (noteRead s r) r) r).lastFreshPile.isEmpty && (noteRead (noteRead (noteRead s r) r) r).provenNotFull)) ]
  ++ (match e with
     | .read r => acts.flatMap (fun a =>
        let t := a.rel.target
        [ ("target_drawn", r.drawn.contains t), ("target_movable", (movable s r).contains t), ("target_not_subject", t != a.subject),
          ("target_in_record", s.record.contains t), ("subject_in_record", s.record.contains a.subject),
          ("no_inflight_after", s'.inFlight == some a),
          (if a.user then "noop_user" else "noop_engine", applyMove r.drawn a != r.drawn),
          ("plan_gate", r.kind == .pass && r.settled && r.level != .incomplete) ]
        ++ (if !a.user then [("engine_gate", r.chevron != .stale && !r.stripOpen && !s.restricted && (movable s r).contains a.subject && s.record.contains t)] else [])
        ++ (if a.user && s.owedKeys.contains a.subject && r.drawn.contains a.subject && !(foldedAll s r).contains a.subject then
              [("user_target_anchor", !s.owedKeys.contains t)] else [])
        ++ (if s.restricted then [("restricted_only_owed", s.owedKeys.contains a.subject)] else [])
        ++ (if a.strip then [("strip_session_fresh", !s.editSessionUsed && !r.stripOpen)] else [])
        ++ (if !s.owedKeys.contains a.subject then [("nonowed_notgiven", !s.givenUp.contains a.subject && !s.skipped.contains a.subject), ("nonowed_notrestricted", !s.restricted)] else [])
        ++ (if a.user && !s.owedKeys.contains a.subject then [("grant_needed", s.stripGrant && a.strip && !s'.stripGrant)] else [])
        ++ (if !a.user then [("budget_state", decide (s.moveCount < cap (fullBar s r)) && !s.hold && !a.strip)] else [])
        ++ (if !r.drawn.contains a.subject then [("pullout_was_request", s.foldRequest == some a.subject)] else []))
     | .moveResult k .failed true =>
        (match s.inFlight with
         | some a => if a.subject == k && !s.provenNotFull then [("failed_holds", s'.hold && s'.givenUp.contains k)] else []
         | none => [])
     | _ => [])
def proofTrace (s0 : State) (evs : List Event) : List (String × Bool) := Id.run do
  let mut s := s0
  let mut run_ := 0
  let mut out := []
  for e in evs do
    let (s', _) := step s e
    match e with
    | .read r =>
      if r.chevron != .absent || r.level == .incomplete then run_ := 0 else run_ := run_ + 1
      if s'.provenNotFull && !s.provenNotFull then out := out ++ [("proof_three_consecutive", decide (run_ >= 3))]
      if !s.provenNotFull && !s'.provenNotFull then out := out ++ [("proof_not_early_late", decide (run_ < 3))]
    | _ => pure ()
    s := s'
  return out
/-- at most one strip action leaves between two user events (posted result; unposted ones return it) -/
def stripPerEdit (s0 : State) (evs : List Event) : List (String × Bool) := Id.run do
  let mut s := s0
  let mut n := 0
  let mut out := []
  for e in evs do
    if isUserEvent e then n := 0
    let (s', acts) := step s e
    match e, s.inFlight with
    | .moveResult k _ false, some a => if a.subject == k && a.strip then n := n - 1
    | _, _ => pure ()
    for a in acts do
      if a.strip then
        n := n + 1
        out := out ++ [("strip_per_event", decide (n ≤ 1))]
    s := s'
  return out
def maxBudget (s0 : State) (evs : List Event) : Nat := postedEngine s0 evs
/-- A real-world-biased no-user trace: long, mostly clean reads with a persistent mismatch: pushes the budget -/
def goodRead (fresh : Bool) (rec_ : List Key) : G Read := do
  let dr ← shuffle rec_
  pure { kind := .pass, chevron := if fresh then .fresh else .absent, level := .complete, settled := true, stripOpen := false, drawn := dr, pile := [], folded := [], trusted := dr, nearFold := [] }
def budgetTrace (fresh : Bool) (prove : Bool) (n : Nat) : G (Nat × Nat) := do
  let rec_ := allKeys
  let mut s := State.init rec_
  let mut evs : List Event := []
  if prove then
    for _ in List.range 3 do
      let r ← goodRead false rec_
      s := (step s (.read { r with kind := .poll })).1
  let s0 := s
  for _ in List.range n do
    let r ← goodRead fresh rec_
    let e := Event.read r
    let (s1, acts) := step s e
    evs := evs ++ [e]; s := s1
    for a in acts do
      let e2 := Event.moveResult a.subject .verified true
      evs := evs ++ [e2]; s := (step s e2).1
  pure (postedEngine s0 evs, s.moveCount)

/-- Budget and strip invariants over a trace from the initial state with no user event. -/
def pureChecks (t : Trace) : List (String × Bool) :=
  let s0 := State.init t.record
  let n := postedEngine s0 t.evs
  let acts := (run s0 t.evs).2
  [ ("budget_any", decide (n ≤ capNotFull)), ("stripNone", acts.all (fun a => !a.strip)) ]
  ++ (if fullThroughout s0 t.evs then [("budget_full", decide (n ≤ capFull))] else [])

/-! ### Tally -/

structure Tally where
  name : String
  n : Nat
  bad : Nat
  cex : Option String

def record (ts : List Tally) (name : String) (ok : Bool) (cex : Unit → String) : List Tally :=
  match ts.find? (fun t => t.name == name) with
  | none => ts ++ [⟨name, 1, if ok then 0 else 1, if ok then none else some (cex ())⟩]
  | some _ => ts.map fun t =>
      if t.name == name then
        { t with n := t.n + 1, bad := t.bad + (if ok then 0 else 1),
                 cex := match t.cex with | some c => some c | none => if ok then none else some (cex ()) }
      else t

def addAll (ts : List Tally) (rs : List (String × Bool)) (cex : Unit → String) : List Tally :=
  rs.foldl (fun acc (nm, ok) => record acc nm ok cex) ts

def fuzz (mixed pure_ seed : Nat) : List Tally × Nat × Nat :=
  let go : G (List Tally × Nat) := do
    let mut ts : List Tally := []
    let mut steps := 0
    for _ in List.range mixed do
      let t ← genTrace 30 true
      let desc := fun (_ : Unit) => toString (repr (t.record, t.evs))
      let pairs := t.states.zip t.evs
      for (s, e) in pairs do
        ts := addAll ts (stepChecks s e) desc
        ts := addAll ts (extraStep s e) desc
        steps := steps + 1
      for i in List.range t.evs.length do
        ts := addAll ts (quiescenceCheck (t.states.getD i (State.init [])) (t.evs.drop i)) desc
      ts := addAll ts (stripPerEdit (State.init t.record) t.evs) desc
      ts := addAll ts (proofTrace (State.init t.record) t.evs) desc
      -- userAlwaysAnswered at a random earlier state
      for _ in List.range 6 do
        let i ← rnd t.states.length
        let s0 := t.states.getD i (State.init [])
        let s := { s0 with inFlight := none, owedKeys := [], foldRequest := none }
        let r0 ← genRead
        let rec_ ← shuffle (← subset allKeys 85)
        let k := 1 + (← rnd 7)
        -- a plannable read that shows k drawn and trusted
        let r := { r0 with kind := .pass, settled := true, level := .complete,
                           drawn := k :: r0.drawn.filter (· != k), trusted := k :: r0.trusted }
        ts := addAll ts (answeredCheck s r rec_ k) desc
    for _ in List.range pure_ do
      let t ← genTrace 30 false
      ts := addAll ts (pureChecks t) (fun _ => toString (repr (t.record, t.evs)))
      steps := steps + t.evs.length
    pure (ts, steps)
  let ((ts, steps), _) := go.run seed
  (ts, steps, mixed + pure_)

end Sommelier.Fuzz

open Sommelier.Fuzz in
def main (args : List String) : IO UInt32 := do
  let mixed := (args.getD 0 "20000").toNat!
  let pure_ := (args.getD 1 "5000").toNat!
  let seed := (args.getD 2 "1").toNat!
  let (ts, steps, traces) := fuzz mixed pure_ seed
  IO.println s!"traces: {traces} (mixed {mixed}, no-user {pure_}), events: {steps}, seed {seed}"
  let (b1, _) := (budgetTrace true false 60).run seed
  let (b2, _) := (budgetTrace false true 60).run seed
  IO.println s!"budget saturation: full bar, 60 reads: posted={b1.1} (cap {Sommelier.capFull}); proven not full, 60 reads: posted={b2.1} (cap {Sommelier.capNotFull})"
  let mut bad := if b1.1 == Sommelier.capFull && b2.1 == Sommelier.capNotFull then 0 else 1
  if bad == 1 then IO.println "  budget saturation FAILED: the caps are not reached (or exceeded)"
  for t in ts do
    IO.println s!"  {t.name}: {t.n} instances, {t.bad} failures"
    bad := bad + t.bad
    if let some c := t.cex then IO.println s!"    first counterexample: {c}"
  return if bad == 0 then 0 else 1
