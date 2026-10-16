import Ownership.DiagnosticCalls
import Ownership.DiagnosticFixtures
import Ownership.Enumerate
import Ownership.Fixtures

namespace Ownership.DiagnosticCampaign

open InPlaceSemantics

structure Tally where
  programs : Nat := 0
  rejected : Nat := 0
  accepted : Nat := 0
  completed : Nat := 0
  executionErrors : Nat := 0
  snapshotErrors : Nat := 0
  divergences : Nat := 0
  incompletePrograms : Nat := 0
  withLinks : Nat := 0
  attemptedWrites : Nat := 0
  changedWrites : Nat := 0
  linkedWrites : Nat := 0
  checkedReaders : Nat := 0
  q1HitPrograms : Nat := 0
  q1Hits : Nat := 0
  calls : DiagnosticCalls.Tally := {}
  deriving Repr

def finish (value : Value) (state : InPlaceSemantics.State) : Except String Trace := do
  let finalValue ← snapshot state.heap observationDepth value
  pure {reads := state.reads.toList, finalValue, externalReads := state.externalReads.toList}

def inspect (label : String) (p : Program) (t0 : Tally) (out : IO.FS.Handle)
    (fuel := 100000) : IO Tally := do
  let t := {t0 with programs := t0.programs + 1}
  let .ok accepted := check p | return {t with rejected := t.rejected + 1}
  let mut t := {t with accepted := t.accepted + 1}
  let ordinary := Diagnostics.run p {fuel}
  let instrumented := Diagnostics.run p {fuel, enabled := true}
  match ordinary, instrumented with
  | .error a, .error b =>
    if a != b then
      out.putStrLn s!"{label}\tDIVERGENCE\tordinary={repr a}\tdiagnostic={repr b}\n{repr p}"
      return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}
    out.putStrLn s!"{label}\tEXECUTION INCOMPLETE\t{repr a}"
    return {t with executionErrors := t.executionErrors + 1, incompletePrograms := t.incompletePrograms + 1}
  | .ok ((a, sa), _), .ok ((b, sb), report) =>
    if !(a == b && Diagnostics.stateEqual sa sb) then
      out.putStrLn s!"{label}\tSTATE DIVERGENCE\n{repr p}"
      return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}
    match finish a sa, finish b sb with
    | .ok ta, .ok tb =>
      if ta != tb then
        out.putStrLn s!"{label}\tTRACE DIVERGENCE\n{repr p}"
        return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}
    | .error error, .error same =>
      if error != same then
        out.putStrLn s!"{label}\tSNAPSHOT DIVERGENCE\n{repr p}"
        return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}
      out.putStrLn s!"{label}\tSNAPSHOT INCOMPLETE\t{repr error}"
      return {t with snapshotErrors := t.snapshotErrors + 1, incompletePrograms := t.incompletePrograms + 1}
    | _, _ =>
      out.putStrLn s!"{label}\tSNAPSHOT DIVERGENCE\n{repr p}"
      return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}
    let mut incomplete := !report.incomplete.isEmpty
    for problem in report.incomplete do out.putStrLn s!"{label}\tQ1 INCOMPLETE\t{problem}"
    for hit in report.hits do out.putStrLn s!"{label}\tQ1 HIT\t{repr hit}\n{repr p}"
    t := {t with
      withLinks := t.withLinks + (if sa.links.isEmpty then 0 else 1)
      attemptedWrites := t.attemptedWrites + report.attemptedWrites
      changedWrites := t.changedWrites + report.changedWrites
      linkedWrites := t.linkedWrites + report.linkedWrites
      checkedReaders := t.checkedReaders + report.checkedReaders
      q1HitPrograms := t.q1HitPrograms + (if report.hits.isEmpty then 0 else 1)
      q1Hits := t.q1Hits + report.hits.size}
    for (call, index) in sa.calls.toList.zipIdx do
      let (counts, evidence) := DiagnosticCalls.inspect p.declarations accepted.cache call
      t := {t with calls := t.calls.add counts}
      if counts.incompleteCalls > 0 then incomplete := true
      for item in evidence do out.putStrLn s!"{label}\tcall={index}\t{item}"
    if incomplete then return {t with incompletePrograms := t.incompletePrograms + 1}
    return {t with completed := t.completed + 1}
  | _, _ =>
    out.putStrLn s!"{label}\tEXECUTION DIVERGENCE\n{repr p}"
    return {t with divergences := t.divergences + 1, incompletePrograms := t.incompletePrograms + 1}

