import Ownership.Diagnostics
import Ownership.Falsify

/-! Per-call diagnostics for q2, R2, and legal read-only linked inputs.
The caller supplies a real call log from a program that `check` accepted.
This module performs no campaign or IO. It does not prove a soundness theorem.

Public-premise matching and diagnostic completeness are independent.
In particular, the current summary theorem has no observer-snapshot premise.
A dangling observer can therefore occur in a matched but incomplete call.
The chosen class descriptions use exactly the canonical naming; their extra
`closureAbs` naming never enters a premise check. -/

namespace Ownership.DiagnosticCalls

open InPlaceSemantics Soundness

inductive RootKind where
  | input
  | observer
  deriving Repr, BEq

inductive ClassFailure where
  | outerShape
  | alternatives
  | captureCount
  | captureShallow (capture : Nat) (detail : String)
  | captureAgreement (capture : Nat)
  deriving Repr

inductive PremiseFailure where
  | declaration
  | callDeclaration
  | arity
  | inputCount
  | separating
  | described (slot : Nat) (detail : String)
  | classes (slot : Nat) (reason : ClassFailure)
  | guardAnswer (slot : Nat)
  | guardEvaluation (slot : Nat) (detail : String)
  deriving Repr

inductive Incomplete where
  | snapshot (kind : RootKind) (index : Nat) (detail : String)
  | referenceGraph (kind : RootKind) (detail : String)
  | strictReach (kind : RootKind) (detail : String)
  | linkedComponent (address : Nat) (detail : String)
  deriving Repr

inductive PremiseStatus where
  | matched
  | unmatched (reason : PremiseFailure)
  | incomplete
  deriving Repr

def PremiseStatus.isMatched : PremiseStatus → Bool
  | .matched => true
  | _ => false

structure References where
  reachable : List Nat
  dangling : List Nat
  deriving Repr

/-- Missing arrays are explicit leaves. The complete finite reference set
includes roots and every heap edge, so the graph bound is not a depth limit. -/
def references (heap : Array (List Value)) (roots : List Value) : Except String References := do
  let vertices := (roots.flatMap Diagnostics.directRefs ++
    heap.toList.flatMap (fun xs => xs.flatMap Diagnostics.directRefs)).eraseDups
  let reached ← Diagnostics.graph vertices.length
    (fun c => pure ((heap[c]?.getD []).flatMap Diagnostics.directRefs))
    (roots.flatMap Diagnostics.directRefs)
  pure {reachable := reached, dangling := reached.filter fun c => c ≥ heap.size}

def snapshotIssues (heap : Array (List Value)) (roots : List Value)
    (kind : RootKind) : List Incomplete :=
  roots.zipIdx.filterMap fun (v, index) =>
    match snapshot heap Falsify.depthFuel v with
    | .ok _ => none
    | .error detail => some (.snapshot kind index detail)

/-- Exactly the outer `DescribesClosure` shape. Root provenance is not a
premise here; each capture still needs shallow description and recursive code
agreement under the same canonical naming. Snapshots precede this check. -/
def describesClosureB (gamma : Falsify.FNaming) (heap : Array (List Value))
    (a : Abstract) (v : Value) : Option ClassFailure := Id.run do
  match a, v with
  | .function _ alternatives, .closure id caps =>
    let mut firstFailure : Option ClassFailure := none
    for (candidate, abstracts) in alternatives do
      if candidate != id then continue
      if abstracts.length != caps.length then
        if firstFailure.isNone then firstFailure := some .captureCount
        continue
      let mut bad : Option ClassFailure := none
      for index in List.range caps.length do
        let abstractValue := abstracts[index]?.getD .bottom
        let concrete := caps[index]?.getD (.int 0)
        if let some detail := Falsify.shallowB gamma heap abstractValue concrete then
          bad := bad.orElse fun _ => some (.captureShallow index detail)
        else if !Falsify.closureAgreementB gamma heap Falsify.depthFuel abstractValue concrete then
          bad := bad.orElse fun _ => some (.captureAgreement index)
      if bad.isNone then return none
      firstFailure := firstFailure.orElse fun _ => bad
    return firstFailure.orElse fun _ => some .alternatives
  | .symbolic .., .closure _ _ => return none
  | .list cells _ _, .closure _ _ =>
    return if cells.contains .unknown then none else some .outerShape
  | _, _ => return some .outerShape

