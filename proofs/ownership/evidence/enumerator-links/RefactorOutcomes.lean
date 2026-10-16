import Ownership.Fixtures
import Ownership.Enumerate

open Ownership

def flat (s : String) : String := s.replace "\n" "\\n"

def heapOutcome (p : Program) (fuel : Nat) := do
  let (v, s) ← (InPlaceSemantics.eval fuel p.declarations none [] p.main).run {fuel}
  pure (v, s.fuel, s.heap, s.links, s.reads, s.kept, s.externalReads, s.writes)

def valueOutcome (p : Program) (fuel : Nat) := do
  let (v, s) ← (ValueSemantics.eval fuel p.declarations none [] p.main).run {fuel}
  pure (v, s.fuel, s.reads, s.kept, s.externalReads)

def record (label : String) (p : Program) (fuel := 100000) : IO Unit := do
  let verdict := (check p).map fun _ => ()
  IO.println s!"{label}\tcheck\t{flat (reprStr verdict)}"
  let fuel := if verdict.isOk then fuel else 5000
  IO.println s!"{label}\tvalue-{fuel}\t{flat (reprStr (valueOutcome p fuel))}"
  IO.println s!"{label}\theap-{fuel}\t{flat (reprStr (heapOutcome p fuel))}"

def main : IO Unit := do
  for f in Fixtures.all do record s!"fixture:{f.id}" f.program
  for (name, p, _) in Sync.fixtures do record s!"sync:{name}" p
  for (p, i) in Targeted.programs.zipIdx do record s!"targeted:{i}" p
  for version in [5, 6] do
    for seed in [20261011, 17, 271828] do
      let mut state := seed
      for i in List.range 20000 do
        let ((_, p), next) := (Oracle.generateVersion version).run state
        state := next
        record s!"v{version}:{seed}:{i}" p
  let index ← IO.mkRef 0
  let _ ← Enumerate.walk 2 Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun main => do
    let i ← index.modifyGet fun i => (i, i + 1)
    record s!"enum:{i}" {declarations := Generator.decls, main} 20000
    pure true
