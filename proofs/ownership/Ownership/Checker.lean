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
  bridgeRoot : String := "main"
  declarations : List Decl
  config : Config
  moduleInitializer : Bool := true
  privateTransfer : Bool := false
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
  /-- Cells of the continuation's uses of outer variables that an inner `let`
      has since rebound: live after the current expression whatever the
      name now means (shadowing is refused, this keeps liveness right anyway). -/
  pinned : List Origin := []
  deriving Inhabited

structure CacheEntry where
  decl : Nat
  inputs : List Abstract
  owned : List Origin
  summary : Summary
  deriving Repr, Inhabited

structure St where
  bridgeSites : List String := []
  privateCells : List Origin := []
  facts : Summary := {}
  cache : Array CacheEntry := #[]
  /-- Summaries computed, and call sites served from the cache. -/
  computed : Nat := 0
  reused : Nat := 0
  /-- Which checker rows this check exercised (for per-row hit counts). -/
  hits : List String := []
  deriving Inhabited

abbrev CheckM := StateT St (Except String)

/-- Diagnostic breadcrumbs only. The ordinary exception and state are unchanged
    when disabled. A failure carries the sites visited before it; unvisited
    sites must not be classified by a differential consumer. -/
def bridgeKey (ctx : Context) (site : List Nat) : String :=
  ctx.bridgeRoot ++ String.join (site.map fun n => s!"/{n}")

def bridgeObserve (ctx : Context) (site : List Nat) (m : CheckM Abstract) : CheckM Abstract :=
  if !ctx.config.bridgeTrace || ctx.config.shapeOnly then m else fun st =>
    match m.run st with
    | .ok (a, next) => .ok (a, { next with bridgeSites := next.bridgeSites ++ [bridgeKey ctx site] })
    | .error e =>
      if e.startsWith "BRIDGE\n" then .error e
      else .error ("BRIDGE\n" ++ bridgeKey ctx site ++ "\n" ++
        String.intercalate "," st.bridgeSites ++ "\n" ++ e)

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
  if !cfg.shapeOnly then
    if let some problem := demandProblem cfg (← getFacts).escapes cs later others then throw problem
  modifyFacts fun s => { s with writes := union s.writes (cs.filter external) }

def individuallyOwned (ctx : Context) (cs : List Origin) : Bool :=
  !cellOverlap (cs.map Origin.base) (ctx.escaped.map Origin.base) &&
  cs.all fun c => unescaped c && (!external c || ctx.owned.any (aliases c))

/-- The roots exposed by records, stopping at list containers and closures.
    Captures are still present in `paths` for ordinary alias checks. -/
def containerPath (p : Path) : Bool := p.all fun st => match st with
  | .field _ => true
  | _ => false

def containers (a : Abstract) : List (Path × List Origin) :=
  a.paths.filter fun (p, _) => containerPath p

def storeSpines (ctx : Context) (values : List Abstract) (later other : List Origin) : Bool :=
  let paths := values.flatMap containers
  separatedPaths paths && paths.all fun (_, cs) =>
    individuallyOwned ctx cs && !cellOverlap cs (union later other) &&
    -- A retained capture or a descendant in a different field is also a holder.
    values.all fun a => a.paths.all fun (p, ds) =>
      containerPath p || !cellOverlap cs ds

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

def spineProblem (escapes : List Origin) (a : Abstract) (later other : List Origin) : Option String :=
  match a with
  | .list _ elem ex =>
    let paths := containers elem
    if !ex.spine || !separatedPaths paths then some "container contents: positions may share"
    else if paths.any (fun (_, cs) => cellOverlap (cs.map Origin.base) (escapes.map Origin.base)) then
      some "container contents: escaped"
    else if paths.any (fun (_, cs) => cellOverlap cs (union later other)) then
      some "container contents: outside holder"
    else none
  | _ => some "container contents: not a list"

def requireSpine (a : Abstract) (later other : List Origin) (cfg : Config := {}) : CheckM Unit := do
  if !cfg.shapeOnly then
    if let some problem := spineProblem (← getFacts).escapes a later other then throw problem
  modifyFacts fun s => { s with requiresSpine := union s.requiresSpine (a.roots.filter external) }

def requireExclusive (a : Abstract) (later other : List Origin) (cfg : Config := {}) : CheckM Unit := do
  if !cfg.shapeOnly then
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
           requiresSpine := externalBase s.requiresSpine
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

/-- `liveCells`, or the `once-live` control's weakened one: the capture
    paths of a once closure hold nothing. -/
def liveCellsWith (cfg : Config) (env : Env Abstract) (l : Live) : List Origin :=
  if !cfg.has .onceLive then liveCells env l else
  l.foldl (fun cs (v, p) =>
    match env.lookup v with
    | none => union cs [.unknown]
    | some a => (a.paths.filter fun (q, _) => a.roots.isEmpty ||
          !(match q with | .capture _ :: _ => true | _ => false)).foldl (fun cs (q, ds) =>
        if isPrefix p q || isPrefix q p then union cs ds else cs) cs) []

