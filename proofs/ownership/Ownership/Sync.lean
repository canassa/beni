import Ownership.Oracle
import Ownership.Falsify

/-! Small executable projections of the Zig ownership fixtures. Markup's opaque
slots are positional fields; a constructor is an ordinary zero-capture record
function. `owned` is the platform's returns-owned boundary, not a permission to
mutate: its two interpreters are identities. The continuation acts as the receiver
and edits the delivered value, making a false ownership claim observable. -/
namespace Ownership.Sync
private def v := Atom.var
private def l := Ty.list Ty.int
private def lit (n : Int) : Expr := .prim (.literal .int) [.int n]
private def push (a : Atom) : Expr := .prim .push [a, .int 9]
private def get : Decl := {
  name := "get", parameters := [.int], captures := [l], result := l
  body := .atom (v 1) }
private def scalar : Decl := { name := "scalar", parameters := [.int], captures := [.int], result := .int, body := .atom (v 1) }
private def boundary (t : Ty) (forwarded : Bool) : Decl := {
  name := if forwarded then "forwardNeed" else "unseenNeed"
  parameters := if forwarded then [.fn [.int] t] else [t, .fn [.int] t]
  result := t
  body := if forwarded then
    .letE 1 (.app (v 0) [.int 0]) (.prim (.owned true) [v 1, v 0])
  else .prim (.owned false) [v 0, v 1] }

/-- AlternativeArmEscapes / RealEscape: the count is not used as a path proof. -/
def branchEscape (n : Int) (before joined : Bool := false) : Program := {
  main := .letE 0 (lit n) <|
    .letE 1 (if before then .prim .shared [v 0] else .atom (.int 0)) <|
    .letE 2 (.branch (.int n)
      (.letE 3 (.prim .shared [v 0]) (.atom (.int 0)))
      (.letE 3 (push (v 0)) (.prim .length [v 3]))) <|
    if joined then .letE 4 (push (v 0)) (.prim .length [v 4]) else .atom (v 2) }

/-- BranchEscapes.afterCall and .repeat: summary joins are not arm-local. -/
def branchCall (n : Int) (recursive := false) : Program := {
  declarations := [{
    name := "escape", parameters := [.int, l], result := .int
    body := .branch (v 0)
      (.letE 2 (.prim .shared [v 1]) <|
        if recursive then .recur [.int 1, v 1] else .atom (.int 0))
      (if recursive then .letE 2 (push (v 1)) (.prim .length [v 2]) else .atom (.int 0)) }]
  main := .letE 0 (lit n) <| .letE 1 (.closure 0 []) <|
    .letE 2 (.app (v 1) [.int 0, v 0]) <|
    if recursive then .atom (v 2) else .letE 3 (push (v 0)) (.prim .length [v 3]) }

/-- Prepend: a prior edit must see the base's later read. -/
def prepend (n : Int) (edit := false) : Program := {
  main := .letE 0 (lit n) <|
    .letE 1 (if edit then push (v 0) else .atom (.int 0)) <|
    .letE 2 (.prim .prepend [.int 7, v 0]) (.prim .length [v 2]) }

/-- MaybeDefault / ResultDefault after map/case lowering. An eager edit cannot
    inherit the disjoint default/map arms. No sum types or failing map opcode. -/
def withDefault (n : Int) (eager reread : Bool := false) : Program := {
  main := .letE 0 (lit n) <|
    .letE 1 (if eager then push (v 0) else .atom (v 0)) <|
    .letE 2 (.branch (.int n) (push (v 1)) (.atom (v 0))) <|
    if reread then .prim .record [v 0, v 2] else .atom (v 2) }

/-- FoldContainer / ModelExclusive: two distinct positions must never be
    certified from the freshness of their outer list. Both positions are run. -/
def invariant (n : Int) (kind : Source) (duplicate := false) : Program := {
  main := .letE 0 (lit n) <| .letE 1 (lit (n+1)) <|
    .letE 2 (.prim (.literal l) [v 0, if duplicate then v 0 else v 1]) <|
    .traverse kind (.int 2) (v 2) 3 4 5
      (.focus (v 5) (v 3) 6 (push (v 6))) }

