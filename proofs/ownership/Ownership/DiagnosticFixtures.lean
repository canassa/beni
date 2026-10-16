import Ownership.Checker
import Ownership.DiagnosticCalls

/-! Diagnostic fixtures. The case tables state predictions. The runner checks
those predictions and reports actual failures without a checker change.

Run `safeCases` through the ordinary checker before the diagnostic interpreter.
Run `rejectedCases` and `shadowControls` without the checker for diagnostic tests.
Keep checker rejection and diagnostic hits as separate results.
Compare every diagnostic run with the ordinary in-place run at the same fuel.
Compare the complete runtime state, result, and error. A failed run is incomplete.
Never count an incomplete run as a clean result.

The diagnostic predicate tests every attempted write. It includes no-op writes
and writes that leave the live counterpart unchanged. Such hits need a separate
classification. `staleBuilderPut` and `noOpLive` test these two cases.

Each view family runs with `front = true` and `front = false`. Sources contain three
items, so both views are nonempty and share their sources through real links.
The program cases use no synthetic heaps or checker environments. Separate call
controls use arbitrary pre-states and cache entries from accepted programs.
-/

namespace Ownership.DiagnosticFixtures

private def v := Atom.var
private def l : Ty := .list .int
private def fresh : Expr := .prim (.literal .int) [.int 10, .int 20, .int 30]
private def push (a : Atom) : Expr := .prim .push [a, .int 99]

/-- Bind source 0 and view 1. Later binders start at 2. -/
private def withView (front : Bool) (rest : Expr) (ds : List Decl := []) : Program := {
  declarations := ds
  main := .letE 0 fresh <| .letE 1 (.prim (.view front) [v 0]) rest }

/-- The fixed generator table has no read-only two-list declaration. -/
def readBoth : Decl := {
  name := "readBoth", parameters := [l, l], result := .record [.int, .int]
  body := .letE 2 (.prim .length [v 0]) <|
    .letE 3 (.prim .length [v 1]) (.prim .record [v 2, v 3]) }

private def grow : Decl := {
  name := "grow", parameters := [l], result := l, body := push (v 0) }

def readOnlyCall (front : Bool) : Program :=
  withView front (.letE 2 (.closure 0 []) (.app (v 2) [v 1, v 0])) [readBoth]

def firstOrderWriteCall : Program := {
  declarations := [grow]
  main := .letE 0 fresh <| .letE 1 (.closure 0 []) (.app (v 1) [v 0]) }

/-- The caller keeps no future use of the source or the callee closure. -/
def writeViewCall (front : Bool) : Program :=
  withView front (.letE 2 (.closure 0 []) (.app (v 2) [v 1])) [grow]

/-- The permanent observer holds an independent list throughout the call. -/
def observedIndependentWriteCall : Program := {
  declarations := [grow]
  main := .letE 0 fresh <| .letE 1 (.prim .shared [v 0]) <|
    .letE 2 fresh <| .letE 3 (.closure 0 []) (.app (v 3) [v 2]) }

/-- The counterpart has one completed read. Its old reference stays in the
environment but no continuation uses it at the write. -/
def deadCounterpart (front throughView : Bool) : Program :=
  let receiver := v (if throughView then 1 else 0)
  let counterpart := v (if throughView then 0 else 1)
  withView front <| .letE 2 (.prim .length [counterpart]) <|
    .letE 3 (push receiver) (.prim .record [v 2, v 3])

def mainLive (front throughView : Bool) : Program :=
  let receiver := v (if throughView then 1 else 0)
  let counterpart := v (if throughView then 0 else 1)
  withView front <| .letE 2 (push receiver) (.prim .record [v 2, counterpart])

/-- The callee has no local name for the caller's live view. -/
def callerLive (front : Bool) : Program :=
  withView front (.letE 2 (.closure 0 []) <|
    .letE 3 (.app (v 2) [v 0]) (.prim .record [v 3, v 1])) [grow]

