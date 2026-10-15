import Ownership.Library
import Ownership.OracleLegacy
import Ownership.Semantics
import Ownership.Generator
import Ownership.Reinfer
import Ownership.Aliasing

namespace Ownership.Oracle

abbrev Gen := StateM Nat

def draw (bound : Nat) : Gen Nat := do
  let s ← get
  let next := (s * 1664525 + 1013904223) % 4294967296
  set next
  pure ((next / 65536) % (max 1 bound))

def number : Gen Atom := do pure (.int (Int.ofNat (← draw 5)))
def choose (xs : List α) (fallback : α) : Gen α := do
  pure (xs[← draw xs.length]?.getD fallback)

/-- Compositional typed ANF generator. Every choice extends a typed environment;
    the checker is not consulted while constructing syntax. Sharing is selected
    by reusing existing atoms, including cells below record/container paths. -/
def chain : Nat → Nat → List (Atom × Ty) → Gen Expr
  | 0, _, env => pure (.prim .record (env.map Prod.fst))
  | depth + 1, next, env => do
  let lists := env.filterMap fun (a,t) => if t == .list .int then some a else none
  let nested := env.filterMap fun (a,t) => if t == .list (.list .int) then some a else none
  let records := env.filterMap fun (a,t) => if t == .record [.list .int,.list .int] then some a else none
  let choice ← draw 13
  let (rhs, ty) ← match choice with
    | 0 => pure (.prim (.literal .int) [← number, ← number], Ty.list .int)
    | 1 => pure (.prim .push [← choose lists (.var 0), ← number], Ty.list .int)
    | 2 => pure (.prim .copy [← choose lists (.var 0)], Ty.list .int)
    | 3 => pure (.prim .record [← choose lists (.var 0), ← choose lists (.var 0)],
                  Ty.record [.list .int, .list .int])
    | 4 => pure (.prim (.literal (.list .int)) [← choose lists (.var 0), ← choose lists (.var 0)],
                  Ty.list (.list .int))
    | 5 => pure (.prim .length [← choose lists (.var 0)], Ty.int)
    | 6 => pure (.branch (← number)
                  (.prim .push [← choose lists (.var 0), ← number])
                  (.atom (← choose lists (.var 0))), Ty.list .int)
    | 7 => pure (.prim .set [← choose lists (.var 0),← number,← number], Ty.list .int)
    | 8 => pure (.prim .at [← choose lists (.var 0),← number,.int 0], Ty.int)
    | 9 =>
      if nested.isEmpty then pure (.prim (.literal (.list .int)) [← choose lists (.var 0)], Ty.list (.list .int))
      else pure (.focus (← choose nested (.var 0)) (← number) (next+1000)
        (.prim .push [.var (next+1000),← number]), Ty.list (.list .int))
    | 10 =>
      if records.isEmpty then pure (.prim .record [← choose lists (.var 0),← choose lists (.var 0)], Ty.record [.list .int,.list .int])
      else pure (.prim .push [.field (← choose records (.var 0)) (← draw 2),← number], Ty.list .int)
    | 11 => pure (.prim .shared [← choose lists (.var 0)], Ty.list .int)
    | _ => pure (.atom (← choose lists (.var 0)), Ty.list .int)
  return .letE next rhs (← chain depth (next + 1) ((.var next,ty)::env))

/-- Fresh callbacks are built from independently selected numbers, lengths,
    multiplicities and sharing decisions. This is not the fixed T59 fixture. -/
def nested : Gen Program := do
  let sharing ← draw 3
  let n ← draw 3
  let count := n + 1
  let cell ← number
  let write ← number
  let index ← draw count
  let useMap ← draw 2
  let callback : Decl := {
    name := "generatedFresh"
    parameters := [.int]
    result := .list (.list .int)
    body := .letE 1 (.prim (.literal .int) [cell]) <|
      .letE 2 (if sharing < 2 then .atom (.var 1) else .prim (.literal .int) [cell]) <|
      .prim (.literal (.list .int)) [.var 1, .var 2] }
  let invoke : Expr := if useMap == 0 then .app (.var 0) [.int count, .var 1] else
    .letE 8 (.prim (.literal .int) ((List.range count).map (fun i => .int (Int.ofNat i)))) <|
    .app (.var 0) [.var 8, .var 1]
  return {
    declarations := [if useMap == 0 then Library.initialize (.list (.list .int))
                               else Library.map .int (.list (.list .int)), callback]
    main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
      .letE 2 invoke <| .focus (.var 2) (.int index) 3 <|
        .focus (.var 3) (.int 0) 4 (.prim .push [.var 4, write]) }

def captureProgram : Gen Program := do
  let consuming ← draw 2
  let duplicate ← draw 2
  let cell ← number
  let d : Decl := {
    name := "captured", parameters := [.int], captures := [.list .int],
    result := if consuming == 0 then .int else .list .int,
    body := if consuming == 0 then .prim .length [.var 1] else .prim .push [.var 1, .var 0] }
  return {
    declarations := [d]
    main := .letE 0 (.prim (.literal .int) [cell]) <|
      .letE 1 (.closure 0 [.var 0]) <|
      .letE 2 (.closure 0 [.var 0]) <|
      .letE 3 (.app (.var 1) [cell]) <|
      if duplicate == 0 then .app (.var 2) [cell] else .prim .record [.var 3, .var 0] }

