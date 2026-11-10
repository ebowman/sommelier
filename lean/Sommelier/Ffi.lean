import Sommelier.Status
import Sommelier.Fast
import Sommelier.Adopt
import Sommelier.GestureDef

/-!
# C boundary: the thin exports the Swift app links

The app holds an opaque `State` and sends flat `Nat` token lists (the C shim turns `UInt32` words into `Nat`s).  Every export only
DECODES its input, calls the PROVED function (`step`, `statusLine`, `rowLine`, `shownVerdict`, `rowVerdict`, `rowNote`, `adoptProposal`, `applyGesture`), and ENCODES the answer.
No decision is made here.  This file adds no definition to any other module.

The exports call the FAST versions of `Fast.lean` (`stepF`, `statusLineF`, `shownVerdictF`, `rowLineF`, `rowVerdictF`); each is PROVED EQUAL to the specification
(`stepF_eq`, ...), and below `stepTokF = stepTok` etc. say the same of the token functions, so every wrapper theorem about the specification is a theorem
about what the export computes.  (The specification takes 22-45 ms to `step` a 36-key record; see docs/verified-core.md.)

Protocol.  An input that does not decode is never given a default: the export answers the single word `[errTag]` (and `step` leaves
the state unchanged).  A decoded input is answered `okTag :: payload`.  `okTag ≠ errTag`, so the two cannot be confused.

Proved below, for EVERY boundary type, in both directions as used:
* inputs: `dec (enc x) = some x` for `Event` (hence `Read`, `Outcome`, `Bool`), record/key lists, and the row key;
* outputs: the same for `List Action` (hence `Action`, `Rel`), `Status` (hence `Why`), `Verdict`, `RowLine`, `RowVerdict`;
* the wrappers: on an encoded input they answer exactly the encoding of the proved function's value; on an input that does not decode
  they answer `[errTag]`.
-/
namespace Sommelier.Ffi
open Sommelier

/-! ## Words -/

def okTag : Nat := 0
def errTag : Nat := 1

/-- the answer to an input that did not decode -/
def errAns : List Nat := [errTag]
def okAns (payload : List Nat) : List Nat := okTag :: payload

theorem ok_ne_err (p : List Nat) : okAns p ≠ errAns := by simp [okAns, errAns, okTag, errTag]

def b (x : Bool) : Nat := if x then 1 else 0
def ub : Nat → Option Bool | 0 => some false | 1 => some true | _ => none

theorem ub_b (x : Bool) : ub (b x) = some x := by cases x <;> rfl

/-! ## Length-prefixed key lists (records, `moved`, the read's key sets) -/

def encList (l : List Nat) : List Nat := l.length :: l

/-- take a length-prefixed list; fails if the prefix says more than is there -/
def decList : List Nat → Option (List Nat × List Nat)
  | [] => none
  | n :: ts => if n ≤ ts.length then some (ts.take n, ts.drop n) else none

theorem decList_enc (l rest : List Nat) : decList (encList l ++ rest) = some (l, rest) := by
  simp [encList, decList]

theorem decList_enc' (l : List Nat) : decList (encList l) = some (l, []) := by
  simpa using decList_enc l []

/-- a bare key list (the `init` record): every word is a key -/
def encKeys (l : List Key) : List Nat := l
def decKeys (l : List Nat) : Option (List Key) := some l
theorem decKeys_enc (l : List Key) : decKeys (encKeys l) = some l := rfl

/-- a single key (the row key) -/
def encKey (k : Key) : List Nat := [k]
def decKey : List Nat → Option Key
  | [k] => some k
  | _ => none
theorem decKey_enc (k : Key) : decKey (encKey k) = some k := rfl
theorem decKey_nil : decKey [] = none := rfl
theorem decKey_two (a c : Nat) (t : List Nat) : decKey (a :: c :: t) = none := rfl

/-! ## Inputs: `Read`, `Event` -/

def encRead (r : Read) : List Nat :=
  [(match r.kind with | .pass => 0 | .poll => 1),
   (match r.chevron with | .fresh => 0 | .stale => 1 | .absent => 2),
   (match r.level with | .complete => 0 | .exceptSelfPositioning => 1 | .incomplete => 2),
   b r.settled, b r.stripOpen, b r.observed, b r.notFullProven]
  ++ encList r.drawn ++ encList r.pile ++ encList r.folded ++ encList r.trusted
  ++ encList r.nearFold ++ encList r.unread

def encOutcome : Outcome → Nat | .verified => 0 | .failed => 1 | .refused => 2 | .busy => 3