/-- The only future reader holds the view in a closure capture. -/
def closureReaderLive (front : Bool) : Program :=
  let reader : Decl := {
    name := "readCaptured", parameters := [], captures := [l], result := .int
    body := .prim .length [v 0] }
  withView front (.letE 2 (.closure 0 [v 1]) <|
    .letE 3 (push (v 0)) (.app (v 2) [])) [reader]

/-- Only the permanent observer retains the view at the write. No future
expression names the view or the result of `shared`. -/
def permanentObserverLive (front : Bool) : Program :=
  withView front <| .letE 2 (.prim .shared [v 1]) <|
    .letE 3 (push (v 0)) (.atom (v 3))

/-- The outer traversal's unread second row holds the view. An inner range
traversal writes the first row. No later main expression names either row.
With `linked = false`, the second row is fresh and the old view is dead. -/
def nestedTraversal (front linked : Bool) : Program :=
  withView front <| .letE 2 (if linked then .atom (v 1) else fresh) <|
    .letE 3 (.prim (.literal l) [v 0, v 2]) <|
    .traverse .list (v 3) (.int 0) 4 5 6 <|
      .traverse .range (.int 1) (v 6) 7 8 9 <|
        .letE 10 (push (v 5)) (.atom (v 9))

/-- The outer focus's sibling holds the view below a nested list. The inner
focus writes the source. Its own row has no sibling and no future reader.
With `linked = false`, the outer sibling holds an independent fresh list. -/
def nestedFocus (front linked : Bool) : Program :=
  withView front <| .letE 2 (if linked then .atom (v 1) else fresh) <|
    .letE 3 (.prim (.literal l) [v 0]) <|
    .letE 4 (.prim (.literal l) [v 2]) <|
    .letE 5 (.prim (.literal (.list l)) [v 3, v 4]) <|
    .focus (v 5) (.int 0) 6 <| .focus (v 6) (.int 0) 7 (push (v 7))

/-- The base is fresh. The later spread reads a linked view, and its source
stays live. The construction writes neither side of that link. -/
def constructionReadOnlySpread (front : Bool) : Program :=
  withView front <| .letE 2 fresh <|
    .letE 3 (.prim (.construct [true, false, true]) [v 2, .int 99, v 1])
      (.prim .record [v 3, v 0])

/-- The item write changes a later spread before its loop starts. The spread
then grows with the base, so the ordinary interpreter reports an error.
The pending spread is a reader at the first write. The failed run is incomplete.
If an error discards the report, it still cannot count as a clean result. -/
def constructionPendingSpread (front : Bool) : Program :=
  withView front <| .prim (.construct [true, false, true]) [v 0, .int 99, v 1]

/-- Retained atoms refer to the outer environment. They become permanent
readers only after initialization. The initial result does not exist earlier. -/
def entryPendingRetained (front : Bool) : Program :=
  withView front <| .entry (push (v 0)) [v 1] 2 (.prim .length [v 2])

/-- The entry body has an outer free use. The model binder is a different name. -/
def entryPendingBody (front : Bool) : Program :=
  withView front <| .entry (push (v 0)) [] 2 <|
    .letE 3 (.prim .length [v 1]) (.prim .length [v 2])

/-- A recursive call restores its captures from `self`. Its explicit operands
do not name the view. The next base case reads the implicit captured view. -/
def recursiveSelfCapture (front write : Bool) : Program :=
  let d : Decl := {
    name := "recursiveReadCaptured", parameters := [.int, l], captures := [l]
    result := .int
    body := .branch (v 0) (.prim .length [v 2]) <|
      .letE 3 (.prim .sub [v 0, .int 1]) <|
      if write then .letE 4 (push (v 1)) (.recur [v 3, v 4])
      else .letE 4 (.prim .length [v 1]) (.recur [v 3, v 1]) }
  withView front (.letE 2 (.closure 0 [v 1]) (.app (v 2) [.int 1, v 0])) [d]