/-- Liveness includes terminal results, within each arm's own context. The
    controls remove only the corresponding read rule, never interpreter code. -/
def usesWith (cfg : Config) (e : Expr) (resultRead : Bool := true) : Live :=
  match e with
  | .atom a => if resultRead then atomUses a else []
  | .letE v rhs rest => union (usesWith cfg rhs)
      (removeVars [v] (usesWith cfg rest (resultRead && !cfg.has .blockResult)))
  | .branch c a b =>
    let ua := usesWith cfg a (resultRead && !cfg.has .armResult)
    let ub := if cfg.has .branchLive then [] else usesWith cfg b (resultRead && !cfg.has .armResult)
    let ua := if cfg.has .branchClosure then ua.filter (fun u => !(closureCapUses a).contains u) else ua
    let ub := if cfg.has .branchClosure then ub.filter (fun u => !(closureCapUses b).contains u) else ub
    union (atomUses c) (union ua ub)
  | .resultCase input err ok a b => union (atomUses input)
      (union (removeVars [err] (usesWith cfg a (resultRead && !cfg.has .armResult)))
        (removeVars [ok] (usesWith cfg b (resultRead && !cfg.has .armResult))))
  | .chainCase input head tail a b => union (atomUses input)
      (union (usesWith cfg a (resultRead && !cfg.has .armResult))
        (removeVars [head, tail] (usesWith cfg b (resultRead && !cfg.has .armResult))))
  | .entry initial retained model body => union (usesWith cfg initial)
      (union (atomsUses retained) (removeVars [model] (usesWith cfg body resultRead)))
  | .closure _ xs => if cfg.has .captureRead then [] else atomsUses xs
  | .traverse _ src init i x acc body =>
    union (atomsUses [src, init]) (removeVars [i, x, acc] (usesWith cfg body))
  | .focus src i x body => union (atomsUses [src, i]) (removeVars [x] (usesWith cfg body))
  | _ => usesArms (!cfg.has .branchLive) (!cfg.has .branchClosure) (!cfg.has .prependBase) e

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

/-- Paths of a type at which cells may live. -/
def tyPaths : Ty → List Path
  | .int | .fn _ _ => []
  | .result e a => (tyPaths e).map (.field 1 :: ·) ++ (tyPaths a).map (.field 2 :: ·)
  | .record ts => ts.attach.zipIdx.flatMap fun (t, i) => (tyPaths t.val).map (.field i :: ·)
  | .chain t | .list t | .builder t => [] :: (tyPaths t).map (.element :: ·)
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem t.property
  all_goals simp_all +arith
  all_goals omega

/-- A value of type `t` whose cells and exclusivity are given per path. -/
def shapeOf (cells : List (Path × List Origin)) (exclusive : List Path) (spines : List Path) : Ty → Path → Abstract
  | .int, _ | .fn _ _, _ => .scalar
  | .result e a, p => .record [.scalar,
      shapeOf cells exclusive spines e (p ++ [.field 1]),
      shapeOf cells exclusive spines a (p ++ [.field 2])]
  | .record ts, p => .record (ts.attach.zipIdx.map fun (t, i) => shapeOf cells exclusive spines t.val (p ++ [.field i]))
  | .chain t, p | .list t, p | .builder t, p =>
    .list ((cells.lookup p).getD []) (shapeOf cells exclusive spines t (p ++ [.element])) ⟨exclusive.contains p, spines.contains p⟩
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
  | .requiresSpine k p => if s.requiresSpine.any (·.base == .parameter k p) then [1] else []
  | .spine q => match s.result.atPath q with
    | .list _ _ ex => if ex.spine then [1] else []
    | _ => [1]
  | .xres q => match s.result.atPath q with
    | .list _ _ ex => if ex.deep then [1] else []
    | _ => [1]
  | .escapesEnv => if s.escapes.any (fun c => match c with | .capture .. => true | _ => false) then [1] else []
  | .once => []

/-- Several alternatives: the class of their join. `xres` must hold of all. -/
def combineFact (f : Fact) (a b : List Nat) : List Nat :=
  match f with
  | .xres _ | .spine _ => if a.isEmpty || b.isEmpty then [] else [1]
  | _ => union a b

/-- Note that a checker row was exercised. -/
def hit (row : String) : CheckM Unit :=
  modify fun s => if s.hits.contains row then s else { s with hits := s.hits ++ [row] }

