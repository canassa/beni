-- Import existing proof equations before the witness reduction chain starts.
import Ownership.Soundness
import Ownership.KernelChecks

/-! Construction uses expression ticks in both interpreters (#168).
This accepted closed program previously refuted the same-fuel main theorem. -/

open Ownership

namespace Ownership.ProofPlan.ConstructionFuel

def program : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1])
    (.letE 1 (.prim (.literal .int) [.int 2])
      (.prim (.construct [true, true]) [.var 0, .var 1])) }

#guard (check program).isOk

#guard match ValueSemantics.run program 5 with
  | .ok trace => trace.finalValue == .list [.int 1, .int 2]
  | .error _ => false

#guard match InPlaceSemantics.run program 5 with
  | .ok trace => trace.finalValue == .list [.int 1, .int 2]
  | .error _ => false

#guard match (ValueSemantics.eval 6 [] none [] program.main).run {fuel := 6},
    (InPlaceSemantics.eval 6 [] none [] program.main).run {fuel := 6} with
  | .ok (_, valueState), .ok (_, heapState) =>
    valueState.fuel == 1 && heapState.fuel == 1
  | _, _ => false

theorem accepted : (check program).isOk = true := by
  cbv

theorem value_run : ValueSemantics.run program 5 =
    .ok {reads := [], finalValue := .list [.int 1, .int 2]} := by
  cbv

theorem heap_run : InPlaceSemantics.run program 5 =
    .ok {reads := [], finalValue := .list [.int 1, .int 2]} := by
  cbv

theorem runs_agree : ValueSemantics.run program 5 = InPlaceSemantics.run program 5 := by
  rw [value_run, heap_run]

theorem remaining_fuel :
    (ValueSemantics.eval 6 [] none [] program.main).run {fuel := 6} =
      .ok (.list [.int 1, .int 2], {fuel := 1}) ∧
    (InPlaceSemantics.eval 6 [] none [] program.main).run {fuel := 6} =
      .ok (.ref 0, {fuel := 1, heap := #[[.int 1, .int 2], [.int 2]], writes := 1}) := by
  constructor <;> cbv

end Ownership.ProofPlan.ConstructionFuel
