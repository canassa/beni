import Ownership.Domain
import Ownership.Config

/-! The ownership checker with a summary layer (thesis §3.7, §4.4–§4.7).

Every declaration is summarised once per published guard valuation. Its
function-typed inputs are `symbolic`: the body never sees the closures a caller
passes, only the answers to `Fact`s about one call of them. The summary carries
the §3.7 rows: `use` (reads R, result A, escapes E, writes and consumes W),
`res` and `xres` (the result value), `xreq` (`requiresExclusive`), and per
function-typed input the `calls` count and one `Supply` per call (provenance,
owned bit, exclusive bit). A call site resolves the guards with the closures it
passes, checks the directional edges (W ⇒ owned supply, xreq ⇒ exclusive
supply, once ⇒ at most one call), and instantiates the summary. Recursive
groups take the optimistic fixpoint of §4.5 and are validated. The frozen
per-call re-inference checker is `Ownership.Reinfer`, kept as a cross-check. -/

namespace Ownership

structure Context where
  declarations : List Decl
  config : Config
  owned : List Origin := []
  escaped : List Origin := []
  recursiveSummary : Summary := {}
  recursiveCaptures : List Abstract := []
  recursiveParameters : List Abstract := []
  /-- Set inside a traversal or focus step, whose vocabulary is not the
      enclosing declaration's: a recursive call there is a limit. -/
  inScope : Bool := false
  /-- Innermost first: the actual function values of the declarations being
      summarised. Only `answer` reads them. -/
  frames : List Frame := []
  deriving Inhabited

structure CacheEntry where
  decl : Nat
  inputs : List Abstract
  owned : List Origin
  summary : Summary
  deriving Repr, Inhabited

structure St where
  facts : Summary := {}
  cache : Array CacheEntry := #[]
  /-- Summaries computed, and call sites served from the cache. -/
  computed : Nat := 0
  reused : Nat := 0
  /-- Which checker rows this check exercised (for per-row hit counts). -/
  hits : List String := []
  deriving Inhabited

abbrev CheckM := StateT St (Except String)

def getFacts : CheckM Summary := do pure (← get).facts

def modifyFacts (f : Summary → Summary) : CheckM Unit :=
  modify fun s => { s with facts := f s.facts }

/-- Run `m` on empty facts and return what it produced; the outer facts are
    restored. The cache and its statistics persist. -/
def isolated (m : CheckM α) : CheckM (α × Summary) := do
  let saved ← getFacts
  modifyFacts fun _ => {}
  let a ← m
  let produced ← getFacts
  modifyFacts fun _ => saved
  pure (a, produced)

def external (o : Origin) : Bool := match o.base with
  | .parameter .. | .capture .. => true
  | _ => false

def known (o : Origin) : Bool := o.base != .unknown
def unescaped (o : Origin) : Bool := o.base != .unknown && o.base != .shared

def noteRead (cs : List Origin) : CheckM Unit :=
  modifyFacts fun s => { s with reads := union s.reads (cs.filter external) }

/-- The four side conditions of a demand, as a test: `none` when they hold. -/
def demandProblem (cfg : Config) (escapes cs later others : List Origin) : Option String :=
  if !cs.all known then some "Known: unknown cell"
  else if !cs.all unescaped then some "Unescaped: shared cell"
  else if cellOverlap (cs.map Origin.base) (escapes.map Origin.base) then some "Unescaped: program-lifetime holder"
  else if cellOverlap cs later then some "Dead: an old holder is live after the demand"
  else if !cfg.has .disjoint && cellOverlap cs others then some "Disjoint: another operand path holds the written cell"
  else none

def demand (cfg : Config) (cs later others : List Origin) : CheckM Unit := do
  if let some problem := demandProblem cfg (← getFacts).escapes cs later others then throw problem
  modifyFacts fun s => { s with writes := union s.writes (cs.filter external) }

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

def exclusiveProblem (escapes : List Origin) (a : Abstract) (later other : List Origin) : Option String :=
  match a with
  | .list _ elem ex =>
    if !ex || !elem.deepExclusive || !separatedPaths elem.paths then
      some "exclusive contents: positions or nested paths may share"
    else if cellOverlap (elem.cells.map Origin.base) (escapes.map Origin.base) then
      some "exclusive contents: permanent outside holder"
    else if cellOverlap elem.cells (union later other) then
      some "exclusive contents: outside live holder"
    else none
  | _ => some "exclusive contents required of a non-list"

def requireExclusive (a : Abstract) (later other : List Origin) : CheckM Unit := do
  if let some problem := exclusiveProblem (← getFacts).escapes a later other then throw problem
  modifyFacts fun s => { s with requiresExclusive := union s.requiresExclusive (a.roots.filter external) }

def canonical (kind : Nat → Path → Origin) (i : Nat) (a : Abstract) : Abstract :=
  a.mapOrigins fun p cs => if cs.isEmpty then [] else [kind i p]

def isFunctionValue : Abstract → Bool
  | .function .. | .symbolic .. => true
  | _ => false

def hasFunction : Abstract → Bool
  | .function .. | .symbolic .. => true
  | .record xs => xs.attach.any (fun x => hasFunction x.val)
  | .list _ x _ => hasFunction x
  | _ => false
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

/-- An input of a declaration being summarised. A function value becomes the
    symbolic slot `slot`: its alternatives are hidden from the body. -/