def identityMap : Gen Program := do
  let live ← draw 2
  let count ← draw 4
  let d : Decl := {
    name := "identity", parameters := [.list .int], result := .list .int,
    body := .atom (.var 0) }
  return {
    declarations := [Library.map (.list .int) (.list .int), d]
    main := .letE 0 (.prim (.literal .int) [.int count]) <|
      .letE 1 (.prim (.literal (.list .int)) [.var 0]) <|
      .letE 2 (.closure 0 []) <| .letE 3 (.closure 1 []) <|
      .letE 4 (.app (.var 2) [.var 1,.var 3]) <|
      .letE 5 (.focus (.var 4) (.int 0) 6 (.prim .push [.var 6,.int 9])) <|
      if live == 0 then .atom (.var 5) else .prim .record [.var 5,.var 1] }

def loopProgram : Gen Program := do
  let n ← draw 5
  let borrowed ← draw 2
  return {
    main := .letE 0 (.prim (.literal .int) [.int 0]) <|
      .letE 1 (.traverse .range (.int n) (.var 0) 2 3 4 <|
        .branch (.var 2) (.atom (.var 4)) (.prim .push [.var 4,.var 3])) <|
      if borrowed == 0 then .atom (.var 1) else .prim .record [.var 0,.var 1] }

/-- A callback publishes a captured cell without returning it. Escape effects
    must survive traversal independently of the accumulator provenance. -/
def escapedProgram : Gen Program := do
  let count ← draw 3
  let cell ← number
  return {
    main := .letE 0 (.prim (.literal .int) [cell]) <|
      .letE 1 (.traverse .range (.int (count + 1)) (.int 0) 2 3 4 <|
        .letE 5 (.prim .shared [.var 0]) (.atom (.var 4))) <|
      .prim .push [.var 0, cell] }

/-- Scalar recursion with a list accumulator, optional retained argument, and
    optional consuming capture: termination is selected by a concrete bound. -/
def recursiveProgram : Gen Program := do
  let count ← draw 7
  let capture ← draw 2
  let retain ← draw 2
  let d : Decl := {
    name := "recursiveGrow", parameters := [.int,.list .int],
    captures := if capture == 0 then [] else [.list .int], result := .list .int,
    body := .branch (.var 0) (if capture == 0 then .atom (.var 1) else .prim .push [.var 2,.int 0])
      (.letE 3 (.prim .sub [.var 0,.int 1]) <|
       .letE 4 (.prim .push [.var 1,.var 0]) (.recur [.var 3,.var 4])) }
  return {
    declarations := [d],
    main := .letE 0 (.prim (.literal .int) [← number]) <|
      .letE 1 (.closure 0 (if capture == 0 then [] else [.var 0])) <|
      .letE 2 (.app (.var 1) [.int count,.var 0]) <|
      if retain == 0 then .atom (.var 2) else .prim .record [.var 0,.var 2] }

/-- A variable-depth callback/library pipeline. The callback consumes records'
    nested cells conditionally; its input is initialized independently or with
    repeated captures. Update and fold then act on the map result. -/
def pipeline : Gen Program := do
  let repeated ← draw 2
  let count ← draw 4
  let stages ← draw 5
  let retain ← draw 2
  let row := Ty.record [.int,.list .int]
  let ds : List Decl := [Library.initialize row, Library.map row row,
    Library.update row, Library.foldl row (.list .int),
    { name := "makeRow", parameters := [.int], captures := [.list .int], result := row,
      body := .letE 2 (if repeated == 0 then .prim (.literal .int) [.var 0] else .atom (.var 1))
        (.prim .record [.var 0,.var 2]) },
    { name := "editRow", parameters := [row], result := row,
      body := .branch (.field (.var 0) 0) (.atom (.var 0))
        (.letE 1 (.prim .push [.field (.var 0) 1,.int 9])
          (.prim .record [.field (.var 0) 0,.var 1])) },
    { name := "foldRows", parameters := [row,.list .int], result := .list .int,
      body := .letE 2 (.prim .length [.field (.var 0) 1]) (.prim .push [.var 1,.var 2]) }]
  let mut rest : Expr := .letE 30 (.prim (.literal .int) []) <|
    .letE 31 (.app (.var 3) [.var (10+stages),.var 30,.var 6]) <|
    .letE 32 (.app (.var 2) [.var (10+stages),.int 0,.var 5]) <|
    if retain == 0 then .prim .record [.var 31,.var 32]
    else .prim .record [.var 31,.var 32,.var 10]
  for j in (List.range stages).reverse do
    rest := .letE (11+j) (.app (.var 1) [.var (10+j),.var 5]) rest
  return {
    declarations := ds,
    main := .letE 7 (.prim (.literal .int) [← number]) <|
      .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
      .letE 2 (.closure 2 []) <| .letE 3 (.closure 3 []) <|
      .letE 4 (.closure 4 [.var 7]) <| .letE 5 (.closure 5 []) <|
      .letE 6 (.closure 6 []) <| .letE 10 (.app (.var 0) [.int (count+1),.var 4]) rest }

/-- Copy/read/set sequences vary out-of-range indices and shallow sharing. -/
def indexedProgram : Gen Program := do
  let count ← draw 5
  let index ← draw 8
  let retain ← draw 2
  let copied ← draw 2
  let depth ← draw 12
  let tail ← chain (depth+1) 10 [(.var 4,.list .int),(.var 0,.list .int)]
  return {
    main := .letE 0 (.prim (.literal .int) ((List.range count).map (fun n => .int (Int.ofNat n)))) <|
    .letE 1 (.prim .at [.var 0,.int (Int.ofNat index - 1),.int 0]) <|
    .letE 2 (if copied == 0 then .prim .copy [.var 0] else .atom (.var 0)) <|
    .letE 3 (.prim .set [.var 2,.int index,.var 1]) <|
    .letE 4 (.prim .push [.var 3,← number]) <|
    if retain == 0 then tail else .prim .record [.var 0,.var 4] }