def factKind : Fact → String
  | .spine _ => "spine∈res" | .requiresSpine .. => "spine(callback arg)"
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
  | .ok _, [a] => pure (.record [.scalar, .bottom, a])
  | .err _, [e] => pure (.record [.scalar, if ctx.config.has .earlyErr then e.mapOrigins (fun _ _ => []) else e, .bottom])
  | .privateRoot, [a] => do
    if !ctx.moduleInitializer then throw "private root outside main initialization"
    let escapes := (← getFacts).escapes
    let eligible := a.cells.filter fun c => unescaped c && !cellOverlap [c] escapes
    if ctx.privateTransfer && !hasFunction a then
      modify fun st => {st with privateCells := union st.privateCells eligible}
    modifyFacts fun s => {s with escapes := union s.escapes a.cells}
    pure a
  | .endChain _, [] => pure (.list [fresh] .bottom true)
  | .link, [a, .list _ elem ex] =>
    pure (.list [fresh] (if ctx.config.has .recursivePayload then (a.join elem).mapOrigins (fun _ _ => []) else a.join elem)
      ⟨ex.deep && storeExclusive ctx [a] later elem.cells,
       ex.spine && storeSpines ctx [a] later elem.cells⟩)
  | .add, _ | .sub, _ | .eq, _ | .lt, _ => pure .scalar
  | .record, xs => pure (.record (if ctx.config.has .constructorArgs then
      xs.map (·.mapOrigins fun _ _ => []) else xs))
  | .events, [.record [_, events]] =>
    pure (if ctx.config.has .eventCapture then events.mapOrigins (fun _ _ => []) else events)
  | .owned forwarded, [value, retained] => do
    let forged := value.mapOrigins fun _ cs => if cs.isEmpty then [] else [fresh]
    if (!forwarded && ctx.config.has .taggerNeed) || (forwarded && ctx.config.has .forwardNeed) then return forged
    let holders := if ctx.config.has .captureEmpty then [] else retained.cells
    let later := if ctx.config.has .captureEmpty then later.filter (fun c => !retained.cells.any (aliases c)) else later
    demand ctx.config value.cells later holders
    if !ctx.config.shapeOnly && (!value.deepExclusive || !separatedPaths value.paths) then throw "owned result: repeated positions"
    pure (if ctx.config.has .captureEmpty then forged else value)
  | .prepend, [v, .list cs elem ex] => do
    noteRead cs
    pure (.list (union [fresh] cs) (v.join elem)
      ⟨ex.deep && storeExclusive ctx [v] later elem.cells,
       ex.spine && storeSpines ctx [v] later elem.cells &&
         (ctx.config.has .resultPositions ||
           (containers elem).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old v.cells))⟩)
  | .literal _, xs =>
    pure (.list [fresh] (xs.foldl Abstract.join .bottom) ⟨storeExclusive ctx xs later [], storeSpines ctx xs later []⟩)
  | .builder _, [] => pure (.list [fresh] .bottom true)
  | .shared, [a] => do
    let escaped := if ctx.config.has .sharedRoots then a.roots
      else if ctx.config.has .sharedFn then
        -- The `shared-fn` control: forget cells under a capture below a field.
        (a.paths.filter fun (p, _) => !(match p with
          | .field _ :: q => q.any fun st => match st with | .capture _ => true | _ => false
          | _ => false)).foldl (fun cs (_, xs) => union cs xs) []
      else a.cells
    modifyFacts fun s => { s with escapes := union s.escapes escaped }
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
    let exclusive := exclusive || (ctx.config.has .setExclusive && op == .set && ex)
    let stored := if exclusive && op == .put && ctx.config.oldFreshRule then v.grantExclusive else v
    let spine := ex.spine && storeSpines ctx [v] later elem.cells &&
      (ctx.config.has .resultPositions ||
        (containers elem).all (fun (_, old) => individuallyOwned ctx old && !cellOverlap old v.cells))
    pure (.list cs (elem.join stored) ⟨exclusive, spine⟩)
  | .copy, [.list cs elem _] => do
    noteRead cs
    pure (.list [fresh] elem (ctx.config.has .copyExclusive))
  | .close, [.list cs elem ex] => pure (.list cs elem ex)
  | .close, [.list cs elem ex, .list ds old _] =>
    -- A11: preserve every possible input alias, even if this execution's
    -- callback must allocate; no representation-based specialization here.
    if ctx.config.has .closeSource then pure (.list cs elem ex)
    else pure (.list (union cs ds) (elem.join old) ex)
  | .construct spreads, avs =>
    -- §3.2/§5: one demand on the base's cells, after every operand is
    -- evaluated. Disjoint covers every other operand path: the items, each
    -- later spread (`xs ++ xs` included) and the base's own contents.
    let b := spreads.idxOf true
    match avs[b]? with
    | some (.list cs elem ex) => do
      let operands := ((avs.zip spreads).zipIdx.filter (·.2 != b)).map (·.1)
      let stored := operands.map fun (a, spread) =>
        if spread then (match a with | .list _ e _ => e | x => x) else a
      let others := operands.foldl (fun os (a, _) => union os a.cells) elem.cells
      demand ctx.config cs later (if ctx.config.has .constructDisjoint then elem.cells else others)
      for (a, spread) in operands do
        if spread then noteRead a.roots
      -- A spread stores every position of its operand: its own certificate.
      let spreadCertificate := operands.foldl (fun (k : Certificate) (a, spread) =>
        if !spread then k else match a with
          | .list _ _ e => k.meet e
          | _ => k.meet false) true
      let exclusive := ex.deep && spreadCertificate.deep && storeExclusive ctx stored later elem.cells
      let spine := ex.spine && spreadCertificate.spine && storeSpines ctx stored later elem.cells &&
        (ctx.config.has .resultPositions ||
          (containers elem).all (fun (_, old) => individuallyOwned ctx old &&
            !cellOverlap old (stored.foldl (fun cs a => union cs a.cells) [])))
      pure (.list cs (stored.foldl Abstract.join elem) ⟨exclusive, spine⟩)
    | _ => if avs.any (· == .bottom) then pure .bottom else throw "abstract construction shape"
  | .view _, [.list cs elem ex] => do
    -- A view shares its source's array (§5, *Views*); an empty source gives
    -- a fresh `[]`. The `view-alias` control forgets the sharing.
    noteRead cs
    pure (.list (if ctx.config.has .viewAlias then [fresh] else union cs [fresh]) elem ex)
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
    let spine := sp.spine.filter fun (k, p) =>
      let inner := (sp.args[k]?.getD .bottom).atPath p
      (spineProblem escapes ((inst[k]?.getD .bottom).atPath p)
        (inner.cells.flatMap outsideFor) []).isNone
    { sp with args := inst, env, owned, exclusive, spine }

