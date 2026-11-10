import Sommelier.Step
import Sommelier.Status

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
            (match e with
              | .moveResult _ .failed true => !s.provenNotFull && s.inFlight.isSome
              | _ => false))] else [])
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
                    && ((decide r.usable && r.chevron == .fresh) || !s.lastFreshPile.contains a.rel.target)
                    && !s'.lastFreshPile.contains a.rel.target) ]
                ++ (if !a.user then
                    [("noFoldedEngineSubject",
                      !r.pile.contains a.subject && !r.folded.contains a.subject
                      && ((decide r.usable && r.chevron == .fresh) || !s.lastFreshPile.contains a.subject))] else []))
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

/-- The anchors, wanted set and seen set of a dropped key, restated here (not imported from `Gates.lean`, so that a broken proof there cannot stop the fuzz
harness from building): the movable keys of the record that are not `k` and not owed; those that precede `k` in the record; those that precede it on the bar. -/
def fzAnchors (s : State) (r : Read) (k : Key) : List Key :=
  (movable s r).filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a)
def fzWant (s : State) (r : Read) (k : Key) : List Key :=
  (s.record.takeWhile (fun x => x != k)).filter (fun a => (fzAnchors s r k).contains a)
def fzSeen (s : State) (r : Read) (k : Key) : List Key :=
  ((movable s r).filter (fun a => a == k || (fzAnchors s r k).contains a)).takeWhile (fun x => x != k)

/-- userAlwaysAnswered (drawn and folded cases) from any state with nothing in flight and `k` first in the queue, on a read where the gate is true;
and the converse: an owed key that gets no move has a named reason. -/
def answeredCheck (s : State) (r : Read) (rec_ : List Key) (k : Key) : List (String × Bool) :=
  let s1 := (step s (.userEdit rec_ [k])).1
  if s.inFlight.isNone && rec_.contains k && s1.gate r && ((s1.foldRequest.toList ++ s1.owedKeys).head? == some k) then
    let acts := (step s1 (.read r)).2
    let same := (fzSeen s1 r k).all (fun a => (fzWant s1 r k).contains a) && (fzWant s1 r k).all (fun a => (fzSeen s1 r k).contains a)
    (if r.drawn.contains k && r.trusted.contains k && !(foldedAll s1 r).contains k && !same
        && (prefixFor (fzWant s1 r k) (fzAnchors s1 r k)).isSome then
      [("userAlwaysAnswered", acts.length == 1 && acts.all (fun a => a.subject == k && a.user))] else [])
    ++ (if r.chevron == .fresh && r.foldedSet.contains k && !r.drawn.contains k
        && (movable s1 r).any (fun x => (s1.record.takeWhile (· != k)).contains x) then
      [("userAlwaysAnswered_pull", acts.length == 1 && acts.all (fun a => a.subject == k && a.user && a.strip))] else [])
  else []

/-- The converse of `userAlwaysAnswered`: on a gate-true read with nothing in flight, an owed key `k` with no move emitted for it has a named reason. -/
def owedReasonCheck (s : State) (r : Read) : List (String × Bool) :=
  if s.inFlight.isNone && s.gate r then
    let acts := (step s (.read r)).2
    s.owedKeys.flatMap fun k =>
      if acts.any (fun a => a.subject == k) then [] else
      let same := (fzSeen s r k).all (fun a => (fzWant s r k).contains a) && (fzWant s r k).all (fun a => (fzSeen s r k).contains a)
      let lic := r.chevron == .fresh && r.foldedSet.contains k
      let pred := ((movable s r).filter (fun x => (s.record.takeWhile (fun y => y != k)).contains x)).getLast?
      let mv := (movable s r).contains k
      let fa := (foldedAll s r).contains k
      [("owed_unanswered_reason",
        (mv && !misplaced s r k)
        || (mv && misplaced s r k && (!s.record.contains k || ((fallbackCands s r k).all fun rel => decide (invCount s r r.drawn ≤ worstCount s r k rel))))
        || (!fa && !(r.drawn.contains k && r.trusted.contains k))
        || (fa && !lic)
        || (fa && lic && pred.isNone)
        || (fa && lic && (match pred with | some p => applyMove r.drawn ⟨k, .after p, needsStrip s r k (.after p), true⟩ == r.drawn | none => false))
        || (match userMove s r k with | some a => a.strip && s.editSessionUsed | none => false)
        || (acts.any (fun a => a.user && (s.foldRequest.toList ++ s.owedKeys).contains a.subject && a.subject != k))) ]
  else []