/-- The builder and its closed list have the same runtime address. After a
view exists, a stale builder `put` changes the source but does not refresh
the view. The checker rejects the stale alias. Diagnostics must still report
the attempted write, even though the live counterpart stays unchanged. -/
def staleBuilderPut (front : Bool) : Program := {
  main := .letE 0 (.prim (.builder .int) []) <|
    .letE 1 (.prim .put [v 0, .int 10]) <|
    .letE 2 (.prim .put [v 1, .int 20]) <|
    .letE 3 (.prim .put [v 2, .int 30]) <|
    .letE 4 (.prim .close [v 3]) <|
    .letE 5 (.prim (.view front) [v 4]) <|
    .letE 6 (.prim .put [v 3, .int 99]) (.prim .record [v 5, v 6]) }

/-- The out-of-range set changes neither array. The diagnostic predicate
still reports an attempted write with a distinct live linked counterpart. -/
def noOpLive (front : Bool) : Program :=
  withView front <| .letE 2 (.prim .set [v 0, .int 99, .int 7])
    (.prim .record [v 2, v 1])

/-- The final use of 1 names the outer view. The inner 1 is a fresh list.
Ordinary typing accepts the terms, but noShadowing rejects the program.
An unchecked diagnostic run must pin the outer reader before the inner binder. -/
def shadowedOuter (front : Bool) : Program :=
  withView front <|
    .letE 2 (.letE 1 fresh (push (v 0))) (.prim .length [v 1])

/-- The retained atom reads outer 1 before the model binder reuses that name.
This is an unchecked control: the language forbids the model shadow. -/
def shadowedEntry (front : Bool) : Program :=
  withView front <| .entry (push (v 0)) [v 1] 1 (.prim .length [v 1])

/-- Initialization only allocates a fresh list. The body writes the source.
The outer continuation still reads the old view named 1 after the entry ends.
The model binder also uses 1, so the diagnostic must pin the inherited reader. -/
def shadowedEntryBody (front : Bool) : Program :=
  withView front <| .letE 2 (.entry fresh [] 1 (push (v 0))) (.prim .length [v 1])

inductive DiagnosticExpected where
  | clean
  | hit
  | incomplete
  deriving Repr, BEq

structure Case where
  name : String
  program : Program
  diagnostic : DiagnosticExpected
  coverage : String

private def direction (front : Bool) : String := if front then "rest" else "init"

/-- These cases predict checker acceptance and zero diagnostic hits. -/
def safeCases : List Case := [
  { name := "first-order write call", program := firstOrderWriteCall
    diagnostic := .clean, coverage := "accepted first-order written-input demand" },
  { name := "write call with independent permanent observer", program := observedIndependentWriteCall
    diagnostic := .clean, coverage := "written input stays separate from a real pre-call permanent observer" }
] ++ [true, false].flatMap fun front =>
  let side := direction front
  [
    { name := s!"{side}: read-only view/source call", program := readOnlyCall front
      diagnostic := .clean, coverage := "readBoth reads both linked arguments without a write" },
    { name := s!"{side}: write call with source dead", program := writeViewCall front
      diagnostic := .clean, coverage := "accepted written-input demand has real links and a dead counterpart" },
    { name := s!"{side}: source write after view dies", program := deadCounterpart front false
      diagnostic := .clean, coverage := "a completed length read does not keep the old view live" },
    { name := s!"{side}: view write after source dies", program := deadCounterpart front true
      diagnostic := .clean, coverage := "a completed length read does not keep the old source live" },
    { name := s!"{side}: independent nested focus rows", program := nestedFocus front false
      diagnostic := .clean, coverage := "outer focus sibling has an independent row" },
    { name := s!"{side}: construction reads linked spread", program := constructionReadOnlySpread front
      diagnostic := .clean, coverage := "pending spread and its live source stay read-only" },
    { name := s!"{side}: recursive read-only captures", program := recursiveSelfCapture front false
      diagnostic := .clean, coverage := "recursion restores a linked read-only capture" }
  ]

