import Ownership.Bridge
open Ownership

-- Replay the original deterministic streams, selecting only retained leads.
-- No checker verdict gates execution in either interpreter.
def observationJson : Observation → String
  | .int n => toString n
  | .record fs => "{" ++ String.intercalate "," (fs.attach.zipIdx.map fun (x, i) =>
      Bridge.quote s!"f{i}" ++ ":" ++ observationJson x.val) ++ "}"
  | .list xs => Bridge.arr (xs.attach.map fun x => observationJson x.val)
  | .closure d xs => "{\"closure\":" ++ toString d ++ ",\"captures\":" ++
      Bridge.arr (xs.attach.map fun x => observationJson x.val) ++ "}"
termination_by o => sizeOf o
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

def traceJson (t : Trace) : String :=
  "{\"result\":" ++ observationJson t.finalValue ++
  ",\"reads\":" ++ Bridge.arr (t.reads.map observationJson) ++
  ",\"externalReads\":" ++ Bridge.arr (t.externalReads.map fun xs =>
    Bridge.arr (xs.map observationJson)) ++ "}"

def judge (out : IO.FS.Handle) (id phase : String) (p : Program) : IO Unit := do
  let _ ← match typecheck p with
    | .ok t => pure t | .error e => throw (IO.userError s!"{id}: {e}")
  let a ← match ValueSemantics.run p with
    | .ok t => pure t | .error e => throw (IO.userError s!"{id} value: {e}")
  let b ← match InPlaceSemantics.run p with
    | .ok t => pure t | .error e => throw (IO.userError s!"{id} in-place: {e}")
  let reason := match check p with | .ok _ => "" | .error e => e
  out.putStrLn ("{\"id\":" ++ Bridge.quote id ++ ",\"phase\":" ++ Bridge.quote phase ++
    ",\"diverges\":" ++ toString (a != b) ++ ",\"lean\":" ++ Bridge.quote reason ++
    ",\"value\":" ++ traceJson a ++ ",\"inPlace\":" ++ traceJson b ++
    ",\"core\":" ++ Bridge.arr [Bridge.arr (p.declarations.map Bridge.decl), Bridge.expr p.main] ++ "}")

def main (args : List String) : IO Unit := do
  let [input, output] := args.take 2 | throw (IO.userError "usage: triage input.tsv output.jsonl [--only]")
  unless args.length == 2 || args == [input, output, "--only"] do
    throw (IO.userError "unknown triage arguments")
  let out ← IO.FS.Handle.mk output .write
  let mut ids : Std.HashSet String := {}
  for line in (← IO.FS.readFile input).splitOn "\n" do
    if line.isEmpty then continue
    let [id, wire] := line.splitOn "\t" | throw (IO.userError "bad triage line")
    let p ← match BridgeWire.program wire with
      | .ok p => pure p | .error e => throw (IO.userError e)
    if ids.contains id then throw (IO.userError s!"duplicate {id}")
    ids := ids.insert id
    judge out id "minimum" p
  if args.contains "--only" then
    out.flush
    return
  let seen ← IO.mkRef ({} : Std.HashSet String)
  let emit := fun id p => do
    if ids.contains id then
      judge out id "original" p
      seen.modify (·.insert id)
  for (f, i) in Fixtures.all.zipIdx do emit s!"fixture-{i}" f.program
  for ((_, p, _), i) in Sync.fixtures.zipIdx do emit s!"sync-{i}" p
  for (p, i) in Targeted.programs.zipIdx do emit s!"targeted-{i}" p
  let index ← IO.mkRef 0
  let _ ← Enumerate.walk 2 Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun main => do
    let i ← index.modifyGet fun n => (n, n+1)
    emit s!"enum-2-{i}" { declarations := Generator.decls, main }
    pure true
  for seed in [17, 20261011, 314159] do
    let mut state := seed
    for i in List.range 20000 do
      let ((_, p), next) := (Oracle.generateVersion 5).run state
      state := next
      emit s!"seed-{seed}-{i}" p
  unless (← seen.get).size == ids.size do throw (IO.userError "missing original leads")
  out.flush
  IO.println s!"judged {ids.size} originals and minima"
