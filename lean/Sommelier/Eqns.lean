import Sommelier.Step

/-!
# Equation lemmas, generated once

`Safety.lean` and `Gates.lean` both `unfold` the same definitions.  Lean generates auxiliary declarations
(`result.match_1.congr_eq_1._sparseCasesOn_2`, ...) in the first module that needs them, so two modules that
generate them separately cannot both be imported (`Pins.lean`, `Sommelier.lean`).  Generating them here, in a module
both import, keeps `Gates.lean` and `Honesty.lean` independent of `Safety.lean` (a mutant that breaks a `Safety.lean`
proof cannot mask a theorem in `Gates.lean`).
-/

namespace Sommelier

theorem eqns_result (s : State) (a : Action) (o : Outcome) (p : Bool) : (result s a o p).inFlight = none := by
  unfold result; grind

theorem eqns_noteRead (s : State) (r : Read) : (noteRead s r).record = s.record := by
  unfold noteRead; grind

/-- What counts as folded: this read's folded set, plus the memory unless this read is a usable fresh-chevron read (which supersedes it). -/
theorem mem_foldedAll (s : State) (r : Read) (k : Key) :
    k ∈ foldedAll s r ↔ k ∈ r.foldedSet ∨ (¬(r.usable ∧ r.chevron = .fresh) ∧ k ∈ s.lastFreshPile) := by
  unfold foldedAll
  by_cases h : r.usable ∧ r.chevron = .fresh
  · simp [h]
  · simp [h]

end Sommelier
