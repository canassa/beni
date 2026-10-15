import Ownership.Domain
import Ownership.Config

/-! The frozen per-call re-inference checker, kept as a cross-check mode
(`--reinfer`). Every call re-infers its callee for the actual arguments,
including the concrete closures it is passed, so no summary is ever shared
between call sites and the summary rows of the thesis (§3.7) are not exercised.
It shares the abstract domain, the primitive rules and the mutants with
`Ownership.Checker`. One defect found while building the summary layer is
repaired here as there: a recursive call inside a traversal or focus step was
analysed with an empty summary and is now an explicit limit (fixture
"recursion inside a step"). -/

namespace Ownership.Reinfer


structure Context where
  declarations : List Decl
  config : Config
  owned : List Origin := []
  escaped : List Origin := []
  recursiveSummary : Summary := {}
  recursiveCaptures : List Abstract := []
  recursiveParameters : List Abstract := []
  inScope : Bool := false
  deriving Inhabited

abbrev CheckM := StateT Summary (Except String)

def external (o : Origin) : Bool := match o.base with
  | .parameter .. | .capture .. => true
  | _ => false

def known (o : Origin) : Bool := o.base != .unknown
def unescaped (o : Origin) : Bool := o.base != .unknown && o.base != .shared

def noteRead (cs : List Origin) : CheckM Unit :=
  modify fun s => { s with reads := union s.reads (cs.filter external) }

def demand (cfg : Config) (cs later others : List Origin) : CheckM Unit := do
  if !cs.all known then throw "Known: unknown cell"
  if !cs.all unescaped then throw "Unescaped: shared cell"
  if cellOverlap (cs.map Origin.base) ((← get).escapes.map Origin.base) then throw "Unescaped: program-lifetime holder"
  if cellOverlap cs later then throw "Dead: an old holder is live after the demand"
  if !cfg.has .disjoint && cellOverlap cs others then throw "Disjoint: another operand path holds the written cell"
  modify fun s => { s with writes := union s.writes (cs.filter external) }

def individuallyOwned (ctx : Context) (cs : List Origin) : Bool :=
  !cellOverlap (cs.map Origin.base) (ctx.escaped.map Origin.base) &&
  cs.all fun c => unescaped c && (!external c || ctx.owned.any (aliases c))

def storeExclusive (ctx : Context) (values : List Abstract) (later other : List Origin)
    (oldBuilder := false) : Bool :=
  let freshOnly := values.all fun v =>
    v.cells.all (fun c => match c.base with | .site .. => true | _ => false)
  let recursivePremise := values.all Abstract.deepExclusive ||
    (oldBuilder && ctx.config.oldFreshRule && freshOnly)
  recursivePremise && separatedValues values && values.all fun v =>
    individuallyOwned ctx v.cells && !cellOverlap v.cells (union later other)

def requireExclusive (a : Abstract) (later other : List Origin) : CheckM Unit := do
  let .list cs elem ex := a | throw "exclusive contents required of a non-list"
  if !ex || !elem.deepExclusive || !separatedPaths elem.paths then
    throw "exclusive contents: positions or nested paths may share"
  if cellOverlap (elem.cells.map Origin.base) ((← get).escapes.map Origin.base) then
    throw "exclusive contents: permanent outside holder"
  if cellOverlap elem.cells (union later other) then
    throw "exclusive contents: outside live holder"
  modify fun s => { s with requiresExclusive := union s.requiresExclusive (cs.filter external) }

def canonical (kind : Nat → Path → Origin) (i : Nat) (a : Abstract) : Abstract :=
  a.mapOrigins fun p cs => if cs.isEmpty then [] else [kind i p]

def canonicalOwned (ctx : Context) (args caps : List Abstract) (later : List Origin) : List Origin :=
  let all := (args.map (fun x => (false, x))) ++ caps.map (fun x => (true, x))
  all.zipIdx.flatMap fun ((isCap, a), i) =>
    a.paths.filterMap fun (p, cs) =>
      let others := all.zipIdx.flatMap fun ((_, b), j) =>
        b.paths.flatMap fun (q, ds) => if i == j && p == q then [] else ds
      if individuallyOwned ctx cs && !cellOverlap cs (union later others) then
        some (if isCap then .capture (i - args.length) p else .parameter i p)
      else none