/-- Returned and captured function cells, direct calls versus many positions. -/
def onceProgram : Gen Program := do
  let many ← draw 2
  let calls ← draw 4
  let readOnly ← draw 2
  let count ← draw 4
  let result := if readOnly == 0 then Ty.int else Ty.list .int
  let ds := [
    { name := "capturedOp", parameters := [Ty.int], captures := [.list .int], result := result,
      body := if readOnly == 0 then .prim .length [.var 1] else .prim .push [.var 1,.var 0] : Decl },
    { name := "factory", parameters := [.list .int], result := .fn [.int] result,
      body := .closure 0 [.var 0] },
    { name := "wrapper", parameters := [.int], captures := [.fn [.int] result], result := result,
      body := .app (.var 1) [.var 0] }, Library.map .int result]
  let mut rest : Expr := .atom (.int 0)
  for j in (List.range (calls+1)).reverse do
    rest := .letE (10+j) (.app (.var 3) [.int j]) rest
  if many == 1 then
    rest := .letE 4 (.closure 3 []) <|
      .letE 5 (.prim (.literal .int) ((List.range (count+1)).map (fun n => .int (Int.ofNat n))))
        (.app (.var 4) [.var 5,.var 3])
  return {
    declarations := ds,
    main := .letE 0 (.prim (.literal .int) [← number]) <| .letE 1 (.closure 1 []) <|
      .letE 2 (.app (.var 1) [.var 0]) <| .letE 3 (.closure 2 [.var 2]) rest }

/-- Explicit limit exploration: recursive higher-order actuals have a precise
    implementation-limit diagnostic rather than being silently accepted. -/
def recursiveHigherOrder : Gen Program := do
  let count ← draw 6
  return {
    declarations := [
      { name := "recursiveHO", parameters := [.int,.fn [.int] .int], result := .int,
        body := .branch (.var 0) (.app (.var 1) [.int 0])
          (.letE 2 (.prim .sub [.var 0,.int 1]) (.recur [.var 2,.var 1])) },
      { name := "id", parameters := [.int], result := .int, body := .atom (.var 0) }],
    main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) (.app (.var 0) [.int count,.var 1]) }

def towerTy : Nat → Ty
  | 0 => .list .int
  | n+1 => .list (towerTy n)

def freshTree : Nat → Nat → Bool → Gen (Expr × Nat)
  | 0, next, _ => do return (.prim (.literal .int) [← number],next)
  | n+1, next, sharing => do
    let (left, after) ← freshTree n (next+2) sharing
    let (right, last) ← freshTree n after sharing
    return (.letE next left <|
      .letE (next+1) (if sharing then .atom (.var next) else right)
        (.prim (.literal (towerTy n)) [.var next,.var (next+1)]),last)

def towerEdit : Nat → Atom → Nat → Expr
  | 0, src, _ => .prim .push [src,.int 9]
  | n+1, src, next => .focus src (.int 0) next (towerEdit n (.var next) (next+1))

/-- Arbitrary nested callback-result depth, with fresh distinct or shared cells
    at every interior layer. Scoped consumption follows all those layers. -/
def towerProgram : Gen Program := do
  let depth ← draw 4
  let sharing ← draw 2
  let count ← draw 3
  let (body,_) ← freshTree (depth+1) 1 (sharing == 1)
  let t := towerTy (depth+1)
  return {
    declarations := [Library.initialize t,
      { name := "freshTower", parameters := [.int], result := t, body := body }],
    main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
      .letE 2 (.app (.var 0) [.int (count+1),.var 1])
        (.focus (.var 2) (.int 0) 3 (towerEdit (depth+1) (.var 3) 4)) }

def generateFamily : Gen (String × Program) := do
  match ← draw 12 with
  | 0 => return ("fresh-nested", ← nested)
  | 1 => return ("captures", ← captureProgram)
  | 2 => return ("identity-map", ← identityMap)
  | 3 => return ("branch-traversal", ← loopProgram)
  | 4 => return ("escape-traversal", ← escapedProgram)
  | 5 => return ("recursion", ← recursiveProgram)
  | 6 => return ("library-pipeline", ← pipeline)
  | 7 => return ("indexed-chain", ← indexedProgram)
  | 8 => return ("once-many-wrappers", ← onceProgram)
  | 9 => return ("recursive-higher-order-limit", ← recursiveHigherOrder)
  | 10 => return ("fresh-tower", ← towerProgram)
  | _ =>
    let depth ← draw 24
    return ("anf-chain", {
      main := .letE 0 (.prim (.literal .int) [← number])
        (← chain (depth + 1) 1 [(.var 0,.list .int)]) })

def generate : Gen Program := do return (← generateFamily).2

def exprDepth : Expr → Nat
  | .letE _ a b => 1 + max (exprDepth a) (exprDepth b)
  | .resultCase _ _ _ a b | .chainCase _ _ _ a b | .entry a _ _ b => 1 + max (exprDepth a) (exprDepth b)
  | .branch _ a b => 1 + max (exprDepth a) (exprDepth b)
  | .traverse _ _ _ _ _ _ b | .focus _ _ _ b => 1 + exprDepth b
  | _ => 1

/-- `inPlaceFailed`: the value run finished and the in-place run failed (for
    example a traversal whose source grew until fuel ran out). It is a
    disagreement like `mismatch`; `inconclusive` is a value run that fails. -/
inductive Outcome where
  | equal | mismatch (value inPlace : Trace) | inPlaceFailed (value : Trace) (message : String)
  | inconclusive (message : String)
  deriving Repr

def Outcome.disagrees : Outcome → Bool
  | .mismatch .. | .inPlaceFailed .. => true
  | _ => false

