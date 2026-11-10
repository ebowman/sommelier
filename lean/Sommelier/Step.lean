import Sommelier.Model

/-!
# Sommelier decision core: the step function

`step : State -> Event -> State x List Action`, total and computable.
Read it top to bottom: evidence, who may move, what move, then the event cases.
-/

namespace Sommelier

/-! ### Evidence: is the bar full? -/

/-- FULL until proven otherwise; any chevron in the read makes it full. -/
def fullBar (s : State) (r : Read) : Bool := !s.provenNotFull || r.chevron != .absent

def cap (full : Bool) : Nat := if full then capFull else capNotFull

/-- Fold what a read shows into the state (pass reads and polls alike, settled or not).
Never touches the budget or the record. -/
def noteRead (s : State) (r : Read) : State :=
  let s := if r.kind == .pass && r.settled && r.level != .incomplete then { s with lastDrawn := r.drawn } else s
  -- only a settled, readable, strip-closed read with a fresh chevron REPLACES the pile; any other chevron read adds to it
  let union := s.lastFreshPile ++ r.foldedSet.filter (fun k => !s.lastFreshPile.contains k)
  let c : State :=
    match r.chevron with
    | .fresh =>
        { s with provenNotFull := false, noChevronReads := 0,
                 lastFreshPile := if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet else union }
    | .stale => { s with provenNotFull := false, noChevronReads := 0, lastFreshPile := union }
    | .absent =>
        if s.provenNotFull then s
        else if r.level == .incomplete || !r.observed then { s with noChevronReads := 0 }   -- a non-observation is no evidence: it resets the count
        else if r.kind == .pass && !r.settled then s   -- an unsettled COMPLETE pass read is not evidence either way (Swift: it ends before noteChevronEvidence): no count, no reset
        -- WHEN THE PROOF TAKES EFFECT (Swift `noteChevronEvidence` :1855-1865, `notePollScan` :1871-1883).  `noChevronReads` counts the
        -- chevronless complete reads and may REACH 3 without effect: Swift's `notFullProven` is exactly `noChevronReads >= 3` while the bar is
        -- still full.  A PASS read that reaches 3 only arms the proof; the NEXT settled chevronless pass read flips `fullBarState` (here:
        -- `provenNotFull`) and clears hold and pile, if nothing reset the count in between (a chevron, an incomplete read).  A quiet POLL that
        -- reaches 3 flips at once (docs/architecture.md rule 2).  A poll that finds the count already at 3 flips at once too.
        else if (if r.kind == .pass then 3 else 2) <= s.noChevronReads then
          { s with provenNotFull := true, noChevronReads := 0, hold := false, lastFreshPile := [] }
        else { s with noChevronReads := s.noChevronReads + 1 }
  c

/-- The reading is a usable witness of the bar: a settled pass read of a readable tree that observed a bar, strip closed, and either
a FRESH chevron (one reading suffices) or NO chevron with the proof that the bar is not full (three complete readings in a row
without one: D1).  A stale chevron is not usable.  Holds at the levels `complete` and `exceptSelfPositioning`. -/
def Read.usable (r : Read) : Prop :=
  r.kind = .pass ∧ r.settled = true ∧ r.level ≠ .incomplete ∧ r.observed = true ∧ r.stripOpen = false ∧
    (r.chevron = .fresh ∨ (r.chevron = .absent ∧ r.notFullProven = true))

instance (r : Read) : Decidable r.usable := by unfold Read.usable; infer_instance

/-! ### Which keys may move, and does a move need the « strip? -/

/-- Everything that counts as folded for planning.  A USABLE fresh-chevron read is itself the witness of the pile: what is folded is exactly what
THIS read lists (`r.foldedSet`), and it supersedes the memory (`noteRead` replaces `lastFreshPile` by it on the same read), so a key the memory
still holds but this read shows drawn is judged as drawn.  On any other read: this read's pile and folded keys and the last fresh pile. -/
def foldedAll (s : State) (r : Read) : List Key :=
  if r.usable ∧ r.chevron = .fresh then r.foldedSet else r.foldedSet ++ s.lastFreshPile