def encEvent : Event → List Nat
  | .read r => 0 :: encRead r
  | .userEdit rec mv => 1 :: (encList rec ++ encList mv)
  | .userRetry => [2]
  | .retryKey k => [3, k]
  | .moveResult k o p => [4, k, encOutcome o, b p]
  | .passBoundary => [5]

def decRead : List Nat → Option Read
  | k :: c :: l :: se :: so :: ob :: nf :: ts => do
    let kind ← (match k with | 0 => some ReadKind.pass | 1 => some .poll | _ => none)
    let chevron ← (match c with | 0 => some ChevronRead.fresh | 1 => some .stale | 2 => some .absent | _ => none)
    let level ← (match l with | 0 => some ReadLevel.complete | 1 => some .exceptSelfPositioning | 2 => some .incomplete | _ => none)
    let settled ← ub se; let stripOpen ← ub so; let observed ← ub ob; let notFullProven ← ub nf
    let (drawn, ts) ← decList ts
    let (pile, ts) ← decList ts
    let (folded, ts) ← decList ts
    let (trusted, ts) ← decList ts
    let (nearFold, ts) ← decList ts
    let (unread, ts) ← decList ts
    if ts = [] then some { kind, chevron, level, settled, stripOpen, drawn, pile, folded, trusted, nearFold,
                           observed, unread, notFullProven } else none
  | _ => none

def decOutcome : Nat → Option Outcome
  | 0 => some .verified | 1 => some .failed | 2 => some .refused | 3 => some .busy | _ => none

theorem decOutcome_enc (o : Outcome) : decOutcome (encOutcome o) = some o := by cases o <;> rfl

def decEvent : List Nat → Option Event
  | 0 :: ts => (decRead ts).map .read
  | 1 :: ts => do
    let (rec, ts) ← decList ts
    let (mv, ts) ← decList ts
    if ts = [] then some (.userEdit rec mv) else none
  | [2] => some .userRetry
  | [3, k] => some (.retryKey k)
  | [4, k, o, p] => do some (.moveResult k (← decOutcome o) (← ub p))
  | [5] => some .passBoundary
  | _ => none