/-- Count source reads, including eager capture atoms, rather than distinct
    paths. Two also means ineligible: a free read in a deferred body or a
    recursive initializer cannot authorize a direct private transfer. -/
def atomReadCount (v : Var) (a : Atom) : Nat :=
  match a with
  | .var n => if n == v then 1 else 0
  | .field a _ => atomReadCount v a
  | .int _ => 0

def readCount (v : Var) : Expr → Nat
  | .atom a => atomReadCount v a
  | .prim _ xs | .closure _ xs => (xs.map (atomReadCount v)).sum
  | .recur xs => if (xs.map (atomReadCount v)).sum == 0 then 0 else 2
  | .app a xs => atomReadCount v a + (xs.map (atomReadCount v)).sum
  | .letE _ a b => readCount v a + readCount v b
  | .branch c a b => atomReadCount v c + readCount v a + readCount v b
  | .resultCase a _ _ x y | .chainCase a _ _ x y => atomReadCount v a + readCount v x + readCount v y
  | .entry initial retained _ body => readCount v initial + (retained.map (atomReadCount v)).sum +
      (if readCount v body == 0 then 0 else 2)
  | .traverse _ a z _ _ _ b => atomReadCount v a + atomReadCount v z +
      (if readCount v b == 0 then 0 else 2)
  | .focus a i _ b => atomReadCount v a + atomReadCount v i +
      (if readCount v b == 0 then 0 else 2)

/-- A deliberately narrow private-read proof: one straight allocation/alias/
    capture chain ends in the single initializer; ineligible sources stay shared.
    Eligibility only removes the publication escape. It does not upgrade
    exclusivity or bound reads inside an eagerly captured closure: ordinary
    Dead, separation and summary obligations still reject retained aliases. -/
def privateToInit (v : Var) : Expr → Bool
  | .entry initial retained _ body => readCount v initial == 1 &&
      (retained.map (atomReadCount v)).sum == 0 && readCount v body == 0
  | .letE n rhs rest =>
    if readCount v rhs == 0 then privateToInit v rest
    else readCount v rhs == 1 && readCount v rest == 0 &&
      match rhs with
      | .entry .. => privateToInit v rhs
      | .atom _ | .closure .. | .prim .record _ => privateToInit n rest
      | _ => false
  | _ => false

mutual