/-- Drawn, trusted, not folded: the only keys a planned move may name, as subject or target. -/
def movable (s : State) (r : Read) : List Key :=
  r.drawn.filter (fun k => r.trusted.contains k && !(foldedAll s r).contains k)

def Rel.target : Rel → Key
  | .before t => t
  | .after t => t

/-- The drag touches a folded key or one in the churn zone: macOS may open the « strip. -/
def needsStrip (s : State) (r : Read) (subject : Key) (rel : Rel) : Bool :=
  let f := foldedAll s r ++ r.nearFold
  f.contains subject || f.contains rel.target

/-! ### Planning (the order planner is a stub: the first inversion) -/

/-- First position where the wanted order and the drawn order differ: (wanted key, drawn key there). -/
def firstInversion : List Key → List Key → Option (Key × Key)
  | w :: ws, h :: hs => if w == h then firstInversion ws hs else some (w, h)
  | _, _ => none

/-- Engine order move: put the first out-of-place key before the key now in its slot.
Never a given-up or skipped subject. -/
def planOrderMoves (s : State) (r : Read) : Option Action :=
  let hv := (movable s r).filter (fun k => s.record.contains k)
  match firstInversion (s.record.filter (fun k => hv.contains k)) hv with
  | some (w, h) =>
      if s.givenUp.contains w || s.skipped.contains w then none
      else some ⟨w, .before h, needsStrip s r w (.before h), false⟩
  | none => none

/-- Apply a drag to a list of keys: the subject leaves its place and re-enters next to the target (if the target is present). -/
def applyMove (l : List Key) (a : Action) : List Key :=
  let l' := l.filter (fun x => x != a.subject)
  if !l'.contains a.rel.target then l
  else l'.flatMap fun x =>
    if x == a.rel.target then (match a.rel with | .before _ => [a.subject, x] | .after _ => [x, a.subject]) else [x]

/-- `l` has a prefix whose key set equals `want` (as a set): the smallest such prefix length. -/
def prefixFor (want : List Key) (l : List Key) : Option Nat :=
  (List.range (l.length + 1)).find? fun i =>
    (l.take i).all (fun a => want.contains a) && want.all (fun a => (l.take i).contains a)

/-- The ANCHOR rule for a movable `k`.  Anchors are the movable keys of the record that are not owed (every OTHER still-owed key is pinned out; a key already
SERVED is an ordinary anchor and may be a target).  `k` is RIGHT when exactly the anchors that precede it in the record precede it on the bar.  Otherwise it goes to the
first gap, in DRAWN order, whose preceding anchors are exactly those: right after the last anchor of that gap, or before the first anchor if the gap is empty.
If no gap satisfies the test (anchors out of record order) there is no move (and `fallbackMove` is asked). -/
def anchorMove (s : State) (r : Read) (k : Key) : Option Action :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩
  let anchors := hv.filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a)
  let want := before.filter (fun a => anchors.contains a)
  let seen := (hv.filter (fun a => a == k || anchors.contains a)).takeWhile (fun x => x != k)
  if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none
  else match prefixFor want anchors with
    | none => none
    | some i =>
        match (anchors.take i).getLast? with
        | some p => some (mk (.after p))
        | none => anchors.head?.map (fun t => mk (.before t))

/-- `k` is out of place among ALL the movable keys of the record (owed ones included): some such key `x` stands before `k` in the record and after it on the bar, or
the other way round. -/
def misplaced (s : State) (r : Read) (k : Key) : Bool :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  let seen := hv.takeWhile (fun x => x != k)
  hv.any (fun x => x != k && s.record.contains x && (before.contains x != seen.contains x))

/-- Inversions (pairs in the wrong order against the record) in a list of keys. -/
def invs (rec : List Key) : List Key → Nat
  | [] => 0
  | x :: xs => (xs.filter (fun y => decide (rec.idxOf y < rec.idxOf x))).length + invs rec xs

/-- The inversions among the MOVABLE RECORD keys of the bar `l` (the keys a drag may name, as subject or target). -/
def invCount (s : State) (r : Read) (l : List Key) : Nat :=
  invs s.record (l.filter (fun x => (movable s r).contains x && s.record.contains x))