/-- Fresh update allocations must be proved by every arm. A duplicated
    update result refutes preservation even though init was separated. -/
def modelUpdate (n : Int) (duplicate escaped : Bool := false) : Program := {
  main := .letE 0 (lit n) <| .letE 1 (lit (n+1)) <|
    .letE 2 (.prim (.literal l) [v 0, v 1]) <|
    .traverse .model (.int 2) (v 2) 3 4 5 <|
      .branch (v 3)
        (if escaped then .prim .shared [v 5] else
          .letE 6 (lit n) <| .letE 7 (lit (n+1)) <|
            .prim (.literal l) [v 6, if duplicate then v 6 else v 7])
        (.focus (v 5) (.int 0) 6 (push (v 6))) }

/-- Shared, escaped, captured and duplicated-result accumulator twins. -/
def badFold (n : Int) (which : Nat) : Program := {
  declarations := [get]
  main := .letE 0 (lit n) <|
    .letE 1 (if which == 0 then .prim .shared [v 0] else .atom (v 0)) <|
    .letE 2 (.prim (.literal l) [v 1]) <|
    .traverse .range (.int 2) (v 2) 3 4 5 <|
      if which == 1 then
        .letE 6 (.prim .shared [v 5]) (.focus (v 5) (.int 0) 7 (push (v 7)))
      else if which == 2 then
        .letE 6 (.focus (v 5) (.int 0) 7 <|
          .letE 8 (.closure 0 [v 7]) <|
          .letE 9 (push (v 7)) <| .letE 10 (.app (v 8) [.int 0]) (.atom (v 9))) (.atom (v 6))
      else if which == 3 then
        .branch (v 3)
          (.letE 6 (.prim (.literal .int) []) <| .letE 7 (.prim .at [v 5, .int 0, v 6])
            (.prim (.literal l) [v 7, v 7]))
          (.focus (v 5) (.int 0) 7 (push (v 7)))
      else .focus (v 5) (.int 0) 7 (push (v 7)) }

/-- FoldAccumulators.capturedAfter: the reader is stored after appending.
    The old reader is retained through the next iteration's write. -/
def capturedAfter (n : Int) : Program := {
  declarations := [get]
  main := .letE 0 (lit n) <|
    .letE 1 (.prim (.literal (.fn [.int] l)) []) <|
    .letE 2 (.prim .record [v 0, v 1]) <|
    .letE 9 (.traverse .range (.int 2) (v 2) 3 4 5 <|
      .letE 6 (push (.field (v 5) 0)) <|
      .letE 7 (.closure 0 [v 6]) <|
      .letE 8 (.prim .push [.field (v 5) 1, v 7]) (.prim .record [v 6, v 8])) <|
    .letE 10 (lit 0) <| .letE 11 (.closure 0 [v 10]) <|
    .letE 12 (.prim .at [.field (v 9) 1, .int 0, v 11]) <|
    .letE 13 (.app (v 12) [.int 0]) (.prim .record [.field (v 9) 0, v 13]) }

/-- SubscriptionTapFold's written footprint: the same opaque callback may
    capture a list in every tap; the tap-list containers themselves differ. -/
def taps (n : Int) (duplicate nestedWrite := false) : Program := Id.run do
  let f := Ty.fn [.int] l
  return {
    declarations := [get]
    main := .letE 0 (lit n) <| .letE 1 (.closure 0 [v 0]) <|
      .letE 2 (.prim (.literal f) [v 1]) <| .letE 3 (.prim (.literal f) [v 1]) <|
      .letE 4 (.prim (.literal (.list f)) [v 2, if duplicate then v 2 else v 3]) <|
      .letE 5 (.traverse .range (.int 2) (v 4) 6 7 8 <|
        .focus (v 8) (v 6) 9 <|
          if nestedWrite then
            .letE 10 (.prim .at [v 9, .int 0, v 1]) <|
            .letE 11 (.app (v 10) [.int 0]) <| .letE 12 (push (v 11)) (.atom (v 9))
          else .prim .push [v 9, v 1]) <|
      .prim .record [v 5, v 0] }

/-- The fold starts empty and allocates a fresh tap container per step.
    Reusing that container at two positions is the rejected twin. -/