/-- The inner range step consumes the outer element as a capture. The checker
applies its conservative many-call rule even when the range has one item.
These programs finish with zero hits and exact ordinary/diagnostic agreement.
Their rejection follows the many-call contract and is not a checker defect. -/
def rejectedCleanCases : List Case := [true, false].map fun front =>
  { name := s!"{direction front}: independent nested traversal rows"
    program := nestedTraversal front false, diagnostic := .clean
    coverage := "outer suffix has an independent row; many-call capture rule still rejects the inner step" }

/-- These cases predict ownership rejection. Execute them unchecked to test
diagnostic hits. A hit alone does not establish an observable disagreement. -/
def rejectedCases : List Case := [true, false].flatMap fun front =>
  let side := direction front
  [
    { name := s!"{side}: source write with main view live", program := mainLive front false
      diagnostic := .hit, coverage := "main continuation retains the linked view" },
    { name := s!"{side}: view write with main source live", program := mainLive front true
      diagnostic := .hit, coverage := "main continuation retains the linked source" },
    { name := s!"{side}: caller retains the view", program := callerLive front
      diagnostic := .hit, coverage := "caller continuation crosses a callee frame" },
    { name := s!"{side}: future closure retains the view", program := closureReaderLive front
      diagnostic := .hit, coverage := "continuation reader reaches the view through a closure capture" },
    { name := s!"{side}: permanent observer retains the view", program := permanentObserverLive front
      diagnostic := .hit, coverage := "only pre.kept retains the linked view at the write" },
    { name := s!"{side}: outer traversal pending row", program := nestedTraversal front true
      diagnostic := .hit, coverage := "outer unread suffix survives an inner traversal frame" },
    { name := s!"{side}: outer focus sibling", program := nestedFocus front true
      diagnostic := .hit, coverage := "outer sibling survives an inner focus frame" },
    { name := s!"{side}: retained atom pending at entry", program := entryPendingRetained front
      diagnostic := .hit, coverage := "outer retained atom is pending before its permanent registration" },
    { name := s!"{side}: outer body use pending at entry", program := entryPendingBody front
      diagnostic := .hit, coverage := "free body use crosses initialization; the model has no pre-value" },
    { name := s!"{side}: recursive implicit capture", program := recursiveSelfCapture front true
      diagnostic := .hit, coverage := "implicit self capture survives before a recursive call" },
    { name := s!"{side}: stale builder put", program := staleBuilderPut front
      diagnostic := .hit, coverage := "raw put changes the receiver and leaves the live counterpart unchanged" },
    { name := s!"{side}: no-op set with live view", program := noOpLive front
      diagnostic := .hit, coverage := "attempted write changes neither receiver nor counterpart" }
  ]

/-- These cases predict ordinary typing success and shadow-check rejection. -/
def shadowControls : List Case := [true, false].flatMap fun front =>
  let side := direction front
  [
    { name := s!"{side}: shadowed outer continuation", program := shadowedOuter front
      diagnostic := .hit, coverage := "pin the outer reader before the inner let replaces its name" },
    { name := s!"{side}: retained outer atom with model shadow", program := shadowedEntry front
      diagnostic := .hit, coverage := "retained atoms use outerenv before the model binder" },
    { name := s!"{side}: entry body shadows inherited reader", program := shadowedEntryBody front
      diagnostic := .hit, coverage := "entry body preserves an inherited outer reader after the model binder" }
  ]

/-- These cases predict checker rejection and an incomplete unchecked run. -/
def incompleteControls : List Case := [true, false].map fun front =>
  { name := s!"{direction front}: construction pending linked spread"
    program := constructionPendingSpread front, diagnostic := .incomplete
    coverage := "first item write has a pending linked spread; its later loop detects growth" }

/-- The campaign includes every predicted accepted fixture. -/
def acceptedPrograms : List (String × Program) :=
  safeCases.map fun c => (c.name, c.program)

/-- The Boolean is the predicted ordinary checker verdict. Every case also
needs an unchecked runtime comparison, including checker-rejected controls. -/
def expectedCases : List (Bool × Case) :=
  safeCases.map (fun c => (true, c)) ++
  (rejectedCleanCases ++ rejectedCases ++ shadowControls ++ incompleteControls).map (fun c => (false, c))