/-- Where the fallback puts `k` when two places tie: just after `k`'s nearest movable record predecessor; if it has none, just before the first movable key that
follows `k` in the record. -/
def fallbackRel (s : State) (r : Read) (k : Key) : Option Rel :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  match (before.filter (fun x => hv.contains x)).getLast? with
  | some p => some (.after p)
  | none => ((s.record.dropWhile (fun x => x != k)).tail.find? (fun x => x != k && hv.contains x)).map Rel.before

/-- Every single drag of `k` the engine may make: next to a movable record key other than `k`, on either side.  The tie-break place comes first. -/
def fallbackCands (s : State) (r : Read) (k : Key) : List Rel :=
  (fallbackRel s r k).toList ++
    ((movable s r).filter (fun t => t != k && s.record.contains t)).flatMap (fun t => [Rel.before t, Rel.after t])

/-- The first minimum of `f` over a list. -/
def argmin (f : Rel → Nat) (l : List Rel) : Option Rel :=
  l.foldl (fun acc x => match acc with
    | none => some x
    | some b => if f x < f b then some x else acc) none

/-- The inversion count of the bar after dragging `k` by `rel`. -/
def afterCount (s : State) (r : Read) (k : Key) (rel : Rel) : Nat :=
  invCount s r (applyMove r.drawn ⟨k, rel, false, true⟩)

/-- THE READ VERIFIES THE WHOLE BAR (for the record's keys).  Every record key that the read lists anywhere (drawn, in the pile, folded or unread) is either movable (drawn,
trusted, not counted as folded: its place in the open order is corroborated) or listed folded under a FRESH chevron (pinned behind the « by A2: it is not open, so it takes no
part in the order of the open keys and a fallback drag never names it).  A drawn record key that is untrusted, an unread record key, and a pile or folded record key under a chevron that
is not fresh all FAIL the condition: they could sit anywhere among the open keys, so no drag can be judged against them.  Record keys the read lists nowhere are not on the bar
and never make the condition false (`wholeBar_unlisted`). -/
def wholeBar (s : State) (r : Read) : Bool :=
  s.record.all (fun x =>
    !(r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) ||
    (movable s r).contains x || (r.chevron == .fresh && r.foldedSet.contains x))

/-- THE FREE RECORD KEYS: the record keys that could stand ANYWHERE among the open keys of some possible bar.  Each is listed by the read (drawn, in the pile, folded or unread:
a key listed nowhere is not on the bar), is not movable (so its place is not corroborated), and is not pinned behind a fresh chevron (so it may be open).  `wholeBar` is exactly "there is none"
(`wholeBar_iff_free`). -/
def freeKeys (s : State) (r : Read) : List Key :=
  s.record.filter (fun x =>
    (r.drawn.contains x || r.pile.contains x || r.folded.contains x || r.unread.contains x) &&
    !(movable s r).contains x && !(r.chevron == .fresh && r.foldedSet.contains x))

/-- The drag of `k` by `rel` moves `k` toward the front of the bar: its target stands before `k` in the order the read draws. -/
def leftward (r : Read) (k : Key) (rel : Rel) : Bool := decide (r.drawn.idxOf rel.target < r.drawn.idxOf k)

/-- THE WORST CASE THE FREE KEYS CAN ADD.  A free record key `y` may stand between `k` and the place the drag takes it to, on some possible bar, and then the drag crosses it.  Crossing `y` raises the
inversions by one when the drag moves `k` forward and `y` is before `k` in the record (`k` is put ahead of a key that should be ahead of it), or moves `k` backward and `y` is after `k` in the record; otherwise
it lowers them by one or leaves them.  `penalty` counts the free keys whose crossing would raise them: the most the free keys can add on any possible bar. -/
def penalty (s : State) (r : Read) (k : Key) (rel : Rel) : Nat :=
  ((freeKeys s r).filter (fun y =>
    if leftward r k rel then decide (s.record.idxOf y < s.record.idxOf k) else decide (s.record.idxOf k < s.record.idxOf y))).length