def compare (p : Program) (fuel := 100000) : Outcome :=
  match ValueSemantics.run p fuel, InPlaceSemantics.run p fuel with
  | .ok a, .ok b => if a == b then .equal else .mismatch a b
  | .ok a, .error e => .inPlaceFailed a e
  | a,b => .inconclusive s!"value={repr a}; in-place={repr b}"

/-- The verdict of the selected checker: the summary layer, or the frozen
    per-call re-inference checker when `config.reinfer`. -/
-- Also returns summaries computed and reused, and the checker rows exercised.
def verdictStats (p : Program) (config : Config := {}) : Except String (Nat × Nat × List String) :=
  if config.reinfer then (Reinfer.check p config).map (fun _ => (0, 0, []))
  else (check p config).map (fun a => (a.computed, a.reused, a.hits))

def verdictOf (p : Program) (config : Config := {}) : Except String Unit :=
  (verdictStats p config).map (fun _ => ())

def disagrees (p : Program) (config : Config) (fuel := 100000) : Bool :=
  (typesOf p).isOk && (verdictOf p config).isOk &&
    (compare p fuel).disagrees

def atomReductions : Atom → List Atom
  | .int n => if n == 0 then [] else
      [.int 0] ++ (if n.natAbs > 1 then [.int (n / 2),.int (if n < 0 then -1 else 1)] else [])
  | .var _ => []
  | .field a i => (atomReductions a).map (fun x => .field x i)

def argumentReductions (args : List Atom) : List (List Atom) :=
  args.zipIdx.flatMap fun (a,i) => (atomReductions a).map (fun x => args.set i x)

def reductions : Expr → List Expr
  | .entry initial retained model body => [initial, body] ++
      (reductions initial).map (fun a => .entry a retained model body) ++
      (reductions body).map (fun b => .entry initial retained model b)
  | .resultCase a e k left right => [left, right] ++
      (reductions left).map (fun b => .resultCase a e k b right) ++
      (reductions right).map (fun b => .resultCase a e k left b)
  | .chainCase a h t left right => [left, right] ++
      (reductions left).map (fun b => .chainCase a h t b right) ++
      (reductions right).map (fun b => .chainCase a h t left b)
  | .letE v rhs rest => [rhs, rest] ++
      (reductions rhs).map (fun r => .letE v r rest) ++
      (reductions rest).map (fun r => .letE v rhs r)
  | .branch c yes no => [yes,no] ++
      (reductions yes).map (fun y => .branch c y no) ++
      (reductions no).map (fun n => .branch c yes n)
  | .prim (.literal t) args => ((List.range args.length).map fun i =>
      .prim (.literal t) (args.take i ++ args.drop (i+1))) ++
      (argumentReductions args).map (.prim (.literal t))
  | .prim op args => (argumentReductions args).map (.prim op)
  | .atom a => (atomReductions a).map .atom
  | .app f args => (argumentReductions args).map (.app f)
  | .recur args => (argumentReductions args).map .recur
  | .closure d caps => (argumentReductions caps).map (.closure d)
  | .traverse k src init i x acc body => [.atom init] ++
      (reductions body).map (fun b => .traverse k src init i x acc b) ++
      (atomReductions src).map (fun a => .traverse k a init i x acc body)
  | .focus src i x body => [.atom src] ++ (reductions body).map (fun b => .focus src i x b) ++
      (atomReductions i).map (fun a => .focus src a x body)

/-- Fuel-bounded greedy reduction over syntax, integers, indices and call counts. Every
    proposed reduction must remain ordinarily typed, accepted and disagreeing. -/
def shrinkFuel : Nat → Program → Config → Program
  | 0, p, _ => p
  | fuel+1, p, config =>
    let mains := (reductions p.main).map (fun e => { p with main := e })
    let bodies := p.declarations.zipIdx.flatMap fun (d,i) =>
      (reductions d.body).map fun e => { p with declarations := p.declarations.set i { d with body := e } }
    -- Candidates run with fuel 5 000: removing a recursive declaration's base
    -- case makes the interpreters recurse until fuel runs out, as deep as the
    -- fuel, which overflowed the stack at the campaign's 100 000.
    match (mains ++ bodies).find? (fun q => q != p && disagrees q config 5000) with
    | none => p
    | some q => shrinkFuel fuel q config


def shrink (p : Program) (config : Config) : Program := shrinkFuel 1000 p config