def instantiateOrigin (site : List Nat) (args caps : List Abstract) : Origin → List Origin
  | .parameter i p => (args[i]?.getD .bottom).cellsAt p
  | .capture i p => (caps[i]?.getD .bottom).cellsAt p
  | .fresh i => [.site site i]
  | c => [c]

def instantiate (site : List Nat) (args caps : List Abstract) (a : Abstract) : Abstract :=
  a.mapOrigins fun _ cs => cs.foldl (fun acc c => union acc (instantiateOrigin site args caps c)) []

def normalized (s : Summary) : Summary :=
  let locals := s.result.cells.filter fun c => match c with | .site .. => true | _ => false
  { s with escapes := s.escapes.filter external
           result := s.result.mapOrigins fun _ cs => cs.map fun c =>
      if cellOverlap [c] s.escapes then .shared else match c with
      | .site .. => .fresh (List.idxOf c locals)
      | c => c }

def otherPaths (args caps : List Abstract) (o : Origin) : List Origin :=
  let ps := args.zipIdx.flatMap fun (a, i) => a.paths.map fun (p, cs) => (Origin.parameter i p, cs)
  let es := caps.zipIdx.flatMap fun (a, i) => a.paths.map fun (p, cs) => (Origin.capture i p, cs)
  (ps ++ es).flatMap fun (q, cs) => if q == o then [] else cs

def applySummary (cfg : Config) (s : Summary) (site : List Nat) (args caps : List Abstract)
    (later : List Origin) : CheckM Abstract := do
  for w in s.writes do
    demand cfg (instantiateOrigin site args caps w) later (otherPaths args caps w)
  for x in s.requiresExclusive do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    -- Other paths of this same list include its own contents, which the
    -- certificate covers; outside holders were checked at the write.
    requireExclusive a later []
  noteRead (s.reads.flatMap (instantiateOrigin site args caps))
  modify fun facts => { facts with escapes := union facts.escapes (s.escapes.flatMap (instantiateOrigin site args caps)) }
  pure (instantiate site args caps s.result)

def keepsShape (a : Abstract) (parameter := 0) : Bool :=
  a.deepExclusive && separatedPaths a.paths && a.paths.all fun (p, cs) =>
    cs.all fun c => match c with
      | .parameter i q => i == parameter && p == q
      | .fresh _ => true
      | _ => false

def closureCaps (env : Env Abstract) (body : Expr) (bound : List Var) : List (Var × Abstract) :=
  let names := (removeVars bound (uses body)).map Prod.fst |>.foldl (fun xs x => union xs [x]) []
  names.filterMap fun v => (env.lookup v).map (v, ·)

def capabilityShape : Abstract → Abstract
  | .bottom | .scalar => .scalar
  | .record xs => .record (xs.attach.map (fun x => capabilityShape x.val))
  | .list _ x ex => .list [.unknown] (capabilityShape x) ex
  | .function .. | .symbolic .. => .function [.unknown] []
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega


def hasFunction : Abstract → Bool
  | .function .. => true
  | .record xs => xs.attach.any (fun x => hasFunction x.val)
  | .list _ x _ => hasFunction x
  | _ => false
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega


