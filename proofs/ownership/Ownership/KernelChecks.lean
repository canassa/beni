import Ownership.Checker

namespace Ownership.KernelChecks

/- Kernel regression proofs, not native_decide and not a universal checker
   theorem. These exercise the actual total definitions at the repaired rules. -/
set_option maxRecDepth 10000

theorem scalar_checks :
    (check {main := .atom (.int 1)} {inferenceFuel := 1}).isOk = true := by
  simp [check, typecheck, exprType, inferExpr, abstractAtom, StateT.run]
  rfl

private def internallyShared : Abstract :=
  .list [.site [1] 0] (.list [.site [0] 0] .scalar true) false

theorem shared_result_not_certified :
    storeExclusive {declarations := [], config := {}}
      [internallyShared] [] [] true = false := by
  decide +kernel

theorem old_rule_falsely_certifies :
    storeExclusive {declarations := [], config := {oldFreshRule := true}}
      [internallyShared] [] [] true = true := by
  decide +kernel

theorem permanent_escape_ignores_position_partition :
    ((demand {} [.position [0] true (.site [1] 0)] [] []).run
      {facts := {escapes := [.position [0] false (.site [1] 0)]}}).isOk = false := by
  decide +kernel

end Ownership.KernelChecks
