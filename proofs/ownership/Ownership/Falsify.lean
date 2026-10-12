import Ownership.Soundness
import Ownership.Oracle

/-! # Falsification attempts against the unproved statements

`Soundness.lean` leaves three statements `sorry`. Each is meant to be true;
this module tries to show it is not, by executing it on concrete
configurations, so that a statement that is false as written is found before
anyone tries to prove it.

* `invariant_preserved`: random small configurations — a heap of int lists,
  nested lists, records of lists and closures over lists, bound to variables,
  some registered as permanent observers, with abstract values derived from a
  random naming (sometimes coarser than the heap: an extra origin, a dropped
  exclusivity flag), random continuation uses, and a random expression over
  them (writes, reads, copies, literals, `shared`, focus, traversals, calls of
  closures and of map/update/foldl, builder/close, lets and branches). The
  hypotheses are checked, not assumed; when the checker accepts the
  expression both interpreters run it, and every observational conclusion is
  checked (reads, external reads, fuel, observers, live bindings, result).
  For the naming conclusions a naming `γ'` is constructed (`rename`); a
  failure to construct one is reported separately, since the statement only
  asks that one exist.
* `summary_sound` and `map_summary_sound`: every call made while running the
  accepted programs of a generated campaign, against every published summary
  of the called declaration whose hypotheses the call meets under the
  canonical naming (each canonical input origin names the arrays at its
  path), with clauses 1–3 (and, for map, the certificate) checked.

Everything here is executable code over the definitions of `Soundness.lean`
and is not part of any proof. -/

namespace Ownership.Falsify

open InPlaceSemantics Soundness HeapProof

/-! ## Executable readings of the definitions -/

/-- The arrays `v` reaches, with fuel (the heaps here are acyclic). -/
def reachArrays (heap : Heap) : Nat → Value → List Nat
  | 0, _ => []
  | n + 1, .ref c => c :: ((heap[c]?).getD []).flatMap (reachArrays heap n)
  | n + 1, .record xs | n + 1, .closure _ xs => xs.flatMap (reachArrays heap n)
  | _, .int _ => []

/-- Every (path, array) pair of `AtPath`/`ArrayAt`, `env` paths included. -/
def pathsOf (heap : Heap) : Nat → Value → Path → List (Path × Nat)
  | 0, _, _ => []
  | n + 1, .ref c, pre => (pre, c) :: (((heap[c]?).getD []).flatMap fun x => pathsOf heap n x (pre ++ [.element]))
  | n + 1, .record xs, pre => xs.zipIdx.flatMap fun (x, i) => pathsOf heap n x (pre ++ [.field i])
  | n + 1, .closure _ caps, pre =>
    (caps.zipIdx.flatMap fun (x, i) => pathsOf heap n x (pre ++ [.capture i])) ++
    (caps.flatMap (reachArrays heap n)).map (pre ++ [.env], ·)
  | _, .int _, _ => []

/-- The values at path `q` (as `AtPath`), `env` excluded (no certificate is
    ever stated there). -/
def valuesAt (heap : Heap) : Value → Path → List Value
  | v, [] => [v]
  | .ref c, .element :: q => ((heap[c]?).getD []).flatMap (valuesAt heap · q)
  | .record xs, .field i :: q => match xs[i]? with | some x => valuesAt heap x q | none => []
  | .closure _ caps, .capture i :: q => match caps[i]? with | some x => valuesAt heap x q | none => []
  | _, _ => []