/-- Choose `fs` exactly as `Falsify.checkCall` does. Do not add the extra
site origins returned by `closureAbs` to the canonical naming. -/
def actualClasses (cr : CallRecord) (entry : CacheEntry) : List (Nat × Abstract) := Id.run do
  let inputs := cr.args ++ cr.caps
  let mut fs := []
  for (a, slot) in entry.inputs.zipIdx do
    if let .symbolic .. := a then
      let once := entry.summary.guards.any fun g =>
        g.query.slot == slot && g.query.fact == .once && !g.answer.isEmpty
      fs := fs ++ [(slot, (Falsify.closureAbs cr.preHeap (inputs[slot]?.getD (.int 0)) once).1)]
  return fs

/-- The supplied accepted result provides cache membership. The real call log
provides the successful execution. All remaining public premises are checked
under one canonical naming. Failed input snapshots block bounded helpers. -/
def premises (decls : List Decl) (cr : CallRecord) (entry : CacheEntry)
    (inputSnapshotsComplete : Bool) : PremiseStatus := Id.run do
  let some declaration := decls[entry.decl]? | return .unmatched .declaration
  if entry.decl != cr.decl then return .unmatched .callDeclaration
  if cr.args.length != declaration.parameters.length || cr.caps.length != declaration.captures.length then
    return .unmatched .arity
  if entry.inputs.length != cr.args.length + cr.caps.length then return .unmatched .inputCount
  if !inputSnapshotsComplete then return .incomplete
  let inputs := cr.args ++ cr.caps
  let gamma := Falsify.canonicalNaming cr.preHeap entry.inputs inputs declaration.parameters.length
  if !Falsify.separatingB gamma then return .unmatched .separating
  for (value, slot) in inputs.zipIdx do
    if let some detail := Falsify.describesB gamma cr.preHeap (entry.inputs[slot]?.getD .bottom) value then
      return .unmatched (.described slot detail)
  let fs := actualClasses cr entry
  for (slot, abstractValue) in fs do
    if let some reason := describesClosureB gamma cr.preHeap abstractValue (inputs[slot]?.getD (.int 0)) then
      return .unmatched (.classes slot reason)
  for g in entry.summary.guards do
    match (answer ({} : Config).inferenceFuel decls {} [{actuals := fs}] g.query).run {} with
    | .ok (answerValue, _) =>
      if answerValue != g.answer then return .unmatched (.guardAnswer g.query.slot)
    | .error detail => return .unmatched (.guardEvaluation g.query.slot detail)
  return .matched

inductive ObserverMode where
  | direct
  | linked
  deriving Repr, BEq

structure ObserverHit where
  input : Nat
  path : Path
  address : Nat
  mode : ObserverMode
  observedAddresses : List Nat
  deriving Repr

structure ReadOnlyLinkedContext where
  firstInput : Nat
  secondInput : Nat
  firstPath : Path
  secondPath : Path
  firstAddress : Nat
  secondAddress : Nat
  deriving Repr, BEq

/-- One concrete target of a canonical write or consume row. Observer presence
counts registrations, not overlap; observer hits remain separate evidence. -/
structure DemandTarget where
  input : Nat
  path : Path
  address : Nat
  linked : Bool
  withPermanentObservers : Bool
  deriving Repr, BEq

structure Candidate where
  cacheIndex : Nat
  status : PremiseStatus
  demandTargets : List DemandTarget := []
  observerHits : List ObserverHit := []
  readOnlyLinked : List ReadOnlyLinkedContext := []
  incomplete : List Incomplete := []
  deriving Repr