def inferExpr (fuel : Nat) (ctx : Context) (env : Env Abstract)
    (e : Expr) (after : Live) (site : List Nat) : CheckM Abstract := bridgeObserve ctx site do
  if fuel = 0 then throw "limit: inference depth"
  else
    let f := fuel - 1
    let ctx := { ctx with escaped := union ctx.escaped (← getFacts).escapes }
    if !ctx.config.has .noScope then liveScope env after
    let later := union (liveCellsWith ctx.config env after) ctx.pinned
    match e with
    | .atom a => abstractAtom env a
    | .letE v rhs rest =>
      let rhsCtx := {ctx with privateTransfer := (match rhs with
        | .prim .privateRoot _ => privateToInit v rest
        | _ => false)}
      let a ← inferExpr f rhsCtx env rhs (union after (removeVars [v] (usesWith ctx.config rest))) (site ++ [0])
      -- The continuation's uses of `v` name the outer binding. Inside `rest`
      -- `v` is the new one, so their cells are pinned here, resolved
      -- against the outer environment (the `shadowing` control does not).
      let outer := after.filter (·.1 == v)
      if ctx.config.has .shadowing || outer.isEmpty then
        inferExpr f ctx ((v, a) :: env) rest after (site ++ [1])
      else
        inferExpr f { ctx with pinned := union ctx.pinned (liveCellsWith ctx.config env outer) } ((v, a) :: env) rest
          (removeVars [v] after) (site ++ [1])
    | .prim op args => primitive ctx site op (← args.mapM (m := Except String) (abstractAtom env)) later
    | .entry initial retained model body =>
      let pendingPrivate := (← get).privateCells
      let privateCells := if ctx.moduleInitializer || ctx.config.has .initFrame then pendingPrivate else []
      -- Transfer authority is single-use. A nested entry cannot clear a
      -- new escape of the model produced by this initialization.
      if ctx.moduleInitializer && !ctx.config.has .initAuthority then
        modify fun st => {st with privateCells := []}
      modifyFacts fun s => {s with escapes := s.escapes.filter fun c => !privateCells.contains c}
      let ctx := {ctx with escaped := ctx.escaped.filter fun c => !privateCells.contains c}
      let initialAfter := union after (union (atomsUses retained) (removeVars [model] (usesWith ctx.config body)))
      let a ← inferExpr f ctx env initial initialAfter (site ++ [0])
      let a := if ctx.config.has .initShared then a.mapOrigins (fun _ cs =>
        cs.map fun c => if c == .shared then .site site 99 else c) else a
      if ctx.config.has .initShared then
        modifyFacts fun s => {s with escapes := s.escapes.filter fun c => !cellOverlap [c] a.cells}
      let kept ← retained.mapM (m := Except String) (abstractAtom env)
      if !ctx.config.has .initRetained then
        modifyFacts fun s => {s with escapes := union s.escapes (kept.flatMap Abstract.cells)}
      inferExpr f {ctx with moduleInitializer := false} ((model, a) :: env) body after (site ++ [1])
    | .resultCase input err ok onError onSuccess =>
      let value ← abstractAtom env input
      if value == .bottom then return .bottom
      let .record [_, e, a] := value | throw "abstract result case"
      let before ← getFacts
      let left ← if e == .bottom then pure .bottom else inferExpr f ctx ((err, e) :: env) onError after (site ++ [0])
      let leftFacts ← getFacts
      modifyFacts fun _ => before
      let right ← if a == .bottom then pure .bottom else inferExpr f ctx ((ok, a) :: env) onSuccess after (site ++ [1])
      let rightFacts ← getFacts
      modifyFacts fun _ => leftFacts.join rightFacts
      pure (left.join right)
    | .chainCase input head tail onEnd onLink =>
      let value ← abstractAtom env input
      if value == .bottom then return .bottom
      let .list cs elem ex := value | throw "abstract chain case"
      let before ← getFacts
      let left ← inferExpr f ctx env onEnd after (site ++ [0])
      let leftFacts ← getFacts
      modifyFacts fun _ => before
      -- The tail conservatively holds every payload position. It is copied
      -- by the interpreters; no destructive spine operation has a Chain type.
      let right ← inferExpr f ctx ((head, elem) :: (tail, .list cs elem ex) :: env)
        onLink after (site ++ [1])
      let rightFacts ← getFacts
      modifyFacts fun _ => leftFacts.join rightFacts
      pure (left.join right)
    | .branch c yes no =>
      let _ ← abstractAtom env c
      let before ← getFacts
      let a ← inferExpr f ctx env yes after (site ++ [0])
      let left ← getFacts
      modifyFacts fun _ => if ctx.config.has .branchEscapes then { before with escapes := [] } else before
      let b ← inferExpr f ctx env no after (site ++ [1])
      let right ← getFacts
      modifyFacts fun _ => left.join right
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
      applyCall ctx ctx.recursiveSummary site actuals
        (if ctx.config.has .recursiveCapture then
          ctx.recursiveCaptures.map (·.mapOrigins fun _ _ => []) else ctx.recursiveCaptures) later
    | .focus src index x body =>
      let input ← abstractAtom env src
      let _ ← abstractAtom env index
      if input == .bottom then return .bottom
      let .list cs item ex := input | throw "abstract focus"
      let caps := closureCaps ctx.config env body [x]
      let capValues := caps.map Prod.snd
      let element := if ex then item.grantExclusive else item
      let s ← inferScope f { ctx with bridgeRoot := bridgeKey ctx site ++ "/body" } [(x, element)] caps body later
      let consumes := (s.writes ++ s.consumes).any fun c => match c with | .parameter 0 _ => true | _ => false
      let rootWrites := (s.writes ++ s.consumes).all fun c => match c with
        | .parameter 0 p => containerPath p
        | _ => true
      if consumes then
        if rootWrites && !ex.deep then requireSpine input later (capValues.flatMap Abstract.cells) ctx.config
        else requireExclusive input later (capValues.flatMap Abstract.cells) ctx.config
      demand ctx.config cs later (capValues.flatMap Abstract.cells)
      let out ← applyScope ctx s (site ++ [0]) [element] capValues later (fun _ => later) false
      let keepsContainers := (containers s.result).all fun (p, os) =>
        (s.result.paths.all fun (q, ds) => p == q || !cellOverlap os ds) &&
        os.all fun o => match o with
          | .parameter 0 q => p == q
          | .fresh _ => true
          | _ => false
      let oldContainers := (containers item).flatMap Prod.snd
      -- A selected parameter can move into an opaque slot: its old position
      -- was removed. A captured value may instead be a retained *other*
      -- position, so it must remain separate from all old containers.
      let avoidsRetained := (s.result.paths.filter fun (p, _) => !containerPath p).all fun (_, os) =>
        os.all fun o => match o.base with
          | .parameter 0 _ | .fresh _ => true
          | .capture .. => !cellOverlap oldContainers (instantiateOrigin (site ++ [0]) [element] capValues o)
          | _ => false
      pure (.list cs (item.join out)
        ⟨ex.deep && (ctx.config.has .keepsShape || keepsShape s.result),
         ex.spine && (ctx.config.has .keepsShape || (keepsContainers && (ctx.config.has .resultPositions || avoidsRetained)))⟩)
    | .traverse kind src initial i x acc body =>
      let input ← abstractAtom env src
      let init ← abstractAtom env initial
      let (roots, rawElement, sourceEx) ← match kind, input with
        | .range, _ | .model, _ => pure ([], Abstract.scalar, true)
        | .list, .list cs elem ex => pure (cs, elem, ex.deep)
        | .list, .bottom => pure ([], Abstract.bottom, true)
        | _, _ => throw "abstract traversal"
      noteRead roots
      let caps := closureCaps ctx.config env body [i, x, acc]
      let capValues := caps.map Prod.snd
      let element := if sourceEx || ctx.config.has .foldLoan then
          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))
        else rawElement
      let previous := fun a : Abstract => a.mapOrigins fun _ cs => cs.map fun c =>
        match c with
        | .position s _ o => if s == site then .position s false o else c
        | c => c
      let cacheBefore := (← get).cache
      let ((shape, made), _) ← isolated do
        let shapeCtx := { ctx with bridgeRoot := bridgeKey ctx site ++ "/body", config := { ctx.config with shapeOnly := true } }
        let mut shape := init
        let mut made : List Origin := []
        let mut stable := false
        for _ in List.range ctx.config.rounds do
          if !stable then
            let s ← inferScope f shapeCtx [(i, .scalar), (x, element), (acc, shape)] caps body later
            let args := [Abstract.scalar, element, shape]
            let allocations := s.result.cells.filter fun o => match o with | .fresh _ => true | _ => false
            made := union made (allocations.flatMap (instantiateOrigin (site ++ [2]) args capValues))
            let next := previous (instantiateValue (site ++ [2]) args capValues false s.result)
            let joined := shape.join next
            stable := joined == shape
            shape := joined
        if !stable then throw "limit: traversal shape did not converge"
        pure (shape, made)
      -- Shape summaries are never eligible to serve an ordinary call.
      modify fun st => { st with cache := cacheBefore }
      let initialCells := init.cells.map Origin.base
      let initialCertificate := fun c => init.paths.foldl (fun cert (p, cs) =>
        if cs.contains c then match init.atPath p with
          | .list _ _ ex => cert.meet ex
          | _ => (false : Certificate)
        else cert) (true : Certificate)
      let mut current := shape.mapCertificates fun cs ex =>
        if cs.isEmpty then ex else
        let eligible := fun c => made.contains c && !initialCells.contains c.base && unescaped c
        ⟨ex.deep || cs.all (fun c => eligible c || (initialCells.contains c.base && unescaped c && (initialCertificate c).deep)),
         ex.spine || cs.all (fun c => eligible c || (initialCells.contains c.base && unescaped c && (initialCertificate c).spine))⟩
      if (kind != .model && ctx.config.has .foldInvariant) || (kind == .model && ctx.config.has .modelInvariant) then
        current := current.grantExclusive
      if ctx.config.has .resultPositions then
        current := current.mapOrigins fun p cs =>
          if p.any (fun st => match st with | .capture _ | .env => true | _ => false) then [] else cs
      let baseFacts ← getFacts
      let mut proofEscapes := baseFacts.escapes
      let mut done_ := false
      for _ in List.range ctx.config.rounds do
        if !done_ then
          let ((joined, escapeStable), effects) ← isolated do
            modifyFacts fun _ => { baseFacts with escapes := proofEscapes }
            let beforeEscapes := (← getFacts).escapes
            let s ← inferScope f { ctx with bridgeRoot := bridgeKey ctx site ++ "/body" } [(i, .scalar), (x, element), (acc, current)] caps body later
            if !ctx.config.shapeOnly && !ctx.config.has .manyCalls &&
                (s.writes ++ s.consumes).any (fun c => match c with | .capture .. => true | _ => false) then
              throw "many calls: traversal step consumes a capture or once closure"
            let consumes := (s.writes ++ s.consumes).any fun c => match c with | .parameter 1 _ => true | _ => false
            if consumes then
              if kind == .list then
                if !ctx.config.has .traversalExclusive then
                  requireExclusive input later (capValues.flatMap Abstract.cells) ctx.config
                demand ctx.config roots later (union current.cells (capValues.flatMap Abstract.cells))
            -- A borrowed source remains an observer of any accumulator cell drawn
            -- from it. Exclusive position loans separate past from current slots.
            -- Live under summaries: it rejects 20–34 programs per 20000 trials
            -- that the line's removal would accept, none of which has been seen
            -- to disagree (`ownership verdict-diff --mutant=borrowed-supply`).
            -- Kept: removing a rule on an argued, unproved equivalence is not
            -- done here (COVERAGE.md, "Borrowed supply").
            let retained := union roots (if consumes || ctx.config.has .borrowedSupply then later
              else if ctx.config.has .foldLoan then later else union later rawElement.cells)
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
              requireExclusive a later [] ctx.config
            for req in s.requiresSpine do
              let a := match req with
                | .parameter j p => (scopeArgs[j]?.getD .bottom).atPath p
                | _ => .bottom
              requireSpine a later [] ctx.config
            noteRead (s.reads.flatMap (instantiateOrigin site scopeArgs capValues))
            if !ctx.config.dropTraversalEscapes then
              let escaped := s.escapes.flatMap (instantiateOrigin site scopeArgs capValues)
              modifyFacts fun facts => { facts with escapes := union facts.escapes (escaped.map Origin.base) }
            transfer ctx s site scopeArgs capValues outsideFor true
            let next := previous (instantiateValue (site ++ [2]) scopeArgs capValues false s.result)
            let joined := current.join next
            let joined := if (kind != .model && ctx.config.has .foldInvariant) ||
                (kind == .model && ctx.config.has .modelInvariant) then joined.grantExclusive else joined
            let joined := if ctx.config.has .resultPositions then joined.mapOrigins (fun p cs =>
              if p.any (fun st => match st with | .capture _ | .env => true | _ => false) then [] else cs)
              else joined
            pure (joined, (← getFacts).escapes == beforeEscapes)
          done_ := joined == current && escapeStable
          current := joined
          proofEscapes := effects.escapes
          -- Only the evaluation under the stable invariant publishes effects.
          if done_ then modifyFacts fun _ => effects
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
    owned := own, recursiveSummary := {}, recursiveCaptures := es.map Prod.snd, inScope := true,
    moduleInitializer := false,
    pinned := [] }
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
    calls := mergeCalls (· + ·) facts.calls (s.calls.map fun (j, n) => (j, if many && n > (if ctx.config.has .manyOff then 1 else 0) then 2 else n))
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
    requireExclusive a later [] ctx.config
  for x in s.requiresSpine do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    requireSpine a later [] ctx.config
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
    demand ctx.config (instantiateOrigin site args caps w) later (otherPaths args (if ctx.config.has .calleeCapture then [] else caps) w)
  for x in s.requiresExclusive do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    -- Other paths of this same list include its own contents, which the
    -- certificate covers; outside holders were checked at the write.
    requireExclusive a later [] ctx.config
  for x in s.requiresSpine do
    let a := match x with
      | .parameter i p => (args[i]?.getD .bottom).atPath p
      | .capture i p => (caps[i]?.getD .bottom).atPath p
      | _ => .bottom
    requireSpine a later [] ctx.config
  noteRead (s.reads.flatMap (instantiateOrigin site args caps))
  modifyFacts fun facts => { facts with escapes := union facts.escapes (s.escapes.flatMap (instantiateOrigin site args caps)) }
  pure (instantiateValue site args caps true s.result)