def clean (t : Tally) : Bool :=
  t.programs > 0 && t.accepted > 0 && t.completed == t.accepted && t.incompletePrograms == 0 &&
  t.divergences == 0 && t.q1Hits == 0 && t.calls.incompleteCalls == 0 &&
  t.calls.danglingInputCalls == 0 && t.calls.danglingObserverCalls == 0 &&
  t.calls.directObserverCalls == 0 && t.calls.linkedObserverCalls == 0 && t.calls.noCandidateCalls == 0

/-- Finite coverage is explicit: fixtures, the whole grammar at `bound`, and
both generators at three seeds. Every accepted run needs exact state/trace
agreement before it contributes complete diagnostics. -/
def run (count seed bound : Nat) (path : String) : IO Bool := do
  let out ← IO.FS.Handle.mk path .write
  out.putStrLn s!"grammar={Enumerate.grammarVersion} bound={bound} count={count} seeds={( [seed, 17, 271828] : List Nat).eraseDups}"
  if !(← DiagnosticFixtures.run out) then
    IO.println "diagnostic controls failed"
    return false
  let mut fixtures : Tally := {}
  for f in Fixtures.all do fixtures ← inspect s!"fixture:{f.id}" f.program fixtures out
  for (name, p, _) in Sync.fixtures do fixtures ← inspect s!"sync:{name}" p fixtures out
  for (p, index) in Targeted.programs.zipIdx do fixtures ← inspect s!"targeted:{index}" p fixtures out
  for (name, p) in DiagnosticFixtures.acceptedPrograms do fixtures ← inspect s!"diagnostic:{name}" p fixtures out
  IO.println s!"diagnostics fixtures: {repr fixtures} clean={clean fixtures}"
  let result ← IO.mkRef ({} : Tally)
  let index ← IO.mkRef 0
  let walked ← Enumerate.walk bound Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun main => do
    let i ← index.modifyGet fun n => (n, n + 1)
    result.set (← inspect s!"enum:{i}" {declarations := Generator.decls, main} (← result.get) out 20000)
    pure true
  let enumerated ← result.get
  let expected ← Enumerate.countOnly bound
  let pinned := if bound == 2 then expected == 105150 else if bound == 1 then expected == 200 else true
  let enumerationComplete := walked && enumerated.programs == expected && pinned && Enumerate.grammarVersion == 2
  IO.println s!"diagnostics grammar={Enumerate.grammarVersion} bound={bound} expected={expected}: {repr enumerated} complete={enumerationComplete} clean={clean enumerated}"
  let mut ok := clean fixtures && enumerationComplete && clean enumerated
  let mut calls := fixtures.calls.add enumerated.calls
  for version in [5, 6] do
    for seed in ([seed, 17, 271828] : List Nat).eraseDups do
      let mut t : Tally := {}
      let mut state := seed
      for i in List.range count do
        let ((_, p), next) := (Oracle.generateVersion version).run state
        state := next
        t ← inspect s!"v{version}:{seed}:{i}" p t out
      IO.println s!"diagnostics version={version} seed={seed} count={count}: {repr t} clean={clean t}"
      ok := ok && clean t
      calls := calls.add t.calls
  let nonvacuous := calls.matchedDemandCalls > 0 && calls.matchedLinkedDemandCalls > 0 &&
    calls.matchedObservedDemandCalls > 0 && calls.matchedReadOnlyLinkedCalls > 0
  IO.println s!"diagnostics all calls: {repr calls} nonvacuous={nonvacuous}"
  ok := ok && nonvacuous
  out.flush
  IO.println s!"diagnostics clean={ok} evidence={path}"
  pure ok

end Ownership.DiagnosticCampaign
