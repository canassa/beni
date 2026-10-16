import Ownership.Fixtures
import Ownership.Enumerate

/-! Remaining fuel for accepted programs in the construction-fuel stream.
Each row preserves the exact evaluation error or the remaining fuel and full
public trace result. A final snapshot error stays explicit even when expression
evaluation succeeded. This finite measurement does not prove `Invariant.fuel`.
The archived `FuelOutcomes.lean` and its stream hashes remain unchanged. -/

open Ownership

namespace Ownership.FuelLeftEvidence

structure SuccessfulEval where
  remainingFuel : Nat
  trace : Except String Trace
  deriving Repr

def valueResult (p : Program) (fuel : Nat) : Except String SuccessfulEval := do
  let (value, state) ← (ValueSemantics.eval fuel p.declarations none [] p.main).run {fuel}
  let trace : Except String Trace := do
    ValueSemantics.observable value
    pure {reads := state.reads.toList, finalValue := value, externalReads := state.externalReads.toList}
  pure {remainingFuel := state.fuel, trace}

def heapResult (p : Program) (fuel : Nat) : Except String SuccessfulEval := do
  let (value, state) ← (InPlaceSemantics.eval fuel p.declarations none [] p.main).run {fuel}
  let trace : Except String Trace := do
    let finalValue ← InPlaceSemantics.snapshot state.heap observationDepth value
    pure {reads := state.reads.toList, finalValue, externalReads := state.externalReads.toList}
  pure {remainingFuel := state.fuel, trace}

def publicResult (result : Except String SuccessfulEval) : Except String Trace := do
  let completed ← result
  completed.trace

structure Tally where
  programs : Nat := 0
  accepted : Nat := 0
  rejected : Nat := 0
  runs : Nat := 0
  bothEvalSuccess : Nat := 0
  equalFuel : Nat := 0
  unequalFuel : Nat := 0
  valueEvalOnly : Nat := 0
  heapEvalOnly : Nat := 0
  bothEvalError : Nat := 0
  bothRunSuccess : Nat := 0
  traceMismatch : Nat := 0
  valueRunOnly : Nat := 0
  heapRunOnly : Nat := 0
  bothRunError : Nat := 0
  deriving Repr

def flat (s : String) : String := s.replace "\n" "\\n"

def one (label : String) (p : Program) (fuel : Nat) (start : Tally) : IO Tally := do
  let value := valueResult p fuel
  let heap := heapResult p fuel
  IO.println s!"{label}\tvalue-{fuel}\t{flat (reprStr value)}"
  IO.println s!"{label}\theap-{fuel}\t{flat (reprStr heap)}"
  let mut t := {start with runs := start.runs + 1}
  match value, heap with
  | .ok vs, .ok hs =>
    t := {t with bothEvalSuccess := t.bothEvalSuccess + 1}
    if vs.remainingFuel == hs.remainingFuel then
      t := {t with equalFuel := t.equalFuel + 1}
    else
      t := {t with unequalFuel := t.unequalFuel + 1}
      IO.eprintln s!"{label} fuel={fuel}: value-left={vs.remainingFuel}, heap-left={hs.remainingFuel}\n{repr p}"
  | .ok _, .error error =>
    t := {t with valueEvalOnly := t.valueEvalOnly + 1}
    IO.eprintln s!"{label} fuel={fuel}: only value evaluation succeeded; heap error={repr error}\n{repr p}"
  | .error error, .ok _ =>
    t := {t with heapEvalOnly := t.heapEvalOnly + 1}
    IO.eprintln s!"{label} fuel={fuel}: only heap evaluation succeeded; value error={repr error}\n{repr p}"
  | .error _, .error _ => t := {t with bothEvalError := t.bothEvalError + 1}
  match publicResult value, publicResult heap with
  | .ok a, .ok b =>
    t := {t with
      bothRunSuccess := t.bothRunSuccess + 1
      traceMismatch := t.traceMismatch + (if a == b then 0 else 1)}
    if a != b then IO.eprintln s!"{label} fuel={fuel}: public traces differ\n{repr p}"
  | .ok _, .error error =>
    t := {t with valueRunOnly := t.valueRunOnly + 1}
    IO.eprintln s!"{label} fuel={fuel}: only value run succeeded; heap error={repr error}"
  | .error error, .ok _ =>
    t := {t with heapRunOnly := t.heapRunOnly + 1}
    IO.eprintln s!"{label} fuel={fuel}: only heap run succeeded; value error={repr error}"
  | .error _, .error _ => t := {t with bothRunError := t.bothRunError + 1}
  pure t

def record (state : IO.Ref Tally) (label : String) (p : Program) (fuels : List Nat) : IO Unit := do
  let verdict := (check p).map fun _ => ()
  IO.println s!"{label}\tcheck\t{flat (reprStr verdict)}"
  let t ← state.get
  let t := {t with programs := t.programs + 1}
  if verdict.isOk then
    let mut t := {t with accepted := t.accepted + 1}
    for fuel in fuels do t ← one label p fuel t
    state.set t
  else
    state.set {t with rejected := t.rejected + 1}

def witness : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1])
    (.letE 1 (.prim (.literal .int) [.int 2])
      (.prim (.construct [true, true]) [.var 0, .var 1])) }

def run : IO UInt32 := do
  let state ← IO.mkRef ({} : Tally)
  let small := List.range 33 ++ [100000]
  record state "witness" witness small
  for f in Fixtures.all do record state s!"fixture:{f.id}" f.program [100000]
  for (name, p, _) in Sync.fixtures do record state s!"sync:{name}" p [100000]
  for (p, index) in Targeted.programs.zipIdx do record state s!"targeted:{index}" p [100000]
  for version in [5, 6] do
    for seed in [20261011, 17, 271828] do
      let mut generatorState := seed
      for index in List.range 20000 do
        let ((_, p), next) := (Oracle.generateVersion version).run generatorState
        generatorState := next
        record state s!"v{version}:{seed}:{index}" p (if version == 6 then small else [100000])
  let index ← IO.mkRef 0
  let walked ← Enumerate.walk 2 Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun body => do
    let i ← index.modifyGet fun n => (n, n + 1)
    record state s!"enum:{i}" {declarations := Generator.decls, main := body} [20000]
    pure true
  let expected ← Enumerate.countOnly 2
  let visited ← index.get
  let t ← state.get
  IO.eprintln s!"remaining-fuel enumeration: visited={visited} expected={expected} completed={walked}"
  IO.eprintln s!"remaining-fuel summary: {repr t}"
  let passed := walked && visited == expected && t.accepted > 0 && t.bothEvalSuccess > 0 && t.bothRunSuccess > 0 &&
    t.unequalFuel == 0 && t.valueEvalOnly == 0 && t.heapEvalOnly == 0 &&
    t.traceMismatch == 0 && t.valueRunOnly == 0 && t.heapRunOnly == 0
  pure (if passed then 0 else 1)

end Ownership.FuelLeftEvidence

def main : IO UInt32 := Ownership.FuelLeftEvidence.run