def primitive (ctx : Context) (site : List Nat) (op : Prim) (args : List Abstract)
    (later : List Origin) : CheckM Abstract := do
  let fresh := Origin.site site 0
  match op, args with
  | .add, _ | .sub, _ | .eq, _ | .lt, _ => pure .scalar
  | .record, xs => pure (.record xs)
  | .events, [.record [_, events]] => pure events
  | .owned _, [value, retained] => do
    demand ctx.config value.cells later retained.cells
    if !value.deepExclusive || !separatedPaths value.paths then throw "owned result: repeated positions"
    pure value
  | .prepend, [v, .list cs elem ex] => do
    noteRead cs
    pure (.list (union [fresh] cs) (v.join elem) (ex.deep && storeExclusive ctx [v] later elem.cells))
  | .literal _, xs =>
    pure (.list [fresh] (xs.foldl Abstract.join .bottom) (storeExclusive ctx xs later []))
  | .builder _, [] => pure (.list [fresh] .bottom true)
  | .shared, [a] => do
    modify fun s => { s with escapes := union s.escapes a.cells }
    pure (a.mapOrigins fun _ cs => if cs.isEmpty then [] else union cs [.shared])
  | .length, [a] => do noteRead a.roots; pure .scalar
  | .at, [.list cs elem _, _, fallback] => do
    noteRead (union cs elem.cells)
    pure (elem.join fallback)
  | .set, [.list cs elem ex, _, v]
  | .push, [.list cs elem ex, v]
  | .put, [.list cs elem ex, v] => do
    demand ctx.config cs later (union elem.cells v.cells)
    let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)
    let stored := if exclusive && op == .put && ctx.config.oldFreshRule then v.grantExclusive else v
    pure (.list cs (elem.join stored) exclusive)
  | .copy, [.list cs elem _] => do
    noteRead cs
    pure (.list [fresh] elem (ctx.config.has .copyExclusive))
  | .close, [.list cs elem ex] => pure (.list cs elem ex)
  | .close, [.list cs elem ex, .list ds old _] =>
    -- A11: preserve every possible input alias, even if this execution's
    -- callback must allocate; no representation-based specialization here.
    if ctx.config.has .closeSource then pure (.list cs elem ex)
    else pure (.list (union cs ds) (elem.join old) ex)
  | _, _ =>
    if args.any (· == .bottom) then pure .bottom else throw s!"abstract primitive shape: {repr op}"

mutual

