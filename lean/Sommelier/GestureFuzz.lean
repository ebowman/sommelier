import Sommelier.GestureDef

/-!
# Gesture fuzz (sommelier-ejb.32)

Seeded random layouts and gestures checked against an INDEPENDENT statement of what a gesture means, written directly from the
description in `GestureDef.lean` (not by calling `moveKey` again, and not through the proofs): so it notices a wrong
definition by meaning.  Imports `GestureDef` only.  Each table prints `instances, failures` in the format `lake exe fuzz` uses,
and the mutant runner reads the failures.
-/

namespace Sommelier.GestureFuzz

abbrev G := StateM Nat
def next : G Nat := modifyGet fun x => let y := (x * 6364136223846793005 + 1442695040888963407) % 18446744073709551616; (y / 65536, y)
def rnd (n : Nat) : G Nat := do let v ← next; pure (v % n)
def coin (pct : Nat) : G Bool := do pure ((← rnd 100) < pct)
def insertAt (x : Key) (l : List Key) (i : Nat) : List Key := l.take i ++ x :: l.drop i
def shuffle (l : List Key) : G (List Key) := l.foldlM (fun acc x => do pure (insertAt x acc (← rnd (acc.length + 1)))) []

/-- the world of one case: a unit table (keys not listed are their own unit), the system-module keys (90 and up) and the layout -/
structure Case where
  units : List (Key × Nat)
  layout : Layout3
  normal : Bool

def Case.unit (c : Case) (k : Key) : Nat := (c.units.lookup k).getD (1000 + k)
def isSys (k : Key) : Bool := decide (90 ≤ k)

/-- a random layout over keys 1..14 plus modules 90..92: some keys absent, three random sections; `normal` makes every unit all-visible or all-hidden -/
def genCase : G Case := do
  let nUnits ← rnd 4
  let big ← coin 30
  let all := (List.range 14).map (· + 1)
  let order ← shuffle all
  -- units: a 9-key unit (keys 1..9 scrambled) sometimes, otherwise small units of 2-3 keys
  let units : List (Key × Nat) :=
    if big then (order.take 9).map (fun k => (k, 7)) ++ ((order.drop 9).take 3).map (fun k => (k, 8))
    else (order.take (nUnits * 3)).zipIdx.map (fun (k, i) => (k, i / 3 + 20))
  let normal ← coin 60
  let present ← all.filterM (fun _ => coin 85)
  let u (k : Key) : Nat := (units.lookup k).getD (1000 + k)
  -- section per UNIT when normal (all of a unit visible, or all non-visible), per key otherwise
  let secOf (k : Key) : G Nat := rnd 3
  let mut unitSec : List (Nat × Nat) := []
  for k in all do
    if (unitSec.lookup (u k)).isNone then unitSec := (u k, ← secOf k) :: unitSec
  let mut v : List Key := []
  let mut h : List Key := []
  let mut a : List Key := []
  for k in (← shuffle present) do
    let s ← if normal then pure ((unitSec.lookup (u k)).getD 0) else rnd 3
    if s == 0 then v := v ++ [k] else if s == 1 then h := h ++ [k] else a := a ++ [k]
  -- modules: sometimes one in the middle of Visible (an anchor), always a trailing run of 0-3
  let nMod ← rnd 4
  let mods := ([90, 91, 92].take nMod)
  let v0 := v
  let v1 ← if (← coin 20) && !v0.isEmpty then pure (insertAt 93 v0 (← rnd v0.length)) else pure v0
  pure { units := units, layout := ⟨v1 ++ mods, h, a⟩, normal := normal }

def Case.keysOf (c : Case) (s : Section) : List Key := c.layout.keys s

def secs : List Section := [.visible, .hidden, .alwaysHidden]

/-- the expected index: an explicit one clamped to the section without the lifted keys; none appends, except in Visible before the trailing system run -/
def expIdx (lifted : List Key) (s : Section) : Option Nat → Nat
  | some n => if n < lifted.length then n else lifted.length
  | none =>
    if s == .visible then
      let rec go (i : Nat) : Nat := match i with
        | 0 => 0
        | i + 1 => if isSys (lifted.getD i 0) then go i else i + 1
      go lifted.length
    else lifted.length

structure Tally where
  n : Nat := 0
  bad : Nat := 0
  cex : Option String := none

def Tally.add (t : Tally) (ok : Bool) (w : Unit → String) : Tally :=
  { n := t.n + 1, bad := t.bad + (if ok then 0 else 1), cex := if ok || t.cex.isSome then t.cex else some (w ()) }

def sortedEq (a b : List Key) : Bool := (a.mergeSort (· ≤ ·)) == (b.mergeSort (· ≤ ·))