/-- Snapshot success makes `pathsOf` complete for these concrete values.
Only canonical W/C paths enter q2 counts. A called callback environment alone
does not establish a write and does not enter this category. -/
def inspectCandidate (decls : List Decl) (cr : CallRecord) (cacheIndex : Nat)
    (entry : CacheEntry) (inputSnapshotsComplete : Bool)
    (observed : List Nat) : Candidate := Id.run do
  let mut result : Candidate := {cacheIndex, status := premises decls cr entry inputSnapshotsComplete}
  if !inputSnapshotsComplete then return result
  let inputs := cr.args ++ cr.caps
  let paths := inputs.zipIdx.flatMap fun (value, slot) =>
    (Falsify.pathsOf cr.preHeap Falsify.depthFuel value []).filterMap fun (path, address) =>
      if ((entry.inputs[slot]?.getD .bottom).paths.map Prod.fst).contains path then
        some (slot, path, address)
      else none
  let paths := paths.eraseDups
  for (slot, path, address) in paths do
    if !rowHas (entry.summary.writes ++ entry.summary.consumes) (inputOrigin cr.args.length slot path) then
      continue
    if observed.contains address then
      result := {result with observerHits := result.observerHits ++
        [{input := slot, path, address, mode := .direct, observedAddresses := [address]}]}
    match Diagnostics.component cr.preHeap cr.preLinks address with
    | .error detail =>
      result := {result with
        demandTargets := result.demandTargets ++ [{input := slot, path, address, linked := false, withPermanentObservers := !cr.preKept.isEmpty}]
        incomplete := result.incomplete ++ [.linkedComponent address detail]}
    | .ok members =>
      result := {result with demandTargets := result.demandTargets ++
        [{input := slot, path, address, linked := members.any (· != address), withPermanentObservers := !cr.preKept.isEmpty}]}
      let linkedObserved := members.filter fun c => c != address && observed.contains c
      if !linkedObserved.isEmpty then
        result := {result with observerHits := result.observerHits ++
          [{input := slot, path, address, mode := .linked, observedAddresses := linkedObserved}]}
  -- These contexts have no summary permission to write an input. Excluding
  -- all called callbacks is conservative; no claim about their effects is needed.
  let inputReadOnly := entry.summary.writes.isEmpty && entry.summary.consumes.isEmpty &&
    entry.summary.calls.all (fun (_, count) => count == 0)
  if inputReadOnly then
    for (firstInput, firstPath, firstAddress) in paths do
      match Diagnostics.component cr.preHeap cr.preLinks firstAddress with
      | .error detail =>
        result := {result with incomplete := result.incomplete ++ [.linkedComponent firstAddress detail]}
      | .ok members =>
        for (secondInput, secondPath, secondAddress) in paths do
          if firstInput < secondInput && firstAddress != secondAddress && members.contains secondAddress then
            result := {result with readOnlyLinked := result.readOnlyLinked ++
              [{firstInput, secondInput, firstPath, secondPath, firstAddress, secondAddress}]}
  result := {result with readOnlyLinked := result.readOnlyLinked.eraseDups}
  return result

inductive Evidence where
  | dangling (kind : RootKind) (addresses : List Nat)
  | incomplete (reason : Incomplete)
  | unmatchedCandidate (cacheIndex : Nat) (reason : PremiseFailure)
  | incompleteCandidate (cacheIndex : Nat)
  | noCandidate
  | observedWrittenPath (cacheIndex : Nat) (matched : Bool) (hit : ObserverHit)
  | readOnlyLinkedContext (cacheIndex : Nat) (matched : Bool) (context : ReadOnlyLinkedContext)
  deriving Repr

structure Tally where
  calls : Nat := 0
  noCandidateCalls : Nat := 0
  matchedCalls : Nat := 0
  matchedDemandCalls : Nat := 0
  matchedDemandTargets : Nat := 0
  matchedLinkedDemandCalls : Nat := 0
  matchedLinkedDemandTargets : Nat := 0
  matchedObservedDemandCalls : Nat := 0
  matchedObservedDemandTargets : Nat := 0
  unmatchedCalls : Nat := 0
  premiseIncompleteCalls : Nat := 0
  incompleteCalls : Nat := 0
  candidates : Nat := 0
  matchedCandidates : Nat := 0
  unmatchedCandidates : Nat := 0
  incompleteCandidates : Nat := 0
  danglingInputCalls : Nat := 0
  danglingObserverCalls : Nat := 0
  matchedDanglingInputCalls : Nat := 0
  matchedDanglingObserverCalls : Nat := 0
  directObserverCalls : Nat := 0
  linkedObserverCalls : Nat := 0
  matchedDirectObserverCalls : Nat := 0
  matchedLinkedObserverCalls : Nat := 0
  readOnlyLinkedCalls : Nat := 0
  matchedReadOnlyLinkedCalls : Nat := 0
  deriving Repr