/-- Inversions of the bar `d` against the record, counted pair by pair (independent of `invCount`; every key of `d` is movable in the enumerations below). -/
def invInd (rec d : List Key) : Nat :=
  (d.zipIdx.map fun (x, i) => (d.zipIdx.filter fun (y, j) => i < j && decide (rec.idxOf y < rec.idxOf x)).length).foldl (· + ·) 0

/-- Some single drag of `k` (to any place in the bar) leaves STRICTLY fewer inversions (independent of the fallback's candidates). -/
def canReduce (rec d : List Key) (k : Key) : Bool :=
  let rest := d.filter (· != k)
  (List.range (rest.length + 1)).any fun i => decide (invInd rec (insertAt k rest i) < invInd rec d)

def dropRd (d : List Key) : Read :=
  { kind := .pass, chevron := .fresh, level := .complete, settled := true, stripOpen := false, drawn := d, pile := [9], folded := [],
    trusted := d ++ [9], nearFold := [] }

def permsK : List Key → List (List Key)
  | [] => [[]]
  | x :: xs => (permsK xs).flatMap fun p => (List.range (p.length + 1)).map fun i => insertAt x p i

def subsetsK : List Key → List (List Key)
  | [] => [[]]
  | x :: xs => let r := subsetsK xs; r ++ r.map (x :: ·)

/-- Drain the owed queue on the bar `d` (record = [1,2,3,4] up to relabelling, which covers every 4-key bar): each read, then the result of the drag it asked for; `busy` mode answers the
first drag of every key with an interrupted (not posted) result, then verifies.  Returns the moves and the final state and bar. -/
def drainSim (s0 : State) (d0 : List Key) (busy : Bool) : List Action × State × List Key := Id.run do
  let mut s := s0
  let mut d := d0
  let mut moves : List Action := []
  for _ in List.range 14 do
    let (s1, acts) := step s (.read (dropRd d))
    s := s1
    match acts with
    | [a] =>
      moves := moves ++ [a]
      let interrupted := busy && !(moves.filter (fun m => m.subject == a.subject)).length > 1 && (moves.filter (fun m => m.subject == a.subject)).length == 1
      if interrupted then s := (step s (.moveResult a.subject .busy false)).1
      else
        s := (step s (.moveResult a.subject .verified true)).1
        d := applyMove d a
    | _ => pure ()
  return (moves, s, d)

/-- Every 4-key bar, every dropped subset (including (b)- and (c)-shaped ones): the first read moves something whenever an owed key can be fixed by one drag and is not right;
the drain is within `|owed|` moves (`2 |owed|` with interrupted drags), moves only owed keys, ends with no move of any owed key, and every owed key left with a
"not where you put it" row carries the note; with every key dropped the bar ends in the record's order. -/
def dropEnumChecks : List (String × Bool × String) := Id.run do
  let U : List Key := [1, 2, 3, 4]
  let mut out : List (String × Bool × String) := []
  for d in permsK U do
    for o in subsetsK U do
      if o.isEmpty then continue
      let s0 := (step (State.init U) (.userEdit U o)).1
      let desc := s!"drawn {d} owed {o}"
      let (s1, acts) := step s0 (.read (dropRd d))
      let fixable := o.any fun k => canReduce U d k
      out := out ++ [("drop_answered_if_reducible", !fixable || !acts.isEmpty, desc)]
      for busy in [false, true] do
        let (moves, sf, df) := drainSim s0 d busy
        let n := o.length
        let desc2 := desc ++ s!" busy {busy}"
        out := out ++ [("drain_bound", decide (moves.length ≤ (if busy then 2 * n else n)), desc2),
                       ("drain_subjects_owed", moves.all (fun m => m.user && o.contains m.subject), desc2)]
        let r := dropRd df
        let ended := (step sf (.read r)).2.isEmpty
        out := out ++ [("drain_ends", ended, desc2)]
        if !busy then
          out := out ++ [("drain_notes", sf.owedKeys.all (fun k => rowLine sf r k != .notWherePut || rowNote sf r k == some .noMoveHelps), desc2),
                         ("drain_final_known", true, desc2)]
  return out

/-- "Try again" on a row that says "not where you put it" either lets a user's move leave or leaves the note on the row (`try_again_answers`). -/
def tryAgainCheck (s : State) (r : Read) : List (String × Bool) :=
  if s.inFlight.isNone && s.gate r then
    s.record.flatMap fun k =>
      if rowLine s r k == .notWherePut then
        let s' := (step s (.retryKey k)).1
        let acts := (step s' (.read r)).2
        [("try_again_answers", acts.any (fun a => a.user) || ((rowNote s' r k).isSome && (userMove s' r k).isNone)),
         ("try_again_seen", true)]
      else []
  else []

/-- The note is shown only where it is true (`rowNote_true`). -/
def noteCheck (s : State) (r : Read) : List (String × Bool) :=
  s.record.flatMap fun k =>
    match rowNote s r k with
    | some .noMoveHelps =>
        [("note_true", rowLine s r k == .notWherePut && owedNow s k && s.gate r && (userMove s r k).isNone && !movingKey s r k
            && (movable s r).contains k && s.owedKeys.contains k && misplaced s r k && wholeBar s r && (userPick s r).isNone
            && ((movable s r).filter (fun t => t != k && s.record.contains t)).all (fun t =>
                 [Rel.before t, Rel.after t].all fun rel => decide (invCount s r r.drawn ≤ afterCount s r k rel))),
         ("note_seen", true)]
    | some .cantJudge =>
        [("note_cant_true", rowLine s r k == .notWherePut && (movable s r).contains k && s.owedKeys.contains k && misplaced s r k && !wholeBar s r && (fallbackMove s r k).isNone && (decideMove s r).isNone),
         ("note_cant_seen", true)]
    | some .noMoveHere => [("note_here_true", rowLine s r k == .notWherePut && owedNow s k && (userMove s r k).isNone), ("note_here_seen", true)]
    | none => [("note_absent_ok", !(rowLine s r k == .notWherePut && owedNow s k))]

/-- Single-drop table over every drawn permutation of `n` keys (record = 1..n, all trusted, a fresh chevron with key 9 behind it): for each dropped key, the first
good read's action, classified by who made it (the anchor rule, i.e. the old behaviour, or the fallback) and by what it did to the inversions.  Returns
(fires, (worse, unchanged)) for the fallback and for the anchor rule, and the number of drops with no move. -/
def singleDropTable (n : Nat) : (Nat × Nat × Nat) × (Nat × Nat × Nat) × Nat := Id.run do
  let U := (List.range n).map (· + 1)
  let mut fb := (0, 0, 0)
  let mut an := (0, 0, 0)
  let mut none_ := 0
  for d in permsK U do
    for k in U do
      let s0 := (step (State.init U) (.userEdit U [k])).1
      let r := dropRd d
      match (step s0 (.read r)).2 with
      | [a] =>
        let after := invInd U (applyMove d a)
        let before := invInd U d
        let isAnchor := anchorMove s0 r k == some a
        let bump := fun (c : Nat × Nat × Nat) => (c.1 + 1, c.2.1 + (if after > before then 1 else 0), c.2.2 + (if after == before then 1 else 0))
        if isAnchor then an := bump an else fb := bump fb
      | _ => none_ := none_ + 1
  return (fb, an, none_)

/-- ejb.20.  Every drawn permutation of `n` keys, every one key near the fold, on a fresh chevron with key 9 behind it, nothing owed, no grant: the status "needs Re-apply" appears
exactly when the engine's first planned move needs the strip.  Returns (cases, shown, violations): a violation is a case where the status disagrees with an independent reading
(the planner's move, `needsStrip`), where nothing is withheld yet no move leaves, or where Re-apply does not release the move (a granted user move of the same subject). -/
def reapplyTable (n : Nat) : Nat × Nat × Nat := Id.run do
  let U := (List.range n).map (· + 1)
  let mut cases := 0
  let mut shown := 0
  let mut bad := 0
  for d in permsK U do
    for nf in U do
      let r : Read := { dropRd d with nearFold := [nf] }
      let s := State.init U
      cases := cases + 1
      let plan := planOrderMoves s r
      let acts := (step s (.read r)).2
      let st := statusLine s r
      match plan with
      | some a =>
        if a.strip then
          shown := shown + 1
          let rel := (step (step s .userRetry).1 (.read r)).2
          if !(st == .differs (.needsReapply a.subject) && acts.isEmpty && rel == [{ a with user := true }]) then bad := bad + 1
        else if !(acts == [a] && st == .moving) then bad := bad + 1
      | none => if !(acts.isEmpty && st != .differs (.needsReapply 0)) then bad := bad + 1
  return (cases, shown, bad)

/-- Multi-drop: every drawn permutation of `n` keys and every nonempty dropped subset, drained with verified drags: the number of cases that END with MORE inversions than they began with. -/
def multiDropWorse (n : Nat) : Nat × Nat := Id.run do
  let U := (List.range n).map (· + 1)
  let mut worse := 0
  let mut total := 0
  for d in permsK U do
    for o in subsetsK U do
      if o.isEmpty then continue
      let s0 := (step (State.init U) (.userEdit U o)).1
      let (_, _, df) := drainSim s0 d false
      total := total + 1
      if invInd U df > invInd U d then worse := worse + 1
  return (worse, total)

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
              (if anchorMove s r a.subject == some a then [("user_target_anchor", !s.owedKeys.contains t)]
               else [("fallback_only_when_anchor_none", anchorMove s r a.subject == none), ("fallback_owed_misplaced", misplaced s r a.subject && s.owedKeys.contains a.subject), ("fallback_reduces", decide (invCount s r (applyMove r.drawn a) < invCount s r r.drawn))])
            else [])
        ++ (if s.restricted then [("restricted_only_owed", s.owedKeys.contains a.subject)] else [])
        ++ (if a.strip then [("strip_session_fresh", !s.editSessionUsed && !r.stripOpen)] else [])
        ++ (if !s.owedKeys.contains a.subject then [("nonowed_notgiven", !s.givenUp.contains a.subject && !s.skipped.contains a.subject), ("nonowed_notrestricted", !s.restricted)] else [])
        ++ (if a.user && !s.owedKeys.contains a.subject then [("grant_needed", s.stripGrant && a.strip && !s'.stripGrant)] else [])
        ++ (if !a.user then [("budget_state", decide (s.moveCount < cap (fullBar s r)) && !s.hold && !a.strip)] else [])
        ++ (if !r.drawn.contains a.subject then [("pullout_was_request", s.foldRequest == some a.subject || s.owedKeys.contains a.subject)] else []))
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
      -- the model's count: a chevron, an incomplete read or an unobserved one resets; an unsettled complete PASS read neither counts nor resets
      if r.chevron != .absent || r.level == .incomplete || !r.observed then run_ := 0
      else if r.kind == .pass && !r.settled then pure ()
      else run_ := run_ + 1
      if s'.provenNotFull && !s.provenNotFull then out := out ++ [("proof_three_consecutive", decide (run_ >= 3))]
      if !s.provenNotFull && !s'.provenNotFull then out := out ++ [("proof_not_late", decide (run_ <= 3))]
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
def goodReadG (fresh : Bool) (rec_ : List Key) : G Read := do
  let dr ← shuffle rec_
  pure { kind := .pass, chevron := if fresh then .fresh else .absent, level := .complete, settled := true, stripOpen := false, drawn := dr, pile := [], folded := [], trusted := dr, nearFold := [] }
def budgetTrace (fresh : Bool) (prove : Bool) (n : Nat) : G (Nat × Nat) := do
  let rec_ := allKeys
  let mut s := State.init rec_
  let mut evs : List Event := []
  if prove then
    for _ in List.range 3 do
      let r ← goodReadG false rec_
      s := (step s (.read { r with kind := .poll })).1
  let s0 := s
  for i in List.range n do
    -- ejb.17: the bar is the record with ONE adjacent pair swapped, a different pair on every read.  A random reshuffle would leave the key just moved misplaced
    -- on the next read, and a verified drag the next read contradicts is a strike (3 give the key up), which would stop the engine before its budget.
    let p := i % (rec_.length - 1)
    let dr := (rec_.take p) ++ (rec_.getD (p + 1) 0) :: (rec_.getD p 0) :: (rec_.drop (p + 2))
    let r : Read := { kind := .pass, chevron := if fresh then .fresh else .absent, level := .complete, settled := true, stripOpen := false, drawn := dr, pile := [], folded := [], trusted := dr, nearFold := [] }
    let e := Event.read r
    let (s1, acts) := step s e
    evs := evs ++ [e]; s := s1
    for a in acts do
      let e2 := Event.moveResult a.subject .verified true
      evs := evs ++ [e2]; s := (step s e2).1
  pure (postedEngine s0 evs, s.moveCount)

/-- ejb.26.  A read of `bar`: every key drawn and trusted, a fresh chevron, settled and complete. -/
def barRead (bar : List Key) : Event :=
  .read { kind := .pass, chevron := .fresh, level := .complete, settled := true, stripOpen := false, drawn := bar, pile := [], folded := [], trusted := bar, nearFold := [] }

/-- ejb.26.  An HONEST macOS applies every drag the engine makes and answers `verified`.  Then no key is ever struck or given up, and the last confirming
read clears the mark (`verified = none`): a mutant that never strikes is blind here, but one that keeps the mark after a confirming read, or strikes a drag
that took, is not. -/
def honestTrace : G (List (String × Bool)) := do
  let mut bar ← shuffle allKeys
  let mut s := State.init allKeys
  for _ in List.range 10 do
    let (s1, acts) := step s (barRead bar)
    s := s1
    for a in acts do
      bar := applyMove bar a
      s := (step s (.moveResult a.subject .verified true)).1
  for _ in List.range 2 do
    s := (step s (barRead bar)).1
  pure [("honest_no_strike", s.strikes.isEmpty && s.givenUp.isEmpty), ("honest_mark_cleared", s.verified.isNone)]

/-- ejb.26.  After ONE honest verified engine drag of `k`, either a user edit (any record, any moved keys) or a record key other than `k` and its anchor that macOS moves
to another place; the next read takes NO strike (it is not a revert of `k`'s own drag). -/
def falseStrikeTrace (edit : Bool) : G (List (String × Bool)) := do
  let bar ← shuffle allKeys
  let s0 := State.init allKeys
  let (s1, acts) := step s0 (barRead bar)
  match acts with
  | [] => pure []
  | a :: _ =>
    let bar1 := applyMove bar a
    let s2 := (step s1 (.moveResult a.subject .verified true)).1
    if edit then
      let rec2 ← shuffle allKeys
      let moved ← subset rec2 30
      let s3 := (step s2 (.userEdit rec2 moved)).1
      let bar2 ← shuffle allKeys
      let s4 := (step s3 (barRead bar2)).1
      pure [("edit_no_strike", s4.strikes == s3.strikes && s4.givenUp == s3.givenUp)]
    else
      let others := allKeys.filter (fun y => y != a.subject && y != a.rel.target)
      let y := others.getD (← rnd others.length) 0
      let bar2 := insertAt y (bar1.erase y) (← rnd bar1.length)
      let s3 := (step s2 (barRead bar2)).1
      pure [("crossing_no_strike", s3.strikes == s2.strikes)]

/-- ejb.17.  A bar macOS never changes: every drag is answered `verified` but every later read shows the same inversions.  No key is dragged more
than three times (`verified_revert_bounded`), on a full bar and on a bar proven not full alike. -/
def revertTrace (fresh prove : Bool) : G (List (String × Bool)) := do
  let rec_ := allKeys
  let bar ← shuffle rec_
  let rd : Read := { kind := .pass, chevron := if fresh then .fresh else .absent, level := .complete, settled := true, stripOpen := false,
                     drawn := bar, pile := [], folded := [], trusted := bar, nearFold := [] }
  let mut s := State.init rec_
  if prove then
    for _ in List.range 3 do
      s := (step s (.read { rd with kind := .poll })).1
  let mut moves : List Key := []
  for _ in List.range 40 do
    let (s1, acts) := step s (.read rd)
    s := s1
    for a in acts do
      if !a.user then moves := a.subject :: moves
      s := (step s (.moveResult a.subject .verified true)).1
  let worst := allKeys.foldl (fun m k => max m (moves.filter (· == k)).length) 0
  pure ([("revert_bound", decide (worst ≤ 3)), ("revert_struck_at_three", moves.isEmpty || worst == 3)] ++ (if worst == 3 then [("revert_hit3", true)] else []))

/-- Budget and strip invariants over a trace from the initial state with no user event. -/
def pureChecks (t : Trace) : List (String × Bool) :=
  let s0 := State.init t.record
  let n := postedEngine s0 t.evs
  let acts := (run s0 t.evs).2
  [ ("budget_any", decide (n ≤ capNotFull)), ("stripNone", acts.all (fun a => !a.strip)) ]
  ++ (if fullThroughout s0 t.evs then [("budget_full", decide (n ≤ capFull))] else [])

/-! ### The status and the moves against a random honest bar

At each read a REAL bar `b` is drawn first and the reading is derived from it by the assumptions of `Truth.lean` (A1 trusted drawn keys are
open in the shown order; A2 pile and folded keys are behind a fresh chevron; A3 no chevron only when nothing is behind; A6 every key on the
bar is drawn, in the pile, folded or unread; A7 the lists' shape).  The bar may or may not match the record.  Then, for the state before the
read: "Menu bar matches" implies `barMatches` of that bar, "differs" implies not, "matches except U" implies `barMatchesExcept U`, a
tick is open, a « is behind, "not on the bar" is neither, an engine move implies the bar differs and the subject of a move that is not a
pull-out is open. -/

def genBar (rec : List Key) : G Bar := do
  let aligned ← coin 55
  let on ← allKeys.filterM (fun _ => coin 85)
  let ord0 ← if aligned then pure (rec.filter (fun k => on.contains k) ++ on.filter (fun k => !rec.contains k)) else shuffle on
  let nb ← rnd (ord0.length + 1)
  let ord1 ← if (← coin 20) && ord0.length ≥ 2 then
      let i ← rnd (ord0.length - 1)
      pure (ord0.take i ++ [ord0.getD (i + 1) 0, ord0.getD i 0] ++ ord0.drop (i + 2))
    else pure ord0
  pure ⟨ord1.drop nb, ord1.take nb⟩

def genReadOf (b : Bar) : G Read := do
  let kindPass ← coin 85
  let settled ← coin 90
  let lv ← rnd 20
  let so ← coin 6
  let obs ← coin 96
  let c ← rnd 100
  let chev : ChevronRead :=
    if b.behind.isEmpty then (if c < 55 then .absent else .fresh) else (if c < 90 then .fresh else .stale)
  let pile ← if chev == .fresh then subset b.behind 60 else pure []
  let folded ← if chev == .fresh then subset (b.behind.filter (fun k => !pile.contains k)) 50 else pure []
  let kept ← b.open_.filterM (fun _ => coin 88)
  let junkOn ← coin 12
  let junk := allKeys.filter (fun k => !b.open_.contains k && !b.behind.contains k)
  let ji ← rnd (kept.length + 1)
  let jk := junk.getD (← rnd (junk.length + 1)) 0
  let drawn := if junkOn && junk.contains jk then kept.take ji ++ [jk] ++ kept.drop ji else kept
  let trusted ← kept.filterM (fun _ => coin 92)
  let leftover := b.behind.filter (fun k => !pile.contains k && !folded.contains k)
  let removed := b.open_.filter (fun k => !kept.contains k)
  let extra ← subset allKeys 8
  let unread := (leftover ++ removed ++ extra).eraseDups.filter (fun k => !trusted.contains k && !pile.contains k && !folded.contains k)
  pure { kind := if kindPass then .pass else .poll, chevron := chev,
         level := if lv < 16 then .complete else if lv < 18 then .exceptSelfPositioning else .incomplete,
         settled := settled, stripOpen := so, drawn := drawn, pile := pile, folded := folded,
         trusted := trusted, nearFold := [], observed := obs, unread := unread }

/-- An event, with the real bar behind it when it is a read. -/
def genHEvent (s : State) : G (Event × Option Bar) := do
  let p ← rnd 100
  let ans ← coin 60
  match s.inFlight with
  | some a =>
      if ans then
        let o ← rnd 4
        let posted ← coin 75
        return (.moveResult a.subject (match o with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) posted, none)
  | none => pure ()
  if p < 58 then
    let b ← genBar s.record
    return (.read (← genReadOf b), some b)
  else if p < 66 then
    let o ← rnd 4
    let posted ← coin 75
    return (.moveResult (1 + (← rnd 7)) (match o with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) posted, none)
  else if p < 76 then
    let rec_ ← shuffle (← subset allKeys 85)
    let moved ← subset rec_ 30
    return (.userEdit rec_ moved, none)
  else if p < 80 then return (.userRetry, none)
  else if p < 84 then return (.retryKey (1 + (← rnd 7)), none)
  else return (.passBoundary, none)

def honestChecks (s : State) (e : Event) (ob : Option Bar) : List (String × Bool) :=
  match e, ob with
  | .read r, some b =>
    let poss := decide (Possible (s.view r) b)
    let m := decide (barMatches s.record b)
    [("generator_honest", poss), (if m then "bar_matches_seen" else "bar_differs_seen", true)]
    ++ (if !poss then [] else
      (match statusLine s r with
       | .matches => [("claim_matches", m), ("status_matches_seen", true)]
       | .matchesExcept U => [("claim_except", decide (barMatchesExcept U s.record b)), ("status_except_seen", true)]
       | .differs (.needsReapply k) =>
           -- ejb.20: independent of `enginePlan`: nothing leaves, no hold, no grant, and the planner's move of `k` needs the strip; Re-apply never leaves the same text
           [("claim_differs", !m), ("status_differs_seen", true), ("reapply_seen", true),
            ("reapply_withheld", (decideMove s r).isNone && s.inFlight.isNone && !s.hold && !s.stripGrant && !(cap (fullBar s r) ≤ s.moveCount)
                                 && (planOrderMoves (judge s r) r).any (fun a => a.strip && a.subject == k)),
            ("reapply_clears", statusLine (step s .userRetry).1 r != .differs (.needsReapply k))]
       | .differs _ => [("claim_differs", !m), ("status_differs_seen", true)]
       | .checking => [("status_checking_seen", true)]
       | .moving => [("status_moving_seen", true)])
      ++ s.record.flatMap (fun k =>
          match rowLine s r k with
          | .tick => [("row_tick_open", decide (k ∈ b.open_)), ("row_tick_seen", true)]
          | .behind => [("row_behind_behind", decide (k ∈ b.behind)), ("row_behind_seen", true)]
          | .notOnBar => [("row_notOnBar_off", decide (k ∉ b.open_ ∧ k ∉ b.behind)), ("row_notOnBar_seen", true)]
          | .notWherePut => [("row_notWherePut_seen", true)]
          | _ => [])
      ++ (step s e).2.flatMap (fun a =>
          (if !a.user then [("engine_move_bar_differs", !m), ("engine_move_seen", true)] else [("user_move_seen", true)])
          ++ (if a.user && s.owedKeys.contains a.subject && r.drawn.contains a.subject && anchorMove s r a.subject == none then
                [("fallback_bar_improves",
                  decide (invs s.record ((applyMove b.open_ a).filter (fun x => s.record.contains x)) < invs s.record (b.open_.filter (fun x => s.record.contains x)))),
                 ("fallback_bar_seen", true)] else [])
          ++ [("move_target_open", decide (a.rel.target ∈ b.open_)),
              ("move_subject_open_or_pullout", decide (a.subject ∈ b.open_ ∨ (a.subject ∈ foldedAll s r ∧ a.subject ∈ b.behind))),
              ("move_not_on_cannotTell", shownVerdict s r != .cannotTell)]))
  | _, _ => []

def genHTrace (n : Nat) : G (List Key × List (Event × Option Bar) × List State) := do
  let rec_ ← shuffle (← subset allKeys 90)
  let mut s := State.init rec_
  let mut evs : List (Event × Option Bar) := []
  let mut sts : List State := []
  for _ in List.range n do
    let e ← genHEvent s
    sts := sts ++ [s]
    evs := evs ++ [e]
    s := (step s e.1).1
  pure (rec_, evs, sts)

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
        let idle ← rnd 2
        let s := if idle == 0 then { s0 with inFlight := none, owedKeys := [], foldRequest := none } else { s0 with inFlight := none }
        let r0 ← genRead
        let rec_ ← shuffle (← subset allKeys 85)
        let k := 1 + (← rnd 7)
        let folded ← rnd 2
        -- a plannable read that shows k drawn and trusted, or one that lists k as folded under a fresh chevron
        let r := if folded == 0 then
            { r0 with kind := .pass, settled := true, level := .complete,
                      drawn := k :: r0.drawn.filter (· != k), trusted := k :: r0.trusted }
          else
            { r0 with kind := .pass, settled := true, level := .complete, chevron := .fresh, stripOpen := false,
                      drawn := r0.drawn.filter (· != k), pile := k :: r0.pile.filter (· != k), trusted := r0.trusted.filter (· != k) }
        ts := addAll ts (answeredCheck s r rec_ k) desc
        ts := addAll ts (owedReasonCheck ((step s (.userEdit rec_ [k])).1) r) desc
        let s2 := (step s (.userEdit rec_ [k])).1
        ts := addAll ts (tryAgainCheck s2 r) desc
        ts := addAll ts (noteCheck s2 r) desc
    for (nm, ok, d) in dropEnumChecks do
      ts := record ts nm ok (fun _ => d)
    for _ in List.range mixed do
      let (rec_, evs, sts) ← genHTrace 30
      let desc := fun (_ : Unit) => toString (repr (rec_, evs.map (·.1)))
      for (st, e) in sts.zip evs do
        ts := addAll ts (honestChecks st e.1 e.2) desc
        steps := steps + 1
    for _ in List.range (pure_ / 5) do
      let fresh ← coin 50
      let prove ← coin 50
      ts := addAll ts (← revertTrace fresh (prove && !fresh)) (fun _ => s!"revertTrace {fresh} {prove}")
    for _ in List.range (pure_ / 5) do
      ts := addAll ts (← honestTrace) (fun _ => "honestTrace")
      ts := addAll ts (← falseStrikeTrace true) (fun _ => "falseStrikeTrace edit")
      ts := addAll ts (← falseStrikeTrace false) (fun _ => "falseStrikeTrace crossing")
    for _ in List.range pure_ do
      let t ← genTrace 30 false
      ts := addAll ts (pureChecks t) (fun _ => toString (repr (t.record, t.evs)))
      steps := steps + t.evs.length
    pure (ts, steps)
  let ((ts, steps), _) := go.run seed
  (ts, steps, mixed + pure_)

end Sommelier.Fuzz

open Sommelier.Fuzz in
def fuzzMain (args : List String) : IO UInt32 := do
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
  for n in [4, 5] do
    let (fb, an, nn) := singleDropTable n
    IO.println s!"single-drop table, {n} keys (fires, worse, unchanged): fallback {fb}, anchor rule {an}, no move {nn}"
    if fb.2.1 != 0 || fb.2.2 != 0 then
      IO.println "  FALLBACK WORSE OR UNCHANGED"
      bad := bad + 1
  let (w4, t4) := multiDropWorse 4
  let (w5, t5) := multiDropWorse 5
  IO.println s!"multi-drop ends worse (inversions): {w4} of {t4} (4 keys), {w5} of {t5} (5 keys); the anchor rule is old behaviour"
  let (rc, rs, rb) := reapplyTable 5
  IO.println s!"needs Re-apply table, 5 keys (cases, shown, violations): {rc}, {rs}, {rb}"
  if rs == 0 || rb != 0 then
    IO.println "  NEEDS-REAPPLY TABLE FAILED"
    bad := bad + 1
  for t in ts do
    IO.println s!"  {t.name}: {t.n} instances, {t.bad} failures"
    bad := bad + t.bad
    if let some c := t.cex then IO.println s!"    first counterexample: {c}"
  -- both sides of every claim must be exercised
  for nm in ["claim_matches", "claim_differs", "claim_except", "engine_move_bar_differs", "bar_matches_seen", "bar_differs_seen",
             "status_checking_seen", "status_moving_seen", "row_tick_open", "row_behind_behind", "row_notOnBar_off", "user_move_seen",
             "drop_answered_if_reducible", "drain_bound", "drain_notes", "try_again_seen", "note_seen", "fallback_owed_misplaced", "fallback_bar_seen", "note_cant_seen"] do
    if !(ts.any (fun t => t.name == nm && t.n > 0)) then
      IO.println s!"  NOT EXERCISED: {nm}"
      bad := bad + 1
  return if bad == 0 then 0 else 1