def freshTaps (n : Int) (duplicate := false) : Program := Id.run do
  let f := Ty.fn [.int] l
  return {
    declarations := [get]
    main := .letE 0 (lit n) <| .letE 1 (.closure 0 [v 0]) <|
      .letE 2 (.prim (.literal (.list f)) []) <|
      .letE 3 (.traverse .range (.int 2) (v 2) 4 5 6 <|
        .letE 7 (.prim (.literal f) [v 1]) <|
        .letE 8 (.prim .push [v 6, v 7]) <|
        if duplicate then .prim .push [v 8, v 7] else .atom (v 8)) <|
      .letE 10 (.focus (v 3) (.int 0) 11 (.prim .push [v 11, v 1])) <|
      .prim .record [v 10, v 0] }

/-- Appending a record can retain an earlier position's container in its
    callback. No write is needed to refute the advertised spine certificate. -/
def earlierCapture (n : Int) (focus := false) (viaFold := false) : Program := Id.run do
  let f := Ty.fn [.int] l
  let r := Ty.record [l, f]
  return {
    declarations := [get]
    main := .letE 0 (lit n) <| .letE 1 (lit (n+1)) <| .letE 2 (.closure 0 [v 1]) <|
      .letE 3 (.prim .record [v 0, v 2]) <|
      .letE 14 (lit (n+2)) <| .letE 15 (.prim .record [v 14, v 2]) <|
      .letE 4 (.prim (.literal r) [v 3, v 15]) <|
      .letE 5 (lit 0) <| .letE 6 (.prim .record [v 5, v 2]) <|
      .letE 7 (.prim .at [v 4, .int 0, v 6]) <|
      if viaFold then
        .letE 16 (.prim (.literal l) [.field (v 7) 0]) <|
        .traverse .list (v 16) (v 4) 17 18 19 <|
          .letE 8 (lit 2) <| .letE 9 (.closure 0 [v 18]) <|
          .letE 10 (.prim .record [v 8, v 9]) (.prim .push [v 19, v 10])
      else if focus then .focus (v 4) (.int 1) 13 <|
        .letE 8 (lit 2) <| .letE 9 (.closure 0 [.field (v 7) 0]) (.prim .record [v 8, v 9])
      else .letE 8 (lit 2) <| .letE 9 (.closure 0 [.field (v 7) 0]) <|
        .letE 10 (.prim .record [v 8, v 9]) (.prim .push [v 4, v 10]) }

/-- Markup render/event slots: the render alias remains visible to general
    ownership checks, but the event projection excludes it. -/
def markup (n : Int) (handler renderWrite := false) (depth : Nat := 0) : Program := Id.run do
  let mk : Atom → Nat → Atom := fun a d => (List.range d).foldl (fun b _ => .field b 0) a
  let finish := fun k =>
    if renderWrite then Expr.letE 30 (push (v 0)) (.prim .record [v k, v 30])
    else .letE 20 (.prim .events [mk (v k) depth]) <|
      if handler then .letE 21 (.app (v 20) [.int 0]) <|
        .letE 22 (push (v 21)) (.prim .record [v k, v 22])
      else .prim .record [v k, v 20]
  let body := (List.range depth).foldr (fun j e => Expr.letE (4+j) (.prim .record [v (3+j)]) e) (finish (3+depth))
  return {
    declarations := [get]
    main := .letE 0 (lit n) <| .letE 1 (.closure 0 [v 0]) <|
      .letE 3 (.prim .record [v 0, if handler then v 1 else .int 0]) body }

/-- Constructors carried through a helper remain ordinary zero-capture classes.
    Dropping the record's list-bearing argument loses the later-read alias. -/
def constructor (n : Int) (listPayload : Bool) : Program := Id.run do
  let t := if listPayload then l else Ty.int
  return {
    declarations := [
      { name := "Ctor", parameters := [t], result := .record [t], body := .prim .record [v 0] },
      { name := "carry", parameters := [.fn [t] (.record [t]), t], result := .record [t],
        body := .app (v 0) [v 1] }]
    main := .letE 0 (lit n) <| .letE 1 (.closure 0 []) <| .letE 2 (.closure 1 []) <|
      .letE 3 (.app (v 2) [v 1, if listPayload then v 0 else .int n]) <|
      .letE 4 (push (v 0)) (.prim .record [v 3, v 4]) }