private def fixtureFuel : Nat := 100000

private def finalTrace (value : InPlaceSemantics.Value)
    (state : InPlaceSemantics.State) : Except String Trace := do
  let finalValue ← InPlaceSemantics.snapshot state.heap observationDepth value
  pure {reads := state.reads.toList, finalValue, externalReads := state.externalReads.toList}

private structure ControlResult where
  passed : Bool
  completed : Nat := 0
  incomplete : Nat := 0
  hits : Nat := 0

private def sameError (out : IO.FS.Handle) (c : Case) (checkerMatches : Bool)
    (stage ordinary diagnostic : String) : IO ControlResult := do
  let equal := ordinary == diagnostic
  let expected := c.diagnostic == .incomplete
  let passed := checkerMatches && equal && expected
  out.putStrLn s!"control:{c.name}\t{stage} INCOMPLETE\tordinary={repr ordinary}\tdiagnostic={repr diagnostic}\tequal={equal}\texpected={expected}\tpassed={passed}"
  pure {passed, incomplete := 1}

/-- Checker agreement never substitutes for the unchecked runtime comparison. -/
private def runCase (out : IO.FS.Handle) (expectedChecker : Bool) (c : Case) : IO ControlResult := do
  let checker := check c.program
  let checkerMatches := checker.isOk == expectedChecker
  let checkerDetail := match checker with
    | .ok _ => "accepted"
    | .error detail => s!"rejected: {detail}"
  out.putStrLn s!"control:{c.name}\tCHECKER\texpected={expectedChecker}\tactual={checkerDetail}\tmatched={checkerMatches}\tcoverage={c.coverage}"
  let ordinary := Diagnostics.run c.program {fuel := fixtureFuel}
  let diagnostic := Diagnostics.run c.program {fuel := fixtureFuel, enabled := true}
  match ordinary, diagnostic with
  | .error a, .error b => sameError out c checkerMatches "EXECUTION" a b
  | .ok ((a, sa), _), .ok ((b, sb), report) =>
    for problem in report.incomplete do
      out.putStrLn s!"control:{c.name}\tQ1 INCOMPLETE\t{problem}"
    for hit in report.hits do out.putStrLn s!"control:{c.name}\tQ1 HIT\t{repr hit}"
    if !(a == b && Diagnostics.stateEqual sa sb) then
      out.putStrLn s!"control:{c.name}\tVALUE OR STATE DIVERGENCE\n{repr c.program}"
      return {passed := false, incomplete := 1}
    match finalTrace a sa, finalTrace b sb with
    | .error a, .error b => sameError out c checkerMatches "SNAPSHOT" a b
    | .ok ta, .ok tb =>
      if ta != tb then
        out.putStrLn s!"control:{c.name}\tTRACE DIVERGENCE\n{repr c.program}"
        return {passed := false, incomplete := 1}
      if !report.incomplete.isEmpty then
        out.putStrLn s!"control:{c.name}\tEXPECTED COMPLETE DIAGNOSTICS\tpassed=false"
        return {passed := false, incomplete := 1}
      let expected := match c.diagnostic with
        | .clean => report.hits.isEmpty
        | .hit => !report.hits.isEmpty
        | .incomplete => false
      let passed := checkerMatches && expected
      out.putStrLn s!"control:{c.name}\tCOMPLETE\tvalue-state-trace-equal=true\texpected={repr c.diagnostic}\thits={report.hits.size}\tpassed={passed}"
      pure {passed, completed := 1, hits := report.hits.size}
    | .error error, .ok _ =>
      out.putStrLn s!"control:{c.name}\tSNAPSHOT DIVERGENCE\tordinary-error={repr error}\tdiagnostic=success\n{repr c.program}"
      pure {passed := false, incomplete := 1}
    | .ok _, .error error =>
      out.putStrLn s!"control:{c.name}\tSNAPSHOT DIVERGENCE\tordinary=success\tdiagnostic-error={repr error}\n{repr c.program}"
      pure {passed := false, incomplete := 1}
  | .error error, .ok _ =>
    out.putStrLn s!"control:{c.name}\tEXECUTION DIVERGENCE\tordinary-error={repr error}\tdiagnostic=success\n{repr c.program}"
    pure {passed := false, incomplete := 1}
  | .ok _, .error error =>
    out.putStrLn s!"control:{c.name}\tEXECUTION DIVERGENCE\tordinary=success\tdiagnostic-error={repr error}\n{repr c.program}"
    pure {passed := false, incomplete := 1}

