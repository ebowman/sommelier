import Sommelier.Fuzz
import Sommelier.Fast
open Sommelier Sommelier.Fuzz

/-!
# `lake exe fastfuzz [cases] [seed]`: the fast functions against the specification

Random states and reads (records of 2..36 keys, 36 in a fifth of the cases; reads that list a key twice; owed keys, fold requests, holds, in-flight
drags) are given to both the specification and the fast version of `fallbackMove`, `userMove`, `userPick`, `decideMove`, `step`, `statusLine`,
`shownVerdict`, `rowVerdict` and `rowLine`; any difference is a failure.  The equality is a THEOREM (`Fast.lean`); this check finds a false statement
before a proof is spent on it, and exercises the compiled code.  The specification is slow (22 ms per fallback at 36 keys), so each case asks the
slow functions about a few keys only.  Exit code 1 on any difference or if a branch was never exercised.
-/

def genRec : G (List Key) := do
  let big ← coin 20
  let m ← rnd 35
  let n := if big then 36 else 2 + m
  shuffle ((List.range n).map (· + 1))

/-- an order of the keys: shuffled, reversed, or the record's with a few swaps -/
def genOrder (ks rec_ : List Key) : G (List Key) := do
  let m ← rnd 3
  if m == 0 then shuffle ks
  else if m == 1 then pure (rec_.filter (ks.contains ·)).reverse
  else
    let base := rec_.filter (ks.contains ·) ++ ks.filter (fun k => !rec_.contains k)
    let mut l := base
    for _ in List.range (1 + (← rnd 4)) do
      if l.length ≥ 2 then
        let i ← rnd l.length
        let j ← rnd l.length
        let x := l.getD i 0
        let y := l.getD j 0
        l := (l.map fun z => if z == x then y else if z == y then x else z)
    pure l

def genRead36 (rec_ : List Key) : G Read := do
  let extra := (List.range 3).map (· + rec_.length + 1)
  let univ := rec_ ++ extra
  let pdrawn ← rnd 100
  let ks ← subset univ (if pdrawn < 50 then 70 else if pdrawn < 80 then 100 else 40)
  let drawn0 ← genOrder ks rec_
  let dup ← coin 4
  let di ← rnd (drawn0.length + 1)
  let drawn := if dup && !drawn0.isEmpty then drawn0 ++ [drawn0.getD di 0] else drawn0
  let rest := univ.filter (fun k => !drawn.contains k)
  let pile ← subset rest 50
  let folded ← subset (rest.filter (fun k => !pile.contains k)) 40
  let tr ← rnd 10
  let trusted ← if tr < 6 then pure drawn else subset univ 85
  let near ← subset univ 8
  let unread ← subset (rest.filter (fun k => !pile.contains k && !folded.contains k)) 30
  let c ← rnd 20
  let l ← rnd 10
  pure { kind := if (← coin 90) then .pass else .poll,
         chevron := if c < 9 then .fresh else if c < 17 then .absent else .stale,
         level := if l < 8 then .complete else if l < 9 then .exceptSelfPositioning else .incomplete,
         settled := (← coin 92), stripOpen := (← coin 5), drawn := drawn, pile := pile, folded := folded,
         trusted := trusted, nearFold := near, observed := (← coin 95), unread := unread, notFullProven := (← coin 30) }

def genState36 (rec_ : List Key) (r : Read) : G State := do
  let no ← rnd 5
  let owedPool := rec_.filter (fun k => r.drawn.contains k) ++ rec_
  let mut owed : List Key := []
  for _ in List.range no do
    owed := owed ++ [owedPool.getD (← rnd (owedPool.length + 1)) 0]
  owed := (owed.filter (rec_.contains ·)).eraseDups
  let fr ← coin 15
  let fqi ← rnd (rec_.length + 1)
  let fq := if fr && !rec_.isEmpty then some (rec_.getD fqi 0) else none
  let pile ← subset rec_ 15
  let hold ← coin 15
  let pnf ← coin 40
  let inflight ← coin 15
  let ifk := rec_.getD (← rnd (rec_.length + 1)) 0
  let ift := rec_.getD (← rnd (rec_.length + 1)) 0
  let ifs ← coin 30
  let ifu ← coin 50
  let ifa : Option Action := if inflight then some ⟨ifk, .before ift, ifs, ifu⟩ else none
  let ncr ← rnd 4
  let mc ← rnd 25
  let rs ← coin 40
  let sg ← coin 30
  let esu ← coin 25
  let ld ← rnd 10
  let gu ← subset rec_ 5
  let sk ← subset rec_ 5
  let st ← subset rec_ 5
  let hf ← subset rec_ 5
  let gn ← rnd 3
  pure { State.init rec_ with
         owedKeys := owed, foldRequest := fq, lastFreshPile := pile, hold := hold, provenNotFull := pnf,
         noChevronReads := ncr, moveCount := mc, restricted := rs, stripGrant := sg,
         editSessionUsed := esu, lastDrawn := r.drawn.take ld, givenUp := gu,
         skipped := sk, strikes := st, holdFolded := hf, gen := gn, inFlight := ifa }