/-- Unseen tagger / cell-free captured message / enclosing callback `need`.
    Returning a capture is not fresh-across-calls, even if calls were unseen. -/
def owned (n : Int) (which : Nat) (safe := false) : Program := {
  declarations := [get, scalar, boundary (if safe then .int else l) (which == 2)]
  main := .letE 0 (lit n) <|
    .letE 1 (if which == 0 && !safe then .prim .shared [v 0] else .atom (v 0)) <|
    .letE 2 (.closure (if safe then 1 else 0) (if safe then [.int n] else [v 1])) <|
    .letE 3 (.app (v 2) [.int n]) <|
    .letE 7 (.closure 2 []) <|
    .letE 4 (if which == 1 then .prim (.owned false) [v 3, v 2]
      else .app (v 7) (if which == 2 then [v 2] else [v 3, v 2])) <|
    if safe then .prim .record [v 2, v 4]
    else .letE 5 (push (v 4)) <| .letE 6 (.app (v 2) [.int n]) (.prim .record [v 5, v 6]) }

def ownedFresh (n : Int) : Program := {
  declarations := [
    {name := "fresh", parameters := [.int], result := l, body := .prim (.literal .int) [v 0]},
    boundary l true]
  main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
    .letE 2 (.app (v 1) [v 0]) <| .letE 3 (push (v 2)) <|
    .letE 4 (.app (v 0) [.int n]) (.prim .record [v 3, v 4]) }

/-- Finite products, independent of seeds. These are not fixed probes alone. -/
def programs : List Program := [-1, 0, 1, 2].flatMap fun n =>
  [branchEscape n, branchEscape n true, branchEscape n false true, branchCall n, branchCall n true,
   modelUpdate n, modelUpdate n true, modelUpdate n false true,
   prepend n, prepend n true, withDefault n, withDefault n true, withDefault n false true] ++
  [Source.range, Source.model].flatMap (fun kind => [false,true].map (fun duplicate => invariant n kind duplicate)) ++
  [0,1,2,3].map (badFold n) ++
  [earlierCapture n, earlierCapture n true, earlierCapture n false true, capturedAfter n, taps n, taps n true, taps n false true, freshTaps n, freshTaps n true] ++
  [0,1,2,3].flatMap (fun d => [markup n false false d, markup n true false d, markup n false true d]) ++
  [constructor n false, constructor n true, ownedFresh n] ++
  [0,1,2].flatMap (fun k => [owned n k, owned n k true])

def fixtures : List (String × Program × Bool) := [
  ("AlternativeArmEscapes", branchEscape 1, true),
  ("RealEscape before", branchEscape 1 true, false),
  ("RealEscape joined", branchEscape 1 false true, false),
  ("BranchEscapes.afterCall", branchCall 1, false),
  ("BranchEscapes.repeat", branchCall 1 true, false),
  ("ModelExclusive fresh update", modelUpdate 1, true),
  ("ModelExclusive sharing update arm", modelUpdate 1 true, false),
  ("ModelExclusive escaped update arm", modelUpdate 1 false true, false),
  ("Prepend reads base", prepend 1 true, false),
  ("Prepend copies", prepend 1, true),
  ("Maybe/ResultDefault case", withDefault 1, true),
  ("Default eager handler", withDefault 0 true, false),
  ("Default later read", withDefault 1 false true, false),
  ("ModelExclusive distinct", invariant 1 .model, true),
  ("ModelExclusive duplicate init", invariant 1 .model true, false),
  ("FoldContainer distinct", invariant 1 .range, true),
  ("FoldContainer duplicate init", invariant 1 .range true, false),
  ("FoldContainer shared start", badFold 1 0, false),
  ("FoldContainer escaped", badFold 1 1, false),
  ("FoldContainer captured", badFold 1 2, false),
  ("FoldContainer duplicated result", badFold 1 3, false),
  ("FoldContainer captured after append", capturedAfter 1, false),
  ("Fold container captured from an earlier position", earlierCapture 1, true),
  ("Focus replacement captures an earlier container", earlierCapture 1 true, true),
  ("Fold inputs collapse canonical container paths", earlierCapture 1 false true, true),
  ("SubscriptionTapFold starts empty", freshTaps 1, true),
  ("SubscriptionTapFold reused fresh container", freshTaps 1 true, false),
  ("SubscriptionTapFold shared opaque descendants", taps 1, true),
  ("SubscriptionTapFold duplicate containers", taps 1 true, false),
  ("SubscriptionTapFold nested write", taps 1 false true, false),
  ("Markup render slot", markup 1, true),
  ("Markup handler capture", markup 1 true, false),
  ("Markup general render alias", markup 1 false true, false),
  ("ConduitArticleErrors render-only", markup 1, true),
  ("ConduitHomeFeedErrors render-only", markup 1 false false 1, true),
  ("ConduitProfileErrors render-only", markup 1 false false 2, true),
  ("ConduitProfileFeedErrors render-only", markup 1 false false 3, true),
  ("Constructor scalar crossing", constructor 1 false, true),
  ("Constructor retained payload", constructor 1 true, false),
  ("Unseen tagger shared result", owned 1 0, false),
  ("Conditional capture nonempty", owned 1 1, false),
  ("Forwarded callback result", owned 1 2, false),
  ("Conditional capture scalar", owned 1 1 true, true),
  ("Forwarded callback fresh across calls", ownedFresh 1, true)]