/-- The most inversions among the open record keys that the drag can leave on a possible bar, in excess of what the corroborated keys show: the inversions of the movable record keys after the drag
plus the free keys' worst case.  Equal to `afterCount` when the read verifies the whole bar (`penalty_wholeBar`). -/
def worstCount (s : State) (r : Read) (k : Key) (rel : Rel) : Nat := afterCount s r k rel + penalty s r k rel

/-- THE FALLBACK for an OWED movable `k` that is `misplaced`, when the anchor rule gave no move (the other owed keys are not anchors, or the anchors have no gap).  Among ALL single drags of `k`
(`fallbackCands`: next to a movable record key, on either side) it takes the one with the lowest `worstCount` (the inversions among the movable record keys after the drag, plus the most the free keys can
add: `penalty`), ties to the place nearest `k`'s record predecessor (`fallbackRel` is tried first and only a strictly lower count replaces it), and it fires ONLY if that worst case is STRICTLY lower than
the inversions of the movable record keys now.  Then the drag strictly lowers the record inversions of EVERY possible bar (`fallback_improves_bar`), whether or not the read verifies the whole bar; the rule picks
the best drag by that worst case, not the drag that is best on some particular bar.  When the read verifies the whole bar (`wholeBar`) there is no free key and this is the rule of ejb.10.  Otherwise there
is no drag (`NoReducingDrag`, or some drag could improve the bar but not on every possible bar). -/
def fallbackMove (s : State) (r : Read) (k : Key) : Option Action :=
  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩
  if s.owedKeys.contains k && s.record.contains k && (movable s r).contains k && misplaced s r k then
    ((argmin (worstCount s r k) (fallbackCands s r k)).map mk).filter (fun a => decide (worstCount s r k a.rel < invCount s r r.drawn))
  else none

/-- The user's own move of an owed key `k`.  A drawn `k` gets the anchor rule's move, or, when that gives none, the fallback.
A folded `k` is pulled out only if it is the fold request or owed, the chevron is fresh and THIS read lists `k` as folded, to just after the
rightmost drawn key that precedes it in the record (unless that changes nothing). -/
def userMove (s : State) (r : Read) (k : Key) : Option Action :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩
  if (foldedAll s r).contains k then
    -- a pull-out is licensed by the key being OWED (the user dropped it; `foldRequest` is only the priority hint) and THIS read listing it as folded
    -- (`r.foldedSet`) with a fresh chevron; the pile memory alone (`lastFreshPile`) never licenses a drag, and a folded key the user did not drop never gets one
    if (s.foldRequest == some k || s.owedKeys.contains k) && r.chevron == .fresh && r.foldedSet.contains k then
      (((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))).filter
        (fun a => applyMove r.drawn a != r.drawn)
    else none
  else if hv.contains k then
    match anchorMove s r k with
    | some a => some a
    | none => fallbackMove s r k
  else none

/-- PHASE ONE of the user's queue: the move of `k` by the anchor rule or the licensed pull-out (exactly `userMove` without the fallback). -/
def userMove1 (s : State) (r : Read) (k : Key) : Option Action :=
  if (foldedAll s r).contains k then userMove s r k
  else if (movable s r).contains k then anchorMove s r k
  else none

/-- PHASE TWO: the fallback of a drawn key that has no phase-one move. -/
def userMove2 (s : State) (r : Read) (k : Key) : Option Action :=
  if (userMove1 s r k).isNone && !(foldedAll s r).contains k && (movable s r).contains k then fallbackMove s r k else none

/-- A user's move that may open the strip waits once this edit's session is used, and while the strip is open. -/
def userAllowed (s : State) (r : Read) (a : Action) : Bool := !(a.strip && (s.editSessionUsed || r.stripOpen))

/-! ### The gate on every decision (ejb.3 truth statements, D1 and D2)

Every move, the user's drop included, waits for a USABLE reading of a bar that some honest macOS could have drawn.  The definitions
are the ones `Truth.lean` states its theorems with. -/