theorem decRead_enc (r : Read) : decRead (encRead r) = some r := by
  obtain ⟨k, c, l, se, so, dr, pi, fo, tr, nf, ob, un, nfp⟩ := r
  have h : ∀ (k : ReadKind) (c : ChevronRead) (l : ReadLevel),
      decRead ((match k with | .pass => 0 | .poll => 1) :: (match c with | .fresh => 0 | .stale => 1 | .absent => 2) ::
        (match l with | .complete => 0 | .exceptSelfPositioning => 1 | .incomplete => 2) ::
        b se :: b so :: b ob :: b nfp :: (encList dr ++ encList pi ++ encList fo ++ encList tr ++ encList nf ++ encList un))
      = some { kind := k, chevron := c, level := l, settled := se, stripOpen := so, drawn := dr, pile := pi,
               folded := fo, trusted := tr, nearFold := nf, observed := ob, unread := un, notFullProven := nfp } := by
    intro k c l
    cases k <;> cases c <;> cases l <;>
      simp only [decRead, ub_b, List.append_assoc, decList_enc, decList_enc', bind, Option.bind] <;> simp
  exact h k c l

theorem decEvent_enc (e : Event) : decEvent (encEvent e) = some e := by
  cases e with
  | read r => simp [encEvent, decEvent, decRead_enc]
  | userEdit rec mv => simp [encEvent, decEvent, encList, decList]
  | userRetry => rfl
  | retryKey k => rfl
  | moveResult k o p => cases o <;> cases p <;> rfl
  | passBoundary => rfl

/-- malformed inputs are refused, never defaulted (examples of each kind) -/
theorem decEvent_malformed :
    decEvent [] = none ∧ decEvent [9] = none ∧ decEvent [2, 0] = none ∧ decEvent [4, 1, 7, 0] = none ∧
    decEvent [4, 1, 0, 2] = none ∧ decEvent [3] = none ∧ decEvent [1, 5, 1, 2] = none ∧ decEvent [0] = none ∧
    decEvent [1, 0, 0, 7] = none := by decide

/-! ## Outputs: actions, status, verdicts, rows -/

def encRel : Rel → List Nat | .before t => [0, t] | .after t => [1, t]

def encAction (a : Action) : List Nat := a.subject :: (encRel a.rel ++ [b a.strip, b a.user])

def encActions : List Action → List Nat
  | [] => []
  | a :: as => encAction a ++ encActions as

def decActions : List Nat → Option (List Action)
  | [] => some []
  | s :: r :: t :: st :: u :: rest => do
    let rel ← (match r with | 0 => some (Rel.before t) | 1 => some (Rel.after t) | _ => none)
    let strip ← ub st
    let user ← ub u
    let more ← decActions rest
    some (⟨s, rel, strip, user⟩ :: more)
  | _ => none

theorem decActions_enc (as : List Action) : decActions (encActions as) = some as := by
  induction as with
  | nil => rfl
  | cons a as ih =>
    obtain ⟨s, rel, st, u⟩ := a
    cases rel <;> simp [encActions, encAction, encRel, decActions, ub_b, ih]

/-- A reason is `[0]` stopped, `[1]` barFull, `[2]` plain, `[3, k]` needsReapply k (ejb.20). -/
def encWhy : Why → List Nat | .stopped => [0] | .barFull => [1] | .plain => [2] | .needsReapply k => [3, k]
def decWhy : List Nat → Option Why
  | [0] => some .stopped | [1] => some .barFull | [2] => some .plain | [3, k] => some (.needsReapply k) | _ => none
theorem decWhy_enc (w : Why) : decWhy (encWhy w) = some w := by cases w <;> rfl

def encStatus : Status → List Nat
  | .moving => [0] | .matches => [1] | .matchesExcept u => 2 :: u
  | .differs w => 3 :: encWhy w | .checking => [4]

def decStatus : List Nat → Option Status
  | [0] => some .moving
  | [1] => some .matches
  | 2 :: u => some (.matchesExcept u)
  | 3 :: w => (decWhy w).map .differs
  | [4] => some .checking
  | _ => none

theorem decStatus_enc (s : Status) : decStatus (encStatus s) = some s := by
  cases s with
  | moving => rfl
  | «matches» => rfl
  | matchesExcept u => rfl
  | differs w => simp [encStatus, decStatus, decWhy_enc]
  | checking => rfl

def encVerdict : Verdict → List Nat
  | .matches => [0] | .matchesExcept u => 1 :: u | .differs => [2] | .cannotTell => [3]

def decVerdict : List Nat → Option Verdict
  | [0] => some .matches
  | 1 :: u => some (.matchesExcept u)
  | [2] => some .differs
  | [3] => some .cannotTell
  | _ => none

theorem decVerdict_enc (v : Verdict) : decVerdict (encVerdict v) = some v := by cases v <;> rfl

def encRowLine : RowLine → Nat
  | .moving => 0 | .waiting => 1 | .tick => 2 | .behind => 3 | .notWherePut => 4 | .notOnBar => 5 | .cannotTell => 6

def decRowLine : Nat → Option RowLine
  | 0 => some .moving | 1 => some .waiting | 2 => some .tick | 3 => some .behind | 4 => some .notWherePut
  | 5 => some .notOnBar | 6 => some .cannotTell | _ => none

theorem decRowLine_enc (l : RowLine) : decRowLine (encRowLine l) = some l := by cases l <;> rfl

def encRowVerdict : RowVerdict → Nat
  | .inOrder => 0 | .behindChevron => 1 | .behindOutOfTurn => 2 | .notOnBar => 3 | .outOfPlace => 4 | .cannotTell => 5

def decRowVerdict : Nat → Option RowVerdict
  | 0 => some .inOrder | 1 => some .behindChevron | 2 => some .behindOutOfTurn | 3 => some .notOnBar
  | 4 => some .outOfPlace | 5 => some .cannotTell | _ => none

theorem decRowVerdict_enc (v : RowVerdict) : decRowVerdict (encRowVerdict v) = some v := by cases v <;> rfl

/-- the row note: `0` = no note, else the note's code (an `Option RowNote` is one word) -/
def encNote : Option RowNote → Nat
  | none => 0 | some .noMoveHelps => 1 | some .cantJudge => 2 | some .noMoveHere => 3

def decNote : Nat → Option (Option RowNote)
  | 0 => some none | 1 => some (some .noMoveHelps) | 2 => some (some .cantJudge) | 3 => some (some .noMoveHere) | _ => none

theorem decNote_enc (n : Option RowNote) : decNote (encNote n) = some n := by
  cases n with
  | none => rfl
  | some w => cases w <;> rfl

/-- a word that is not a note code is refused -/
theorem decNote_malformed : decNote 4 = none ∧ decNote 99 = none := by decide

/-- the adopt proposal (ejb.9): `[0]` = no proposal, `1 :: record` = the proposed record -/
def encAdopt : Option (List Key) → List Nat
  | none => [0] | some L => 1 :: L

def decAdopt : List Nat → Option (Option (List Key))
  | [0] => some none | 1 :: L => some (some L) | _ => none

theorem decAdopt_enc (o : Option (List Key)) : decAdopt (encAdopt o) = some o := by cases o <;> rfl

/-- the answer envelope round-trips, and the error word is never an ok answer -/
def decAns : List Nat → Option (Option (List Nat))
  | okTag' :: p => if okTag' = okTag then some (some p) else if okTag' = errTag then (if p = [] then some none else none) else none
  | [] => none

theorem decAns_ok (p : List Nat) : decAns (okAns p) = some (some p) := by simp [decAns, okAns, okTag]
theorem decAns_err : decAns errAns = some none := by simp [decAns, errAns, errTag, okTag]

/-! ## Pure token functions (what the exports compute) -/

def initTok (rec : List Nat) : State := State.init rec

def stepTok (s : State) (ev : List Nat) : State × List Nat :=
  match decEvent ev with
  | none => (s, errAns)
  | some e => let (s', as) := step s e; (s', okAns (encActions as))

def statusTok (s : State) (rd : List Nat) : List Nat :=
  match decRead rd with | none => errAns | some r => okAns (encStatus (statusLine s r))

def shownTok (s : State) (rd : List Nat) : List Nat :=
  match decRead rd with | none => errAns | some r => okAns (encVerdict (shownVerdict s r))

def rowLineTok (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encRowLine (rowLine s r k)]
  | _, _ => errAns

def rowVerdictTok (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encRowVerdict (rowVerdict s.record (s.view r) k)]
  | _, _ => errAns

def rowNoteTok (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encNote (rowNote s r k)]
  | _, _ => errAns

/-- `adoptProposal s (the read)`: the record "Use the bar's current order" would save, or no proposal (ejb.9). -/
def adoptTok (s : State) (rd : List Nat) : List Nat :=
  match decRead rd with | none => errAns | some r => okAns (encAdopt (adoptProposal s r))


/-! ## Gestures (ejb.32): `applyGesture` -/

def encSection : Section → Nat | .visible => 0 | .hidden => 1 | .alwaysHidden => 2
def decSection : Nat → Option Section | 0 => some .visible | 1 => some .hidden | 2 => some .alwaysHidden | _ => none
theorem decSection_enc (s : Section) : decSection (encSection s) = some s := by cases s <;> rfl

/-- the layout: three length-prefixed key lists, Visible, Hidden, Always hidden -/
def encLayout3 (L : Layout3) : List Nat := encList L.visible ++ encList L.hidden ++ encList L.alwaysHidden

/-- a layout at the start of the words, and the words after it -/
def decLayout3Rest (ts : List Nat) : Option (Layout3 × List Nat) := do
  let (v, ts) ← decList ts
  let (h, ts) ← decList ts
  let (a, ts) ← decList ts
  some (⟨v, h, a⟩, ts)

def decLayout3 (ts : List Nat) : Option Layout3 :=
  match decLayout3Rest ts with | some (L, []) => some L | _ => none

theorem decLayout3Rest_enc (L : Layout3) (rest : List Nat) : decLayout3Rest (encLayout3 L ++ rest) = some (L, rest) := by
  obtain ⟨v, h, a⟩ := L
  simp [encLayout3, decLayout3Rest, decList_enc, List.append_assoc, bind, Option.bind]

theorem decLayout3_enc (L : Layout3) : decLayout3 (encLayout3 L) = some L := by
  have := decLayout3Rest_enc L []
  simp only [List.append_nil] at this
  simp [decLayout3, this]

/-- the answer of a gesture: the new layout, then the moved keys (length-prefixed) -/
def encGestureResult (r : Layout3 × List Key) : List Nat := encLayout3 r.1 ++ encList r.2

def decGestureResult (ts : List Nat) : Option (Layout3 × List Key) := do
  let (L, ts) ← decLayout3Rest ts
  let (mv, ts) ← decList ts
  if ts = [] then some (L, mv) else none

theorem decGestureResult_enc (r : Layout3 × List Key) : decGestureResult (encGestureResult r) = some r := by
  obtain ⟨L, mv⟩ := r
  simp [encGestureResult, decGestureResult, decLayout3Rest_enc, decList_enc', bind, Option.bind]

/-- the hide-unit table: length-prefixed, `(key, unit)` pairs flattened.  A key the table does not list is its own unit (`4294967296 + key`, outside the 32-bit ids a unit
is given on the Swift side) -/
def encUnits (tbl : List (Key × Nat)) : List Nat := encList (tbl.flatMap fun p => [p.1, p.2])

def decPairs : List Nat → Option (List (Key × Nat))
  | [] => some []
  | k :: u :: r => (decPairs r).map ((k, u) :: ·)
  | _ => none

def decUnits (ts : List Nat) : Option (List (Key × Nat)) :=
  match decList ts with | some (l, []) => decPairs l | _ => none

theorem decPairs_enc (tbl : List (Key × Nat)) : decPairs (tbl.flatMap fun p => [p.1, p.2]) = some tbl := by
  induction tbl with
  | nil => rfl
  | cons p tbl ih => simp [decPairs, ih]

theorem decUnits_enc (tbl : List (Key × Nat)) : decUnits (encUnits tbl) = some tbl := by
  simp [decUnits, encUnits, decList_enc', decPairs_enc]

/-- a bare length-prefixed key list (the system-module keys) -/
def encKeyList (l : List Key) : List Nat := encList l
def decKeyList (ts : List Nat) : Option (List Key) := match decList ts with | some (l, []) => some l | _ => none
theorem decKeyList_enc (l : List Key) : decKeyList (encKeyList l) = some l := by simp [decKeyList, encKeyList, decList_enc']

/-- the unit function of a table -/
def unitOfTable (tbl : List (Key × Nat)) (k : Key) : Nat := (tbl.lookup k).getD (4294967296 + k)

/-- a gesture: `[0, key, section, 0]` (no index), `[0, key, section, 1, index]`, or `1 :: length-prefixed keys` (hide what does not fit) -/
def encGesture : Gesture → List Nat
  | .drop k s none => [0, k, encSection s, 0]
  | .drop k s (some n) => [0, k, encSection s, 1, n]
  | .hideNotFitting ks => 1 :: encList ks

def decGesture : List Nat → Option Gesture
  | [0, k, s, 0] => (decSection s).map fun sec => .drop k sec none
  | [0, k, s, 1, n] => (decSection s).map fun sec => .drop k sec (some n)
  | 1 :: ts => match decList ts with | some (ks, []) => some (.hideNotFitting ks) | _ => none
  | _ => none

theorem decGesture_enc (g : Gesture) : decGesture (encGesture g) = some g := by
  cases g with
  | drop k s idx => cases idx <;> cases s <;> rfl
  | hideNotFitting ks => simp [encGesture, decGesture, decList_enc']

/-- malformed gestures are refused, never defaulted -/
theorem decGesture_malformed :
    decGesture [] = none ∧ decGesture [2] = none ∧ decGesture [0, 1, 3, 0] = none ∧ decGesture [0, 1, 0, 2] = none ∧
    decGesture [0, 1, 0, 1] = none ∧ decGesture [0, 1, 0, 0, 5] = none ∧ decGesture [1] = none ∧ decGesture [1, 2, 7] = none ∧
    decGesture [1, 0, 9] = none := by decide

/-- malformed layouts, unit tables and key lists are refused (a short list, trailing words, an odd pair count) -/
theorem decGestureInputs_malformed :
    decLayout3 [] = none ∧ decLayout3 [1, 5, 0] = none ∧ decLayout3 [0, 0, 0, 7] = none ∧ decLayout3 [2, 5, 0, 0] = none ∧
    decUnits [] = none ∧ decUnits [3, 1, 2, 3] = none ∧ decUnits [2, 1, 2, 9] = none ∧ decUnits [2, 1] = none ∧
    decKeyList [] = none ∧ decKeyList [1] = none ∧ decKeyList [0, 4] = none := by decide

/-- `gestureTok layout units sys gesture`: all four inputs decode, or the answer is the error word -/
def gestureTok (lay units sys gst : List Nat) : List Nat :=
  match decLayout3 lay, decUnits units, decKeyList sys, decGesture gst with
  | some L, some tbl, some sysKeys, some g => okAns (encGestureResult (applyGesture (unitOfTable tbl) (fun k => sysKeys.contains k) L g))
  | _, _, _, _ => errAns

theorem gestureTok_enc (L : Layout3) (tbl : List (Key × Nat)) (sysKeys : List Key) (g : Gesture) :
    gestureTok (encLayout3 L) (encUnits tbl) (encKeyList sysKeys) (encGesture g) =
      okAns (encGestureResult (applyGesture (unitOfTable tbl) (fun k => sysKeys.contains k) L g)) := by
  simp [gestureTok, decLayout3_enc, decUnits_enc, decKeyList_enc, decGesture_enc]

theorem gestureTok_bad_layout (lay units sys gst : List Nat) (h : decLayout3 lay = none) : gestureTok lay units sys gst = errAns := by
  simp [gestureTok, h]
theorem gestureTok_bad_units (lay units sys gst : List Nat) (h : decUnits units = none) : gestureTok lay units sys gst = errAns := by
  simp [gestureTok, h]
theorem gestureTok_bad_sys (lay units sys gst : List Nat) (h : decKeyList sys = none) : gestureTok lay units sys gst = errAns := by
  simp [gestureTok, h]
theorem gestureTok_bad_gesture (lay units sys gst : List Nat) (h : decGesture gst = none) : gestureTok lay units sys gst = errAns := by
  simp [gestureTok, h]

/-! ## Wrapper theorems: encoded input gives the encoding of the proved value; undecodable input gives the error word -/

theorem initTok_enc (rec : List Key) : initTok (encKeys rec) = State.init rec := rfl

theorem stepTok_enc (s : State) (e : Event) :
    stepTok s (encEvent e) = ((step s e).1, okAns (encActions (step s e).2)) := by
  simp [stepTok, decEvent_enc]

theorem stepTok_bad (s : State) (ev : List Nat) (h : decEvent ev = none) : stepTok s ev = (s, errAns) := by
  simp [stepTok, h]

theorem statusTok_enc (s : State) (r : Read) : statusTok s (encRead r) = okAns (encStatus (statusLine s r)) := by
  simp [statusTok, decRead_enc]

theorem statusTok_bad (s : State) (rd : List Nat) (h : decRead rd = none) : statusTok s rd = errAns := by
  simp [statusTok, h]

theorem shownTok_enc (s : State) (r : Read) : shownTok s (encRead r) = okAns (encVerdict (shownVerdict s r)) := by
  simp [shownTok, decRead_enc]

theorem shownTok_bad (s : State) (rd : List Nat) (h : decRead rd = none) : shownTok s rd = errAns := by
  simp [shownTok, h]

theorem rowLineTok_enc (s : State) (r : Read) (k : Key) :
    rowLineTok s (encRead r) (encKey k) = okAns [encRowLine (rowLine s r k)] := by
  simp [rowLineTok, decRead_enc, decKey_enc]

theorem rowLineTok_bad_read (s : State) (rd key : List Nat) (h : decRead rd = none) : rowLineTok s rd key = errAns := by
  simp [rowLineTok, h]

theorem rowLineTok_bad_key (s : State) (rd key : List Nat) (h : decKey key = none) : rowLineTok s rd key = errAns := by
  simp [rowLineTok, h]

theorem rowVerdictTok_enc (s : State) (r : Read) (k : Key) :
    rowVerdictTok s (encRead r) (encKey k) = okAns [encRowVerdict (rowVerdict s.record (s.view r) k)] := by
  simp [rowVerdictTok, decRead_enc, decKey_enc]

theorem rowVerdictTok_bad_read (s : State) (rd key : List Nat) (h : decRead rd = none) : rowVerdictTok s rd key = errAns := by
  simp [rowVerdictTok, h]

theorem rowVerdictTok_bad_key (s : State) (rd key : List Nat) (h : decKey key = none) : rowVerdictTok s rd key = errAns := by
  simp [rowVerdictTok, h]

theorem rowNoteTok_enc (s : State) (r : Read) (k : Key) :
    rowNoteTok s (encRead r) (encKey k) = okAns [encNote (rowNote s r k)] := by
  simp [rowNoteTok, decRead_enc, decKey_enc]

theorem rowNoteTok_bad_read (s : State) (rd key : List Nat) (h : decRead rd = none) : rowNoteTok s rd key = errAns := by
  simp [rowNoteTok, h]

theorem rowNoteTok_bad_key (s : State) (rd key : List Nat) (h : decKey key = none) : rowNoteTok s rd key = errAns := by
  simp [rowNoteTok, h]

theorem adoptTok_enc (s : State) (r : Read) : adoptTok s (encRead r) = okAns (encAdopt (adoptProposal s r)) := by
  simp [adoptTok, decRead_enc]

theorem adoptTok_bad (s : State) (rd : List Nat) (h : decRead rd = none) : adoptTok s rd = errAns := by
  simp [adoptTok, h]

/-! ## The token functions the exports compute: the fast versions, proved equal to the ones above -/

def stepTokF (s : State) (ev : List Nat) : State × List Nat :=
  match decEvent ev with
  | none => (s, errAns)
  | some e => let (s', as) := stepF s e; (s', okAns (encActions as))

def statusTokF (s : State) (rd : List Nat) : List Nat :=
  match decRead rd with | none => errAns | some r => okAns (encStatus (statusLineF s r))

def shownTokF (s : State) (rd : List Nat) : List Nat :=
  match decRead rd with | none => errAns | some r => okAns (encVerdict (shownVerdictF s r))

def rowLineTokF (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encRowLine (rowLineF s r k)]
  | _, _ => errAns

def rowVerdictTokF (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encRowVerdict (rowVerdictF s.record (s.view r) k)]
  | _, _ => errAns

def rowNoteTokF (s : State) (rd : List Nat) (key : List Nat) : List Nat :=
  match decRead rd, decKey key with
  | some r, some k => okAns [encNote (rowNoteF s r k)]
  | _, _ => errAns

theorem rowNoteTokF_eq (s : State) (rd key : List Nat) : rowNoteTokF s rd key = rowNoteTok s rd key := by
  unfold rowNoteTokF rowNoteTok
  cases decRead rd <;> cases decKey key <;> simp only [rowNoteF_eq]

theorem stepTokF_eq (s : State) (ev : List Nat) : stepTokF s ev = stepTok s ev := by
  unfold stepTokF stepTok
  cases decEvent ev with
  | none => rfl
  | some e => simp only [stepF_eq]

theorem statusTokF_eq (s : State) (rd : List Nat) : statusTokF s rd = statusTok s rd := by
  unfold statusTokF statusTok
  cases decRead rd with
  | none => rfl
  | some r => simp only [statusLineF_eq]

theorem shownTokF_eq (s : State) (rd : List Nat) : shownTokF s rd = shownTok s rd := by
  unfold shownTokF shownTok
  cases decRead rd with
  | none => rfl
  | some r => simp only [shownVerdictF_eq]

theorem rowLineTokF_eq (s : State) (rd key : List Nat) : rowLineTokF s rd key = rowLineTok s rd key := by
  unfold rowLineTokF rowLineTok
  cases decRead rd <;> cases decKey key <;> simp only [rowLineF_eq]

theorem rowVerdictTokF_eq (s : State) (rd key : List Nat) : rowVerdictTokF s rd key = rowVerdictTok s rd key := by
  unfold rowVerdictTokF rowVerdictTok
  cases decRead rd <;> cases decKey key <;> simp only [rowVerdictF_eq]

/-! ## Names (test support, not part of the proofs)

A rendering of every boundary value as text, by explicit name tables.  `lake exe fixture` prints the expected OUTPUTS with it and
`sommelier_describe_event` returns the Lean-side reading of an INPUT with it, so the Swift tests compare names (rendered by Swift's own
name functions, independent of the Swift `Codec`) and not codes. -/

def nameList (l : List Nat) : String := "[" ++ ",".intercalate (l.map toString) ++ "]"
def nameRel : Rel → String | .before t => s!"before {t}" | .after t => s!"after {t}"
def nameAction (a : Action) : String := s!"{a.subject} {nameRel a.rel} strip={a.strip} user={a.user}"
def nameActions (as : List Action) : String := " | ".intercalate (as.map nameAction)
def nameWhy : Why → String | .stopped => "stopped" | .barFull => "barFull" | .plain => "plain" | .needsReapply k => s!"needsReapply {k}"
def nameStatus : Status → String
  | .moving => "moving" | .matches => "matches" | .matchesExcept u => s!"matchesExcept{nameList u}"
  | .differs w => s!"differs({nameWhy w})" | .checking => "checking"
def nameVerdict : Verdict → String
  | .matches => "matches" | .matchesExcept u => s!"matchesExcept{nameList u}" | .differs => "differs" | .cannotTell => "cannotTell"
def nameRow : RowLine → String
  | .moving => "moving" | .waiting => "waiting" | .tick => "tick" | .behind => "behind" | .notWherePut => "notWherePut"
  | .notOnBar => "notOnBar" | .cannotTell => "cannotTell"
def nameNote : Option RowNote → String
  | none => "none" | some .noMoveHelps => "noMoveHelps" | some .cantJudge => "cantJudge" | some .noMoveHere => "noMoveHere"
def nameRowVerdict : RowVerdict → String
  | .inOrder => "inOrder" | .behindChevron => "behindChevron" | .behindOutOfTurn => "behindOutOfTurn" | .notOnBar => "notOnBar"
  | .outOfPlace => "outOfPlace" | .cannotTell => "cannotTell"
def nameOutcome : Outcome → String | .verified => "verified" | .failed => "failed" | .refused => "refused" | .busy => "busy"
def nameRead (r : Read) : String :=
  let kind := match r.kind with | .pass => "pass" | .poll => "poll"
  let chev := match r.chevron with | .fresh => "fresh" | .stale => "stale" | .absent => "absent"
  let lvl := match r.level with | .complete => "complete" | .exceptSelfPositioning => "exceptSelfPositioning" | .incomplete => "incomplete"
  s!"read(kind={kind} chevron={chev} level={lvl} settled={r.settled} stripOpen={r.stripOpen} observed={r.observed} notFullProven={r.notFullProven} drawn={nameList r.drawn} pile={nameList r.pile} folded={nameList r.folded} trusted={nameList r.trusted} nearFold={nameList r.nearFold} unread={nameList r.unread})"
def nameEvent : Event → String
  | .read r => nameRead r
  | .userEdit rec mv => s!"userEdit(record={nameList rec} moved={nameList mv})"
  | .userRetry => "userRetry" | .retryKey k => s!"retryKey({k})"
  | .moveResult k o p => s!"moveResult({k} {nameOutcome o} posted={p})"
  | .passBoundary => "passBoundary"

def nameLayout3 (L : Layout3) : String := s!"visible={nameList L.visible} hidden={nameList L.hidden} alwaysHidden={nameList L.alwaysHidden}"
def nameGestureResult (r : Layout3 × List Key) : String := s!"{nameLayout3 r.1} moved={nameList r.2}"

/-- the Lean-side reading of an input: the name of the event the words decode to -/
def describeTok (ev : List Nat) : List Nat :=
  match decEvent ev with
  | none => errAns
  | some e => okAns ((nameEvent e).toUTF8.toList.map (·.toNat))

/-! ## Exports.  Thin: `Array` in, `Array` out; the logic is the `…Tok` functions above. -/

@[export sommelier_init]
def exInit (record : Array Nat) : State := initTok record.toList

/-- Result: (new state, answer).  A malformed event leaves the state unchanged and answers `[errTag]`. -/
@[export sommelier_step]
def exStep (s : State) (ev : Array Nat) : State × Array Nat :=
  let (s', o) := stepTokF s ev.toList
  (s', o.toArray)

@[export sommelier_status]
def exStatus (s : State) (r : Array Nat) : Array Nat := (statusTokF s r.toList).toArray

@[export sommelier_shown_verdict]
def exShown (s : State) (r : Array Nat) : Array Nat := (shownTokF s r.toList).toArray

@[export sommelier_row_line]
def exRowLine (s : State) (r : Array Nat) (k : Array Nat) : Array Nat := (rowLineTokF s r.toList k.toList).toArray

@[export sommelier_row_verdict]
def exRowVerdict (s : State) (r : Array Nat) (k : Array Nat) : Array Nat := (rowVerdictTokF s r.toList k.toList).toArray

@[export sommelier_row_note]
def exRowNote (s : State) (r : Array Nat) (k : Array Nat) : Array Nat := (rowNoteTokF s r.toList k.toList).toArray

/-- ejb.9: the adopted record, or `[0]` (no proposal). Decides in `adoptProposal` (Adopt.lean); nothing here. -/
@[export sommelier_adopt]
def exAdopt (s : State) (r : Array Nat) : Array Nat := (adoptTok s r.toList).toArray

/-- ejb.32: `applyGesture`.  Inputs: the layout, the hide-unit table, the system-module keys, the gesture (see `encLayout3`, `encUnits`, `encKeyList`, `encGesture`).
Answer: `okTag :: new layout ++ length-prefixed moved keys`, or `[errTag]` if ANY input does not decode.  Decides in `applyGesture` (GestureDef.lean); nothing here.
There is no `Fast` twin: one call per gesture, never on a hot path. -/
@[export sommelier_gesture]
def exGesture (lay units sys gst : Array Nat) : Array Nat := (gestureTok lay.toList units.toList sys.toList gst.toList).toArray

/-- Test support: the name of the event the words decode to, as UTF-8 bytes (`[errTag]` if they do not decode). -/
@[export sommelier_describe_event]
def exDescribeEvent (ev : Array Nat) : Array Nat := (describeTok ev.toList).toArray

end Sommelier.Ffi
