import Sommelier.Status
import Std.Data.HashMap
open Sommelier
-- proof-independent semantic oracle: enumerates every bar over a small key universe.  `lake exe oracle [n]` (default 1500 traces); exit code 1 iff any check fails.
abbrev G := StateM Nat
def next : G Nat := modifyGet fun x => let y := (x * 6364136223846793005 + 1442695040888963407) % 18446744073709551616; (y / 65536, y)
def rnd (n : Nat) : G Nat := do let v ← next; pure (v % n)
def coin (p : Nat) : G Bool := do pure ((← rnd 100) < p)
def subset (l : List Key) (p : Nat) : G (List Key) := l.filterM (fun _ => coin p)
def insertAt (x : Key) (l : List Key) (i : Nat) : List Key := l.take i ++ x :: l.drop i
def shuffle (l : List Key) : G (List Key) := l.foldlM (fun acc x => do pure (insertAt x acc (← rnd (acc.length + 1)))) []
def U4 : List Key := [1,2,3,4]
def perms : List Key → List (List Key)
  | [] => [[]]
  | x :: xs => (perms xs).flatMap fun p => (List.range (p.length+1)).map (insertAt x p)
def subsets : List Key → List (List Key)
  | [] => [[]]
  | x :: xs => let r := subsets xs; r ++ r.map (x :: ·)
def bars : List Bar := (subsets U4).flatMap fun op =>
  (perms op).flatMap fun o => (subsets (U4.filter (fun k => !op.contains k))).map fun b => ⟨o, b⟩
def genRead : G Read := do
  let c ← rnd 10; let l ← rnd 10; let all ← shuffle U4; let nd ← rnd 5
  let drawn := all.take nd; let rest := all.drop nd
  let pile ← subset rest 50; let folded ← subset (rest.filter (!pile.contains ·)) 40
  let trusted ← subset U4 80; let near ← subset U4 15; let un ← subset (rest ++ drawn.filter (!trusted.contains ·)) 40
  let junk ← coin 3
  let clean ← coin 55
  let trusted := if clean then U4 else trusted
  let un := if clean then [] else un
  pure { kind := if ← coin 95 then .pass else .poll,
         chevron := if c < 5 then .fresh else if c < 9 then .absent else .stale,
         level := if l < 8 then .complete else if l < 9 then .exceptSelfPositioning else if clean then .complete else .incomplete,
         settled := ← coin 96, stripOpen := ← coin 3, observed := ← coin 98, drawn := if junk then drawn ++ drawn.take 1 else drawn, pile := pile, folded := folded,
         trusted := trusted, nearFold := near, unread := un, notFullProven := ← coin 60 }
def genEvent (s : State) : G Event := do
  match s.inFlight with
  | some a => if ← coin 70 then
      let o ← rnd 4
      return .moveResult a.subject (match o with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) (← coin 75)
  | none => pure ()
  let p ← rnd 100
  if p < 65 then return .read (← genRead)
  else if p < 80 then
    let rec_ ← shuffle s.record
    return .userEdit rec_ (← subset rec_ 35)
  else if p < 85 then return .userRetry
  else if p < 90 then return .retryKey ((← rnd 4) + 1)
  else return .passBoundary
structure C where
  m : Std.HashMap String (Nat × Nat) := {}
  ex : Std.HashMap String String := {}
  deriving Inhabited
abbrev T := StateT C IO
def chk (n : String) (ok : Bool) (w : Unit → String := fun _ => "") : T Unit := modify fun c =>
  let p : Nat × Nat := c.m.getD n (0,0)
  let a := p.1; let b := p.2
  { c with m := c.m.insert n (a+1, if ok then b else b+1),
           ex := if ok || c.ex.contains n then c.ex else c.ex.insert n (w ()) }
def imp (a b : Bool) : Bool := !a || b
def fixedPlace (ps : List Bar) (k : Key) : Bool := match ps with
  | [] => true
  | b :: bs => bs.all (fun x => x.place k == b.place k)
def onBarFixed (ps : List Bar) (k : Key) : Bool := fixedPlace ps k && ps.all (fun b => b.place k != .absent) && !ps.isEmpty
def rowOK (ps : List Bar) (rec_ : List Key) (b : Bar) (k : Key) : Bool :=
  rec_.all fun x => imp (x != k && fixedPlace ps x)
    (decide (x ∈ rec_.takeWhile (· != k) ∧ x ∈ b.open_) == decide (x ∈ b.open_.takeWhile (· != k)))