/-- Drawn keys whose position the scanner corroborated (duplicates kept: a read listing a key twice is self-contradictory). -/
def Read.trustedDrawn (r : Read) : List Key := r.drawn.filter (fun k => r.trusted.contains k)

/-- Keys the reading pins open (usable reads only): trusted drawn keys. -/
def Read.pinOpen (r : Read) : List Key := if r.usable then r.trustedDrawn else []

/-- Keys the reading pins behind: pile and folded keys of a usable fresh-chevron read. -/
def Read.pinBehind (r : Read) : List Key := if r.usable ∧ r.chevron = .fresh then r.foldedSet else []

/-- The reading contradicts itself (a pinned key twice, or both open and behind): no bar is honest. -/
def Read.consistent (r : Read) : Bool := r.pinOpen.Nodup && r.pinOpen.all (fun k => !r.pinBehind.contains k)

/-- The reading as `step` judges it: the proof is the ENGINE'S OWN, `provenNotFull` of the state BEFORE this read (`step` decides on `s`, not on
`noteRead s r`): a proof gained by this read's `noteRead` takes effect from the next read, and a pass read that only armed the proof
(`noChevronReads` = 3) flips it on the next pass read, which still decides under the old state.  Equal to `r` when the adapter's field agrees
(`view_of_agree`). -/
def State.view (s : State) (r : Read) : Read := { r with notFullProven := s.provenNotFull }

/-- The one gate: usable and consistent (some honest bar exists). -/
def State.gate (s : State) (r : Read) : Bool := decide (s.view r).usable && (s.view r).consistent

/-- May the ENGINE (not the user) move anything on this read? -/
def engineAllowed (s : State) (r : Read) : Bool :=
  !s.restricted && !s.hold && r.chevron != .stale && !r.stripOpen && s.moveCount < cap (fullBar s r)

/-- The user's queue, in two phases.  FIRST every queued key by the anchor rule and the licensed pull-out (the fold request first, then the owed keys);
only if none of them yields an allowed move, the fallback in queue order. -/
def userPick (s : State) (r : Read) : Option Action :=
  match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove1 s r k).filter (userAllowed s r)) with
  | some a => some a
  | none => (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove2 s r k).filter (userAllowed s r))

/-- One strike for `k` (given up at the third).  The strike of a failed drag on a bar proven not full, and of a verified drag the next read finds undone (ejb.17). -/
def markStrike (s0 : State) (k : Key) : State :=
  let n := (s0.strikes.filter (fun x => x == k)).length + 1
  { s0 with strikes := k :: s0.strikes,
            givenUp := if n >= 3 && !s0.givenUp.contains k then k :: s0.givenUp else s0.givenUp }

def markFail (s0 : State) (k : Key) : State :=
  -- a failed posted drag on a bar not proven not-full holds the bar and gives the key up
  if s0.provenNotFull then
    markStrike s0 k
  else
    { s0 with hold := true, holdFolded := s0.lastFreshPile,
              givenUp := if s0.givenUp.contains k then s0.givenUp else k :: s0.givenUp }

/-- ejb.17.  The key `k` is STILL OUT OF PLACE on this read: movable (drawn, trusted, not folded), in the record, and some movable record key stands on the
wrong side of it (`misplaced`).  A correctly executed engine move of `k` puts it right among every movable record key, so this is exactly "the move did not take". -/
def stillMisplaced (s : State) (r : Read) (k : Key) : Bool :=
  (movable s r).contains k && s.record.contains k && misplaced s r k

/-- ejb.26.  The read shows `k` on the WRONG side of the key `rel` names, among the movable keys: the drag put `k` `rel` that key, and now it is not.  Only the placement of
`k` against ITS OWN anchor counts: it looks at the movable keys `k` and the anchor alone (`two`, in the order the read draws them), so a record key `y` that macOS moves across `k`
changes nothing here unless `y` is the anchor itself (`crossing_keeps_verdict`).  A target the read does not show movable cannot be judged: no verdict, so no strike. -/
def revertedFromAnchor (s : State) (r : Read) (k : Key) (rel : Rel) : Bool :=
  let two := (movable s r).filter (fun x => x == k || x == rel.target)
  match rel with
  | .before t => two == [t, k]
  | .after t => two == [k, t]