def canonicalInput (kind : Nat → Path → Origin) (i slot : Nat) (ty : Ty) (a : Abstract) :
    Except String Abstract :=
  if isFunctionValue a then
    pure (.symbolic slot ty (if a.roots.isEmpty then [] else [kind i []])
      (if a.envCells.isEmpty then [] else [kind i [.env]]))
  else if hasFunction a then throw "limit: function value below an input path"
  else pure (canonical kind i a)

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
  | .parameter i (.env :: _) => (args[i]?.getD .bottom).envCells
  | .capture i (.env :: _) => (caps[i]?.getD .bottom).envCells
  | .parameter i p => (args[i]?.getD .bottom).cellsAt p
  | .capture i p => (caps[i]?.getD .bottom).cellsAt p
  | .fresh i => [.site site i]
  | c => [c]

def substitute (site : List Nat) (args caps : List Abstract) (cs : List Origin) : List Origin :=
  cs.foldl (fun acc c => union acc (instantiateOrigin site args caps c)) []

/-- Translate a value into the caller's vocabulary. At a call (`replaceSlots`)
    a symbolic input becomes the actual function value at its slot; at the end
    of a traversal or focus step it stays symbolic. -/
def instantiateValue (site : List Nat) (args caps : List Abstract) (replaceSlots : Bool) :
    Abstract → Abstract
  | .bottom => .bottom
  | .scalar => .scalar
  | .record xs => .record (xs.attach.map fun x => instantiateValue site args caps replaceSlots x.val)
  | .list cs x ex => .list (substitute site args caps cs) (instantiateValue site args caps replaceSlots x) ex
  | .function cs alts => .function (substitute site args caps cs) (alts.attach.map fun alt =>
      (alt.val.1, alt.val.2.attach.map fun x => instantiateValue site args caps replaceSlots x.val))
  | .symbolic j t cs es =>
    if replaceSlots then (args ++ caps)[j]?.getD .bottom
    else .symbolic j t (substitute site args caps cs) (substitute site args caps es)
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := (show sizeOf alt.val.2 < sizeOf alt.val by cases alt.val; simp +arith)
  all_goals simp_all +arith
  all_goals omega

def isSite (c : Origin) : Bool := match c with | .site .. => true | _ => false

def externalBase (cs : List Origin) : List Origin :=
  (cs.map Origin.base).filter external |>.foldl (fun xs x => union xs [x]) []