structure Counts where
  candidates : Nat := 0
  distinct : Nat := 0
  typed : Nat := 0
  accepted : Nat := 0
  rejected : Nat := 0
  typeErrors : Nat := 0
  limits : Nat := 0
  executionErrors : Nat := 0
  mismatches : Nat := 0
  withWrites : Nat := 0
  /-- Accepted programs counted once per distinct AST, all and with a write. -/
  distinctAccepted : Nat := 0
  distinctWithWrites : Nat := 0
  /-- Accepted programs whose in-place run writes an array that two or more
      names reach (`Aliasing`). -/
  aliasedWrites : Nat := 0
  /-- Precision: typed programs whose two runs agree, and how many of those
      the checker accepts (not computed under a negative control). -/
  agreeing : Nat := 0
  agreeingAccepted : Nat := 0
  /-- Cross-check: verdicts that differ between the two checkers, and
      programs only the other checker accepts that then disagree. -/
  onlyThis : Nat := 0
  onlyOther : Nat := 0
  otherMismatches : Nat := 0
  /-- Summaries computed and call sites served from the cache, over accepted programs. -/
  summariesComputed : Nat := 0
  summariesReused : Nat := 0
  /-- The declaration family's accepted programs: how many call a generated
      declaration at run time, how many of those calls change an array the
      caller passed, and generated calls in all and those passing one array
      at two argument positions (from the in-place run's call log). -/
  declAccepted : Nat := 0
  declRunsGenerated : Nat := 0
  declGeneratedWrites : Nat := 0
  generatedCalls : Nat := 0
  generatedSameArray : Nat := 0
  /-- Rejections by the no-shadowing rule. -/
  shadowing : Nat := 0
  deriving Repr

/-- How a run exercises generated declarations (declarations past the fixed
    table): whether it calls one, whether such a call changes an array its
    inputs reach, how many such calls, and how many pass one array at two
    argument positions. -/
def generatedUse (p : Program) : Bool × Bool × Nat × Nat :=
  let fixed := Generator.decls.length
  match (InPlaceSemantics.eval 100000 p.declarations none [] p.main).run { fuel := 100000, logCalls := true } with
  | .error _ => (false, false, 0, 0)
  | .ok (_, s) =>
    let gen := s.calls.toList.filter (·.decl ≥ fixed)
    let changes := gen.any fun cr => (cr.args ++ cr.caps).any fun v =>
      (Aliasing.reach cr.preHeap 64 v).any fun c => !(cr.preHeap[c]? == cr.postHeap[c]?)
    let same := gen.filter fun cr =>
      let rs := cr.args.map (Aliasing.reach cr.preHeap 64)
      rs.zipIdx.any fun (a, i) => (rs.drop (i + 1)).any fun b => a.any b.contains
    (!gen.isEmpty, changes, gen.length, same.length)

def Counts.line (c : Counts) : String :=
  s!"candidates={c.candidates} distinct={c.distinct} typed={c.typed} accepted={c.accepted} distinctAccepted={c.distinctAccepted} withWrites={c.withWrites} distinctWithWrites={c.distinctWithWrites} aliasedWrites={c.aliasedWrites} agreeing={c.agreeing} agreeingAccepted={c.agreeingAccepted} rejected={c.rejected} limits={c.limits} typeErrors={c.typeErrors} executionErrors={c.executionErrors} mismatches={c.mismatches}" ++
  (if c.onlyThis + c.onlyOther + c.otherMismatches > 0 then
    s!" cross-only-this={c.onlyThis} cross-only-other={c.onlyOther} cross-other-mismatches={c.otherMismatches}" else "") ++
  s!" summaries-computed={c.summariesComputed} summaries-reused={c.summariesReused}"

def percent (a b : Nat) : String :=
  if b == 0 then "-" else s!"{(a * 1000 / b) / 10}.{(a * 1000 / b) % 10} %"

/-- The campaign's headline: distinct accepted programs (all, with a write),
    the share of accepted programs that write an aliased array, and
    precision (accepted among programs whose two runs agree). -/
def Counts.summary (c : Counts) (seed : Nat) : String :=
  s!"summary seed={seed} accepted={c.accepted} distinct-accepted={c.distinctAccepted} with-write={c.withWrites} distinct-with-write={c.distinctWithWrites} aliased-write={c.aliasedWrites} ({percent c.aliasedWrites c.accepted} of accepted) agreeing={c.agreeing} accepted-of-agreeing={c.agreeingAccepted} precision={percent c.agreeingAccepted c.agreeing}" ++
  s!" declarations-accepted={c.declAccepted} run-generated={c.declRunsGenerated} ({percent c.declRunsGenerated c.declAccepted}) generated-call-writes-input={c.declGeneratedWrites} ({percent c.declGeneratedWrites c.declAccepted}) generated-calls={c.generatedCalls} same-array-twice={c.generatedSameArray} ({percent c.generatedSameArray c.generatedCalls}) rejected-shadowing={c.shadowing}"

/-- Generator v4 keeps the eleven v3 template families and replaces the v3
    `anf-chain`, whose final record kept every variable live (so none of its
    accepted programs wrote), by the general family of `Generator.lean`, drawn
    with probability 11/22. `--generator-version=3` reproduces v3 exactly. -/
def generateV4 : Gen (String × Program) := do
  let k ← draw 22
  if k < 11 then
    match k with
    | 0 => return ("fresh-nested", ← nested)
    | 1 => return ("captures", ← captureProgram)
    | 2 => return ("identity-map", ← identityMap)
    | 3 => return ("branch-traversal", ← loopProgram)
    | 4 => return ("escape-traversal", ← escapedProgram)
    | 5 => return ("recursion", ← recursiveProgram)
    | 6 => return ("library-pipeline", ← pipeline)
    | 7 => return ("indexed-chain", ← indexedProgram)
    | 8 => return ("once-many-wrappers", ← onceProgram)
    | 9 => return ("recursive-higher-order-limit", ← recursiveHigherOrder)
    | _ => return ("fresh-tower", ← towerProgram)
  else
    let (_, p) ← Generator.general
    return ("general", p)

/-- Generator v5 (the default): the eleven template families together are
    drawn a quarter of the time (11/44), so most programs come from the
    general generator: 14/44 from its chains of moves (now with conditionals
    whose arms are chains), 19/44 from programs that first generate a table
    of declarations of their own. `--generator-version=4` reproduces v4. -/
def generateV5 : Gen (String × Program) := do
  let k ← draw 44
  if k < 11 then
    match k with
    | 0 => return ("fresh-nested", ← nested)
    | 1 => return ("captures", ← captureProgram)
    | 2 => return ("identity-map", ← identityMap)
    | 3 => return ("branch-traversal", ← loopProgram)
    | 4 => return ("escape-traversal", ← escapedProgram)
    | 5 => return ("recursion", ← recursiveProgram)
    | 6 => return ("library-pipeline", ← pipeline)
    | 7 => return ("indexed-chain", ← indexedProgram)
    | 8 => return ("once-many-wrappers", ← onceProgram)
    | 9 => return ("recursive-higher-order-limit", ← recursiveHigherOrder)
    | _ => return ("fresh-tower", ← towerProgram)
  else if k < 25 then
    let (_, p) ← Generator.generalV5 false
    return ("general", p)
  else
    let (_, p) ← Generator.generalV5 true
    return ("declarations", p)

/-- Generator v6 (opt-in, 2026-10-15): v5's general families with
    constructions, views and record updates drawn three times as often as
    each other move, half of them after a declaration table that may hold a
    declaration appending onto its parameter. v5 is unchanged and remains the
    default; v6 is a stream of its own. -/
def generateV6 : Gen (String × Program) := do
  let extra := Generator.constructionMoves ++ Generator.constructionMoves ++ Generator.constructionMoves
  if (← draw 2) == 0 then
    let (_, p) ← Generator.generalV5 false extra
    return ("constructions", p)
  else
    let (_, p) ← Generator.generalV5 true extra Generator.generatedTableV6
    return ("construct-declarations", p)

def generateVersion (version : Nat) : Gen (String × Program) :=
  match version with
  | 1 => do return ("frozen-legacy", ← OracleLegacy.generate)
  | 3 => generateFamily
  | 4 => generateV4
  | 6 => generateV6
  | _ => generateV5

structure Options where
  keepEvidence : Bool := false
  count : Nat
  seed : Nat
  version : Nat := 5
  config : Config := {}
  /-- Stop at the first accepted disagreement (negative controls). -/
  stopAtFirst : Bool := false
  quiet : Bool := false
  /-- Also run the other checker on every candidate and count verdicts that
      differ; a program only the other checker accepts is executed too. -/
  crossCheck : Bool := false

def Options.negative (o : Options) : Bool :=
  o.config.oldFreshRule || o.config.dropTraversalEscapes || o.config.mutant.isSome

def Options.label (o : Options) : String :=
  let base := match o.config.mutant with
    | some m => s!"mutant-{m.name}"
    | none => if o.config.oldFreshRule then (if o.version == 1 then "legacy-old" else s!"old-v{o.version}")
      else if o.config.dropTraversalEscapes then (if o.version ≥ 4 then s!"old-escape-v{o.version}" else "old-escape")
      else if o.version ≥ 4 then s!"soundness-v{o.version}" else "soundness"
  if o.config.reinfer then base ++ "-reinfer" else base

structure RunResult where
  ok : Bool
  counts : Counts
  firstMismatch : Option Nat := none
  elapsed : Nat := 0

/-- One deterministic campaign. In corrected mode any accepted disagreement is
    a soundness finding and fails. Under a negative control the run succeeds
    only if it finds an accepted disagreement whose minimized form the
    corrected checker rejects. -/
def runWith (o : Options) : IO RunResult := do
  let start ← IO.monoMsNow
  let config := o.config
  let mut state := o.seed
  let mut counts : Counts := {}
  let mut found : Option Nat := none
  let mut seen : Std.HashSet String := {}
  let mut seenAccepted : Std.HashSet String := {}
  let mut seenWithWrite : Std.HashSet String := {}
  let mut families : List (String × Counts × Nat × Nat) := []
  let mut rowHits : List (String × Nat) := []
  let header := s!"generator-version={o.version} seed={o.seed} control={o.label}"
  for index in List.range o.count do
    if o.stopAtFirst && found.isSome then break
    let ((family,p), next) := (generateVersion o.version).run state
    let signature := toString (repr p)
    let isNew := !seen.contains signature
    seen := seen.insert signature
    let prior := families.find? (fun x => x.1 == family)
    let fc := prior.map (fun x => x.2.1) |>.getD {}
    let d := exprDepth p.main
    families := families.filter (fun x => x.1 != family) ++ [(family, {fc with candidates := fc.candidates+1, distinct := fc.distinct+(if isNew then 1 else 0)}, min d (prior.map (fun x => x.2.2.1) |>.getD d), max d (prior.map (fun x => x.2.2.2) |>.getD d))]
    state := next
    counts := { counts with candidates := counts.candidates + 1, distinct := counts.distinct+(if isNew then 1 else 0) }
    match typesOf p with
    | .error msg =>
      counts := { counts with typeErrors := counts.typeErrors + 1 }
      IO.println s!"TYPE GENERATION ERROR seed={o.seed} index={index}: {msg}\n{repr p}"
      return { ok := false, counts }
    | .ok _ => counts := { counts with typed := counts.typed + 1 }
    let stats := verdictStats p config
    let verdict := stats.map (fun _ => ())
    if o.crossCheck then
      let other := verdictOf p { config with reinfer := !config.reinfer }
      if verdict.isOk != other.isOk then
        counts := if verdict.isOk then { counts with onlyThis := counts.onlyThis + 1 }
          else { counts with onlyOther := counts.onlyOther + 1 }
        if !o.quiet || o.keepEvidence then
          IO.println s!"CROSS-CHECK VERDICTS DIFFER index={index} family={family} this={repr verdict} other={repr other}"
        if other.isOk then
          if (compare p).disagrees then
            counts := { counts with otherMismatches := counts.otherMismatches + 1 }
            IO.println s!"CROSS-CHECK: only the other checker accepts index={index}, and it disagrees:\n{repr p}"
    families := families.map fun (f,c,lo,hi) => if f == family then
      (f, { c with typed := c.typed+1, accepted := c.accepted+(if verdict.isOk then 1 else 0), rejected := c.rejected+(if verdict.isOk then 0 else 1), limits := c.limits+(match verdict with | .error m => if m.startsWith "limit:" then 1 else 0 | _ => 0) },lo,hi) else (f,c,lo,hi)
    match verdict with
    | .error msg =>
      counts := { counts with
        rejected := counts.rejected + 1,
        limits := counts.limits + (if msg.startsWith "limit:" then 1 else 0),
        shadowing := counts.shadowing + (if msg.startsWith "shadowing:" then 1 else 0) }
      -- Precision: a rejected program whose runs agree is one the checker
      -- could have accepted.
      if !o.negative then
        if let .equal := compare p 5000 then
          counts := { counts with agreeing := counts.agreeing + 1 }
          families := families.map fun (f,c,lo,hi) => if f == family then
            (f,{ c with agreeing := c.agreeing+1 },lo,hi) else (f,c,lo,hi)
    | .ok _ =>
      let (made, reused, hits) := match stats with | .ok s => s | .error _ => (0, 0, [])
      let newAccepted := !seenAccepted.contains signature
      seenAccepted := seenAccepted.insert signature
      counts := { counts with
        accepted := counts.accepted + 1, summariesComputed := counts.summariesComputed + made,
        summariesReused := counts.summariesReused + reused,
        distinctAccepted := counts.distinctAccepted + (if newAccepted then 1 else 0) }
      if family == "declarations" && !o.negative then
        let (runs, writes, calls, same) := generatedUse p
        counts := { counts with declAccepted := counts.declAccepted + 1 }
        counts := { counts with declRunsGenerated := counts.declRunsGenerated + (if runs then 1 else 0) }
        counts := { counts with declGeneratedWrites := counts.declGeneratedWrites + (if writes then 1 else 0) }
        counts := { counts with generatedCalls := counts.generatedCalls + calls }
        counts := { counts with generatedSameArray := counts.generatedSameArray + same }
      families := families.map fun (f,c,lo,hi) => if f == family then
        (f,{ c with distinctAccepted := c.distinctAccepted+(if newAccepted then 1 else 0) },lo,hi) else (f,c,lo,hi)
      match compare p with
      | .equal =>
        counts := { counts with agreeing := counts.agreeing + 1, agreeingAccepted := counts.agreeingAccepted + 1 }
        let aliased := if !o.negative && Aliasing.aliasedWrite p then 1 else 0
        counts := { counts with aliasedWrites := counts.aliasedWrites + aliased }
        families := families.map fun (f,c,lo,hi) => if f == family then
          (f,{ c with agreeing := c.agreeing+1, agreeingAccepted := c.agreeingAccepted+1,
                      aliasedWrites := c.aliasedWrites+aliased },lo,hi) else (f,c,lo,hi)
        if InPlaceSemantics.writeCount p > 0 then
          let newWrite := !seenWithWrite.contains signature
          seenWithWrite := seenWithWrite.insert signature
          counts := { counts with withWrites := counts.withWrites + 1,
                                  distinctWithWrites := counts.distinctWithWrites + (if newWrite then 1 else 0) }
          families := families.map fun (f,c,lo,hi) => if f == family then
            (f,{ c with distinctWithWrites := c.distinctWithWrites+(if newWrite then 1 else 0) },lo,hi) else (f,c,lo,hi)
          for h in hits do
            rowHits := match rowHits.lookup h with
              | some n => rowHits.map fun (k, m) => if k == h then (k, n + 1) else (k, m)
              | none => rowHits ++ [(h, 1)]
          families := families.map fun (f,c,lo,hi) => if f == family then
            (f,{ c with withWrites := c.withWrites+1 },lo,hi) else (f,c,lo,hi)
      | .inconclusive msg =>
        counts := { counts with executionErrors := counts.executionErrors + 1 }
        IO.println s!"INCONCLUSIVE seed={o.seed} index={index}: {msg}"
        if !o.quiet || o.keepEvidence then
          IO.FS.createDirAll "regressions"
          IO.FS.writeFile s!"regressions/{o.label}-{o.seed}-{index}-unshrunk.txt" s!"{repr p}\n{msg}\n"
        return { ok := false, counts }
      | .mismatch .. | .inPlaceFailed .. =>
        counts := { counts with mismatches := counts.mismatches + 1 }
        families := families.map fun (f,c,lo,hi) => if f == family then
          (f,{ c with mismatches := c.mismatches+1 },lo,hi) else (f,c,lo,hi)
        if o.negative && found.isSome then continue
        -- Recorded before shrinking, which may exhaust the stack on a deep program.
        IO.println s!"{header} mismatch index={index} family={family} (shrinking)"
        -- The unshrunk program and the line above reach the disk before
        -- shrinking starts, so a crash while shrinking loses no evidence.
        (← IO.getStdout).flush
        if !o.quiet || o.keepEvidence then
          IO.FS.createDirAll "regressions"
          IO.FS.writeFile s!"regressions/{o.label}-{o.seed}-{index}-unshrunk.txt"
            s!"{header} index={index} family={family}\nAST:\n{repr p}\n"
        let shrunk := shrink p config
        -- Shrinking judged candidates at fuel 5 000; keep the shrunk program
        -- only if it still disagrees at the campaign's fuel, else report the
        -- original (a candidate must not disagree only for want of fuel).
        let minimal := if disagrees shrunk config then shrunk else p
        let report := s!"{header} index={index} family={family}\nAST:\n{repr minimal}\n{repr (compare minimal)}\ncorrected checker: {repr (verdictOf minimal { reinfer := config.reinfer })}\n"
        if !o.quiet then
          IO.FS.createDirAll "regressions"
          IO.FS.writeFile s!"regressions/{o.label}-{o.seed}-{index}.txt" report
          IO.println report
        if !o.negative then
          IO.println s!"STOP corrected-rule soundness finding: {counts.line}"
          return { ok := false, counts, firstMismatch := some index }
        if (verdictOf minimal { reinfer := config.reinfer }).isOk then
          IO.println s!"STOP {o.label} mismatch also accepted by corrected rule (index {index})"
          return { ok := false, counts, firstMismatch := some index }
        found := some index
  let elapsed := (← IO.monoMsNow) - start
  if !o.quiet then
    for (family,c,lo,hi) in families do
      IO.println s!"family={family} depth={lo}..{hi} {c.line}"
    -- Per checker row: accepted programs that write in place and exercised it.
    for (row, n) in rowHits.mergeSort (fun a b => a.1 < b.1) do
      IO.println s!"row-hits {n} {row}"
  IO.println s!"{header} {counts.line} first-mismatch={found.map toString |>.getD "none"} elapsed-ms={elapsed}"
  if !o.negative then IO.println (counts.summary o.seed)
  if o.negative && found.isNone then
    IO.println s!"no generated accepted disagreement under {o.label} (a failure unless the control is optional)"
    return { ok := false, counts, elapsed }
  pure { ok := counts.accepted > 0 && counts.typeErrors == 0 && counts.executionErrors == 0,
         counts, firstMismatch := found, elapsed }

/-- How often a mutant changes a verdict at all: programs the mutated checker
    accepts and the corrected one rejects, and how many of those disagree when
    run. A mutant that changes no verdict on a campaign is inert there. -/
def verdictDiff (count seed : Nat) (m : Mutant) (reinfer : Bool) (version := 5) (quiet := false) : IO (Nat × Nat) := do
  let mut state := seed
  let mut onlyMutant := 0
  let mut disagreeing := 0
  let mut firstIndex : Option Nat := none
  for index in List.range count do
    let ((family, p), next) := (generateVersion version).run state
    state := next
    if (verdictOf p { reinfer }).isOk then continue
    if !(verdictOf p { mutant := some m, reinfer }).isOk then continue
    onlyMutant := onlyMutant + 1
    if firstIndex.isNone && !quiet then
      firstIndex := some index
      IO.println s!"first verdict change index={index} family={family} corrected={repr (verdictOf p { reinfer })}\n{repr p.main}"
    if (compare p).disagrees then disagreeing := disagreeing + 1
  if !quiet then
    IO.println s!"mutant={m.name} checker={if reinfer then "reinfer" else "summaries"} seed={seed} budget={count} verdicts-changed={onlyMutant} of-which-disagree={disagreeing}"
  pure (onlyMutant, disagreeing)

/-- Rejection reasons and accepted-with-write counts of one family, for tuning
    and for reporting what a family actually exercises. -/
def reasons (count seed : Nat) (family : String) (version := 5) : IO Unit := do
  let mut state := seed
  let mut table : List (String × Nat) := []
  for _ in List.range count do
    let ((f, p), next) := (generateVersion version).run state
    state := next
    if f != family then continue
    let key := match verdictOf p with
      | .error m => (m.splitOn ":").head!
      | .ok _ => if InPlaceSemantics.writeCount p > 0 then "accepted with write" else "accepted without write"
    table := match table.find? (·.1 == key) with
      | some (_, n) => table.map fun (k, m) => if k == key then (k, n + 1) else (k, m)
      | none => table ++ [(key, 1)]
  for (k, n) in table.mergeSort (fun a b => a.2 ≥ b.2) do IO.println s!"{n}\t{k}"

/-- Every required negative control must be caught by the generator alone
    within one normal run's budget: each run stops at its first accepted
    disagreement. Summary-row mutants exist only in the summary checker.
    `borrowed-supply` is reported under summaries (it changes verdicts but no
    disagreement has been seen; COVERAGE.md argues none can) and required
    against the per-call checker; generator-optional mutants are reported. -/
def controls (count seed : Nat) (version := 5) (reinfer := false) : IO Bool := do
  let checkerName := if reinfer then "per-call" else "summaries"
  let named : List (String × Config) :=
    [("old-rule", { oldFreshRule := true, reinfer }), ("old-escape-rule", { dropTraversalEscapes := true, reinfer })] ++
    (Mutant.all.filter (fun m => !reinfer || !m.summaryRow)).map fun m =>
      if m == .borrowedSupply && !reinfer then
        (s!"mutant={m.name}", { mutant := some m, reinfer := true })
      else (s!"mutant={m.name}", { mutant := some m, reinfer })
  let mut ok := true
  let mut rows : List String := []
  for (name, config) in named do
    if config.mutant.any Mutant.enumeratorRequired then
      rows := rows ++ [s!"{name}: required through the targeted enumerator (checked by the CLI)"]
      continue
    if config.mutant == some .borrowedSupply && !reinfer then
      -- Reported separately, never swapped silently: under summaries this
      -- mutant changes verdicts but no program it accepts has been seen to
      -- disagree (COVERAGE.md, "Borrowed supply"). The required catch is
      -- against the per-call checker, on the line below.
      let (changed, disagree) ← verdictDiff count seed .borrowedSupply false version true
      rows := rows ++ [s!"{name} [summaries]: NOT OBSERVABLE (not required) verdicts-changed={changed} disagreeing={disagree}"]
    let r ← runWith { count, seed, version, config, stopAtFirst := true, quiet := true }
    let label := if config.reinfer then "per-call" else checkerName
    let gap := config.mutant.any Mutant.generatorOptional
    rows := rows ++ [s!"{name} [{label}]{if gap then " generator catch reported, not required" else ""}: caught={r.firstMismatch.isSome && r.ok} first-index={r.firstMismatch.map toString |>.getD "none"} elapsed-ms={r.elapsed}"]
    if !r.ok && !gap then ok := false
  for row in rows do IO.println s!"CONTROL {row}"
  IO.println s!"controls budget={count} seed={seed} generator-version={version} checker={checkerName} passed={ok}"
  pure ok

end Ownership.Oracle