/-- one random drop against its meaning -/
def checkDrop (c : Case) (k : Key) (s : Section) (idx : Option Nat) : Bool × String × Bool :=
  let L := c.layout
  let (R, mv) := applyGesture c.unit isSys L (.drop k s idx)
  let was := secs.find? (fun t => L.keys t |>.contains k)
  let same := was == some s
  let w := s!"L={repr L} k={k} to={repr s} idx={idx} -> R={repr R} moved={mv}"
  if same then
    let lifted := (L.keys s).filter (· != k)
    let i := expIdx lifted s idx
    let ok := mv == [k] && R.keys s == lifted.take i ++ [k] ++ lifted.drop i &&
      secs.all (fun t => t == s || R.keys t == L.keys t) && sortedEq R.allKeys L.allKeys
    (ok, w, true)
  else
    let mates := L.allKeys.filter (fun x => x != k && c.unit x == c.unit k)
    let group := k :: mates
    let lifted := (L.keys s).filter (fun x => !group.contains x)
    let i := expIdx lifted s idx
    let ok := mv == [k] && R.keys s == lifted.take i ++ group ++ lifted.drop i &&
      secs.all (fun t => t == s || R.keys t == (L.keys t).filter (fun x => !group.contains x)) &&
      sortedEq R.allKeys ((L.allKeys.filter (· != k)) ++ [k])
    (ok, w, false)

/-- hide what does not fit against its meaning (units all-or-nothing only) -/
def checkHide (c : Case) (ks : List Key) : Bool × String :=
  let L := c.layout
  let (R, mv) := applyGesture c.unit isSys L (.hideNotFitting ks)
  let w := s!"L={repr L} ks={ks} -> R={repr R} moved={mv}"
  -- the named keys that are visible at the start, one per distinct unit, in order
  let named := ks.filter (fun k => L.visible.contains k)
  let firsts := named.foldl (fun acc k => if acc.any (fun j => c.unit j == c.unit k) then acc else acc ++ [k]) []
  let groups := firsts.map (fun k => k :: L.allKeys.filter (fun x => x != k && c.unit x == c.unit k))
  let moved := groups.flatten
  let ok := R.visible == L.visible.filter (fun x => !moved.contains x) && R.alwaysHidden == L.alwaysHidden &&
    R.hidden == L.hidden ++ moved && mv == moved
  (ok, w)

/-- the weaker properties that hold for ANY layout (units not all-or-nothing): no key lost or duplicated, Hidden/Always-hidden keep their order -/
def checkHideAny (c : Case) (ks : List Key) : Bool :=
  let L := c.layout
  let (R, _) := applyGesture c.unit isSys L (.hideNotFitting ks)
  sortedEq R.allKeys L.allKeys && R.allKeys.Nodup == L.allKeys.Nodup

/-- a random gesture over the case's world (for the fixtures): a drop of a listed or an unlisted key, or hide-what-does-not-fit -/
def genGesture : G Gesture := do
  if (← rnd 5) == 0 then
    let hs ← ((List.range 14).map (· + 1)).filterM (fun _ => coin 25)
    pure (.hideNotFitting (← shuffle hs))
  else
    let kk ← rnd 16
    let k := if kk < 14 then kk + 1 else 50 + kk
    let s := secs.getD (← rnd 3) .visible
    let ix ← rnd 10
    let pick ← rnd 8
    pure (.drop k s (if ix < 3 then none else if ix < 8 then some pick else some (20 + pick)))

structure Report where
  same : Tally := {}
  cross : Tally := {}
  absent : Tally := {}
  hide : Tally := {}
  hideAny : Tally := {}
  seenNone : Nat := 0
  seenBig : Nat := 0
  seenOutOfRange : Nat := 0
  seenSys : Nat := 0

def run (cases seed : Nat) : Report := Id.run do
  let mut r : Report := {}
  let mut st := seed
  for _ in List.range cases do
    let (c, st1) := genCase.run st
    st := st1
    let L := c.layout
    -- drops: a listed key, a key not listed, every section; index none / in range / out of range
    let (pick, st2) := (rnd 100).run st
    st := st2
    let keys := (List.range 14).map (· + 1)
    let (kk, st3) := (rnd 16).run st
    st := st3
    let k := if kk < 14 then kk + 1 else 50 + kk   -- 15, 16 are never in the layout
    let (si, st4) := (rnd 3).run st
    st := st4
    let s := secs.getD si .visible
    let (ix, st5) := (rnd 10).run st
    st := st5
    let idx : Option Nat := if ix < 3 then none else if ix < 8 then some (pick % 8) else some (20 + pick)
    let (ok, w, same) := checkDrop c k s idx
    let present := L.allKeys.contains k
    if !present then r := { r with absent := r.absent.add ok (fun _ => w) }
    else if same then r := { r with same := r.same.add ok (fun _ => w) }
    else r := { r with cross := r.cross.add ok (fun _ => w) }
    if idx.isNone then r := { r with seenNone := r.seenNone + 1 }
    if (match idx with | some n => decide (n > 14) | none => false) then r := { r with seenOutOfRange := r.seenOutOfRange + 1 }
    if c.units.length ≥ 9 && c.unit k == 7 then r := { r with seenBig := r.seenBig + 1 }
    if L.visible.any isSys then r := { r with seenSys := r.seenSys + 1 }
    -- hide what does not fit: a random subset of keys (some not visible)
    let (hs, st6) := (keys.filterM (fun _ => coin 25)).run st
    st := st6
    let (hs, st7) := (shuffle hs).run st
    st := st7
    if c.normal then
      let (ok2, w2) := checkHide c hs
      r := { r with hide := r.hide.add ok2 (fun _ => w2) }
    r := { r with hideAny := r.hideAny.add (checkHideAny c hs) (fun _ => s!"L={repr L} ks={hs}") }
  return r

end Sommelier.GestureFuzz