/-- ejb.26.  THE VERIFIED DRAG OF `k` DID NOT TAKE: `k` is still out of place (`stillMisplaced`) AND it stands on the wrong side of the anchor the drag put it next to. -/
def verFailed (s : State) (r : Read) (k : Key) : Bool :=
  stillMisplaced s r k && revertedFromAnchor s r k s.verRel

/-- ejb.17.  THE READ JUDGES THE LAST VERIFIED ENGINE MOVE.  Applies only to a usable, consistent read (`gate`) with no drag in flight.  If the pending key's own drag did not take (`verFailed`: still
misplaced and on the wrong side of its anchor), it takes a strike (`markStrike`: given up at the third, on ANY bar: a verified drag the read contradicts is not evidence that the bar is full, so it
never holds the bar, unlike a failed drag on a bar not proven not full); otherwise the pending marker is simply cleared.  It runs BEFORE the read decides, so a repeat of the contradicted drag is never planned from a read that already struck out the key.
Other reads (unsettled, strip open, polls, unusable) leave the marker. -/
def judge (s : State) (r : Read) : State :=
  match s.verified with
  | none => s
  | some k =>
      if s.inFlight.isNone && s.gate r then
        (if verFailed s r k then markStrike { s with verified := none } k else { s with verified := none })
      else s

/-- The one decision per read: at most one move.  Only a settled pass read with a readable tree may plan.
Owed user moves first (the fold request, then the rest), then the engine's; an engine move that needs the
strip is withheld unless Re-apply granted a session. -/
def decideMove0 (s : State) (r : Read) : Option Action :=
  if r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome || !s.gate r then none
  else
    match userPick s r with
    | some a => some a
    | none =>
      if !engineAllowed s r then none
      else match planOrderMoves s r with
        | some a =>
            if a.strip then
              (if s.stripGrant then some { a with user := true } else none)
            else some a
        | none => none

/-- THE DECISION OF A READ (ejb.17): the read first judges the last verified engine move (`judge`), then decides on the judged state. -/
def decideMove (s : State) (r : Read) : Option Action := decideMove0 (judge s r) r

/-- Bookkeeping for a move that leaves now.  (The budget is counted at the result, when the drag is known posted.) -/
def emit (s : State) (a : Action) : State :=
  let granted := a.strip && !s.owedKeys.contains a.subject
  { s with inFlight := some a, flightOwed := if s.owedKeys.contains a.subject then some s.gen else none,
           flightReq := s.foldRequest == some a.subject,
           owedKeys := s.owedKeys.erase a.subject,
           foldRequest := if s.foldRequest == some a.subject then none else s.foldRequest,
           editSessionUsed := s.editSessionUsed || a.strip,
           stripGrant := if granted then false else s.stripGrant }

/-! ### The step -/

/-- The result of the in-flight drag `a`.  The budget counts only POSTED engine drags (a count that never
decreases).  A drag with no mouse event is not an attempt: its key is `skipped` (no engine move of it until a
user event), the strip session is returned, and a user's interrupted drag (`busy`) is re-armed ONCE.
-/
def result (s : State) (a : Action) (o : Outcome) (posted : Bool) : State :=
  let s0 := { s with inFlight := none, moveCount := s.moveCount + (if posted && !a.user then 1 else 0),
                     -- ejb.17: a verified posted ENGINE drag is judged by the next usable read; every other result leaves nothing to judge
                     verified := if posted && !a.user && o == .verified then some a.subject else none,
                     verRel := a.rel }
  let core : State :=
    if posted then
      match o with
      | .failed => markFail s0 a.subject
      | _ => s0
    else
      -- no mouse event (even a "verified" one): not an attempt, never re-planned by the engine until a user event
      let was := s0.skipped.contains a.subject
      let s1 := { s0 with editSessionUsed := if a.strip then false else s0.editSessionUsed,
                          skipped := if was then s0.skipped else a.subject :: s0.skipped }
      -- a user's interrupted drag is re-armed ONCE, and only if the CURRENT chain owed it (never a granted move)
      if o == .busy && s0.flightOwed == some s0.gen && !was && s0.record.contains a.subject then
        { s1 with owedKeys := (a.subject :: s1.owedKeys).eraseDups,
                  foldRequest := if s0.flightReq && s1.foldRequest.isNone then some a.subject else s1.foldRequest }
      else s1
  core