/-- What a summary publishes: its own cells by provenance (§4.4's read-off).
    Sites made here are `fresh`, escaped ones `shared`; only parameter and
    capture paths remain in the use rows. A slot the result mentions may be
    called by anyone, so its `calls` becomes many. -/
def normalized (s : Summary) : Summary :=
  let locals := s.result.cells.filter isSite
  { s with escapes := s.escapes.filter external
           writes := externalBase s.writes
           consumes := externalBase s.consumes
           reads := externalBase s.reads
           requiresExclusive := externalBase s.requiresExclusive
           supplies := s.supplies.map fun sp => { sp with
             args := sp.args.map (·.mapOrigins fun _ cs => externalBase cs)
             env := externalBase sp.env }
           calls := mergeCalls max s.calls (s.result.slots.map (·, 2))
           result := s.result.mapOrigins fun _ cs => cs.map fun c =>
      if cellOverlap [c] s.escapes then .shared else match c with
      | .site .. => .fresh (List.idxOf c locals)
      | c => c }

def otherPaths (args caps : List Abstract) (o : Origin) : List Origin :=
  let ps := args.zipIdx.flatMap fun (a, i) => a.paths.map fun (p, cs) => (Origin.parameter i p, cs)
  let es := caps.zipIdx.flatMap fun (a, i) => a.paths.map fun (p, cs) => (Origin.capture i p, cs)
  -- A write through a function input's environment (`π_i.env`) names the
  -- same cells as that input's capture paths: they are the same path, not
  -- another operand. Uses of the closure after the write are the callee's
  -- own Dead check (its `π_i` stays live), as for any other input path.
  let same := fun (q : Origin) => q == o || match o, q with
    | .parameter i (.env :: _), .parameter j (.capture _ :: _) => i == j
    | .capture i (.env :: _), .capture j (.capture _ :: _) => i == j
    | _, _ => false
  (ps ++ es).flatMap fun (q, cs) => if same q then [] else cs

def keepsShape (a : Abstract) (parameter := 0) : Bool :=
  a.deepExclusive && separatedPaths a.paths && a.paths.all fun (p, cs) =>
    cs.all fun c => match c with
      | .parameter i q => i == parameter && p == q
      | .fresh _ => true
      | _ => false

/-- `uses`, or the `branch-live` control's weakened liveness. -/
def usesWith (cfg : Config) (e : Expr) : Live :=
  usesArms (!cfg.has .branchLive) e

def closureCaps (cfg : Config) (env : Env Abstract) (body : Expr) (bound : List Var) : List (Var × Abstract) :=
  let names := (removeVars bound (usesWith cfg body)).map Prod.fst |>.foldl (fun xs x => union xs [x]) []
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

def typeShape : Ty → Abstract
  | .int => .scalar
  | .record xs => .record (xs.attach.map (fun x => typeShape x.val))
  | .list t | .builder t => .list [.unknown] (typeShape t) true
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
  | .list t | .builder t => containsFunction t
  | .int => false
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

/-- Paths of a type at which cells may live. -/
def tyPaths : Ty → List Path
  | .int | .fn _ _ => []
  | .record ts => ts.attach.zipIdx.flatMap fun (t, i) => (tyPaths t.val).map (.field i :: ·)
  | .list t | .builder t => [] :: (tyPaths t).map (.element :: ·)
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem t.property
  all_goals simp_all +arith
  all_goals omega

/-- A value of type `t` whose cells and exclusivity are given per path. -/
def shapeOf (cells : List (Path × List Origin)) (exclusive : List Path) : Ty → Path → Abstract
  | .int, _ | .fn _ _, _ => .scalar
  | .record ts, p => .record (ts.attach.zipIdx.map fun (t, i) => shapeOf cells exclusive t.val (p ++ [.field i]))
  | .list t, p | .builder t, p =>
    .list ((cells.lookup p).getD []) (shapeOf cells exclusive t (p ++ [.element])) (exclusive.contains p)
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem t.property
  all_goals simp_all +arith
  all_goals omega

/-- The class fact a published summary gives, for an alternative's answer. -/
def factOf (s : Summary) : Fact → List Nat
  | .writes k p => if (s.writes ++ s.consumes).any (·.base == .parameter k p) then [1] else []
  | .escapes k p => if s.escapes.any (·.base == .parameter k p) then [1] else []
  | .requires k p => if s.requiresExclusive.any (·.base == .parameter k p) then [1] else []
  | .aliases k p q => if (s.result.cellsAt q).any (· == .parameter k p) then [1] else []
  | .env q => if (s.result.cellsAt q).any (fun c => match c with | .capture .. => true | _ => false) then [1] else []
  | .fresh q => (s.result.cellsAt q).filterMap fun c => match c with | .fresh n => some n | _ => none
  | .shared q => if (s.result.cellsAt q).contains .shared then [1] else []
  | .top q => if (s.result.cellsAt q).any (fun c => match c with
      | .parameter .. | .capture .. | .fresh _ | .shared => false | _ => true) then [1] else []
  | .xres q => match s.result.atPath q with
    | .list _ _ ex => if ex then [1] else []
    | _ => [1]
  | .escapesEnv => if s.escapes.any (fun c => match c with | .capture .. => true | _ => false) then [1] else []
  | .once => []

/-- Several alternatives: the class of their join. `xres` must hold of all. -/
def combineFact (f : Fact) (a b : List Nat) : List Nat :=
  match f with
  | .xres _ => if a.isEmpty || b.isEmpty then [] else [1]
  | _ => union a b

/-- Note that a checker row was exercised. -/
def hit (row : String) : CheckM Unit :=
  modify fun s => if s.hits.contains row then s else { s with hits := s.hits ++ [row] }

def factKind : Fact → String
  | .writes .. => "W∈use(callback arg)" | .escapes .. => "E∈use(callback arg)"
  | .requires .. => "xreq(callback arg)" | .aliases .. => "callback arg∈res"
  | .env _ => "env∈res" | .fresh _ => "fresh∈res" | .shared _ => "shared∈res"
  | .top _ => "⊤∈res" | .xres _ => "xres" | .escapesEnv => "E∈use(env)" | .once => "once"

def recordCall (slot n : Nat) : CheckM Unit :=
  modifyFacts fun s => { s with calls := mergeCalls (· + ·) s.calls [(slot, n)] }

def frameFor (offset : Nat) (values : List Abstract) : List (Nat × Abstract) :=
  values.zipIdx.filterMap fun (a, i) => if isFunctionValue a then some (offset + i, a) else none

def primitive (ctx : Context) (site : List Nat) (op : Prim) (args : List Abstract)
    (later : List Origin) : CheckM Abstract := do
  let fresh := Origin.site site 0
  match op, args with
  | .add, _ | .sub, _ | .eq, _ | .lt, _ => pure .scalar
  | .record, xs => pure (.record xs)
  | .literal _, xs =>
    pure (.list [fresh] (xs.foldl Abstract.join .bottom) (storeExclusive ctx xs later []))
  | .builder _, [] => pure (.list [fresh] .bottom true)
  | .shared, [a] => do
    modifyFacts fun s => { s with escapes := union s.escapes a.cells }
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

/-- Re-check the supplies of a step or callee where it ends: each supplied
    cell, translated, must still pass the demand conditions against the
    holders outside (`outsideFor` the cell's inner origin), else the supply is
    no longer owned there; the same for exclusivity. -/
def recheckSupplies (ctx : Context) (s : Summary) (site : List Nat) (args caps : List Abstract)
    (replaceSlots : Bool) (outsideFor : Origin → List Origin) : CheckM (List Supply) := do
  let escapes := (← getFacts).escapes
  pure <| s.supplies.map fun sp =>
    let inst := sp.args.map (instantiateValue site args caps replaceSlots)
    let env := substitute site args caps sp.env
    if ctx.config.has .supplyRecheck then { sp with args := inst, env }
    else
    -- Disjointness between the callback's own arguments was decided where
    -- the call is; here each supplied input path is checked against the
    -- other input paths, as a write through it would be.
    let owned := sp.owned.filter fun (k, p) =>
      ((sp.args[k]?.getD .bottom).cellsAt p).all fun c =>
        (demandProblem ctx.config escapes (instantiateOrigin site args caps c) (outsideFor c)
          (otherPaths args caps c)).isNone
    let exclusive := sp.exclusive.filter fun (k, p) =>
      let inner := (sp.args[k]?.getD .bottom).atPath p
      -- As for `xreq` at a call: the certificate covers the list's own
      -- contents; only holders outside the step or callee are checked.
      (exclusiveProblem escapes ((inst[k]?.getD .bottom).atPath p)
        (inner.cells.flatMap outsideFor) []).isNone
    { sp with args := inst, env, owned, exclusive }

mutual

def inferExpr (fuel : Nat) (ctx : Context) (env : Env Abstract)
    (e : Expr) (after : Live) (site : List Nat) : CheckM Abstract := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let f := fuel - 1
    let ctx := { ctx with escaped := union ctx.escaped (← getFacts).escapes }
    let later := liveCells env after
    match e with
    | .atom a => abstractAtom env a
    | .letE v rhs rest =>
      let a ← inferExpr f ctx env rhs (union after (removeVars [v] (usesWith ctx.config rest))) (site ++ [0])
      inferExpr f ctx ((v, a) :: env) rest after (site ++ [1])
    | .prim op args => primitive ctx site op (← args.mapM (m := Except String) (abstractAtom env)) later
    | .branch c yes no =>
      let _ ← abstractAtom env c
      let a ← inferExpr f ctx env yes after (site ++ [0])
      let b ← inferExpr f ctx env no after (site ++ [1])
      pure (a.join b)
    | .closure id captureAtoms =>
      let d ← ctx.declarations[id]?.toExcept "missing abstract declaration"
      let caps ← captureAtoms.mapM (m := Except String) (abstractAtom env)
      if caps.isEmpty then return .function [] [(id, caps)]
      if !caps.all (fun a => a.cells.isEmpty) && d.parameters.any containsFunction then
        throw "limit: capture affinity conditional on a function parameter"
      -- Only creation of a consuming closure transfers its captured storage.
      let n := d.parameters.length
      let ps := d.parameters.zipIdx.map fun (t, i) => canonical Origin.parameter i (typeShape t)
      let es ← caps.zipIdx.mapM (m := Except String) fun (a, i) =>
        canonicalInput Origin.capture i (n + i) (d.captures[i]?.getD .int) a
      let frame : Frame := { actuals := frameFor n caps }
      let s ← summarise f ctx id (ps ++ es) (canonicalOwned ctx (d.parameters.map typeShape) caps [])
        (frame :: ctx.frames)
      let writes := (s.writes ++ s.consumes).filter fun c => match c with | .capture .. => true | _ => false
      for w in writes do
        demand ctx.config (instantiateOrigin site [] caps w) later (otherPaths [] caps w)
      -- A closure that calls a captured once value is once, and takes it over.
      let mut takesOnce := false
      for (slot, count) in s.calls do
        if count > 0 && slot ≥ n then
          match caps[slot - n]? with
          | some (.symbolic j ..) =>
            if !(← ask f ctx { slot := j, args := [], owned := [], fact := .once }).isEmpty then
              takesOnce := true
              demand ctx.config (caps[slot - n]?.getD .bottom).roots later (otherPaths [] caps (.capture (slot - n) []))
          | some a =>
            if !a.roots.isEmpty then
              takesOnce := true
              demand ctx.config a.roots later (otherPaths [] caps (.capture (slot - n) []))
          | none => pure ()
      if s.recursive && (!writes.isEmpty || takesOnce) then throw "once recursive closure"
      pure (.function (if writes.isEmpty && !takesOnce then [] else [.site site 0]) [(id, caps)])
    | .app callee args =>
      let fn ← abstractAtom env callee
      let actuals ← args.mapM (m := Except String) (abstractAtom env)
      match fn with
      | .bottom => pure .bottom
      | .symbolic .. => callSymbolic f ctx fn actuals site later
      | .function once alternatives =>
        demand ctx.config once later (actuals.flatMap Abstract.cells)
        let mut result := Abstract.bottom
        for (id, caps) in alternatives do
          result := result.join (← callKnown f ctx id actuals caps site later)
        pure result
      | _ => throw "abstract call"
    | .recur args =>
      if ctx.inScope then throw "limit: recursive call inside a traversal or focus step"
      let actuals ← args.mapM (m := Except String) (abstractAtom env)
      if actuals.any hasFunction then throw "limit: higher-order recursive argument"
      if actuals.map capabilityShape != ctx.recursiveParameters.map capabilityShape then
        throw "limit: recursion changes a tracked shape or exclusivity assumption"
      let ownedNow := canonicalOwned ctx actuals ctx.recursiveCaptures later
      if !(ctx.owned.all ownedNow.contains) then
        throw "recursive call does not preserve entry ownership assumptions"
      modifyFacts fun s => { s with recursive := true }
      applyCall ctx ctx.recursiveSummary site actuals ctx.recursiveCaptures later
    | .focus src index x body =>
      let input ← abstractAtom env src
      let _ ← abstractAtom env index
      if input == .bottom then return .bottom
      let .list cs item ex := input | throw "abstract focus"
      let caps := closureCaps ctx.config env body [x]
      let capValues := caps.map Prod.snd
      let element := if ex then item.grantExclusive else item
      let s ← inferScope f ctx [(x, element)] caps body later
      let consumes := (s.writes ++ s.consumes).any fun c => match c with | .parameter 0 _ => true | _ => false
      if consumes then requireExclusive input later (capValues.flatMap Abstract.cells)
      demand ctx.config cs later (capValues.flatMap Abstract.cells)
      let out ← applyScope ctx s (site ++ [0]) [element] capValues later (fun _ => later) false
      pure (.list cs (item.join out) (ex && (ctx.config.has .keepsShape || keepsShape s.result)))
    | .traverse kind src initial i x acc body =>
      let input ← abstractAtom env src
      let init ← abstractAtom env initial
      let (roots, rawElement, sourceEx) ← match kind, input with
        | .range, _ => pure ([], Abstract.scalar, true)
        | .list, .list cs elem ex => pure (cs, elem, ex)
        | .list, .bottom => pure ([], Abstract.bottom, true)
        | _, _ => throw "abstract traversal"
      noteRead roots
      let caps := closureCaps ctx.config env body [i, x, acc]
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
          let beforeEscapes := (← getFacts).escapes
          let s ← inferScope f ctx [(i, .scalar), (x, element), (acc, current)] caps body later
          if !ctx.config.has .manyCalls &&
              (s.writes ++ s.consumes).any (fun c => match c with | .capture .. => true | _ => false) then
            throw "many calls: traversal step consumes a capture or once closure"
          let consumes := (s.writes ++ s.consumes).any fun c => match c with | .parameter 1 _ => true | _ => false
          if consumes then
            if kind == .list then
              if !ctx.config.has .traversalExclusive then
                requireExclusive input later (capValues.flatMap Abstract.cells)
              demand ctx.config roots later (union current.cells (capValues.flatMap Abstract.cells))
          -- A borrowed source remains an observer of any accumulator cell drawn
          -- from it. Exclusive position loans separate past from current slots.
          -- Live under summaries: it rejects 20–34 programs per 20000 trials
          -- that the line's removal would accept, none of which has been seen
          -- to disagree (`ownership verdict-diff --mutant=borrowed-supply`).
          -- Kept: removing a rule on an argued, unproved equivalence is not
          -- done here (COVERAGE.md, "Borrowed supply").
          let retained := union roots (if consumes || ctx.config.has .borrowedSupply then later
            else union later rawElement.cells)
          let outsideFor := fun (w : Origin) => match w with
            | .parameter 1 _ => later
            | _ => retained
          let scopeArgs := [Abstract.scalar, element, current]
          for w in s.writes do
            demand ctx.config (instantiateOrigin site scopeArgs capValues w) (outsideFor w)
              (otherPaths scopeArgs capValues w)
          for req in s.requiresExclusive do
            let a := match req with
              | .parameter j p => (scopeArgs[j]?.getD .bottom).atPath p
              | _ => .bottom
            requireExclusive a later []
          noteRead (s.reads.flatMap (instantiateOrigin site scopeArgs capValues))
          if !ctx.config.dropTraversalEscapes then
            let escaped := s.escapes.flatMap (instantiateOrigin site scopeArgs capValues)
            modifyFacts fun facts => { facts with escapes := union facts.escapes (escaped.map Origin.base) }
          transfer ctx s site scopeArgs capValues outsideFor true
          let next := previous (instantiateValue (site ++ [2]) scopeArgs capValues false s.result)
          let joined := current.join next
          if joined == current && (← getFacts).escapes == beforeEscapes then done_ := true
          current := joined
      if !done_ then throw "limit: traversal invariant did not converge"
      pure (current.mapOrigins fun _ cs => cs.map fun c =>
        match c with | .position s _ o => if s == site then o else c | c => c)
termination_by (fuel, 0)
decreasing_by all_goals simp_wf; omega

/-- A traversal or focus step, summarised over its own canonical inputs. -/
def inferScope (fuel : Nat) (parent : Context) (args caps : List (Var × Abstract))
    (body : Expr) (later : List Origin) : CheckM Summary := do
  let av := args.map Prod.snd
  let cv := caps.map Prod.snd
  let ps := args.zipIdx.map fun ((v, a), i) => (v, canonical Origin.parameter i a)
  let es := caps.zipIdx.map fun ((v, a), i) => (v, canonical Origin.capture i a)
  let own := canonicalOwned parent av cv later
  let ctx := { parent with
    owned := own, recursiveSummary := {}, recursiveCaptures := es.map Prod.snd, inScope := true }
  let (result, facts) ← isolated (inferExpr fuel ctx (ps ++ es) body [] [])
  pure (normalized { facts with result })
termination_by (fuel, 1)
decreasing_by all_goals simp_wf; omega

/-- Carry a step's supply, consume, call and guard rows out of it. Calls made
    in a traversal step happen once per position: many. -/
def transfer (ctx : Context) (s : Summary) (site : List Nat) (args caps : List Abstract)
    (outsideFor : Origin → List Origin) (many : Bool) : CheckM Unit := do
  let supplies ← recheckSupplies ctx s site args caps false outsideFor
  if (supplies.zip s.supplies).any (fun (a, b) => a.owned.length < b.owned.length) then
    hit "supply owned bit cleared where a step ends"
  let consumed := s.consumes.flatMap (instantiateOrigin site args caps)
  modifyFacts fun facts => { facts with
    supplies := union facts.supplies supplies
    consumes := union facts.consumes consumed
    calls := mergeCalls (· + ·) facts.calls (s.calls.map fun (j, n) => (j, if many && n > 0 then 2 else n))
    guards := union facts.guards s.guards }
termination_by (0, 0)
decreasing_by all_goals simp_wf

/-- A focus step's rows, translated back (no slot replacement). -/
def applyScope (ctx : Context) (s : Summary) (site : List Nat) (args caps : List Abstract)
    (later : List Origin) (outsideFor : Origin → List Origin) (many : Bool) : CheckM Abstract := do
  for w in s.writes do
    demand ctx.config (instantiateOrigin site args caps w) later (otherPaths args caps w)
  for x in s.requiresExclusive do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    requireExclusive a later []
  noteRead (s.reads.flatMap (instantiateOrigin site args caps))
  modifyFacts fun facts => { facts with escapes := union facts.escapes (s.escapes.flatMap (instantiateOrigin site args caps)) }
  transfer ctx s site args caps outsideFor many
  pure (instantiateValue site args caps false s.result)
termination_by (0, 1)
decreasing_by all_goals simp_wf

/-- A callee's (or the recursive candidate's) rows at a call: its writes and
    consumes become demands on the actual cells, its `xreq` an exclusivity
    demand; the result is instantiated with the actual function values. -/
def applyCall (ctx : Context) (s : Summary) (site : List Nat) (args caps : List Abstract)
    (later : List Origin) : CheckM Abstract := do
  for w in s.writes ++ s.consumes do
    demand ctx.config (instantiateOrigin site args caps w) later (otherPaths args caps w)
  for x in s.requiresExclusive do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    -- Other paths of this same list include its own contents, which the
    -- certificate covers; outside holders were checked at the write.
    requireExclusive a later []
  noteRead (s.reads.flatMap (instantiateOrigin site args caps))
  modifyFacts fun facts => { facts with escapes := union facts.escapes (s.escapes.flatMap (instantiateOrigin site args caps)) }
  pure (instantiateValue site args caps true s.result)
termination_by (0, 1)
decreasing_by all_goals simp_wf

/-- A call of a known declaration: its summary is looked up (or computed once)
    for the canonical inputs, with the actual function values in a new frame;
    then the guards it forwarded, its supplies and its calls are resolved. -/
def callKnown (fuel : Nat) (ctx : Context) (id : Nat) (actuals caps : List Abstract)
    (site : List Nat) (later : List Origin) : CheckM Abstract := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let f := fuel - 1
    let d ← ctx.declarations[id]?.toExcept "summary declaration"
    let n := actuals.length
    let ps ← actuals.zipIdx.mapM (m := Except String) fun (a, i) =>
      canonicalInput Origin.parameter i i (d.parameters[i]?.getD .int) a
    let es ← caps.zipIdx.mapM (m := Except String) fun (a, i) =>
      canonicalInput Origin.capture i (n + i) (d.captures[i]?.getD .int) a
    let frame : Frame := { actuals := frameFor 0 actuals ++ frameFor n caps }
    let s ← summarise f ctx id (ps ++ es) (canonicalOwned ctx actuals caps later) (frame :: ctx.frames)
    -- Guards on our own symbolic slots become our guards.
    for g in s.guards do
      match frame.actuals.lookup g.query.slot with
      | some (.symbolic j ..) =>
        hit "guard forwarded to the caller's own input"
        if !ctx.config.has .forwardGuards then
          let _ ← ask f ctx { g.query with slot := j }
      | _ => pure ()
    let supplies ← recheckSupplies ctx s site actuals caps true (fun _ => later)
    if (supplies.zip s.supplies).any (fun (a, b) => a.owned.length < b.owned.length) then
      hit "supply owned bit cleared at the caller"
    for sp in supplies do
      match frame.actuals.lookup sp.slot with
      | some (.symbolic j ..) =>
        hit "supply transferred to the caller's own input"
        if !ctx.config.has .transferSupplies then
          modifyFacts fun facts => { facts with supplies := union facts.supplies [{ sp with slot := j }] }
      | some (.function _ alts) =>
        hit "supply resolved at a known callback"
        checkEdges f ctx sp alts
      | _ => pure ()
    for (slot, count) in s.calls do
      match frame.actuals.lookup slot with
      | some (.symbolic j ..) => recordCall j count
      | some (.function roots alts) =>
        if !roots.isEmpty then hit "calls of a once callback checked"
        if count ≥ 2 && !roots.isEmpty && !ctx.config.has .callsEdge then
          throw "calls edge: a once callback is called many times"
        -- A once callback the callee may call is consumed by this call, as a
        -- direct call consumes it: its environment may be written, so no
        -- holder of the closure may be live afterwards.
        if count ≥ 1 && !roots.isEmpty && !ctx.config.has .onceThroughCall then
          let self := if slot < n then Origin.parameter slot [] else .capture (slot - n) []
          demand ctx.config roots later (otherPaths actuals caps self)
          -- The callee's summary does not show the callback writing its own
          -- environment, so the captures the closure's calls write are
          -- demanded here, as `applyCall` demands them at a direct call:
          -- creation made them dead, but a value built later may name them
          -- (a `close` returns its source, which is not a use).
          for (id, fcaps) in alts do
            let fd ← ctx.declarations[id]?.toExcept "summary declaration"
            let fps := fd.parameters.zipIdx.map fun (t, i) => canonical Origin.parameter i (typeShape t)
            let cs ← classOf f ctx.declarations ctx.config ctx.frames id fcaps fps
              (canonicalOwned ctx (fd.parameters.map typeShape) fcaps [])
            for w in cs.writes ++ cs.consumes do
              if let .capture .. := w then
                demand ctx.config (instantiateOrigin site [] fcaps w) later (otherPaths [] fcaps w)
      | _ => pure ()
    applyCall ctx s site actuals caps later
termination_by (fuel, 2)
decreasing_by all_goals simp_wf; omega

/-- The directional edges at a call that knows the callback (thesis §4.7):
    a callback may write a supplied path only where the supply is owned, and
    may require it exclusive only where the supply is exclusive. -/
def checkEdges (fuel : Nat) (ctx : Context) (sp : Supply) (alts : List (Nat × List Abstract)) :
    CheckM Unit := do
  if fuel = 0 then throw "limit: inference depth"
  else
    for (id, caps) in alts do
      let s ← classOf (fuel - 1) ctx.declarations ctx.config ctx.frames id caps sp.state.1 sp.state.2
      for w in s.writes ++ s.consumes do
        if let .parameter k p := w.base then
          hit "edge W ⇒ owned supply checked"
          if k < sp.args.length && !sp.owned.contains (k, p) && !ctx.config.has .supplyEdge then
            throw "supply edge: a callback writes a supply that is not owned"
      for x in s.requiresExclusive do
        if let .parameter k p := x.base then
          hit "edge xreq ⇒ exclusive supply checked"
          if k < sp.args.length && !sp.exclusive.contains (k, p) && !ctx.config.has .requiresEdge then
            throw "supply edge: a callback needs a supply exclusive that is not"
termination_by (fuel, 3)
decreasing_by all_goals simp_wf; omega

/-- A callback's class under σ: the summary of one of its alternatives, its
    parameters in the canonical state σ, its captures as they are. -/
def classOf (fuel : Nat) (decls : List Decl) (config : Config) (rest : List Frame) (id : Nat)
    (caps : List Abstract) (args : List Abstract) (owned : List Origin) : CheckM Summary := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let d ← decls[id]?.toExcept "callback declaration"
    let n := args.length
    let es ← caps.zipIdx.mapM (m := Except String) fun (a, i) =>
      canonicalInput Origin.capture i (n + i) (d.captures[i]?.getD .int) a
    summarise (fuel - 1) { declarations := decls, config } id (args ++ es) owned
      ({ actuals := frameFor n caps } :: rest)
termination_by (fuel, 4)
decreasing_by all_goals simp_wf; omega

/-- Answer one class fact of a slot of the innermost frame, following symbolic
    actuals outwards to the call that knows the closure. -/
def answer (fuel : Nat) (decls : List Decl) (config : Config) (frames : List Frame) (q : Query) :
    CheckM (List Nat) := do
  if fuel = 0 then throw "limit: inference depth"
  else
    match frames with
    | [] => throw "limit: callback class asked outside a call"
    | fr :: rest =>
      match fr.actuals.lookup q.slot with
      | some (.symbolic j ..) => answer (fuel - 1) decls config rest { q with slot := j }
      | some (.function roots alts) =>
        if q.fact == .once then return (if roots.isEmpty then [] else [1])
        let mut out : Option (List Nat) := none
        for (id, caps) in alts do
          let s ← classOf (fuel - 1) decls config rest id caps q.args q.owned
          let a := factOf s q.fact
          out := some (match out with | none => a | some b => combineFact q.fact a b)
        pure (out.getD [])
      | some .bottom => pure []
      | _ => throw "limit: callback value is not a closure"
termination_by (fuel, 5)
decreasing_by all_goals simp_wf; omega

/-- Ask a class fact of a slot of the declaration being summarised; the
    answer is recorded as one of its guards. -/
def ask (fuel : Nat) (ctx : Context) (q : Query) : CheckM (List Nat) := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let a ← answer (fuel - 1) ctx.declarations ctx.config ctx.frames q
    modifyFacts fun s => { s with guards := union s.guards [{ query := q, answer := a }] }
    if !a.isEmpty then hit s!"{factKind q.fact} yes"
    else if q.fact matches .xres _ then hit "xres no"
    pure a
termination_by (fuel, 6)
decreasing_by all_goals simp_wf; omega

/-- A call of a function-typed input (thesis §4.7): its effect on this body is
    read from the class facts the call site will answer. Writes and escapes of
    the arguments become guarded rows of this summary; the supply records
    what is passed, owned and exclusive; the result is built from the
    callback's `res` and `xres`. -/
def callSymbolic (fuel : Nat) (ctx : Context) (g : Abstract) (args : List Abstract)
    (site : List Nat) (later : List Origin) : CheckM Abstract := do
  if fuel = 0 then throw "limit: inference depth"
  else
    let f := fuel - 1
    let .symbolic slot ty _ envCells := g | throw "symbolic call of a non-symbolic value"
    let .fn ps r := ty | throw "symbolic call of a non-function type"
    if ps.any containsFunction || containsFunction r then
      throw "limit: callback with a function-typed parameter or result"
    let state := args.zipIdx.map fun (a, i) => canonical Origin.parameter i a
    let owned := canonicalOwned ctx args [] later
    let query := fun fact => { slot, args := state, owned, fact : Query }
    let escapes := (← getFacts).escapes
    let others := fun (k : Nat) => union envCells (args.zipIdx.flatMap fun (a, i) => if i == k then [] else a.cells)
    let mut ownedPaths : List (Nat × Path) := []
    let mut exclusivePaths : List (Nat × Path) := []
    for (t, k) in ps.zipIdx do
      let a := args[k]?.getD .bottom
      for p in tyPaths t do
        let cs := a.cellsAt p
        if (demandProblem ctx.config escapes cs later (others k)).isNone then
          ownedPaths := ownedPaths ++ [(k, p)]
        if (exclusiveProblem escapes (a.atPath p) later (others k)).isNone then
          exclusivePaths := exclusivePaths ++ [(k, p)]
        if !(← ask f ctx (query (.writes k p))).isEmpty && !ctx.config.has .callbackWrites then
          modifyFacts fun s => { s with consumes := union s.consumes (cs.filter external) }
        if !(← ask f ctx (query (.escapes k p))).isEmpty && !ctx.config.has .callbackEscapes then
          modifyFacts fun s => { s with escapes := union s.escapes cs }
        if !(← ask f ctx (query (.requires k p))).isEmpty && !ctx.config.has .callbackRequires then
          modifyFacts fun s => { s with requiresExclusive := union s.requiresExclusive ((a.atPath p).roots.filter external) }
    if !(← ask f ctx (query .escapesEnv)).isEmpty then
      modifyFacts fun s => { s with escapes := union s.escapes envCells }
    noteRead (union envCells (args.flatMap Abstract.cells))
    modifyFacts fun s => { s with supplies := union s.supplies [{
      slot, site, state := (state, owned), args, env := envCells,
      owned := ownedPaths, exclusive := exclusivePaths }] }
    recordCall slot 1
    hit "callback called through its class"
    let mut cells : List (Path × List Origin) := []
    let mut exclusive : List Path := []
    for q in tyPaths r do
      let mut cs : List Origin := []
      for (t, k) in ps.zipIdx do
        for p in tyPaths t do
          if !(← ask f ctx (query (.aliases k p q))).isEmpty && !ctx.config.has .callbackAliases then
            cs := union cs ((args[k]?.getD .bottom).cellsAt p)
      if !(← ask f ctx (query (.env q))).isEmpty && !ctx.config.has .callbackEnv then cs := union cs envCells
      for n in ← ask f ctx (query (.fresh q)) do cs := union cs [.site site n]
      if !(← ask f ctx (query (.shared q))).isEmpty then cs := union cs [.shared]
      if !(← ask f ctx (query (.top q))).isEmpty then cs := union cs [.unknown]
      cells := cells ++ [(q, cs)]
      if ctx.config.has .callbackXres || !(← ask f ctx (query (.xres q))).isEmpty then
        exclusive := exclusive ++ [q]
    pure (shapeOf cells exclusive r [])
termination_by (fuel, 7)
decreasing_by all_goals simp_wf; omega

/-- The published summary of a declaration for canonical inputs, computed
    once per guard valuation: a cached summary is reused when every guard it
    recorded answers the same at this call. A recursive declaration takes the
    optimistic fixpoint from the bottom summary and is then validated. -/
def summarise (fuel : Nat) (parent : Context) (id : Nat) (inputs : List Abstract)
    (owned : List Origin) (frames : List Frame) : CheckM Summary := do
  if fuel = 0 then throw "limit: summary inference depth"
  else
    let f := fuel - 1
    let d ← parent.declarations[id]?.toExcept "summary declaration"
    let n := d.parameters.length
    for entry in (← get).cache do
      if entry.decl == id && entry.inputs == inputs && entry.owned == owned then
        let mut same := true
        if !parent.config.has .guardReuse then
          for g in entry.summary.guards do
            if same then
              if (← answer f parent.declarations parent.config frames g.query) != g.answer then
                same := false
        if same then
          modify fun s => { s with reused := s.reused + 1 }
          if !entry.summary.guards.isEmpty then hit "summary reused after re-asking its guards"
          return entry.summary
    let ps := inputs.take n
    let es := inputs.drop n
    let base : Context := { declarations := parent.declarations, config := parent.config,
                            owned, frames }
    let mut candidate : Summary := {}
    let mut done_ := false
    for _ in List.range parent.config.rounds do
      if !done_ then
        let ctx := { base with recursiveSummary := candidate, recursiveCaptures := es, recursiveParameters := ps }
        let (result, facts) ← isolated (inferExpr f ctx (bindArgs (ps ++ es)) d.body [] [])
        let next := candidate.join (normalized { facts with result })
        if next == candidate then done_ := true else candidate := next
    if !done_ then throw s!"limit: recursive summary for {d.name} did not converge"
    -- Validation uses the final assignment, including every recursive demand.
    let ctx := { base with recursiveSummary := candidate, recursiveCaptures := es, recursiveParameters := ps }
    let (result, facts) ← isolated (inferExpr f ctx (bindArgs (ps ++ es)) d.body [] [])
    if candidate.join (normalized { facts with result }) != candidate then throw "summary validation failed"
    let published := if candidate.recursive then
      { candidate with calls := candidate.calls.map fun (j, k) => (j, if k > 0 then 2 else 0) }
      else candidate
    modify fun s => { s with cache := s.cache.push { decl := id, inputs, owned, summary := published },
                             computed := s.computed + 1 }
    pure published
termination_by (fuel, 8)
decreasing_by all_goals simp_wf; omega

end

structure Accepted where
  result : Abstract
  facts : Summary
  computed : Nat
  reused : Nat
  cache : Array CacheEntry
  hits : List String
  deriving Repr, Inhabited

def check (p : Program) (config : Config := {}) : Except String Accepted := do
  let _ ← typecheck p
  let ctx : Context := { declarations := p.declarations, config }
  let (result, st) ← (inferExpr config.inferenceFuel ctx [] p.main [] []).run {}
  pure { result, facts := st.facts, computed := st.computed, reused := st.reused, cache := st.cache, hits := st.hits }

end Ownership