/-- The footprint with multiplicity (`Represents`'s `cs`). -/
def footprint (heap : Heap) : Nat → Value → List Nat
  | 0, _ => []
  | n + 1, .ref c => c :: ((heap[c]?).getD []).flatMap (footprint heap n)
  | n + 1, .record xs | n + 1, .closure _ xs => xs.flatMap (footprint heap n)
  | _, .int _ => []

def nodup (xs : List Nat) : Bool := xs.length == xs.eraseDups.length

/-- A finite naming: each array's origins. -/
abbrev FNaming := List (Nat × List Origin)

def originsOf (γ : FNaming) (c : Nat) : List Origin := (γ.lookup c).getD []
def namedB (γ : FNaming) (cs : List Origin) (c : Nat) : Bool := (originsOf γ c).any cs.contains
def separatingB (γ : FNaming) : Bool :=
  γ.all fun (_, os) => os.all fun a => os.all fun b => aliases a b

def depthFuel : Nat := 300

def coversB (γ : FNaming) (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  match (pathsOf heap depthFuel v []).find? (fun (q, c) => !namedB γ (namesAt a q) c) with
  | some (q, c) => some s!"array {c} at {repr q} not named by {repr (namesAt a q)} (it is named {repr (originsOf γ c)})"
  | none => none

def certifiedB (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  let bad := a.paths.find? fun (q, _) => match a.atPath q with
    | .list _ _ true => (valuesAt heap v q).any fun w => !nodup (footprint heap depthFuel w)
    | _ => false
  bad.map fun (q, _) => s!"exclusive at {repr q} but the footprint repeats an array"

def describesB (γ : FNaming) (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  (coversB γ heap a v).orElse fun _ => certifiedB heap a v

def correspondsB (heap : Heap) (o : Observation) (w : Value) : Bool :=
  match snapshot heap depthFuel w with
  | .ok o' => o' == o
  | .error _ => false

def escapedB (escapes : List Origin) (o : Origin) : Bool :=
  !unescaped o || cellOverlap [o.base] (escapes.map Origin.base)

/-- The function values at the paths `atPath` reaches (fields, elements). -/
partial def functionsOf : Abstract → List (List Origin × List (Nat × List Abstract))
  | .function roots alts => [(roots, alts)]
  | .record xs => xs.flatMap functionsOf
  | .list _ x _ => functionsOf x
  | _ => []

/-- `HonestClosures` as a test. -/
def honestB (decls : List Decl) (a : Abstract) : Bool :=
  (functionsOf a).all fun (roots, alts) => !roots.isEmpty || alts.all fun (id, caps) =>
    match (inferExpr ({} : Ownership.Config).inferenceFuel { declarations := decls, config := {} }
        (caps.zipIdx.map fun (c, i) => (i, c)) (.closure id ((List.range caps.length).map .var)) [] []).run {} with
    | .ok (r, _) => r.roots.isEmpty
    | .error _ => false

abbrev Bindings := List (Var × Observation × Value)

def projections (o : Observation) (w : Value) (p : Path) : Option (Observation × Value) := do
  pure (← projectObs o p, ← projectVal w p)

/-- `Invariant` as a test, for a finite naming: `none` when it holds. -/
def invariantB (vs : ValueSemantics.State) (hs : InPlaceSemantics.State) (env : Bindings)
    (live : Live) (aenv : Env Abstract) (escapes : List Origin) (γ : FNaming) (naming := true) : Option String := Id.run do
  if vs.reads.toList != hs.reads.toList then return some "reads differ"
  if vs.externalReads.toList != hs.externalReads.toList then return some "external reads differ"
  if vs.fuel != hs.fuel then return some "fuel differs"
  if vs.kept.size != hs.kept.size then return some "observer counts differ"
  for (o, w) in vs.kept.toList.zip hs.kept.toList do
    if !correspondsB hs.heap o w then return some "an observer does not correspond"
  for k in (if naming then hs.kept.toList else []) do
    for c in reachArrays hs.heap depthFuel k do
      for g in originsOf γ c do
        if !escapedB escapes g then return some s!"observed array {c} named by unescaped {repr g}"
  for (x, p) in live do
    match env.lookup x with
    | none => pure ()
    | some (o, w) =>
      match projections o w p with
      | none => return some s!"live use {x}.{repr p} does not project"
      | some (o', w') =>
        if !correspondsB hs.heap o' w' then return some s!"live use {x}.{repr p} does not correspond"
        if let some a := (if naming then aenv.lookup x else none) then
          if let some why := describesB γ hs.heap (a.atPath p) w' then
            return some s!"live use {x}.{repr p}: {why}"
  for (x, _) in (if naming then env else []) do
    if let some (_, w) := env.lookup x then
      if let some a := aenv.lookup x then
        for (q, c) in pathsOf hs.heap depthFuel w [] do
          if immutablePath q && !namedB γ (a.cellsAt q) c then
            return some s!"binding {x}: array {c} at {repr q} not named"
  if naming && !separatingB γ then return some "naming not separating"
  pure none

/-! ## Constructing the naming after a step -/

/-- Requirements a naming must meet after the step: each listed array must be
    named by some origin of each list, and observed arrays only by escaped
    origins. The naming keeps an old array's origins when they meet every
    requirement, and otherwise names it (old or new) by every origin of one
    base that every requirement mentions. `none`: no such naming. -/
def rename (γ : FNaming) (heap : Heap) (reqs : List (Nat × List Origin)) (observed : List Nat)
    (escapes : List Origin) : Except String FNaming := do
  let arrays := (reqs.map Prod.fst ++ γ.map Prod.fst).eraseDups
  let mut out : FNaming := []
  for c in arrays do
    if c ≥ heap.size then continue
    let rs := (reqs.filter (·.1 == c)).map Prod.snd
    let old := originsOf γ c
    let ok := fun (os : List Origin) => rs.all (fun r => os.any r.contains) &&
      (!observed.contains c || os.all (escapedB escapes))
    if ok old then out := out ++ [(c, old)]; continue
    let candidates := (rs.flatten ++ old).map Origin.base |>.eraseDups
    match candidates.find? (fun b => ok ((rs.flatten ++ old).filter (·.base == b))) with
    | some b => out := out ++ [(c, ((rs.flatten ++ old).filter (·.base == b)).eraseDups)]
    | none => throw s!"array {c}: no single base meets {repr rs} (old {repr old}, observed {observed.contains c})"
  pure out

def requirements (heap : Heap) (a : Abstract) (w : Value) (onlyImmutable : Bool) : List (Nat × List Origin) :=
  (pathsOf heap depthFuel w []).filterMap fun (q, c) =>
    if onlyImmutable && !immutablePath q then none else some (c, namesAt a q)

/-! ## Random configurations for `invariant_preserved` -/

open Generator (draw pick tL tN tR)

private def v := Atom.var

/-- The declaration table of every configuration. -/
def decls : List Decl := [
  Library.map tL tL,
  { name := "identL", parameters := [tL], result := tL, body := .atom (v 0) },
  { name := "bump", parameters := [tL], result := tL, body := .prim .push [v 0, .int 9] },
  { name := "capPush", parameters := [.int], captures := [tL], result := tL, body := .prim .push [v 1, v 0] },
  { name := "capLen", parameters := [.int], captures := [tL], result := .int, body := .prim .length [v 1] },
  { name := "capGet", parameters := [.int], captures := [tL], result := tL, body := .atom (v 1) },
  Library.update tL,
  Library.foldl tL tL,
  { name := "grow", parameters := [tL, tL], result := tL,
    body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) },
  { name := "apply1", parameters := [tL, .fn [tL] tL], result := tL, body := .app (v 1) [v 0] },
  { name := "capAppend", parameters := [tL], captures := [tL], result := tL,
    body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) }]

def fIL : Ty := .fn [.int] tL
def fII : Ty := .fn [.int] .int
def fLL : Ty := .fn [tL] tL

structure Setup where
  heap : Array (List Value)
  env : Bindings
  aenv : Env Abstract
  types : List (Var × Ty)
  kept : List Value
  keptObs : List Observation
  escapes : List Origin
  γ : FNaming

def coin (n : Nat) : Generator.Gen Bool := do pure ((← draw n) == 0)

/-- A random heap, naming, environment and abstract environment. -/
def config : Generator.Gen Setup := do
  let leaves := 1 + (← draw 4)
  let mut heap : Array (List Value) := #[]
  for _ in List.range leaves do
    let n ← draw 3
    let mut xs : List Value := []
    for _ in List.range n do xs := xs ++ [.int (Int.ofNat (← draw 5))]
    heap := heap.push xs
  let nested ← draw 3
  for _ in List.range nested do
    let n ← draw 3
    let mut xs : List Value := []
    for _ in List.range n do xs := xs ++ [.ref (← draw leaves)]
    heap := heap.push xs
  -- Each array gets one origin; two arrays may share one.
  let mut γ : FNaming := []
  for c in List.range heap.size do
    let shareWith ← draw (4 * heap.size)
    γ := γ ++ [(c, [.site [1000 + (if shareWith < heap.size then shareWith else c)] 0])]
  let orig := fun (c : Nat) => originsOf γ c
  let extra : Generator.Gen (List Origin) := do
    if ← coin 4 then pure (orig (← draw heap.size)) else pure []
  let leafAbs : Nat → Generator.Gen Abstract := fun c => do
    pure (Abstract.list (orig c ++ (← extra)) .scalar (← coin 2))
  let nestedAbs : Nat → Generator.Gen Abstract := fun c => do
    let items := (heap[c]?.getD []).filterMap fun x => match x with | .ref d => some d | _ => none
    let innerEx ← coin 2
    let elem := if items.isEmpty then Abstract.bottom
      else .list (items.flatMap orig |>.eraseDups) .scalar innerEx
    let distinct := nodup (footprint heap depthFuel (.ref c))
    pure (Abstract.list (orig c ++ (← extra)) elem (distinct && (← coin 2)))
  let vars := 1 + (← draw 5)
  let mut env : Bindings := []
  let mut aenv : Env Abstract := []
  let mut types : List (Var × Ty) := []
  let mut kept : List Value := []
  for x in List.range vars do
    let kind ← draw 6
    let (w, a, t) ← (show Generator.Gen (Value × Abstract × Ty) from match kind with
      | 0 => do pure (Value.int (Int.ofNat (← draw 3)), Abstract.scalar, Ty.int)
      | 1 => do let c ← draw leaves; pure (.ref c, ← leafAbs c, tL)
      | 2 => if nested == 0 then do let c ← draw leaves; pure (.ref c, ← leafAbs c, tL)
          else do let c := leaves + (← draw nested); pure (.ref c, ← nestedAbs c, tN)
      | 3 => do
          let c ← draw leaves
          let d ← draw leaves
          pure (.record [.ref c, .ref d], .record [← leafAbs c, ← leafAbs d], tR)
      | _ => do
          let c ← draw leaves
          let id ← pick [3, 4, 5, 10] 4
          let once ← coin 2
          let roots := if id == 3 || id == 10 || once then [Origin.site [2000 + x] 0] else []
          let t := if id == 4 then fII else if id == 10 then fLL else fIL
          pure (.closure id [.ref c], .function roots [(id, [← leafAbs c])], t))
    env := env ++ [(x, (snapshot heap depthFuel w).toOption.getD (.int 0), w)]
    aenv := aenv ++ [(x, a)]
    types := types ++ [(x, t)]
    if ← coin 6 then kept := kept ++ [w]
  let observed := kept.flatMap (reachArrays heap depthFuel)
  let keptVars := env.filter fun (_, _, w) => kept.any (·.equal w)
  let escapes := (observed.flatMap orig ++ keptVars.flatMap fun (x, _) =>
    ((aenv.lookup x).map Abstract.cells).getD []).eraseDups
  pure { heap, env, aenv, types, kept, escapes, γ,
         keptObs := kept.map fun w => (snapshot heap depthFuel w).toOption.getD (.int 0) }

/-- Atoms of a type in a configuration, record fields included. -/
def atomsOf (types : List (Var × Ty)) (t : Ty) : List Atom :=
  types.filterMap (fun (x, u) => if u == t then some (v x) else none) ++
  (if t == tL then types.filterMap (fun (x, u) => if u == tR then some (Atom.field (v x) 0) else none) else [])

/-- A random expression of the given configuration; `next` numbers its own
    bindings (above every configuration variable). -/
def expr (types : List (Var × Ty)) (next : Nat) : Nat → Generator.Gen (Expr × Ty)
  | 0 => pure (.atom (.int 0), .int)
  | depth + 1 => do
    let ls := atomsOf types tL
    let ns := atomsOf types tN
    let fs := atomsOf types fIL ++ atomsOf types fII
    let gs := atomsOf types fLL
    let l ← pick ls (.int 0)
    let l' ← pick ls (.int 0)
    let n ← pick ns (.int 0)
    let num := Atom.int (Int.ofNat (← draw 3))
    let idx := Atom.int ((Int.ofNat (← draw 3)) - 1)
    let hasL := !ls.isEmpty
    let hasN := !ns.isEmpty
    match ← draw 20 with
    | 0 => if hasL then pure (.prim .push [l, num], tL) else pure (.prim (.literal .int) [num], tL)
    | 1 => if hasL then pure (.prim .set [l, idx, num], tL) else pure (.atom num, .int)
    | 2 => if hasL then pure (.prim .at [l, idx, .int 0], .int) else pure (.atom num, .int)
    | 3 => if hasL then pure (.prim .length [l], .int) else pure (.atom num, .int)
    | 4 => if hasL then pure (.prim .copy [l], tL) else pure (.prim (.literal .int) [], tL)
    | 5 => if hasL then pure (.prim (.literal tL) [l, l'], tN) else pure (.prim (.literal .int) [num], tL)
    | 6 => if hasL then pure (.prim .record [l, l'], tR) else pure (.atom num, .int)
    | 7 => if hasL then pure (.prim .shared [l], tL) else pure (.atom num, .int)
    | 8 => if hasN && hasL then pure (.prim .push [n, l], tN) else pure (.atom num, .int)
    | 9 => if hasN && hasL then pure (.prim .at [n, idx, l], tL) else pure (.atom num, .int)
    | 10 =>
      if !hasN then pure (.atom num, .int) else
      let y := next
      let body ← match ← draw 3 with
        | 0 => pure (Expr.prim .push [v y, num])
        | 1 => pure (.atom (v y))
        | _ => pure (if hasL then .atom l else .atom (v y))
      pure (.focus n idx y body, tN)
    | 11 =>
      if !hasN then pure (.atom num, .int) else
      let (i, x, acc, k) := (next, next + 1, next + 2, next + 3)
      if ← coin 2 then
        pure (.traverse .list n (.int 0) i x acc (.letE k (.prim .length [v x]) (.prim .add [v acc, v k])), .int)
      else
        pure (.traverse .list n (.int 0) i x acc
          (.letE k (.prim .push [v x, num]) (.letE (next + 4) (.prim .length [v k]) (.prim .add [v acc, v (next + 4)]))), .int)
    | 12 =>
      match fs.head? with
      | some f => pure (.app f [num], if (atomsOf types fII).contains f then .int else tL)
      | none => pure (.atom num, .int)
    | 13 =>
      if !hasN then pure (.atom num, .int) else
      let cb ← pick [1, 2] 1
      pure (.letE next (.closure 0 []) (.letE (next + 1) (.closure cb [])
        (.app (v next) [n, v (next + 1)])), tN)
    | 14 =>
      if !hasN then pure (.atom num, .int) else
      let cb ← pick [1, 2] 1
      pure (.letE next (.closure 6 []) (.letE (next + 1) (.closure cb [])
        (.app (v next) [n, idx, v (next + 1)])), tN)
    | 15 =>
      if !hasN || !hasL then pure (.atom num, .int) else
      pure (.letE next (.closure 7 []) (.letE (next + 1) (.closure 8 [])
        (.app (v next) [n, l, v (next + 1)])), tL)
    | 16 =>
      if !hasN || !hasL then pure (.atom num, .int) else
      pure (.letE next (.prim (.builder tL) []) (.letE (next + 1) (.prim .put [v next, l])
        (.prim .close [v (next + 1), n])), tN)
    | 17 =>
      if !hasL then pure (.atom num, .int) else
      -- A callee calls a list callback: a closure argument, or a fresh once one.
      let g ← match gs.head? with
        | some g => pure g
        | none => pure (v (next + 5))
      let call : Expr := .letE next (.closure 9 []) (.app (v next) [l, g])
      if gs.isEmpty then pure (.letE (next + 5) (.closure 10 [l']) call, tL) else pure (call, tL)
    | 18 =>
      let (a, t) ← expr types (next + 10) depth
      let (b, u) ← expr ((next, t) :: types) (next + 20) depth
      pure (.letE next a b, u)
    | _ =>
      let (a, t) ← expr types (next + 10) depth
      let (b, u) ← expr types (next + 20) depth
      if t == u then pure (.branch num a b, t) else pure (a, t)

def program : Program := { declarations := decls, main := .atom (.int 0) }

structure Tally where
  tried : Nat := 0
  hypothesisFalse : Nat := 0
  accepted : Nat := 0
  valueOk : Nat := 0
  withWrite : Nat := 0
  observational : Nat := 0
  naming : Nat := 0
  errorClause : Nat := 0
  deriving Repr

def writeOps : Expr → Bool
  | .prim .push _ | .prim .set _ | .focus .. => true
  | .letE _ a b | .branch _ a b => writeOps a || writeOps b
  | .traverse _ _ _ _ _ _ body => writeOps body
  | .app .. => true
  | _ => false

/-- One configuration: `none` if fine or vacuous, otherwise what failed. -/
def tryOne (seed : Nat) (t : Tally) (checker : Ownership.Config := {}) : Tally × Option String := Id.run do
  let ((cfg, e, after), _) := (show Generator.Gen (Setup × Expr × Live) from do
      let cfg ← config
      let (e, _) ← expr cfg.types 100 (1 + (← draw 3))
      let mut after : Live := []
      for (x, ty) in cfg.types do
        if ← coin 2 then
          after := after ++ [(x, [])]
        else if ty == tR && (← coin 3) then
          after := after ++ [(x, [.field (← draw 2)])]
      pure (cfg, e, after)).run seed
  let mut t := { t with tried := t.tried + 1 }
  let vs : ValueSemantics.State := { fuel := 5000, kept := cfg.keptObs.toArray }
  let hs : InPlaceSemantics.State := { fuel := 5000, heap := cfg.heap, kept := cfg.kept.toArray }
  if let some why := invariantB vs hs cfg.env (union (uses e) after) cfg.aenv cfg.escapes cfg.γ then
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some s!"hypothesis does not hold by construction: {why}")
  let typed := (exprType decls (mainDecl e) cfg.types e).isOk &&
    cfg.env.all fun (x, o, _) => match cfg.types.lookup x with
      | some u => obsTyped decls o u
      | none => true
  if !typed then
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some s!"hypothesis does not hold by construction: ill-typed ({repr (exprType decls (mainDecl e) cfg.types e)})")
  if !cfg.aenv.all (fun (_, a) => honestB decls a) then
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some "hypothesis does not hold by construction: a closure is described as not once")
  let ctx : Context := { declarations := decls, config := checker }
  let st : St := { facts := { escapes := cfg.escapes } }
  match (inferExpr ctx.config.inferenceFuel ctx cfg.aenv e after [7]).run st with
  | .error _ => return (t, none)
  | .ok (r, st') =>
    t := { t with accepted := t.accepted + 1 }
    let ve := (ValueSemantics.eval 5000 decls none (valueEnv cfg.env) e).run vs
    let he := (InPlaceSemantics.eval 5000 decls none (heapEnv cfg.env) e).run hs
    match ve, he with
    | .error _, .error _ => return (t, none)
    | .error m, .ok _ => return ({ t with errorClause := t.errorClause + 1 }, some s!"value run fails ({m}), in-place run succeeds")
    | .ok _, .error m => return ({ t with observational := t.observational + 1 }, some s!"in-place run fails: {m}")
    | .ok (o, vs'), .ok (w, hs') =>
      t := { t with valueOk := t.valueOk + 1, withWrite := t.withWrite + (if writeOps e then 1 else 0) }
      if !correspondsB hs'.heap o w then
        return ({ t with observational := t.observational + 1 }, some "results do not correspond")
      -- Observational part of the conclusion, on any naming.
      if let some why := invariantB vs' hs' cfg.env after cfg.aenv [] [] (naming := false) then
        return ({ t with observational := t.observational + 1 }, some why)
      if !honestB decls r then
        return ({ t with naming := t.naming + 1 }, some "the result describes a closure as not once that the checker would create once")
      -- Naming part: construct γ'.
      let liveReqs := after.flatMap fun (x, p) => match cfg.env.lookup x, cfg.aenv.lookup x with
        | some (_, w0), some a => match projectVal w0 p with
          | some w' => requirements hs'.heap (a.atPath p) w' false
          | none => []
        | _, _ => []
      let bindingReqs := cfg.env.flatMap fun (x, _, w0) => match cfg.aenv.lookup x with
        | some a => requirements hs'.heap a w0 true
        | none => []
      let reqs := requirements hs'.heap r w false ++ liveReqs ++ bindingReqs
      let observed := hs'.kept.toList.flatMap (reachArrays hs'.heap depthFuel)
      match rename cfg.γ hs'.heap reqs observed st'.facts.escapes with
      | .error why => return ({ t with naming := t.naming + 1 }, some s!"no naming found: {why}")
      | .ok γ' =>
        let full := (invariantB vs' hs' cfg.env after cfg.aenv st'.facts.escapes γ').orElse fun _ =>
          describesB γ' hs'.heap r w
        match full with
        | some why => return ({ t with naming := t.naming + 1 }, some s!"constructed naming fails: {why}")
        | none => return (t, none)

/-- Run `count` configurations; print each failure with its configuration. -/
def invariantCampaign (count seed : Nat) (limit : Nat := 5) (checker : Ownership.Config := {}) : IO Tally := do
  let mut t : Tally := {}
  let mut shown := 0
  for i in List.range count do
    let s := (seed * 7919 + i * 104729) % 4294967296
    let (t', bad) := tryOne s t checker
    t := t'
    if let some why := bad then
      if shown < limit then
        shown := shown + 1
        let ((cfg, e), _) := (show Generator.Gen (Setup × Expr) from do
            let cfg ← config
            let (e, _) ← expr cfg.types 100 (1 + (← draw 3))
            pure (cfg, e)).run s
        IO.println s!"FALSIFY invariant_preserved configuration {i} (state {s}): {why}\n  heap={repr cfg.heap}\n  env={repr (cfg.env.map fun (x, _, w) => (x, w))}\n  aenv={repr cfg.aenv}\n  kept={repr cfg.kept} escapes={repr cfg.escapes}\n  naming={repr cfg.γ}\n  expr={repr e}"
  IO.println s!"invariant_preserved: {repr t}"
  pure t

/-! ## Calls of generated programs against `summary_sound` -/

structure CallRecord where
  decl : Nat
  args : List Value
  caps : List Value
  pre : InPlaceSemantics.State
  post : InPlaceSemantics.State
  result : Value

abbrev LogM := StateT (Array CallRecord) InPlaceSemantics.M
def liftE (x : Except String α) : LogM α := monadLift x
def liftS (x : InPlaceSemantics.M α) : LogM α := monadLift x

/-- The in-place interpreter, recording every call of a declaration (no
    fuel, no observers: only heaps and results are compared here). -/
partial def evalLog (ds : List Decl) (self : Option (Nat × List Value)) (env : Env Value) (e : Expr) :
    LogM Value := do
  let call := fun (id : Nat) (caps actuals : List Value) => do
    let d ← liftE (ds[id]?.toExcept "missing declaration")
    let pre ← getThe InPlaceSemantics.State
    let r ← evalLog ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
    let post ← getThe InPlaceSemantics.State
    modify fun log => log.push { decl := id, args := actuals, caps, pre, post, result := r }
    pure r
  -- Evaluate with the real interpreter, except that calls are taken here.
  match e with
  | .letE x rhs rest =>
    let a ← evalLog ds self env rhs
    evalLog ds self ((x, a) :: env) rest
  | .app f args =>
    let .closure id caps ← liftE (InPlaceSemantics.atom env f) | throw "call"
    let actuals ← liftE (args.mapM (m := Except String) (InPlaceSemantics.atom env))
    call id caps actuals
  | .recur args =>
    let some (id, caps) := self | throw "recursion outside function"
    let actuals ← liftE (args.mapM (m := Except String) (InPlaceSemantics.atom env))
    call id caps actuals
  | .branch c a b =>
    let .int n ← liftE (InPlaceSemantics.atom env c) | throw "condition"
    evalLog ds self env (if n == 0 then a else b)
  | .traverse kind src init i x acc body =>
    let input ← liftE (InPlaceSemantics.atom env src)
    let n ← match kind, input with
      | .list, .ref c => do pure (← liftS (InPlaceSemantics.array c)).length
      | .range, .int n => pure n.toNat
      | _, _ => throw "traversal"
    let mut a ← liftE (InPlaceSemantics.atom env init)
    for j in List.range n do
      let item ← match input with
        | .ref c => do pure (((← liftS (InPlaceSemantics.array c))[j]?).getD (.int 0))
        | _ => pure (.int j)
      a ← evalLog ds self ((i, .int j) :: (x, item) :: (acc, a) :: env) body
    pure a
  | .focus src idx x body =>
    let .ref c ← liftE (InPlaceSemantics.atom env src) | throw "focus"
    let .int i ← liftE (InPlaceSemantics.atom env idx) | throw "index"
    let xs ← liftS (InPlaceSemantics.array c)
    if i < 0 then return .ref c
    match xs[i.toNat]? with
    | none => pure (.ref c)
    | some item =>
      let w ← evalLog ds self ((x, item) :: env) body
      liftS (do
        InPlaceSemantics.write c ((← InPlaceSemantics.array c).set i.toNat w))
  | _ => liftS (InPlaceSemantics.eval 1000 ds self env e)

/-- The canonical naming of a call: each canonical input origin names the
    arrays at its path of the actual input; `none` if two non-aliasing origins
    would name one array (the statement is vacuous there). -/
def canonicalNaming (heap : Heap) (ins : List Abstract) (inputs : List Value) (nargs : Nat) : FNaming :=
  let pairs := (inputs.zipIdx).flatMap fun (w, i) =>
    let a := ins[i]?.getD .bottom
    (pathsOf heap depthFuel w []).filterMap fun (q, c) =>
      if (a.paths.map Prod.fst).contains q then some (c, inputOrigin nargs i q) else none
  let arrays := (pairs.map Prod.fst).eraseDups
  arrays.map fun c => (c, (pairs.filter (·.1 == c)).map Prod.snd |>.eraseDups)

/-- The abstract value of a concrete closure for `classes`: its captures with
    one origin per array (the `extra` naming), certificates where they hold;
    `roots` chosen to match a recorded `once` answer. -/
def closureAbs (heap : Heap) (v : Value) (once : Bool) : Abstract × FNaming :=
  match v with
  | .closure id caps =>
    let abs := fun (w : Value) => match w with
      | .ref c =>
        let items := ((heap[c]?).getD []).filterMap fun x => match x with | .ref d => some d | _ => none
        let elem := if items.isEmpty then Abstract.scalar
          else .list (items.map fun d => Origin.site [6000 + d] 0) .scalar true
        Abstract.list [.site [6000 + c] 0] elem (nodup (footprint heap depthFuel w))
      | .int _ => .scalar
      | _ => .bottom
    let naming := (caps.flatMap (reachArrays heap depthFuel)).eraseDups.map fun c => (c, [Origin.site [6000 + c] 0])
    (.function (if once then [.site [6999] 0] else []) [(id, caps.map abs)], naming)
  | _ => (.bottom, [])

structure CallTally where
  calls : Nat := 0
  checked : Nat := 0
  vacuous : Nat := 0
  guardsDiffer : Nat := 0
  violations : Nat := 0
  mapChecked : Nat := 0
  deriving Repr

def holders (s : InPlaceSemantics.State) (c : Nat) : List Holder :=
  ((List.range s.heap.size).filter fun d => ((s.heap[d]?).getD []).any fun x => (valueRefs x).contains c).map .array ++
  (if s.kept.toList.any fun x => (valueRefs x).contains c then [.kept] else [])

/-- Check one call against one cache entry: `none` if fine or vacuous. -/
def checkCall (decls : List Decl) (cr : CallRecord) (e : CacheEntry) : Option String × Bool × Bool := Id.run do
  let inputs := cr.args ++ cr.caps
  let nargs := cr.args.length
  let heap := cr.pre.heap
  let γ := canonicalNaming heap e.inputs inputs nargs
  if !separatingB γ then return (none, false, false)
  for (w, i) in inputs.zipIdx do
    if let some _ := describesB γ heap (e.inputs[i]?.getD .bottom) w then return (none, false, false)
  -- unique: the owned origins' arrays are held only by input arrays.
  let inputArrays := inputs.flatMap (reachArrays heap depthFuel)
  for (c, os) in γ do
    if os.any e.owned.contains then
      for h in holders cr.pre c do
        match h with
        | .array d => if !inputArrays.contains d then return (none, false, false)
        | .kept => return (none, false, false)
  -- classes: closures at the symbolic slots resolve the guards as recorded.
  let mut fs : List (Nat × Abstract) := []
  for (a, j) in e.inputs.zipIdx do
    if let .symbolic .. := a then
      let once := e.summary.guards.any fun g => g.query.slot == j && g.query.fact == .once && !g.answer.isEmpty
      fs := fs ++ [(j, (closureAbs heap (inputs[j]?.getD (.int 0)) once).1)]
  for g in e.summary.guards do
    match (answer ({} : Config).inferenceFuel decls {} [{ actuals := fs }] g.query).run {} with
    | .ok (ans, _) => if ans != g.answer then return (none, false, true)
    | .error _ => return (none, false, true)
  -- Clause 1.
  for (w, i) in inputs.zipIdx do
    let a := e.inputs[i]?.getD .bottom
    for (q, c) in pathsOf heap depthFuel w [] do
      if (a.paths.map Prod.fst).contains q then
        if !((cr.post.heap[c]?) == (heap[c]?)) &&
            !rowHas (e.summary.writes ++ e.summary.consumes) (inputOrigin nargs i q) then
          return (some s!"clause 1: input {i} array {c} at {repr q} written, no W row", true, false)
        if !rowHas e.summary.escapes (inputOrigin nargs i q) then
          let after := cr.post.kept.toList.any fun k => (reachArrays cr.post.heap depthFuel k).contains c
          let before := cr.pre.kept.toList.any fun k => (reachArrays heap depthFuel k).contains c
          if after && !before then
            return (some s!"clause 2: input {i} array {c} at {repr q} newly observed, no E row", true, false)
  -- Clause 3.
  for (q, c) in pathsOf cr.post.heap depthFuel cr.result [] do
    if c < heap.size then
      let cells := namesAt e.summary.result q
      let ok := cells.any (fun o => o == .shared || o == .unknown) ||
        inputs.zipIdx.any fun (w, i) =>
          let a := e.inputs[i]?.getD .bottom
          (pathsOf heap depthFuel w []).any fun (p, d) =>
            d == c && (a.paths.map Prod.fst).contains p && cells.any (·.base == inputOrigin nargs i p)
      if !ok then
        return (some s!"clause 3: result array {c} at {repr q} is old and res({repr q}) = {repr cells} names no input path holding it", true, false)
  -- map: the certificate of the result.
  if decls[e.decl]?.map (·.name) == some "map" then
    if let some why := certifiedB cr.post.heap e.summary.result cr.result then
      return (some s!"map certificate: {why}", true, false)
  pure (none, true, false)

/-- Every call of every accepted program of a campaign, against every summary
    of its declaration in the program's cache. -/
def summaryCampaign (count seed : Nat) (limit : Nat := 5) : IO CallTally := do
  let mut state := seed
  let mut t : CallTally := {}
  let mut shown := 0
  for index in List.range count do
    let ((family, p), next) := (Oracle.generateVersion 4).run state
    state := next
    let .ok acc := check p | continue
    let run := ((evalLog p.declarations none [] p.main).run #[]).run { fuel := 100000 }
    let .ok ((_, log), _) := run | continue
    for cr in log do
      t := { t with calls := t.calls + 1 }
      for e in acc.cache.toList do
        if e.decl != cr.decl || e.inputs.length != cr.args.length + cr.caps.length then continue
        let (bad, checked, differ) := checkCall p.declarations cr e
        if differ then t := { t with guardsDiffer := t.guardsDiffer + 1 }
        if checked then
          t := { t with checked := t.checked + 1,
                        mapChecked := t.mapChecked + (if (p.declarations[e.decl]?.map (·.name)) == some "map" then 1 else 0) }
        else if !differ then t := { t with vacuous := t.vacuous + 1 }
        if let some why := bad then
          t := { t with violations := t.violations + 1 }
          if shown < limit then
            shown := shown + 1
            IO.println s!"FALSIFY summary_sound program {index} family={family} decl={(p.declarations[cr.decl]?.map (·.name)).getD "?"}: {why}\n  args={repr cr.args} caps={repr cr.caps} result={repr cr.result}\n  inputs={repr e.inputs}\n  summary={repr e.summary.result} writes={repr e.summary.writes} escapes={repr e.summary.escapes}\n  main={repr p.main}"
  IO.println s!"summary_sound: {repr t}"
  pure t

/-! `Observation.depth` is exactly the fuel `snapshot` needs (what makes the
    value side's observation bound the in-place one): a record of a nested
    list and an int has depth 3; three is enough and two is not. -/
private def depthHeap : Heap := #[[], [.ref 0]]
private def depthValue : Value := .record [.ref 1, .int 3]
#guard match snapshot depthHeap 3 depthValue with
  | .ok o => o.depth == 3 && (snapshot depthHeap 2 depthValue).toOption.isNone
  | .error _ => false

end Ownership.Falsify