def Tally.add (a b : Tally) : Tally := {
  calls := a.calls + b.calls
  noCandidateCalls := a.noCandidateCalls + b.noCandidateCalls
  matchedCalls := a.matchedCalls + b.matchedCalls
  matchedDemandCalls := a.matchedDemandCalls + b.matchedDemandCalls
  matchedDemandTargets := a.matchedDemandTargets + b.matchedDemandTargets
  matchedLinkedDemandCalls := a.matchedLinkedDemandCalls + b.matchedLinkedDemandCalls
  matchedLinkedDemandTargets := a.matchedLinkedDemandTargets + b.matchedLinkedDemandTargets
  matchedObservedDemandCalls := a.matchedObservedDemandCalls + b.matchedObservedDemandCalls
  matchedObservedDemandTargets := a.matchedObservedDemandTargets + b.matchedObservedDemandTargets
  unmatchedCalls := a.unmatchedCalls + b.unmatchedCalls
  premiseIncompleteCalls := a.premiseIncompleteCalls + b.premiseIncompleteCalls
  incompleteCalls := a.incompleteCalls + b.incompleteCalls
  candidates := a.candidates + b.candidates
  matchedCandidates := a.matchedCandidates + b.matchedCandidates
  unmatchedCandidates := a.unmatchedCandidates + b.unmatchedCandidates
  incompleteCandidates := a.incompleteCandidates + b.incompleteCandidates
  danglingInputCalls := a.danglingInputCalls + b.danglingInputCalls
  danglingObserverCalls := a.danglingObserverCalls + b.danglingObserverCalls
  matchedDanglingInputCalls := a.matchedDanglingInputCalls + b.matchedDanglingInputCalls
  matchedDanglingObserverCalls := a.matchedDanglingObserverCalls + b.matchedDanglingObserverCalls
  directObserverCalls := a.directObserverCalls + b.directObserverCalls
  linkedObserverCalls := a.linkedObserverCalls + b.linkedObserverCalls
  matchedDirectObserverCalls := a.matchedDirectObserverCalls + b.matchedDirectObserverCalls
  matchedLinkedObserverCalls := a.matchedLinkedObserverCalls + b.matchedLinkedObserverCalls
  readOnlyLinkedCalls := a.readOnlyLinkedCalls + b.readOnlyLinkedCalls
  matchedReadOnlyLinkedCalls := a.matchedReadOnlyLinkedCalls + b.matchedReadOnlyLinkedCalls}

structure Inspection where
  tally : Tally
  evidence : List Evidence
  candidates : List Candidate
  deriving Repr

def bit (value : Bool) : Nat := if value then 1 else 0