def inferExpr (fuel : Nat) (ctx : Context) (env : Env Abstract)
    (e : Expr) (after : Live) (site : List Nat) : CheckM Abstract := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let f := fuel - 1
    let ctx := { ctx with escaped := union ctx.escaped (← get).escapes }
    liveScope env after
    let later := liveCells env after
    match e with
    | .atom a => abstractAtom env a
    | .letE v rhs rest =>
      let a ← inferExpr f ctx env rhs (union after (removeVars [v] (uses rest))) (site ++ [0])
      inferExpr f ctx ((v, a) :: env) rest after (site ++ [1])
    | .prim op args => primitive ctx site op (← args.mapM (m := Except String) (abstractAtom env)) later
    | .entry .. | .resultCase .. | .chainCase .. => throw "limit: sum/recursive data in frozen per-call checker"
    | .branch c yes no =>
      let _ ← abstractAtom env c
      let a ← inferExpr f ctx env yes after (site ++ [0])
      let b ← inferExpr f ctx env no after (site ++ [1])
      pure (a.join b)
    | .closure id captureAtoms =>
      let d ← ctx.declarations[id]?.toExcept "missing abstract declaration"
      let caps ← captureAtoms.mapM (m := Except String) (abstractAtom env)
      if !caps.all (fun a => a.cells.isEmpty) && d.parameters.any containsFunction then
        throw "limit: capture affinity conditional on a function parameter"
      -- Only creation of a consuming closure transfers its captured storage.
      let proto := d.parameters.map typeShape
      let s ← inferFunction f ctx id proto caps []
      let writes := s.writes.filter fun c => match c with | .capture .. => true | _ => false
      for w in writes do
        demand ctx.config (instantiateOrigin site [] caps w) later (otherPaths [] caps w)
      if s.recursive && !writes.isEmpty then throw "once recursive closure"
      pure (.function (if writes.isEmpty then [] else [.site site 0]) [(id, caps)])
    | .app callee args =>
      let fn ← abstractAtom env callee
      let actuals ← args.mapM (m := Except String) (abstractAtom env)
      let .function once alternatives := fn | if fn == .bottom then return .bottom else throw "abstract call"
      demand ctx.config once later (actuals.flatMap Abstract.cells)
      let mut result := Abstract.bottom
      for (id, caps) in alternatives do
        let s ← inferFunction f ctx id actuals caps later
        result := result.join (← applySummary ctx.config s site actuals caps later)
      pure result
    | .recur args =>
      if ctx.inScope then throw "limit: recursive call inside a traversal or focus step"
      let actuals ← args.mapM (m := Except String) (abstractAtom env)
      if actuals.any hasFunction then throw "limit: higher-order recursive argument"
      if actuals.map capabilityShape != ctx.recursiveParameters.map capabilityShape then
        throw "limit: recursion changes a tracked shape or exclusivity assumption"
      let ownedNow := canonicalOwned ctx actuals ctx.recursiveCaptures later
      if !(ctx.owned.all ownedNow.contains) then
        throw "recursive call does not preserve entry ownership assumptions"
      modify fun s => { s with recursive := true }
      applySummary ctx.config ctx.recursiveSummary site actuals ctx.recursiveCaptures later
    | .focus src index x body =>
      let input ← abstractAtom env src
      let _ ← abstractAtom env index
      if input == .bottom then return .bottom
      let .list cs item ex := input | throw "abstract focus"
      let caps := closureCaps env body [x]
      let element := if ex then item.grantExclusive else item
      let s ← inferScope f ctx [(x, element)] caps body later
      let consumes := s.writes.any fun c => match c with | .parameter 0 _ => true | _ => false
      if consumes then requireExclusive input later (caps.flatMap (fun (_, a) => a.cells))
      demand ctx.config cs later (caps.flatMap (fun (_, a) => a.cells))
      let out ← applySummary ctx.config s (site ++ [0]) [element] (caps.map Prod.snd) later
      pure (.list cs (item.join out) (ex && (ctx.config.has .keepsShape || keepsShape s.result)))
    | .traverse kind src initial i x acc body =>
      let input ← abstractAtom env src
      let init ← abstractAtom env initial
      let (roots, rawElement, sourceEx) ← match kind, input with
        | .range, _ | .model, _ => pure ([], Abstract.scalar, true)
        | .list, .list cs elem ex => pure (cs, elem, ex.deep)
        | .list, .bottom => pure ([], Abstract.bottom, true)
        | _, _ => throw "abstract traversal"
      noteRead roots
      let caps := closureCaps env body [i, x, acc]
      let capValues := caps.map Prod.snd
      let element := if sourceEx then
          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))
        else rawElement
      let previous := fun a : Abstract => a.mapOrigins fun _ cs => cs.map fun c =>
        match c with
        | .position s _ o => if s == site then .position s false o else c
        | c => c
      let mut current := init
      let mut done_ := false
      for _ in List.range ctx.config.rounds do
        if !done_ then
          let beforeEscapes := (← get).escapes
          let s ← inferScope f ctx [(i, .scalar), (x, element), (acc, current)] caps body later
          if !ctx.config.has .manyCalls &&
              s.writes.any (fun c => match c with | .capture .. => true | _ => false) then
            throw "many calls: traversal step consumes a capture or once closure"
          let consumes := s.writes.any fun c => match c with | .parameter 1 _ => true | _ => false
          if consumes then
            if kind == .list then
              if !ctx.config.has .traversalExclusive then
                requireExclusive input later (capValues.flatMap Abstract.cells)
              demand ctx.config roots later (union current.cells (capValues.flatMap Abstract.cells))
          -- A borrowed source remains an observer of any accumulator cell drawn
          -- from it. Exclusive position loans separate past from current slots.
          let retained := union roots (if consumes || ctx.config.has .borrowedSupply then later
            else union later rawElement.cells)
          for w in s.writes do
            let outside := match w with
              | .parameter 1 _ => later
              | _ => retained
            demand ctx.config (instantiateOrigin site [.scalar, element, current] capValues w) outside
              (otherPaths [.scalar, element, current] capValues w)
          for req in s.requiresExclusive do
            let a := match req with
              | .parameter j p => ([Abstract.scalar, element, current][j]?.getD .bottom).atPath p
              | _ => .bottom
            requireExclusive a later []
          noteRead (s.reads.flatMap (instantiateOrigin site [.scalar, element, current] capValues))
          if !ctx.config.dropTraversalEscapes then
            let escaped := s.escapes.flatMap (instantiateOrigin site [.scalar, element, current] capValues)
            modify fun facts => { facts with escapes := union facts.escapes (escaped.map Origin.base) }
          let next := previous (instantiate (site ++ [2]) [.scalar, element, current] capValues s.result)
          let joined := current.join next
          if joined == current && (← get).escapes == beforeEscapes then done_ := true
          current := joined
      if !done_ then throw "limit: traversal invariant did not converge"
      pure (current.mapOrigins fun _ cs => cs.map fun c =>
        match c with | .position s _ o => if s == site then o else c | c => c)