private inductive CallExpected where
  | directObserver
  | linkedObserver
  | revivedObserver
  deriving Repr

private structure CallControl where
  name : String
  program : Program
  pre : InPlaceSemantics.State
  expected : CallExpected

private def writerCallProgram : Program := {
  declarations := [grow]
  main := .letE 0 (.prim (.literal .int) []) <|
    .letE 1 (.closure 0 []) (.app (v 1) [v 0]) }

private def holderCallProgram : Program := {
  declarations := [{
    name := "hold", parameters := [l], result := .int
    body := .letE 1 (.prim (.literal l) [v 0]) (.atom (.int 0)) }]
  main := .letE 0 (.prim (.literal .int) []) <|
    .letE 1 (.closure 0 []) (.app (v 1) [v 0]) }

/-- These arbitrary states do not claim accepted caller reachability. Each
control executes a real callee and uses the accepted program's actual cache. -/
private def callControls : List CallControl := [
  { name := "q2 direct observed writer", program := writerCallProgram
    pre := {fuel := fixtureFuel, heap := #[[]], kept := #[.ref 0]}
    expected := .directObserver },
  { name := "q2 linked observed writer", program := writerCallProgram
    pre := {fuel := fixtureFuel, heap := #[[], [.int 10]], kept := #[.ref 1], links := [(0, 1, true)]}
    expected := .linkedObserver },
  { name := "R2 allocation revives dangling observer", program := holderCallProgram
    pre := {fuel := fixtureFuel, heap := #[[]], kept := #[.ref 1]}
    expected := .revivedObserver }
]

private def runCallControl (out : IO.FS.Handle) (c : CallControl) : IO Bool := do
  let checked := check c.program
  let .ok accepted := checked | do
    let problem := match checked with | .error detail => detail | .ok _ => "unexpected acceptance"
    out.putStrLn s!"call-control:{c.name}\tCHECKER FAILED\t{problem}\tpassed=false"
    return false
  let some declaration := c.program.declarations[0]? | do
    out.putStrLn s!"call-control:{c.name}\tMISSING DECLARATION\tpassed=false"
    return false
  let args : List InPlaceSemantics.Value := [.ref 0]
  let ordinary := Soundness.callResult c.program.declarations 0 args [] fixtureFuel c.pre
  let diagnostic := (Diagnostics.eval fixtureFuel c.program.declarations (some (0, []))
    (bindArgs args) declaration.body [] [] []).run {} |>.run c.pre
  match ordinary, diagnostic with
  | .ok (a, sa), .ok ((b, report), sb) =>
    if !(a == b && Diagnostics.stateEqual sa sb && report.incomplete.isEmpty) then
      out.putStrLn s!"call-control:{c.name}\tVALUE OR STATE DIVERGENCE OR INCOMPLETE DIAGNOSTICS\tpassed=false"
      return false
    match finalTrace a sa, finalTrace b sb with
    | .ok ta, .ok tb =>
      if ta != tb then
        out.putStrLn s!"call-control:{c.name}\tTRACE DIVERGENCE\tpassed=false"
        return false
    | .error a, .error b =>
      out.putStrLn s!"call-control:{c.name}\tSNAPSHOT INCOMPLETE\tequal={a == b}\tordinary={repr a}\tdiagnostic={repr b}\tpassed=false"
      return false
    | _, _ =>
      out.putStrLn s!"call-control:{c.name}\tSNAPSHOT DIVERGENCE\tpassed=false"
      return false
    let record : InPlaceSemantics.CallRecord := {
      decl := 0, args, caps := [], preHeap := c.pre.heap, preKept := c.pre.kept
      preLinks := c.pre.links, postHeap := sa.heap, postKept := sa.kept, result := a }
    let inspected := DiagnosticCalls.inspectDetailed c.program.declarations accepted.cache record
    let t := inspected.tally
    for evidence in inspected.evidence do
      out.putStrLn s!"call-control:{c.name}\t{repr evidence}"
    let matched := t.calls == 1 && t.matchedCalls == 1 && t.matchedCandidates > 0 &&
      t.unmatchedCandidates == 0 && t.incompleteCandidates == 0 && t.danglingInputCalls == 0
    let expected := match c.expected with
      | .directObserver =>
        t.matchedDirectObserverCalls == 1 && t.matchedLinkedObserverCalls == 0 &&
        t.danglingObserverCalls == 0 && t.incompleteCalls == 0
      | .linkedObserver =>
        t.matchedDirectObserverCalls == 0 && t.matchedLinkedObserverCalls == 1 &&
        t.danglingObserverCalls == 0 && t.incompleteCalls == 0
      | .revivedObserver =>
        let revived := match DiagnosticCalls.references c.pre.heap c.pre.kept.toList,
            DiagnosticCalls.references sa.heap sa.kept.toList with
          | .ok pre, .ok post =>
            pre.dangling == [1] && !pre.reachable.contains 0 &&
            post.dangling.isEmpty && post.reachable.contains 0
          | _, _ => false
        let noEffects := accepted.cache.toList.all fun entry =>
          entry.summary.writes.isEmpty && entry.summary.consumes.isEmpty && entry.summary.escapes.isEmpty
        t.matchedDanglingObserverCalls == 1 && t.incompleteCalls == 1 &&
        t.matchedDirectObserverCalls == 0 && t.matchedLinkedObserverCalls == 0 && revived && noEffects
    let passed := matched && expected
    out.putStrLn s!"call-control:{c.name}\texpected={repr c.expected}\tvalue-state-trace-equal=true\tactual={repr t}\tpassed={passed}"
    pure passed
  | .error a, .error b =>
    out.putStrLn s!"call-control:{c.name}\tEXECUTION INCOMPLETE\tequal={a == b}\tordinary={repr a}\tdiagnostic={repr b}\tpassed=false"
    pure false
  | _, _ =>
    out.putStrLn s!"call-control:{c.name}\tEXECUTION DIVERGENCE\tpassed=false"
    pure false

/-- Expected errors pass only their error controls. They never enter the
completed-program count. Every other control needs exact complete runtime agreement. -/
def run (out : IO.FS.Handle) : IO Bool := do
  let mut completed := 0
  let mut incomplete := 0
  let mut failed := 0
  let mut hits := 0
  for (expectedChecker, c) in expectedCases do
    let result ← runCase out expectedChecker c
    completed := completed + result.completed
    incomplete := incomplete + result.incomplete
    hits := hits + result.hits
    if !result.passed then failed := failed + 1
  let mut callFailed := 0
  for c in callControls do
    if !(← runCallControl out c) then callFailed := callFailed + 1
  let passed := !expectedCases.isEmpty && failed == 0 && callFailed == 0
  let summary := s!"diagnostic controls: cases={expectedCases.length} completed={completed} incomplete={incomplete} hits={hits} failed={failed} call-controls={callControls.length} call-failed={callFailed} passed={passed}"
  out.putStrLn summary
  out.flush
  IO.println summary
  pure passed

/-! Coverage limits:

* The normal checker forbids shadowing. Only unchecked controls exercise it.
* The constructor cannot finish after a linked spread grows with its base.
  Keep its incomplete result separate from successful hit controls.
* The closed programs do not create an allocated heap cycle or a dangling reference.
  The separate R2 call control starts from an arbitrary dangling observer.
* These cases do not cover every primitive, branch, or callback class guard.
  The extended grammar and the full campaigns provide the wider case set.
-/

end Ownership.DiagnosticFixtures