def inverted (rec_ : List Key) (b : Bar) (k y : Key) : Bool := !decide (barMatches (rec_.filter (fun z => z == k || z == y)) b)
def pureChecks (rec_ : List Key) (r : Read) : T Unit := do
  let ps := bars.filter (fun b => decide (Possible r b))
  let some' := !ps.isEmpty
  let v := verdict rec_ r
  let w := fun (_:Unit) => s!"rec={rec_} r={repr r} v={repr v}"
  let allM := ps.all (fun b => decide (barMatches rec_ b))
  let allD := ps.all (fun b => !decide (barMatches rec_ b))
  chk "T1" ((v == .matches) == (decide r.usable && some' && allM)) w
  chk "T2" ((v == .differs) == (some' && allD)) w
  let party := fun k => !fixedPlace ps k && ps.any (fun b => rec_.any (fun y => y != k && onBarFixed ps y && inverted rec_ b k y))
  match v with
  | .matchesExcept u =>
     chk "T3_ne" (!u.isEmpty && u.all rec_.contains && some') w
     chk "T3_all" (ps.all (fun b => decide (barMatchesExcept u rec_ b))) w
     chk "T3_exact" (rec_.all (fun k => u.contains k == party k)) w
     chk "T3_fixed" (rec_.any (fun k => !u.contains k && onBarFixed ps k)) w
  | .cannotTell =>
     let uP := rec_.filter party
     let valid := !uP.isEmpty && ps.all (fun b => decide (barMatchesExcept uP rec_ b)) && rec_.any (fun k => !uP.contains k && onBarFixed ps k)
     chk "T4" (!decide r.usable || !some' || (!allM && !allD && !valid)) w
  | _ => pure ()
  for k in rec_ do
    let rv := rowVerdict rec_ r k
    let w2 := fun (_:Unit) => s!"k={k} rv={repr rv} rec={rec_} r={repr r}"
    match rv with
    | .inOrder => chk "R_tick" (some' && ps.all (fun b => k ∈ b.open_ && rowOK ps rec_ b k)) w2
    | .behindChevron => chk "R_behind" (some' && ps.all (fun b => k ∈ b.behind)) w2
    | .behindOutOfTurn => chk "R_oot" (some' && ps.all (fun b => k ∈ b.behind && (rec_.takeWhile (· != k)).any (· ∈ b.open_))) w2
    | .outOfPlace => chk "R_oop" (some' && ps.all (fun b => k ∈ b.open_ && !rowOK ps rec_ b k)) w2
    | .notOnBar => chk "R_off" (some' && ps.all (fun b => k ∉ b.open_ && k ∉ b.behind)) w2
    | .cannotTell =>
      -- exactness: if some bar exists and k is fixed, the row must have said so, unless unusable
      chk "R_ct" (!some' || !fixedPlace ps k || !decide r.usable || (ps.all (fun b => b.place k == .absent) && false) ) w2
def rowTruth (ps : List Bar) (rec_ : List Key) (k : Key) (l : RowLine) : Bool :=
  match l with
  | .tick => !ps.isEmpty && ps.all (fun b => k ∈ b.open_ && rowOK ps rec_ b k)
  | .behind => !ps.isEmpty && ps.all (fun b => k ∈ b.behind && (rec_.takeWhile (· != k)).all (fun y => !(fixedPlace ps y && y ∈ b.open_)))
  | .notWherePut => !ps.isEmpty && ps.all (fun b => (k ∈ b.open_ && !rowOK ps rec_ b k) || (k ∈ b.behind && (rec_.takeWhile (· != k)).any (· ∈ b.open_)))
  | .notOnBar => !ps.isEmpty && ps.all (fun b => k ∉ b.open_ && k ∉ b.behind)
  | .cannotTell => true
  | _ => true
def newRule (s : State) (r rv : Read) (ps : List Bar) (as : List Action) (w : Unit → String) : T Unit := do
  let good := decide rv.usable && rv.consistent
  chk "gate_is_good" (s.gate r == good) w
  let rec_ := s.record
  let st := statusLine s r
  -- status directly against bars
  match st with
  | .matches => chk "S_matches_all" (!ps.isEmpty && decide rv.usable && ps.all (fun b => decide (barMatches rec_ b))) w
  | .differs _ => chk "S_differs_all" (!ps.isEmpty && ps.all (fun b => !decide (barMatches rec_ b))) w
  | .matchesExcept u =>
     chk "S_except_all" (!ps.isEmpty && decide rv.usable && !u.isEmpty && ps.all (fun b => decide (barMatchesExcept u rec_ b)) && !ps.all (fun b => decide (barMatches rec_ b))) w
  | .checking => chk "S_checking_real" (!decide rv.usable || !rv.consistent || (!ps.all (fun b => decide (barMatches rec_ b)) && !ps.all (fun b => !decide (barMatches rec_ b)))) w
  | .moving => chk "S_moving" (s.inFlight.isSome || (decideMove s r).isSome) w
  -- each row against bars, when the read is good
  if good then
    for k in rec_ do
      chk "RL_truth" (rowTruth ps rec_ k (rowLine s r k)) (fun _ => s!"k={k} row={repr (rowLine s r k)} {w ()}")
  -- the planner cannot depend on pile memory on a good read in a reachable state
  if good && (!s.provenNotFull || s.lastFreshPile.isEmpty) then
    let s2 := { s with lastFreshPile := [] }
    let s3 := { s with lastFreshPile := [1,2,3,4] }
    if r.chevron == .fresh then
      chk "no_stale_dep" (decideMove s r == decideMove s2 r && decideMove s r == decideMove s3 r) w
  -- only a drop crosses the fold; movable subject otherwise
  for a in as do
    if ps.any (fun b => a.subject ∈ b.behind) then
      chk "fold_cross" (a.user && (s.owedKeys.contains a.subject || s.foldRequest == some a.subject) && r.chevron == .fresh && r.foldedSet.contains a.subject && a.strip) w
      chk "fold_cross_all" (ps.all (fun b => a.subject ∈ b.behind)) w
    if !a.user then chk "E_open_all" (ps.all (fun b => a.subject ∈ b.open_ && a.rel.target ∈ b.open_)) w
    chk "target_open_all" (ps.all (fun b => a.rel.target ∈ b.open_)) w
    if a.strip then chk "strip_session" (!s.editSessionUsed || (!a.user || (a.user && !s.owedKeys.contains a.subject && s.stripGrant))) w
  -- the drop rule, semantically: owed, good read, nothing in flight, k heads the queue and its session is free
  if good && s.inFlight.isNone then
    for k in s.owedKeys do
      let leaving := as.any (·.subject == k)
      let l := rowLine s r k
      if !leaving then
        -- comforting row with no move: must be literally true of every bar
        if l == .tick then chk "C_tick_true" (ps.all (fun b => k ∈ b.open_ && rowOK ps rec_ b k)) w
        if l == .behind then chk "C_behind_true" (ps.all (fun b => k ∈ b.behind)) w
        -- no key that is wrong on EVERY bar may read as comfort
        let wrongAll := !ps.isEmpty && ps.all (fun b =>
           (k ∈ b.open_ && !rowOK ps rec_ b k) || (k ∈ b.behind && (rec_.takeWhile (· != k)).any (· ∈ b.open_)))
        if wrongAll then chk "C_wrong_not_comfort" (l == .notWherePut || l == .waiting) (fun _ => s!"k={k} l={repr l} {w ()}")
        chk "C_no_moving_lie" (l != .moving || s.inFlight.isSome) w
      -- pinned behind, a movable predecessor, first in queue, session free => it moves
      let q := s.foldRequest.toList ++ s.owedKeys
      if q.head? == some k && !s.editSessionUsed then
        let predOpen := (rec_.takeWhile (· != k)).any (fun y => r.trustedDrawn.contains y && !(foldedAll s r).contains y)
        if r.chevron == .fresh && ps.all (fun b => k ∈ b.behind) && !r.drawn.contains k && predOpen then
          chk "D_pull" (as.map (·.subject) == [k]) w
        if ps.all (fun b => k ∈ b.open_ && !rowOK ps rec_ b k) && !(foldedAll s r).contains k then
          let anch := (movable s r).filter (fun a => a != k && rec_.contains a && !s.owedKeys.contains a)
          let want := (rec_.takeWhile (· != k)).filter anch.contains
          let hasGap := (List.range (anch.length+1)).any (fun i => (anch.take i).all want.contains && want.all (anch.take i).contains)
          let others := rec_.any (fun x => x != k && s.owedKeys.contains x && r.trustedDrawn.contains x)
          if hasGap && !others then chk "D_drawn" (as.map (·.subject) == [k]) w
def stepChecks (s : State) (r : Read) : T Unit := do
  let rv := s.view r
  let ps := bars.filter (fun b => decide (Possible rv b))
  let w := fun (_:Unit) => s!"s={repr s} r={repr r}"
  let as := (step s (.read r)).2
  chk "one_action" (as.length ≤ 1) w
  chk "full_any_chevron" (imp (r.chevron != .absent) (fullBar s r)) w
  chk "gate_is_view" (statusLine s r == statusLine s rv) w
  for a in as do
    chk "good_read" (r.kind == .pass && r.settled && r.level != .incomplete && s.inFlight.isNone && decide rv.usable && rv.consistent) w
    if !a.user then
      chk "T6_engine" (shownVerdict s r == .differs) w
      chk "E_hold" (!s.hold) w; chk "E_open" (!r.stripOpen) w; chk "E_stale" (r.chevron != .stale) w; chk "E_restricted" (!s.restricted) w
      chk "E_budget" (s.moveCount < cap (fullBar s r)) w
      chk "E_given" (!s.givenUp.contains a.subject && !s.skipped.contains a.subject) w
      chk "E_nostrip" (!a.strip) w
    else if !(foldedAll s r).contains a.subject then
      chk "T6_user" (ps.all (fun b => a.subject ∈ b.open_ && !rowOK ps s.record b a.subject)) w
    chk "T7_target" (ps.all (fun b => a.rel.target ∉ b.behind)) w
    chk "T7_subject" (ps.all (fun b => if (foldedAll s r).contains a.subject then a.subject ∈ b.behind else a.subject ∈ b.open_)) w
    chk "T9" (shownVerdict s r != .cannotTell) w
    chk "in_record" (s.record.contains a.subject) w
    chk "changes_drawn" (imp r.drawn.Nodup (applyMove r.drawn a != r.drawn)) w
  let st := statusLine s r
  chk "moving_iff" ((st == .moving) == (s.inFlight.isSome || (decideMove s r).isSome)) w
  if st != .moving then
    match shownVerdict s r with
    | .matches => chk "st_m" (st == .matches) w
    | .matchesExcept u => chk "st_e" (st == .matchesExcept u) w
    | .cannotTell => chk "st_c" (st == .checking) w
    | .differs =>
      chk "st_d" (match st with
        | .differs .stopped => cap (fullBar s r) ≤ s.moveCount
        | .differs .barFull => s.hold && !(cap (fullBar s r) ≤ s.moveCount)
        | .differs .plain => !s.hold && !(cap (fullBar s r) ≤ s.moveCount)
        | _ => false) w
  for k in s.record do
    let l := rowLine s r k
    let mv := s.inFlight.any (·.subject == k) || (decideMove s r).any (·.subject == k)
    chk "row_moving" ((l == .moving) == mv) w
    if !mv then
      let ow := s.owedKeys.contains k || s.foldRequest == some k
      let goodRead := decide rv.usable && rv.consistent
      -- independently: a move of k exists on this read
      let ex := (userMove s r k).isSome
      chk "row_waiting" ((l == .waiting) == (ow && (!goodRead || ex))) w
      if !(ow && (!goodRead || ex)) then
        chk "row_line" (l == (match rowVerdict s.record rv k with
          | .inOrder => .tick | .behindChevron => .behind | .outOfPlace => .notWherePut | .behindOutOfTurn => .notWherePut
          | .notOnBar => .notOnBar | .cannotTell => .cannotTell)) w
  newRule s r rv ps as w
  -- noteRead proof rule, hold/pile clear
  let n := noteRead s r
  if !s.provenNotFull && n.provenNotFull then
    chk "proof_rule" (r.chevron == .absent && r.level != .incomplete && r.observed && !(r.kind == .pass && !r.settled) && (if r.kind == .pass then 3 else 2) ≤ s.noChevronReads) w
    chk "proof_clears" (!n.hold && n.lastFreshPile.isEmpty) w
  if r.chevron != .absent then chk "chev_revokes" (!n.provenNotFull && n.noChevronReads == 0) w
  if r.chevron == .absent && (r.level == .incomplete || !r.observed) && !s.provenNotFull then chk "reset" (n.noChevronReads == 0) w
  if s.hold && !n.provenNotFull then chk "hold_kept" n.hold w
  if s.hold && s.provenNotFull then chk "hold_never_proven" false w
def eventChecks (s : State) (e : Event) : T Unit := do
  let w := fun (_:Unit) => s!"s={repr s} e={repr e}"
  let t := (step s e).1
  match e with
  | .userRetry =>
    chk "retry" (!t.hold && t.givenUp.isEmpty && t.moveCount == 0 && !t.restricted && t.stripGrant) w
  | .userEdit rc mv =>
    chk "edit_rec" (t.record == rc) w
    if !mv.isEmpty then
      chk "edit_reset" (t.moveCount == 0 && t.skipped.isEmpty && t.restricted && mv.all (!t.givenUp.contains ·) && mv.all (fun j => imp (rc.contains j) (t.owedKeys.contains j))) w
      chk "edit_keeps_proof" (t.provenNotFull == s.provenNotFull && t.noChevronReads == s.noChevronReads && t.lastFreshPile == s.lastFreshPile) w
  | .passBoundary =>
    chk "pb" (t.owedKeys.isEmpty && t.foldRequest.isNone && !t.restricted) w
    chk "pb_keeps" (t.hold == s.hold && t.provenNotFull == s.provenNotFull && t.moveCount == s.moveCount) w
  | .retryKey k =>
    chk "rk" (!t.hold && t.moveCount == 0 && !t.givenUp.contains k && imp (s.record.contains k) (t.owedKeys.contains k)) w
  | .moveResult k o p =>
    match s.inFlight with
    | some a => if a.subject == k then
        chk "res_clear" t.inFlight.isNone w
        if p && o == .failed && !s.provenNotFull then chk "res_hold" (t.hold && t.givenUp.contains k) w
        if p && !a.user then chk "res_count" (t.moveCount == s.moveCount + 1) w
    | none => chk "res_noop" (t.moveCount == s.moveCount) w
  | _ => pure ()
-- adversarial drain: same read forever, result adversarial, no user events
def drain (s0 : State) (r : Read) (o : Outcome) (p : Bool) : T Unit := do
  let mut s := s0; let mut n := 0
  let bound := 2 * (s0.owedKeys.length + 1) + 1
  let mut user := 0
  for _ in [0:60] do
    let (s1, as) := step s (.read r)
    for a in as do
      n := n + 1
      if a.user then user := user + 1
    s := s1
    if let some a := s.inFlight then
      s := (step s (.moveResult a.subject o p)).1
  chk "drain_user_bound" (user ≤ bound) (fun _ => s!"user={user} owed={s0.owedKeys} o={repr o} p={p} r={repr r}")
  chk "drain_engine_bound" (n - user ≤ 21 + s0.moveCount) (fun _ => s!"n={n} user={user}")
  -- after the drain, a still-owed key has no allowed move on that read
  if s.inFlight.isNone then
    chk "drain_quiet" ((step s (.read r)).2.all (fun a => !a.user || !s.owedKeys.contains a.subject)) (fun _ => s!"s={repr s}")
def trace (seed : Nat) : T Nat := do
  let (rec0, sd) := (shuffle (U4.take 4)).run seed
  let mut g := sd; let mut s := State.init rec0
  let (pf, g0) := (coin 30).run g; g := g0
  if pf then
    let abs : Read := { kind := .pass, chevron := .absent, level := .complete, settled := true, stripOpen := false, drawn := rec0, pile := [], folded := [], trusted := rec0, nearFold := [] }
    s := (run s (List.replicate 5 (.read abs))).1
  for _ in [0:30] do
    let (e, g2) := (genEvent s).run g; g := g2
    if let .read r := e then
      let r' := { r with notFullProven := s.provenNotFull }
      let (fast, g3) := (coin 25).run g; g := g3
      if fast then
        pureChecks s.record r'
        stepChecks s r
      else stepChecks s r
    if let .read r := e then
      if !s.owedKeys.isEmpty || s.stripGrant then
        let (ix, g4) := (rnd 8).run g; g := g4
        drain s r (match ix % 4 with | 0 => .verified | 1 => .failed | 2 => .refused | _ => .busy) (ix >= 4)
    eventChecks s e
    s := (step s e).1
  pure g

-- ejb.10: every 4-key bar read as a good fresh read (drawn = d, the rest in the pile, all trusted), every dropped subset: the semantic ground truth is the enumerated honest bars
def okRead (d : List Key) (pile : List Key) : Read :=
  { kind := .pass, chevron := (if pile.isEmpty then .absent else .fresh), level := .complete, settled := true, stripOpen := false, drawn := d, pile := pile, folded := [],
    trusted := d, nearFold := [], notFullProven := pile.isEmpty }
def wrongAllBars (ps : List Bar) (rec_ : List Key) (k : Key) : Bool :=
  !ps.isEmpty && ps.all (fun b => (k ∈ b.open_ && !rowOK ps rec_ b k) || (k ∈ b.behind && (rec_.takeWhile (· != k)).any (· ∈ b.open_)))
-- independent inversion count of the bar `d` against the record (every drawn key is movable in these reads)
def invI (rec_ d : List Key) : Nat :=
  (d.zipIdx.map fun (x, i) => (d.zipIdx.filter fun (y, j) => i < j && decide (rec_.idxOf y < rec_.idxOf x)).length).foldl (· + ·) 0
-- independent: some single drag of k (to ANY place in the bar) leaves strictly fewer inversions
def reducible (rec_ d : List Key) (k : Key) : Bool :=
  let rest := d.filter (· != k)
  (List.range (rest.length + 1)).any fun i => decide (invI rec_ (insertAt k rest i) < invI rec_ d)
def bestAfter (rec_ d : List Key) (k : Key) : Nat :=
  let rest := d.filter (· != k)
  ((List.range (rest.length + 1)).map fun i => invI rec_ (insertAt k rest i)).foldl min (invI rec_ d)
def dropOracle : T Unit := do
  let rec_ := U4
  for X in subsets U4 do
    for d in perms X do
      let pile := U4.filter (fun k => !X.contains k)
      let r := okRead d pile
      for O in subsets U4 do
        if O.isEmpty then continue
        let s0 := (step (State.init rec_) (.userEdit rec_ O)).1
        let w := fun (_ : Unit) => s!"d={d} pile={pile} O={O}"
        if !decide (s0.gate r) then continue
        let rv := s0.view r
        let ps := bars.filter (fun b => decide (Possible rv b))
        let as := (step s0 (.read r)).2
        -- an owed drawn key that ONE drag can improve (strictly fewer inversions): something leaves
        let fixable := O.any fun k => d.contains k && reducible rec_ d k
        chk "F_answered" (!fixable || !as.isEmpty) w
        -- a fallback move (the anchor rule gave none for its subject) strictly lowers the inversions, and no other place for the key does better
        for a in as do
          if d.contains a.subject && s0.owedKeys.contains a.subject && anchorMove s0 r a.subject == none then
            chk "F_fallback_reduces" (invI rec_ (applyMove d a) < invI rec_ d) w
            chk "F_fallback_best" (invI rec_ (applyMove d a) == bestAfter rec_ d a.subject) (fun _ => s!"a={repr a} {w ()}")
        -- the note: shown for every owed not-where-put row without a move of its key; `noMoveHelps` only when truly no drag of the key can improve and nothing is queued to move
        for k in O do
          if !(as.any (·.subject == k)) && wrongAllBars ps rec_ k then
            chk "F_note_shown" ((rowLine s0 r k == .notWherePut && (rowNote s0 r k).isSome) || rowLine s0 r k == .waiting) (fun _ => s!"k={k} {w ()}")
          if rowNote s0 r k == some .noMoveHelps then
            chk "F_helps_true" (d.contains k && !reducible rec_ d k && as.isEmpty && invI rec_ d > 0) (fun _ => s!"k={k} {w ()}")
        -- try again on every not-where-put row
        for k in rec_ do
          if rowLine s0 r k == .notWherePut then
            let s1 := (step s0 (.retryKey k)).1
            let as1 := (step s1 (.read r)).2
            chk "F_try_again" (as1.any (·.user) || (rowNote s1 r k).isSome) (fun _ => s!"k={k} {w ()}")
        -- Re-apply: a differing verdict with a good read: a move leaves, or the status is the "no move to make" one
        let s2 := (step s0 .userRetry).1
        if decide (s2.gate r) && shownVerdict s2 r == .differs then
          let as2 := (step s2 (.read r)).2
          chk "F_retry_answers" (!as2.isEmpty || statusLine s2 r == .differs .plain) w
          chk "F_plain_iff_no_move" ((statusLine s2 r == .differs .plain) == (as2.isEmpty && s2.inFlight.isNone)) w
        -- drain with verified drags on the honest bar: bounded by the owed keys, then quiet
        let mut s := s0; let mut dd := d; let mut moves := 0
        for _ in [0:12] do
          let (s1, a1) := step s (.read (okRead dd pile))
          s := s1
          if let some a := a1.head? then
            moves := moves + 1
            dd := applyMove dd a
            s := (step s (.moveResult a.subject .verified true)).1
        chk "F_drain_bound" (moves ≤ O.length) w
        chk "F_drain_quiet" ((step s (.read (okRead dd pile))).2.isEmpty) w
        if O.all X.contains then chk "F_drain_not_worse" (invI rec_ dd ≤ invI rec_ d) w

-- ejb.10, pass 2: the fallback and the note against EVERY possible bar, across trusted-subset variations.  For `n` keys (record = 1..n): every set X of drawn keys (the rest
-- in the pile), every order of X, every trusted subset T of X (untrusted drawn keys are free), every single dropped key.
def barsOf (U : List Key) : List Bar := (subsets U).flatMap fun op =>
  (perms op).flatMap fun o => (subsets (U.filter (fun k => !op.contains k))).map fun b => ⟨o, b⟩
def invOpen (rec_ l : List Key) : Nat := invI rec_ (l.filter (fun x => rec_.contains x))
def wholeOracle (n : Nat) : T Unit := do
  let U : List Key := (List.range n).map (· + 1)
  let bs := barsOf U
  for X in subsets U do
    for d in perms X do
      for Tr in subsets d do
        let pile := U.filter (fun k => !X.contains k)
        let r : Read := { okRead d pile with trusted := Tr }
        for k in U do
          let s0 := (step (State.init U) (.userEdit U [k])).1
          let s0 := if pile.isEmpty then { s0 with provenNotFull := true } else s0
          if !decide (s0.gate r) then continue
          let w := fun (_ : Unit) => s!"n={n} d={d} T={Tr} pile={pile} k={k}"
          let as := (step s0 (.read r)).2
          let fb := as.filter (fun a => d.contains a.subject && anchorMove s0 r a.subject == none)
          let helps := rowNote s0 r k == some .noMoveHelps
          if !fb.isEmpty || helps then
            let rv := s0.view r
            let ps := bs.filter (fun b => decide (Possible rv b))
            for a in fb do
              chk "W_fallback_tested" true w
              chk "W_fallback_whole" (wholeBar s0 r) w
              for b in ps do
                chk "W_fallback_bar_improves" (invOpen U (applyMove b.open_ a) < invOpen U b.open_) (fun _ => s!"b={repr b} a={repr a} {w ()}")
            if helps then
              chk "W_helps_tested" true w
              for b in ps do
                let rest := b.open_.filter (· != k)
                for i in List.range (rest.length + 1) do
                  chk "W_helps_bar" (!(invOpen U (insertAt k rest i) < invOpen U b.open_)) (fun _ => s!"b={repr b} i={i} {w ()}")
          -- the can't-judge note is shown only when the bar is not verified
          if rowNote s0 r k == some .cantJudge then chk "W_cant_unverified" (!wholeBar s0 r) w

def main (args : List String) : IO UInt32 := do
  let n := (args.head? >>= String.toNat?).getD 1500
  let (_, c) ← (do
      let mut g := 7
      for _ in [0:n] do g ← trace g
      dropOracle
      wholeOracle 4
      wholeOracle 5
      -- pure sweep with arbitrary field
      for _ in [0:n] do
        let (r, g1) := genRead.run g
        let (rc, g2) := (shuffle U4).run g1
        g := g2
        pureChecks rc r
    : T Unit).run (C.mk {} {})
  let mut bad := 0
  let l := c.m.toList.toArray.qsort (fun a b => a.1 < b.1)
  for (k, (a, b)) in l do
    IO.println s!"{k}: {a} / fail {b}"
    if b > 0 then
      bad := bad + 1
      IO.println s!"  first: {(c.ex.getD k "").take 400}"
  IO.println s!"oracle failures: {bad}"
  return (if bad > 0 then 1 else 0)
