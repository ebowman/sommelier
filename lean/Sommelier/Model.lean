/-!
# Sommelier decision core: the model

Types only: what the engine can be told (`Event`), what it can do (`Action`),
and what it remembers (`State`).  The decision function is in `Step.lean`.
macOS is an adversary: nothing here says what a read MEANS, so every theorem
quantifies over all event lists.  See docs/verified-core.md for the mapping to
the Swift engine.
-/

namespace Sommelier

/-- A menu bar item.  Identity is all the core needs. -/
abbrev Key := Nat

/-- Does the read show the « chevron? `stale` = carried from an earlier scan. -/
inductive ChevronRead where
  | fresh | stale | absent
  deriving DecidableEq, Repr

/-- How much of the agent's accessibility tree was read. -/
inductive ReadLevel where
  | complete | exceptSelfPositioning | incomplete
  deriving DecidableEq, Repr

/-- A pass read may plan; a quiet poll is evidence only (but counts toward the proof). -/
inductive ReadKind where
  | pass | poll
  deriving DecidableEq, Repr

/-- One observation of the bar (a pass read, a post-move read or a quiet poll). -/
structure Read where
  kind     : ReadKind
  chevron  : ChevronRead
  level    : ReadLevel
  /-- two agreeing scans; only settled reads may plan a move -/
  settled  : Bool
  /-- the « strip is open: the engine moves nothing -/
  stripOpen : Bool
  /-- keys macOS draws, left to right -/
  drawn    : List Key
  /-- keys hosted in the chevron's pile -/
  pile     : List Key
  /-- keys known folded but not hosted (left of the chevron's frame) -/
  folded   : List Key
  /-- keys whose position in this read is corroborated -/
  trusted  : List Key
  /-- keys in the churn zone (adversarial; supplied by the adapter): moving them may need the « strip -/
  nearFold : List Key
  deriving Repr

/-- Everything a read says is folded. -/
def Read.foldedSet (r : Read) : List Key := r.pile ++ r.folded

/-- The result of one drag.  `refused`: the actuator declined it; `busy`: the user interrupted. -/
inductive Outcome where
  | verified | failed | refused | busy
  deriving DecidableEq, Repr

/-- Where a move puts its subject.  The target is always a key, never a position. -/
inductive Rel where
  | before (t : Key)
  | after (t : Key)
  deriving DecidableEq, Repr

inductive Event where
  /-- an observation -/
  | read (r : Read)
  /-- the user placed `moved` in the new record (Arrange drop, window drag) -/
  | userEdit (record : List Key) (moved : List Key)
  /-- "Re-apply layout" -/
  | userRetry
  /-- the per-row "Try again" -/
  | retryKey (k : Key)
  /-- the drag the core asked for (of `k`) ended; `posted` = a mouse event was actually sent -/
  | moveResult (k : Key) (o : Outcome) (posted : Bool)
  /-- a regular pass starts, or the user's chain ends: nothing owed survives -/
  | passBoundary
  deriving Repr

/-- The only thing the core ever asks the world to do: ONE physical drag. -/
structure Action where
  subject : Key
  rel     : Rel
  /-- subject or target is folded, in the last fresh pile or near the fold: the drag may open the « strip -/
  strip   : Bool
  /-- the user's own move, or one the user authorised by Re-apply (exempt from hold and budget) -/
  user    : Bool
  deriving DecidableEq, Repr

structure State where
  /-- the order the user wants -/
  record : List Key
  /-- engine-initiated drags actually posted since the last user event.  Grows by one per posted engine drag
  (counted at its result); reset only by user events. -/
  moveCount : Nat
  /-- bar-level hold on every engine move -/
  hold : Bool
  /-- the folded keys when the hold was set: an edit touching them (or the current ones) releases it -/
  holdFolded : List Key
  /-- consecutive qualifying chevronless reads (only meaningful before the proof) -/
  noChevronReads : Nat
  /-- three consecutive qualifying chevronless reads were seen; any chevron revokes it -/
  provenNotFull : Bool
  /-- keys the user dropped whose one attempt is still owed (union over edits, no duplicates) -/
  owedKeys : List Key
  /-- the one folded key the user dropped right of the fold: the only key a pull-out is planned for -/
  foldRequest : Option Key
  /-- `userRetry` (Re-apply) only: authorises ONE strip session for an engine move that needs it.  `retryKey` never sets it. -/
  stripGrant : Bool
  /-- only `owedKeys` may move: the user's pass and its chain -/
  restricted : Bool
  /-- a strip session was already used by this user event -/
  editSessionUsed : Bool
  /-- folded keys of the last fresh chevron, kept through chevronless reads until the proof -/
  lastFreshPile : List Key
  /-- drawn keys of the last plannable read (settled pass read, not `incomplete`) -/
  lastDrawn : List Key
  /-- keys given up: no engine move of them until a user event -/
  givenUp : List Key
  /-- one entry per failed posted drag while the bar is proven not full (given up at three) -/
  strikes : List Key
  /-- keys whose drag was refused or interrupted before any mouse event: no engine move of them until a user event -/
  skipped : List Key
  /-- chain generation: bumped by `passBoundary` and `userRetry` (they end the owed chain) -/
  gen : Nat
  /-- set when a drag leaves: `some gen` iff its subject was owed by the CURRENT chain (never a granted move) -/
  flightOwed : Option Nat
  /-- set when a drag leaves: its subject was the fold request (a busy result re-arms the request only then, and only
  if no later request exists); cleared when a later edit moves that subject -/
  flightReq : Bool
  /-- the drag in flight (at most one); only its `moveResult` clears it -/
  inFlight : Option Action
  deriving Repr

def State.init (record : List Key) : State where
  record := record
  moveCount := 0
  hold := false
  holdFolded := []
  noChevronReads := 0
  provenNotFull := false
  owedKeys := []
  foldRequest := none
  stripGrant := false
  restricted := false
  editSessionUsed := false
  lastFreshPile := []
  lastDrawn := []
  givenUp := []
  strikes := []
  skipped := []
  gen := 0
  flightOwed := none
  flightReq := false
  inFlight := none

/-- Engine-initiated drags allowed per user event on a full bar. -/
def capFull : Nat := 3
/-- ... and on a bar proven not full. -/
def capNotFull : Nat := 20

end Sommelier
