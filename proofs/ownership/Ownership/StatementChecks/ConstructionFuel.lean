-- Import existing proof equations before the witness reduction chain starts.
import Ownership.Soundness
import Ownership.KernelChecks

/-! A later spread costs an extra tick only in the in-place interpreter.
This accepted closed program refutes the current same-fuel claim (#168). -/

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
  | .error message => message == "in-place execution exhausted fuel"
  | .ok _ => false

#guard match (ValueSemantics.eval 6 [] none [] program.main).run {fuel := 6},
    (InPlaceSemantics.eval 6 [] none [] program.main).run {fuel := 6} with
  | .ok (_, valueState), .ok (_, heapState) =>
    valueState.fuel == 1 && heapState.fuel == 0
  | _, _ => false

theorem accepted : (check program).isOk = true := by
  cbv

theorem value_run : ValueSemantics.run program 5 =
    .ok {reads := [], finalValue := .list [.int 1, .int 2]} := by
  cbv

theorem heap_exhausts : InPlaceSemantics.run program 5 =
    .error "in-place execution exhausted fuel" := by
  cbv

end Ownership.ProofPlan.ConstructionFuel
