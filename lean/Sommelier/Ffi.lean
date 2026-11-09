import Sommelier.Status
import Sommelier.Fast

/-!
# C boundary: the thin exports the Swift app links

The app holds an opaque `State` and sends flat `Nat` token lists (the C shim turns `UInt32` words into `Nat`s).  Every export only
DECODES its input, calls the PROVED function (`step`, `statusLine`, `rowLine`, `shownVerdict`, `rowVerdict`), and ENCODES the answer.
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

def encWhy : Why → Nat | .stopped => 0 | .barFull => 1 | .plain => 2
def decWhy : Nat → Option Why | 0 => some .stopped | 1 => some .barFull | 2 => some .plain | _ => none
theorem decWhy_enc (w : Why) : decWhy (encWhy w) = some w := by cases w <;> rfl

def encStatus : Status → List Nat
  | .moving => [0] | .matches => [1] | .matchesExcept u => 2 :: u
  | .differs w => [3, encWhy w] | .checking => [4]

def decStatus : List Nat → Option Status
  | [0] => some .moving
  | [1] => some .matches
  | 2 :: u => some (.matchesExcept u)
  | [3, w] => (decWhy w).map .differs
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
def nameWhy : Why → String | .stopped => "stopped" | .barFull => "barFull" | .plain => "plain"
def nameStatus : Status → String
  | .moving => "moving" | .matches => "matches" | .matchesExcept u => s!"matchesExcept{nameList u}"
  | .differs w => s!"differs({nameWhy w})" | .checking => "checking"
def nameVerdict : Verdict → String
  | .matches => "matches" | .matchesExcept u => s!"matchesExcept{nameList u}" | .differs => "differs" | .cannotTell => "cannotTell"
def nameRow : RowLine → String
  | .moving => "moving" | .waiting => "waiting" | .tick => "tick" | .behind => "behind" | .notWherePut => "notWherePut"
  | .notOnBar => "notOnBar" | .cannotTell => "cannotTell"
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


/-- Test support: the name of the event the words decode to, as UTF-8 bytes (`[errTag]` if they do not decode). -/
@[export sommelier_describe_event]
def exDescribeEvent (ev : Array Nat) : Array Nat := (describeTok ev.toList).toArray

end Sommelier.Ffi