def sh {α : Type} [Repr α] (x : α) : String := toString (repr x)

structure FTally where
  n : Nat := 0
  bad : Nat := 0
  fbSome : Nat := 0
  fbNone : Nat := 0
  fbCond : Nat := 0
  big : Nat := 0
  dups : Nat := 0
  moves : Nat := 0
  gated : Nat := 0
  first : Option String := none

def check (t : FTally) (ok : Bool) (what : Unit → String) : FTally :=
  { t with n := t.n + 1, bad := t.bad + (if ok then 0 else 1),
           first := match t.first with | some f => some f | none => if ok then none else some (what ()) }

def oneCase : G (Nat → FTally → FTally) := do
  let rec_ ← genRec
  let r ← genRead36 rec_
  let s ← genState36 rec_ r
  let keys0 ← subset rec_ 4
  let ki ← rnd (rec_.length + 1)
  let keysSel := (s.owedKeys.take 3) ++ keys0.take 2 ++ [rec_.getD ki 0]
  let ev ← genEvent s
  pure fun _ t0 => Id.run do
    let desc := fun (_ : Unit) => s!"record={rec_} read={sh r} state={sh s}"
    let mut t := t0
    t := { t with big := t.big + (if rec_.length == 36 then 1 else 0), dups := t.dups + (if r.drawn.Nodup then 0 else 1) }
    t := check t (s.gateF r == s.gate r) (fun _ => "gate " ++ desc ())
    t := check t (decide (shownVerdictF s r = shownVerdict s r)) (fun _ => "shownVerdict " ++ desc ())
    t := check t (decide (statusLineF s r = statusLine s r)) (fun _ => "statusLine " ++ desc ())
    let dm := decideMove s r
    t := check t (decideMoveF s r == dm) (fun _ => "decideMove " ++ desc ())
    t := { t with moves := t.moves + (if dm.isSome then 1 else 0), gated := t.gated + (if s.gate r then 1 else 0) }
    t := check t (userPickF s r == userPick s r) (fun _ => "userPick " ++ desc ())
    t := check t (sh (stepF s (.read r)) == sh (step s (.read r))) (fun _ => "step(read) " ++ desc ())
    t := check t (sh (stepF s ev) == sh (step s ev)) (fun _ => "step(event) " ++ desc ())
    for k in keysSel do
      let fb := fallbackMove s r k
      t := check t (fallbackMoveF s r k == fb) (fun _ => s!"fallbackMove k={k} " ++ desc ())
      let cond := s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k
      t := { t with fbSome := t.fbSome + (if fb.isSome then 1 else 0), fbNone := t.fbNone + (if cond && fb.isNone then 1 else 0),
                    fbCond := t.fbCond + (if cond then 1 else 0) }
      t := check t (userMoveF s r k == userMove s r k) (fun _ => s!"userMove k={k} " ++ desc ())
      t := check t (userMove2F s r k == userMove2 s r k) (fun _ => s!"userMove2 k={k} " ++ desc ())
      t := check t (decide (rowVerdictF s.record (s.view r) k = rowVerdict s.record (s.view r) k)) (fun _ => s!"rowVerdict k={k} " ++ desc ())
      t := check t (decide (rowLineF s r k = rowLine s r k)) (fun _ => s!"rowLine k={k} " ++ desc ())
    return t

def fastFuzzMain (args : List String) : IO UInt32 := do
  let cases := (args.getD 0 "10000").toNat!
  let seed := (args.getD 1 "1").toNat!
  let mut gen := seed
  let mut t : FTally := {}
  for i in List.range cases do
    let (f, g') := (oneCase).run gen
    gen := g'
    t := f i t
  IO.println s!"fast vs specification: {cases} cases (seed {seed}), {t.n} comparisons, {t.bad} differences"
  IO.println s!"  36-key records: {t.big}; reads listing a key twice: {t.dups}; decideMove found a move: {t.moves}; gate true: {t.gated}"
  IO.println s!"  fallback: condition met {t.fbCond}, move {t.fbSome}, no move {t.fbNone}"
  if let some f := t.first then IO.println s!"  first difference: {f}"
  let mut bad := t.bad
  for (nm, ok) in [("36-key records", decide (t.big > 0)), ("duplicate-key reads", decide (t.dups > 0)), ("fallback moves", decide (t.fbSome > 0)),
                   ("fallback with no move", decide (t.fbNone > 0)), ("decided moves", decide (t.moves > 0)), ("gate true", decide (t.gated > 0))] do
    if !ok then
      IO.println s!"  NOT EXERCISED: {nm}"
      bad := bad + 1
  return if bad == 0 then 0 else 1

def main (args : List String) : IO UInt32 := fastFuzzMain args