def holes : List (Mutant × Program) := [
  (.branchEscapes, branchEscape 1 true), (.branchLive, withDefault 1 true),
  (.resultPositions, capturedAfter 1), (.prependBase, prepend 1 true),
  (.foldInvariant, invariant 1 .range true), (.modelInvariant, invariant 1 .model true),
  (.constructorArgs, constructor 1 true), (.eventCapture, markup 1 true),
  (.taggerNeed, owned 1 0), (.captureEmpty, owned 1 1), (.forwardNeed, owned 1 2)]

def preservationProbes : List (Mutant × Program) := [
  (.modelInvariant, modelUpdate 1 true), (.foldInvariant, badFold 1 3)]

def run : IO Bool := do
  let mut ok := true
  for hole in Mutant.all.filter Mutant.enumeratorRequired do
    if (holes.filter fun (m, _) => m == hole).length != 1 then
      IO.println s!"SYNC CONTROL COVERAGE FAILED: {hole.name}"
      ok := false
  if (check (modelUpdate 1) {rounds := 0}).isOk then
    IO.println "SYNC EXHAUSTION FAILED: partial model proof accepted"
    ok := false
  for (name, p, expected) in fixtures do
    let result := check p
    let typed := typecheck p
    IO.println s!"sync {name}: expected={expected} accepted={result.isOk} {if result.isOk then "" else toString (repr result)}"
    if !typed.isOk || result.isOk != expected then
      IO.println s!"SYNC FIXTURE FAILED: {name} typing={repr typed}"
      ok := false
    if let .ok a := result then
      if let .error problem := Falsify.resultCertificates p a then
        IO.println s!"SYNC CERTIFICATE FAILED: {name}: {problem}"
        ok := false
    if result.isOk && !(Oracle.compare p matches .equal) then
      IO.println s!"SYNC DIFFERENTIAL FAILED: {name}: {repr (Oracle.compare p)}"
      ok := false
  for p in [earlierCapture 1, earlierCapture 1 true, earlierCapture 1 false true] do
    let caught := match check p {mutant := some .resultPositions} with
      | .ok a => !(Falsify.resultCertificates p a).isOk
      | .error _ => false
    IO.println s!"sync result-positions certificate hole: caught={caught}"
    if !caught then ok := false
  for (hole, p) in holes ++ preservationProbes do
    let caught := !(check p).isOk && Oracle.disagrees p {mutant := some hole}
    IO.println s!"sync hole {hole.name}: caught={caught}"
    if !caught then
      IO.println s!"SYNC HOLE FAILED: {hole.name}: mutant={repr (check p {mutant := some hole})}; compare={repr (Oracle.compare p)}"
      ok := false
  return ok
end Ownership.Sync
