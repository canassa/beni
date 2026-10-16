import Ownership.Fixtures
import Ownership.Enumerate

open Ownership

def flat (s : String) : String := s.replace "\n" "\\n"

def record (label : String) (p : Program) (small := false) (fuel := 100000) (rejected := false) : IO Unit := do
  let verdict := (check p).map fun _ => ()
  IO.println s!"{label}\tcheck\t{flat (reprStr verdict)}"
  if verdict.isOk then
    for fuel in (if small then List.range 33 else [fuel]) do
      IO.println s!"{label}\tvalue-{fuel}\t{flat (reprStr (ValueSemantics.run p fuel))}"
      IO.println s!"{label}\theap-{fuel}\t{flat (reprStr (InPlaceSemantics.run p fuel))}"
    if small then
      IO.println s!"{label}\tvalue-100000\t{flat (reprStr (ValueSemantics.run p 100000))}"
      IO.println s!"{label}\theap-100000\t{flat (reprStr (InPlaceSemantics.run p 100000))}"

  else if rejected then
    IO.println s!"{label}\tvalue-5000\t{flat (reprStr (ValueSemantics.run p 5000))}"
    IO.println s!"{label}\theap-5000\t{flat (reprStr (InPlaceSemantics.run p 5000))}"

def witness : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1])
    (.letE 1 (.prim (.literal .int) [.int 2])
      (.prim (.construct [true, true]) [.var 0, .var 1])) }

def main : IO Unit := do
  record "witness" witness true
  for f in Fixtures.all do record s!"fixture:{f.id}" f.program
  for (name, p, _) in Sync.fixtures do record s!"sync:{name}" p
  for (p, i) in Targeted.programs.zipIdx do record s!"targeted:{i}" p
  for version in [5, 6] do
    for seed in [20261011, 17, 271828] do
      let mut state := seed
      for i in List.range 20000 do
        let ((_, p), next) := (Oracle.generateVersion version).run state
        state := next
        record s!"v{version}:{seed}:{i}" p (version == 6) 100000 true
  let index ← IO.mkRef 0
  let _ ← Enumerate.walk 2 Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun main => do
    let i ← index.modifyGet fun i => (i, i + 1)
    record s!"enum:{i}" {declarations := Generator.decls, main} false 20000
    pure true