termination_by (0, 1)
decreasing_by all_goals simp_wf

/-- The capture writes of a once callback, following captured callbacks it
    calls. A captured function's synthetic root does not name the arrays that
    its own captures may write; a callee can call it through another closure.
    Symbolic captured calls are forwarded to the parent so its caller checks
    them where their actual code is known. -/
def demandCallbackCaptures (fuel : Nat) (ctx : Context) (id : Nat) (caps : List Abstract)
    (site : List Nat) (later : List Origin) : CheckM Unit := do
  if fuel = 0 then throw "limit: capture demand depth"
  else
    let f := fuel - 1
    let d ← ctx.declarations[id]?.toExcept "summary declaration"
    let ps := d.parameters.zipIdx.map fun (t, i) => canonical Origin.parameter i (typeShape t)
    let cs ← classOf f ctx.declarations ctx.config ctx.frames id caps ps
      (canonicalOwned ctx (d.parameters.map typeShape) caps [])
    for w in cs.writes ++ cs.consumes do
      if let .capture .. := w then
        demand ctx.config (instantiateOrigin site [] caps w) later (otherPaths [] caps w)
    for (slot, count) in cs.calls do
      if slot < d.parameters.length || count == 0 then continue
      let k := slot - d.parameters.length
      match caps[k]? with
      | some (.symbolic j ..) => recordCall j count
      | some (.function roots alts) =>
        if roots.isEmpty then continue
        if !ctx.config.has .callsEdge && count ≥ 2 then
          throw "calls edge: a captured once callback is called many times"
        demand ctx.config roots later (otherPaths [] caps (.capture k []))
        for (child, nested) in alts do
          demandCallbackCaptures f ctx child nested site later
      | _ => pure ()
