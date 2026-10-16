import Ownership.DiagnosticCalls
import Ownership.DiagnosticFixtures
import Ownership.Enumerate
import Ownership.Fixtures

namespace Ownership.DiagnosticCampaign

open InPlaceSemantics

/-- Separate reach counts never turn a rejected program into an accepted failure. -/
structure Reach where
  mainView : Nat := 0
  mainSource : Nat := 0
  callView : Nat := 0
  callSource : Nat := 0
  other : Nat := 0
  deriving Repr

def Reach.add (a b : Reach) : Reach :=
  {mainView := a.mainView + b.mainView, mainSource := a.mainSource + b.mainSource,
   callView := a.callView + b.callView, callSource := a.callSource + b.callSource,
   other := a.other + b.other}

def Reach.complete (r : Reach) : Bool :=
  r.mainView > 0 && r.mainSource > 0 && r.callView > 0 && r.callSource > 0

/-- The diagnostic site encoding stores call identifiers after tags 2 and 3.
Traversal tag 12 also carries an index, which is not a context tag. -/
def inCall : List Nat → Bool
  | [] => false
  | 2 :: _ :: _ | 3 :: _ :: _ => true
  | 12 :: _ :: rest => inCall rest
  | _ :: rest => inCall rest

def reachCounts (links : List (Nat × Nat × Bool)) (report : Diagnostics.Report) : Reach := Id.run do
  let mut r : Reach := {}
  for h in report.hits do
    let view := links.any fun (v, s, _) => v == h.receiver && s == h.counterpart
    let source := links.any fun (v, s, _) => v == h.counterpart && s == h.receiver
    if inCall h.site then
      if view then r := {r with callView := r.callView + 1}
      else if source then r := {r with callSource := r.callSource + 1}
      else r := {r with other := r.other + 1}
    else
      if view then r := {r with mainView := r.mainView + 1}
      else if source then r := {r with mainSource := r.mainSource + 1}
      else r := {r with other := r.other + 1}
  return r

structure Tally where
  programs : Nat := 0
  rejected : Nat := 0
  rejectedUntyped : Nat := 0
  rejectedCompleted : Nat := 0
  rejectedExecutionErrors : Nat := 0
  rejectedIncomplete : Nat := 0
  rejectedHitPrograms : Nat := 0
  rejectedReach : Reach := {}
  acceptedReach : Reach := {}
  rawObservedCalls : Nat := 0
  rawObserverErrors : Nat := 0
  rejectedRawObservedCalls : Nat := 0
  rejectedRawObserverErrors : Nat := 0
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

/-- Compare actual pre/post observer storage without cache rows or summaries. -/
def rawObservedWrites (calls : Array CallRecord) : Nat × Nat := Id.run do
  let mut hits := 0
  let mut errors := 0
  for call in calls do
    match DiagnosticCalls.references call.preHeap call.preKept.toList with
    | .error _ => errors := errors + 1
    | .ok refs =>
      if !refs.dangling.isEmpty then errors := errors + 1
      if refs.reachable.any (fun c => call.preHeap[c]? != call.postHeap[c]?) then
        hits := hits + 1
  return (hits, errors)

def inspectRejected (label : String) (p : Program) (t : Tally) (out : IO.FS.Handle) : IO Tally := do
  let t := {t with rejected := t.rejected + 1}
  if !(typesOf p).isOk then return {t with rejectedUntyped := t.rejectedUntyped + 1}
  -- Rejected programs can grow without the checker's restrictions. Keep this cap fixed.
  match Diagnostics.run p {fuel := 5000, enabled := true, logCalls := true} with
  | .error error =>
    out.putStrLn s!"{label}\tREJECTED EXECUTION INCOMPLETE\t{repr error}"
    return {t with rejectedExecutionErrors := t.rejectedExecutionErrors + 1}
  | .ok ((_, state), report) =>
    let reach := reachCounts state.links report
    let (rawHits, rawErrors) := rawObservedWrites state.calls
    if rawHits > 0 || rawErrors > 0 then
      out.putStrLn s!"{label}\tREJECTED RAW OBSERVERS\thits={rawHits} errors={rawErrors}"
    if !report.hits.isEmpty then
      out.putStrLn s!"{label}\tREJECTED REACH\t{repr reach}\n{repr p}"
    for problem in report.incomplete do out.putStrLn s!"{label}\tREJECTED DIAGNOSTIC INCOMPLETE\t{problem}"
    return {t with
      rejectedCompleted := t.rejectedCompleted + 1
      rejectedIncomplete := t.rejectedIncomplete + (if report.incomplete.isEmpty then 0 else 1),
      rejectedHitPrograms := t.rejectedHitPrograms + (if report.hits.isEmpty then 0 else 1),
      rejectedReach := t.rejectedReach.add reach
      rejectedRawObservedCalls := t.rejectedRawObservedCalls + rawHits
      rejectedRawObserverErrors := t.rejectedRawObserverErrors + rawErrors}

def inspect (label : String) (p : Program) (t0 : Tally) (out : IO.FS.Handle)
    (fuel := 100000) : IO Tally := do
  let t := {t0 with programs := t0.programs + 1}
  let .ok accepted := check p | inspectRejected label p t out
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
    let (rawHits, rawErrors) := rawObservedWrites sa.calls
    if rawHits > 0 || rawErrors > 0 then
      out.putStrLn s!"{label}\tACCEPTED RAW OBSERVERS\thits={rawHits} errors={rawErrors}\n{repr p}"
    t := {t with rawObservedCalls := t.rawObservedCalls + rawHits, rawObserverErrors := t.rawObserverErrors + rawErrors}
    let mut incomplete := !report.incomplete.isEmpty || rawErrors > 0
    for problem in report.incomplete do out.putStrLn s!"{label}\tQ1 INCOMPLETE\t{problem}"
    for hit in report.hits do out.putStrLn s!"{label}\tQ1 HIT\t{repr hit}\n{repr p}"
    t := {t with
      acceptedReach := t.acceptedReach.add (reachCounts sa.links report)
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
  t.divergences == 0 && t.q1Hits == 0 && t.rawObservedCalls == 0 && t.rawObserverErrors == 0 && t.calls.incompleteCalls == 0 &&
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
  let pinned := if bound == 2 then expected == 157824 else if bound == 1 then expected == 399 else true
  let enumerationComplete := walked && enumerated.programs == expected && pinned && Enumerate.grammarVersion == 3
  IO.println s!"diagnostics grammar={Enumerate.grammarVersion} bound={bound} expected={expected}: {repr enumerated} complete={enumerationComplete} clean={clean enumerated}"
  let mut ok := clean fixtures && enumerationComplete && clean enumerated
  let mut calls := fixtures.calls.add enumerated.calls
  let mut reach := fixtures.rejectedReach.add enumerated.rejectedReach
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
      reach := reach.add t.rejectedReach
  let nonvacuous := calls.matchedDemandCalls > 0 && calls.matchedLinkedDemandCalls > 0 &&
    calls.matchedObservedDemandCalls > 0 && calls.matchedReadOnlyLinkedCalls > 0 &&
    enumerated.rejectedReach.complete
  IO.println s!"diagnostics rejected reach: {repr reach} enumerated-reach-complete={enumerated.rejectedReach.complete} fuel=5000"
  IO.println "diagnostics read-only linked calls include planted controls; the generated accepted case set previously contained none"
  IO.println s!"diagnostics all calls: {repr calls} nonvacuous={nonvacuous}"
  ok := ok && nonvacuous
  out.flush
  IO.println s!"diagnostics clean={ok} evidence={path}"
  pure ok

end Ownership.DiagnosticCampaign
