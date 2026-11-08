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
  match r.chevron with
  | .fresh =>
      { s with provenNotFull := false, noChevronReads := 0,
               lastFreshPile := if r.settled && r.level != .incomplete && !r.stripOpen then r.foldedSet else union }
  | .stale => { s with provenNotFull := false, noChevronReads := 0, lastFreshPile := union }
  | .absent =>
      if s.provenNotFull then s
      else if r.level == .incomplete then { s with noChevronReads := 0 }
      else if s.noChevronReads + 1 >= 3 then
        { s with provenNotFull := true, noChevronReads := 0, hold := false, lastFreshPile := [] }
      else { s with noChevronReads := s.noChevronReads + 1 }

/-! ### Which keys may move, and does a move need the « strip? -/

/-- Everything that counts as folded for planning: this read's pile and folded keys and the last fresh pile. -/
def foldedAll (s : State) (r : Read) : List Key := r.foldedSet ++ s.lastFreshPile

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

/-- The user's own move of an owed key `k`.  Every OTHER still-owed key is pinned; a key already SERVED is an
ordinary anchor (and may be a target).  Anchors are the movable keys of the record that are not owed.
A drawn `k` is RIGHT when exactly the anchors that precede it in the record precede it on the bar.  Otherwise it goes to the
first gap, in DRAWN order, whose preceding anchors are exactly those: right after the last anchor of that gap, or before the first
anchor if the gap is empty.  If no gap satisfies the test (anchors out of record order) there is no move; the drag then never changes nothing
(fuzz-checked: `noop_user`).  A folded `k` is pulled out only if it is the fold request and the chevron is fresh, to just after the
rightmost drawn key that precedes it in the record (unless that changes nothing). -/
def userMove (s : State) (r : Read) (k : Key) : Option Action :=
  let hv := movable s r
  let before := s.record.takeWhile (fun x => x != k)
  let mk (rel : Rel) : Action := ⟨k, rel, needsStrip s r k rel, true⟩
  if (foldedAll s r).contains k then
    if s.foldRequest == some k && r.chevron == .fresh then
      (((hv.filter (fun x => before.contains x)).getLast?).map (fun p => mk (.after p))).filter
        (fun a => applyMove r.drawn a != r.drawn)
    else none
  else if hv.contains k then
    let anchors := hv.filter (fun a => a != k && s.record.contains a && !s.owedKeys.contains a)
    let want := before.filter (fun a => anchors.contains a)
    let seen := (hv.filter (fun a => a == k || anchors.contains a)).takeWhile (fun x => x != k)
    if seen.all (fun a => want.contains a) && want.all (fun a => seen.contains a) then none
    else match prefixFor want anchors with
      | none => none
      | some i =>
          let a? := match (anchors.take i).getLast? with
            | some p => some (mk (.after p))
            | none => anchors.head?.map (fun t => mk (.before t))
          a?
  else none

/-- A user's move that may open the strip waits once this edit's session is used, and while the strip is open. -/
def userAllowed (s : State) (r : Read) (a : Action) : Bool := !(a.strip && (s.editSessionUsed || r.stripOpen))

/-- May the ENGINE (not the user) move anything on this read? -/
def engineAllowed (s : State) (r : Read) : Bool :=
  !s.restricted && !s.hold && r.chevron != .stale && !r.stripOpen && s.moveCount < cap (fullBar s r)

/-- The one decision per read: at most one move.  Only a settled pass read with a readable tree may plan.
Owed user moves first (the fold request, then the rest), then the engine's; an engine move that needs the
strip is withheld unless Re-apply granted a session. -/
def decideMove (s : State) (r : Read) : Option Action :=
  if r.kind != .pass || !r.settled || r.level == .incomplete || s.inFlight.isSome then none
  else
    match (s.foldRequest.toList ++ s.owedKeys).findSome? (fun k => (userMove s r k).filter (userAllowed s r)) with
    | some a => some a
    | none =>
      if !engineAllowed s r then none
      else match planOrderMoves s r with
        | some a =>
            if a.strip then
              (if s.stripGrant then some { a with user := true } else none)
            else some a
        | none => none

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
user event), the strip session is returned, and a user's interrupted drag (`busy`) is re-armed ONCE. -/
def result (s : State) (a : Action) (o : Outcome) (posted : Bool) : State :=
  let s0 := { s with inFlight := none, moveCount := s.moveCount + (if posted && !a.user then 1 else 0) }
  if posted then
    match o with
    | .failed =>
        -- a failed posted drag on a bar not proven not-full holds the bar and gives the key up
        if s0.provenNotFull then
          let n := (s0.strikes.filter (fun x => x == a.subject)).length + 1
          { s0 with strikes := a.subject :: s0.strikes,
                    givenUp := if n >= 3 && !s0.givenUp.contains a.subject then a.subject :: s0.givenUp else s0.givenUp }
        else
          { s0 with hold := true, holdFolded := s0.lastFreshPile,
                    givenUp := if s0.givenUp.contains a.subject then s0.givenUp else a.subject :: s0.givenUp }
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