termination_by (fuel, 2)
decreasing_by all_goals simp_wf; omega

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
            demandCallbackCaptures f ctx id fcaps site later
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
          if !ctx.config.shapeOnly && k < sp.args.length && !sp.owned.contains (k, p) && !ctx.config.has .supplyEdge then
            throw "supply edge: a callback writes a supply that is not owned"
      for x in s.requiresSpine do
        if let .parameter k p := x.base then
          if !ctx.config.shapeOnly && k < sp.args.length && !sp.spine.contains (k, p) then
            throw "supply edge: container certificate missing"
      for x in s.requiresExclusive do
        if let .parameter k p := x.base then
          hit "edge xreq ⇒ exclusive supply checked"
          if !ctx.config.shapeOnly && k < sp.args.length && !sp.exclusive.contains (k, p) && !ctx.config.has .requiresEdge then
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
    let mut spinePaths : List (Nat × Path) := []
    for (t, k) in ps.zipIdx do
      let a := args[k]?.getD .bottom
      for p in tyPaths t do
        let cs := a.cellsAt p
        if (demandProblem ctx.config escapes cs later (others k)).isNone then
          ownedPaths := ownedPaths ++ [(k, p)]
        if (exclusiveProblem escapes (a.atPath p) later (others k)).isNone then
          exclusivePaths := exclusivePaths ++ [(k, p)]
        if (spineProblem escapes (a.atPath p) later (others k)).isNone then
          spinePaths := spinePaths ++ [(k, p)]
        if !(← ask f ctx (query (.requiresSpine k p))).isEmpty then
          modifyFacts fun s => { s with requiresSpine := union s.requiresSpine ((a.atPath p).roots.filter external) }
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
      owned := ownedPaths, exclusive := exclusivePaths, spine := spinePaths }] }
    recordCall slot 1
    hit "callback called through its class"
    let mut cells : List (Path × List Origin) := []
    let mut exclusive : List Path := []
    let mut spines : List Path := []
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
      if ctx.config.has .callbackXres || !(← ask f ctx (query (.spine q))).isEmpty then spines := spines ++ [q]
      if ctx.config.has .callbackXres || !(← ask f ctx (query (.xres q))).isEmpty then
        exclusive := exclusive ++ [q]
    pure (shapeOf cells exclusive spines r [])
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
    let base : Context := { bridgeRoot := s!"d{id}", moduleInitializer := false,
                            declarations := parent.declarations, config := parent.config,
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
  bridgeSites : List String := []
  result : Abstract
  facts : Summary
  computed : Nat
  reused : Nat
  cache : Array CacheEntry
  hits : List String
  deriving Repr, Inhabited

def check (p : Program) (config : Config := {}) : Except String Accepted := do
  if config.shapeOnly then throw "internal shape pass cannot accept a program"
  else
    let _ ← (if config.has .shadowing then typesOf p else typecheck p)
    let ctx : Context := { declarations := p.declarations, config }
    let (result, st) ← (inferExpr config.inferenceFuel ctx [] p.main [] []).run {}
    pure { bridgeSites := st.bridgeSites, result, facts := st.facts, computed := st.computed, reused := st.reused, cache := st.cache, hits := st.hits }

end Ownership