termination_by (fuel, 0)
decreasing_by all_goals simp_wf; omega

def typeShape : Ty → Abstract
  | .int => .scalar
  | .result e a => .record [.scalar, typeShape e, typeShape a]
  | .record xs => .record (xs.attach.map (fun x => typeShape x.val))
  | .chain t | .list t | .builder t => .list [.unknown] (typeShape t) true
  | .fn _ _ => .function [] []
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega


def containsFunction : Ty → Bool
  | .fn .. => true
  | .record xs => xs.attach.any (fun x => containsFunction x.val)
  | .chain t | .list t | .builder t => containsFunction t
  | .int => false
  | .result e a => containsFunction e || containsFunction a
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega


def inferScope (fuel : Nat) (parent : Context) (args caps : List (Var × Abstract))
    (body : Expr) (later : List Origin) : Except String Summary := do
  let av := args.map Prod.snd
  let cv := caps.map Prod.snd
  let ps := args.zipIdx.map fun ((v, a), i) => (v, canonical Origin.parameter i a)
  let es := caps.zipIdx.map fun ((v, a), i) => (v, canonical Origin.capture i a)
  let own := canonicalOwned parent av cv later
  let ctx := { parent with
    owned := own, recursiveSummary := {}, recursiveCaptures := es.map Prod.snd, inScope := true }
  let (result, facts) ← (inferExpr fuel ctx (ps ++ es) body [] []).run {}
  pure (normalized { facts with result })
termination_by (fuel, 1)
decreasing_by all_goals simp_wf; omega

def inferFunction (fuel : Nat) (parent : Context) (id : Nat)
    (args caps : List Abstract) (later : List Origin) : Except String Summary := do
  if fuel = 0 then throw "limit: summary inference depth"
  else
    let d ← parent.declarations[id]?.toExcept "summary declaration"
    let ps := args.zipIdx.map fun (a, i) => canonical Origin.parameter i a
    let es := caps.zipIdx.map fun (a, i) => canonical Origin.capture i a
    let own := canonicalOwned parent args caps later
    let mut candidate : Summary := {}
    let mut done_ := false
    for _ in List.range parent.config.rounds do
      if !done_ then
        let ctx := { parent with owned := own, recursiveSummary := candidate, recursiveCaptures := es, recursiveParameters := ps }
        let (result, facts) ← (inferExpr (fuel - 1) ctx (bindArgs (ps ++ es)) d.body [] []).run {}
        let next := candidate.join (normalized { facts with result })
        if next == candidate then done_ := true else candidate := next
    if !done_ then throw s!"limit: recursive summary for {d.name} did not converge"
    -- Validation uses the final assignment, including every recursive demand.
    let ctx := { parent with owned := own, recursiveSummary := candidate, recursiveCaptures := es, recursiveParameters := ps }
    let (result, facts) ← (inferExpr (fuel - 1) ctx (bindArgs (ps ++ es)) d.body [] []).run {}
    if candidate.join (normalized { facts with result }) != candidate then throw "summary validation failed"
    pure candidate
termination_by (fuel, 1)
decreasing_by all_goals simp_wf; omega

end

structure Accepted where
  result : Abstract
  facts : Summary
  deriving Repr, Inhabited

def check (p : Program) (config : Config := {}) : Except String Accepted := do
  let _ ← typecheck p
  let ctx : Context := { declarations := p.declarations, config }
  let (result, facts) ← (inferExpr config.inferenceFuel ctx [] p.main [] []).run {}
  pure { result, facts }

end Ownership.Reinfer