/-- Inspect one real call. Counts refer to calls, not candidate summaries.
Matched calls satisfy at least one checked candidate under its canonical naming.
An incomplete call never supplies a complete zero-hit result, even if matched.
Always report unmatched and premise-incomplete counts beside matched counts.
Read-only linked contexts are observations of legal shapes, not q4 violations. -/
def inspectDetailed (decls : List Decl) (cache : Array CacheEntry) (cr : CallRecord) : Inspection := Id.run do
  let inputs := cr.args ++ cr.caps
  let inputSnapshots := snapshotIssues cr.preHeap inputs .input
  let observerSnapshots := snapshotIssues cr.preHeap cr.preKept.toList .observer
  let mut incomplete := inputSnapshots ++ observerSnapshots
  let mut evidence : List Evidence := []
  let mut inputDangling := false
  let mut observerDangling := false
  let inputReferences := references cr.preHeap inputs
  let observerReferences := references cr.preHeap cr.preKept.toList
  for (kind, scanResult) in [(RootKind.input, inputReferences), (.observer, observerReferences)] do
    match scanResult with
    | .error detail => incomplete := incomplete ++ [.referenceGraph kind detail]
    | .ok scan =>
      if !scan.dangling.isEmpty then
        evidence := evidence ++ [.dangling kind scan.dangling]
        match kind with
        | .input => inputDangling := true
        | .observer => observerDangling := true
  -- Strict reach failures remain explicit. The observer reference scan still
  -- gives exact relational reachability with dangling addresses as leaves.
  let mut observed : List Nat := []
  match observerReferences with
  | .ok scan => observed := scan.reachable
  | .error _ => pure ()
  for (kind, roots) in [(RootKind.input, inputs), (.observer, cr.preKept.toList)] do
    if let .error detail := Diagnostics.reach cr.preHeap roots then
      incomplete := incomplete ++ [.strictReach kind detail]
  let mut candidates := []
  for (entry, cacheIndex) in cache.toList.zipIdx do
    if entry.decl != cr.decl then continue
    let candidate := inspectCandidate decls cr cacheIndex entry inputSnapshots.isEmpty observed
    candidates := candidates ++ [candidate]
    incomplete := incomplete ++ candidate.incomplete
    match candidate.status with
    | .matched => pure ()
    | .unmatched reason => evidence := evidence ++ [.unmatchedCandidate cacheIndex reason]
    | .incomplete => evidence := evidence ++ [.incompleteCandidate cacheIndex]
    for hit in candidate.observerHits do
      evidence := evidence ++ [.observedWrittenPath cacheIndex candidate.status.isMatched hit]
    for context in candidate.readOnlyLinked do
      evidence := evidence ++ [.readOnlyLinkedContext cacheIndex candidate.status.isMatched context]
  if candidates.isEmpty then evidence := evidence ++ [.noCandidate]
  evidence := evidence ++ incomplete.map Evidence.incomplete
  let matched := candidates.any (fun c => c.status.isMatched)
  let hasMode := fun (cs : List Candidate) (mode : ObserverMode) =>
    cs.any fun c => c.observerHits.any fun h => h.mode == mode
  let matchedCandidates := candidates.filter fun c => c.status.isMatched
  -- One call can match several cache entries. Count each concrete canonical
  -- target once across those entries, independently of observer-hit evidence.
  let matchedTargets := (matchedCandidates.flatMap (·.demandTargets)).eraseDups
  let linkedTargets := matchedTargets.filter (·.linked)
  let observedTargets := matchedTargets.filter (·.withPermanentObservers)
  let hasReadOnly := fun (cs : List Candidate) => cs.any fun c => !c.readOnlyLinked.isEmpty
  let isUnmatched := fun (c : Candidate) => match c.status with | .unmatched _ => true | _ => false
  let isIncomplete := fun (c : Candidate) => match c.status with | .incomplete => true | _ => false
  return {
    tally := {
      calls := 1
      noCandidateCalls := bit candidates.isEmpty
      matchedCalls := bit matched
      matchedDemandCalls := bit (!matchedTargets.isEmpty)
      matchedDemandTargets := matchedTargets.length
      matchedLinkedDemandCalls := bit (!linkedTargets.isEmpty)
      matchedLinkedDemandTargets := linkedTargets.length
      matchedObservedDemandCalls := bit (!observedTargets.isEmpty)
      matchedObservedDemandTargets := observedTargets.length
      unmatchedCalls := bit (!matched && !candidates.any isIncomplete)
      premiseIncompleteCalls := bit (!matched && candidates.any isIncomplete)
      incompleteCalls := bit (!incomplete.isEmpty || candidates.any isIncomplete)
      candidates := candidates.length
      matchedCandidates := matchedCandidates.length
      unmatchedCandidates := (candidates.filter isUnmatched).length
      incompleteCandidates := (candidates.filter isIncomplete).length
      danglingInputCalls := bit inputDangling
      danglingObserverCalls := bit observerDangling
      matchedDanglingInputCalls := bit (matched && inputDangling)
      matchedDanglingObserverCalls := bit (matched && observerDangling)
      directObserverCalls := bit (hasMode candidates .direct)
      linkedObserverCalls := bit (hasMode candidates .linked)
      matchedDirectObserverCalls := bit (hasMode matchedCandidates .direct)
      matchedLinkedObserverCalls := bit (hasMode matchedCandidates .linked)
      readOnlyLinkedCalls := bit (hasReadOnly candidates)
      matchedReadOnlyLinkedCalls := bit (hasReadOnly matchedCandidates)}
    evidence, candidates}

/-- The runner-facing view preserves the typed inspection internally. Every
unmatched candidate and every incomplete check receives a printable record. -/
def inspect (decls : List Decl) (cache : Array CacheEntry)
    (cr : CallRecord) : Tally × List String :=
  let result := inspectDetailed decls cache cr
  (result.tally, result.evidence.map reprStr)

end Ownership.DiagnosticCalls