def step (s : State) : Event → State × List Action
  | .read r =>
      let s' := noteRead (judge s r) r
      match decideMove s r with
      | none => (s', [])
      | some a => (emit s' a, [a])
  | .userEdit rec moved =>
      if moved.isEmpty then
        ({ s with
            verified := none,   -- ejb.26: ANY record change clears the mark (the read can no longer say whether the drag took)
            record := rec, owedKeys := s.owedKeys.filter (fun k => rec.contains k),
            foldRequest := s.foldRequest.filter (fun k => rec.contains k),
            -- a reorder can invalidate the in-flight pull-out: a busy result must not re-arm it
            flightReq := s.flightReq && rec == s.record }, [])
      else
        let owed := (s.owedKeys ++ rec.filter (fun k => moved.contains k)).eraseDups.filter (fun k => rec.contains k)
        -- `pull` is a PRIORITY HINT (the fold request is served first): the answer to a drop does not need it, `userMove` licenses a pull-out from the key being
        -- owed and THIS read listing it folded.  A pull-out hint is asked for only for a key folded NOW with a drawn key before it in the record; first such key only; it REPLACES an earlier request (T3)
        -- a later edit that moves the in-flight key clears `flightReq` (T5: the busy result must not re-arm a stale pull-out)
        let pull := rec.find? (fun k => moved.contains k && s.lastFreshPile.contains k
                                 && (rec.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x))
        let release := moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)
        ({ s with
            verified := none,   -- ejb.26: ANY record change clears the mark (ejb.17 cleared only the moved keys')
            record := rec, moveCount := 0, restricted := true, editSessionUsed := false,
            owedKeys := owed,
            foldRequest := match pull with
            | some p => some p
            | none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),
            hold := s.hold && !release,
            flightReq := s.flightReq && !(s.inFlight.any (fun (a : Action) => moved.contains a.subject)),
            skipped := [],
            strikes := s.strikes.filter (fun k => !moved.contains k),
            givenUp := s.givenUp.filter (fun k => !moved.contains k) }, [])
  | .userRetry =>
      ({ s with
            verified := none,
            moveCount := 0, hold := false, givenUp := [], strikes := [], skipped := [],
            restricted := false, owedKeys := [], foldRequest := none, stripGrant := true, gen := s.gen + 1,
            editSessionUsed := false }, [])
  | .retryKey k =>
      -- (a priority hint only, as in `userEdit`: not needed for the answer)
      let pull := s.record.contains k && s.lastFreshPile.contains k && (s.record.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x)
      ({ s with
            verified := s.verified.filter (fun x => x != k),
            moveCount := 0, hold := false, givenUp := s.givenUp.erase k,
            strikes := s.strikes.filter (fun x => x != k), skipped := [], restricted := true,
            editSessionUsed := false,
            owedKeys := (k :: s.owedKeys).eraseDups.filter (fun x => s.record.contains x),
            foldRequest := if pull then some k else s.foldRequest,
            -- the pull-out is recomputed for k: an in-flight drag of k no longer stands for the request
            flightReq := s.flightReq && !(s.inFlight.any (fun (a : Action) => a.subject == k)) }, [])
  | .moveResult k o posted =>
      match s.inFlight with
      | some a => if a.subject == k then (result s a o posted, []) else (s, [])
      | none => (s, [])
  | .passBoundary =>
      ({ s with
            restricted := false, owedKeys := [], foldRequest := none, stripGrant := false, gen := s.gen + 1 }, [])

/-- Fold `step` over an event list; all actions in order. -/
def run (s : State) : List Event → State × List Action
  | [] => (s, [])
  | e :: es =>
      let (s1, a1) := step s e
      let (s2, a2) := run s1 es
      (s2, a1 ++ a2)

end Sommelier
