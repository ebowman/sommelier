import Sommelier.Truth

/-!
# Sommelier decision core: what Arrange shows (status line and rows)

`statusLine` and `rowLine` are pure functions of `State` and ONE `Read`.  There is no drop memory: what the window says about the
order comes only from `shownVerdict` (the verdict of the record against the read AS THE ENGINE JUDGES IT, `Truth.lean`) and
`rowVerdict`; the only activity it adds is what the engine is doing right now (a drag in flight or decided by this read) and the
owed list.  The claims are proved in `Honesty.lean`.  The mapping to `ArrangeSections.statusLine` and `ArrangeBarState` is in
docs/verified-core.md.
-/

namespace Sommelier

/-- A drag is in flight or the read decides one. -/
def pending (s : State) (r : Read) : Bool := s.inFlight.isSome || (decideMove s r).isSome

/-- The engine will not move again on its own: the budget is spent. -/
def budgetSpent (s : State) (r : Read) : Bool := cap (fullBar s r) ≤ s.moveCount

/-- Why the bar differs and nothing is happening: `stopped` (the budget is spent), `barFull` (a hold: macOS folded items the engine
cannot unfold), or `plain` (no reason is claimed). -/
inductive Why where
  | stopped | barFull | plain
  deriving DecidableEq, Repr

/-- The bottom line of the Arrange window. -/
inductive Status where
  /-- "Moving ...": a drag is in flight or the read decides one (and only then). -/
  | moving
  /-- "Menu bar matches" -/
  | matches
  /-- "Menu bar matches except U": the keys of `U` are not read -/
  | matchesExcept (U : List Key)
  /-- the bar differs from the record, with the reason if there is one -/
  | differs (why : Why)
  /-- "Checking the menu bar ..." (cannot tell) -/
  | checking
  deriving DecidableEq, Repr

/-- THE STATUS.  `moving` leads exactly when something is pending; otherwise the verdict of the read is shown, and a `differs`
carries its reason: a spent budget (`stopped`), else a hold (`barFull`), else none. -/
def statusLine (s : State) (r : Read) : Status :=
  if pending s r then .moving
  else match shownVerdict s r with
    | .matches => .matches
    | .matchesExcept U => .matchesExcept U
    | .differs => .differs (if budgetSpent s r then .stopped else if s.hold then .barFull else .plain)
    | .cannotTell => .checking

/-- The key is the subject of the drag in flight or of the drag this read decides. -/
def movingKey (s : State) (r : Read) (k : Key) : Bool :=
  s.inFlight.any (fun a => a.subject == k) || (decideMove s r).any (fun a => a.subject == k)

/-- The key is owed (a drop whose one attempt has not left) or requested (a pull-out). -/
def owedNow (s : State) (k : Key) : Bool := s.owedKeys.contains k || s.foldRequest == some k

/-- What a record row shows. -/
inductive RowLine where
  /-- a drag of this key is in flight or decided -/
  | moving
  /-- owed or requested, and no drag of it is leaving, and either the read is not good (the gate is false) or a move of the key is queued
  but blocked (it exists, and is not the one leaving: the strip session is used, another queued key goes first, or a drag is in flight).
  On a good read where the drop needs no move this is NOT shown: the row shows its `rowVerdict` -/
  | waiting
  /-- the check mark: `rowVerdict = inOrder` -/
  | tick
  /-- the « mark: `rowVerdict = behindChevron` -/
  | behind
  /-- "not where you put it": `rowVerdict` is `outOfPlace` or `behindOutOfTurn` -/
  | notWherePut
  /-- not on the bar -/
  | notOnBar
  /-- cannot tell -/
  | cannotTell
  deriving DecidableEq, Repr

/-- The mark of a row that is neither moving nor owed: nothing but its `rowVerdict`. -/
def RowVerdict.line : RowVerdict → RowLine
  | .inOrder => .tick
  | .behindChevron => .behind
  | .outOfPlace => .notWherePut
  | .behindOutOfTurn => .notWherePut
  | .notOnBar => .notOnBar
  | .cannotTell => .cannotTell

/-- The key's drop has an answer queued that is not leaving now: the read is not good (nothing can be judged yet), or a move of the key exists
(`userMove`) and is blocked. -/
def waitingKey (s : State) (r : Read) (k : Key) : Bool := owedNow s k && (!s.gate r || (userMove s r k).isSome)

/-- One record row.  Pure in `State` and `Read`; `waiting` is true only of an owed key whose answer is not leaving (`waitingKey`), every
other mark is `rowVerdict`. -/
def rowLine (s : State) (r : Read) (k : Key) : RowLine :=
  if movingKey s r k then .moving
  else if waitingKey s r k then .waiting
  else (rowVerdict s.record (s.view r) k).line

end Sommelier