def step (s : State) : Event → State × List Action
  | .read r =>
      let s' := noteRead s r
      match decideMove s r with
      | none => (s', [])
      | some a => (emit s' a, [a])
  | .userEdit rec moved =>
      if moved.isEmpty then
        ({ s with record := rec, owedKeys := s.owedKeys.filter (fun k => rec.contains k),
                  foldRequest := s.foldRequest.filter (fun k => rec.contains k),
                  -- a reorder can invalidate the in-flight pull-out: a busy result must not re-arm it
                  flightReq := s.flightReq && rec == s.record }, [])
      else
        let owed := (s.owedKeys ++ rec.filter (fun k => moved.contains k)).eraseDups.filter (fun k => rec.contains k)
        -- a pull-out is asked for only for a key folded NOW with a drawn key before it in the record; first such key only; it REPLACES an earlier request (T3)
        -- a later edit that moves the in-flight key clears `flightReq` (T5: the busy result must not re-arm a stale pull-out)
        let pull := rec.find? (fun k => moved.contains k && s.lastFreshPile.contains k
                                 && (rec.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x))
        let release := moved.any (fun k => s.holdFolded.contains k || s.lastFreshPile.contains k)
        ({ s with record := rec, moveCount := 0, restricted := true, editSessionUsed := false,
                  owedKeys := owed,
                  foldRequest := match pull with
                    | some p => some p
                    | none => s.foldRequest.filter (fun k => !moved.contains k && rec.contains k),
                  hold := s.hold && !release,
                  flightReq := s.flightReq && !(s.inFlight.any (fun a => moved.contains a.subject)),
                  skipped := [],
                  strikes := s.strikes.filter (fun k => !moved.contains k),
                  givenUp := s.givenUp.filter (fun k => !moved.contains k) }, [])
  | .userRetry =>
      ({ s with moveCount := 0, hold := false, givenUp := [], strikes := [], skipped := [],
                restricted := false, owedKeys := [], foldRequest := none, stripGrant := true, gen := s.gen + 1,
                editSessionUsed := false }, [])
  | .retryKey k =>
      let pull := s.record.contains k && s.lastFreshPile.contains k && (s.record.takeWhile (fun x => x != k)).any (fun x => s.lastDrawn.contains x)
      ({ s with moveCount := 0, hold := false, givenUp := s.givenUp.erase k,
                strikes := s.strikes.filter (fun x => x != k), skipped := [], restricted := true,
                editSessionUsed := false,
                owedKeys := (k :: s.owedKeys).eraseDups.filter (fun x => s.record.contains x),
                foldRequest := if pull then some k else s.foldRequest,
                -- the pull-out is recomputed for k: an in-flight drag of k no longer stands for the request
                flightReq := s.flightReq && !(s.inFlight.any (fun a => a.subject == k)) }, [])
  | .moveResult k o posted =>
      match s.inFlight with
      | some a => if a.subject == k then (result s a o posted, []) else (s, [])
      | none => (s, [])
  | .passBoundary =>
      ({ s with restricted := false, owedKeys := [], foldRequest := none, stripGrant := false, gen := s.gen + 1 }, [])

/-- Fold `step` over an event list; all actions in order. -/
def run (s : State) : List Event → State × List Action
  | [] => (s, [])
  | e :: es =>
      let (s1, a1) := step s e
      let (s2, a2) := run s1 es
      (s2, a1 ++ a2)

end Sommelier
