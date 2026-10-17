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

/-- `canon` names the storage an array number uses: a view (`Prim.view`) and
    its source are one array, though two heap entries. -/
def certifiedB (heap : Heap) (a : Abstract) (v : Value) (canon : Nat → Nat := id) : Option String :=
  let bad := a.paths.find? fun (q, _) => match a.atPath q with
    | .list _ _ ex => (valuesAt heap v q).any fun w =>
      let fp := (footprint heap depthFuel w).map canon
      (ex.deep && !nodup fp) || (ex.spine &&
        (pathsOf heap depthFuel w []).any fun (p, c) =>
          match p with
          | .element :: rest => containerPath rest && fp.count (canon c) != 1
          | _ => false)
    | _ => false
  bad.map fun (q, _) => s!"exclusive at {repr q} but the footprint repeats an array"

/-- The array a view chain ends in. -/
def viewRoot (links : List (Nat × Nat × Bool)) : Nat → Nat → Nat
  | 0, c => c
  | n + 1, c => match links.find? (·.1 == c) with
    | some (_, source, _) => viewRoot links n source
    | none => c

/-- Check the advertised result certificates against the actual final heap,
    independently of provenance naming and of observational agreement. -/
def resultCertificates (p : Program) (accepted : Accepted) : Except String Unit := do
  let (v, st) ← (InPlaceSemantics.eval 100000 p.declarations none [] p.main).run {fuel := 100000}
  if let some problem := certifiedB st.heap accepted.result v (viewRoot st.links (st.links.length + 1)) then
    throw problem

/-- The closures at field and element paths (`ClosuresDescribed`'s paths). -/
def closuresAt (heap : Heap) : Nat → Value → Path → List (Path × Value)
  | 0, _, _ => []
  | _ + 1, w@(.closure _ _), pre => [(pre, w)]
  | n + 1, .ref c, pre => ((heap[c]?).getD []).flatMap fun x => closuresAt heap n x (pre ++ [.element])
  | n + 1, .record xs, pre => xs.zipIdx.flatMap fun (x, i) => closuresAt heap n x (pre ++ [.field i])
  | _, .int _, _ => []

def shallowB (γ : FNaming) (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  (coversB γ heap a v).orElse fun _ => certifiedB heap a v

/-- Recursive closure agreement, following the same fields, elements and
    captures as `ClosureAgreement`. Exhausting the bound fails explicitly. -/
def closureAgreementB (γ : FNaming) (heap : Heap) : Nat → Abstract → Value → Bool
  | 0, _, _ => false
  | n + 1, a, w =>
    if isTop a then true else
    match w with
    | .int _ => true
    | .record xs => xs.zipIdx.all fun (x, i) => closureAgreementB γ heap n (a.atPath [.field i]) x
    | .ref c => match heap[c]? with
      | some xs => xs.all fun x => closureAgreementB γ heap n (a.atPath [.element]) x
      | none => false
    | .closure id caps => match a with
      | .symbolic .. => true
      | .function _ alts => alts.any fun (i, cs) =>
          i == id && cs.length == caps.length && (cs.zip caps).all fun (ca, cv) =>
            (shallowB γ heap ca cv).isNone && closureAgreementB γ heap n ca cv
      | _ => false

def closuresB (γ : FNaming) (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  if closureAgreementB γ heap depthFuel a v then none
  else some s!"closure descriptions in {repr v} are not one of {repr a} recursively (or depth bound exhausted)"

def describesB (γ : FNaming) (heap : Heap) (a : Abstract) (v : Value) : Option String :=
  ((shallowB γ heap a v).orElse fun _ => closuresB γ heap a v)

def correspondsB (heap : Heap) (o : Observation) (w : Value) : Bool :=
  match snapshot heap depthFuel w with
  | .ok o' => o' == o
  | .error _ => false

def escapedB (escapes : List Origin) (o : Origin) : Bool :=
  !unescaped o || cellOverlap [o.base] (escapes.map Origin.base)

/-- Every function value, including those nested inside captured values. -/
partial def functionsOf : Abstract → List (List Origin × List (Nat × List Abstract))
  | .function roots alts => [(roots, alts)] ++ alts.flatMap (fun (_, caps) => caps.flatMap functionsOf)
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

/-- `WellTyped` as a test, including actual heap values. Failure to snapshot
    an actual value does not count as a well-typed input. -/
def typedB (ds : List Decl) (heap : Heap) (env : Bindings) (types : Env Ty) (e : Expr) : Bool :=
  (exprType ds (mainDecl e) types e).isOk && env.all fun (x, o, w) =>
    match types.lookup x with
    | some u => obsTyped ds o u && (snapshot heap depthFuel w).toOption.any (fun actual => obsTyped ds actual u)
    | none => true

def projections (o : Observation) (w : Value) (p : Path) : Option (Observation × Value) := do
  pure (← projectObs o p, ← projectVal w p)

/-- `LinksValid` as a test: `none` when every stored link is valid. -/
def linksValidB (hs : InPlaceSemantics.State) : Option String := Id.run do
  for (v, s, front) in hs.links do
    if !(s < v && v < hs.heap.size) then return some s!"link {v} of {s}: not allocated after its source"
    match hs.heap[s]? with
    | none => return some s!"link {v} of {s}: no source array"
    | some source =>
      if source.isEmpty then return some s!"link {v} of {s}: empty source"
      match hs.heap[v]? with
      | none => return some s!"link {v} of {s}: no view array"
      | some view =>
        if !(view == viewOf front source) then return some s!"link {v} of {s}: the view is stale"
  if !nodup (hs.links.map (·.1)) then return some "a view has two sources"
  pure none

/-- The undirected link component of an array, by saturation. -/
def linkComponent (links : List (Nat × Nat × Bool)) (c : Nat) : List Nat := Id.run do
  let mut component := [c]
  for _ in List.range (links.length + 1) do
    for (v, s, _) in links do
      if component.contains v && !component.contains s then component := component ++ [s]
      else if component.contains s && !component.contains v then component := component ++ [v]
  pure component

/-- The arrays a live path or a permanent observer reaches. -/
def protectedArrays (hs : InPlaceSemantics.State) (env : Bindings) (live : Live) : List Nat :=
  live.flatMap (fun (x, p) => match env.lookup x with
    | some (_, w) => match projectVal w p with
      | some w' => reachArrays hs.heap depthFuel w'
      | none => []
    | none => []) ++ hs.kept.toList.flatMap (reachArrays hs.heap depthFuel)

/-- `LinkNamed` as a test: in a link component something protects, every
    array has the same origins. -/
def linkNamedB (hs : InPlaceSemantics.State) (env : Bindings) (live : Live) (γ : FNaming) : Bool :=
  let protectedCells := protectedArrays hs env live
  hs.links.all fun (v, _, _) =>
    let component := linkComponent hs.links v
    !component.any protectedCells.contains ||
      component.all fun d =>
        (originsOf γ v).all (originsOf γ d).contains && (originsOf γ d).all (originsOf γ v).contains

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
  if let some why := linksValidB hs then return some why
  if naming && !linkNamedB hs env live γ then return some "a protected linked array is named apart from its component"
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
    body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) },
  -- 11: a closure over a closure (nested), 12: a factory of such closures,
  -- 13: a conditional that returns a closure or its function argument.
  { name := "capApply", parameters := [.int], captures := [.fn [.int] tL], result := tL,
    body := .app (v 1) [v 0] },
  { name := "mk", parameters := [tL], result := .fn [.int] tL,
    body := .letE 1 (.closure 5 [v 0]) (.closure 11 [v 1]) },
  { name := "choose", parameters := [.int, tL, .fn [.int] tL], result := .fn [.int] tL,
    body := .branch (v 0) (.closure 5 [v 1]) (.atom (v 2)) }]

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
def config (distinct : Bool := false) : Generator.Gen Setup := do
  -- `distinct`: every variable its own arrays and origins, so writes pass
  -- (the write-heavy half of the samples).
  let some4 ← draw 4
  let leaves := if distinct then 12 else 1 + some4
  let mut heap : Array (List Value) := #[]
  for _ in List.range leaves do
    let n ← draw 3
    let mut xs : List Value := []
    for _ in List.range n do xs := xs ++ [.int (Int.ofNat (← draw 5))]
    heap := heap.push xs
  let nested ← if distinct then draw 2 else draw 3
  for _ in List.range nested do
    let n ← draw 3
    let mut xs : List Value := []
    for k in List.range n do
      xs := xs ++ [.ref (← if distinct then pure (10 + k % 2) else draw leaves)]
    heap := heap.push xs
  -- Each array gets one origin; two arrays may share one.
  let mut γ : FNaming := []
  for c in List.range heap.size do
    let shareWith ← draw (4 * heap.size)
    γ := γ ++ [(c, [.site [1000 + (if shareWith < heap.size && !distinct then shareWith else c)] 0])]
  let orig := fun (c : Nat) => originsOf γ c
  let extra : Generator.Gen (List Origin) := do
    if !distinct && (← coin 4) then pure (orig (← draw heap.size)) else pure []
  let leafFor : Nat → Nat → Generator.Gen Nat := fun x k =>
    if distinct then pure ((2 * x + k) % 10) else draw leaves
  let leafAbs : Nat → Generator.Gen Abstract := fun c => do
    pure (Abstract.list (orig c ++ (← extra)) .scalar (distinct || (← coin 2)))
  let nestedAbs : Nat → Generator.Gen Abstract := fun c => do
    let items := (heap[c]?.getD []).filterMap fun x => match x with | .ref d => some d | _ => none
    let innerEx ← if distinct then pure true else coin 2
    let elem := if items.isEmpty then Abstract.bottom
      else .list (items.flatMap orig |>.eraseDups) .scalar innerEx
    let nd := nodup (footprint heap depthFuel (.ref c))
    pure (Abstract.list (orig c ++ (← extra)) elem (nd && (distinct || (← coin 2))))
  let vars := 1 + (← draw 5)
  let mut env : Bindings := []
  let mut aenv : Env Abstract := []
  let mut types : List (Var × Ty) := []
  let mut kept : List Value := []
  for x in List.range vars do
    let kind ← draw 7
    let (w, a, t) ← (show Generator.Gen (Value × Abstract × Ty) from match kind with
      | 0 => do pure (Value.int (Int.ofNat (← draw 3)), Abstract.scalar, Ty.int)
      | 1 => do let c ← leafFor x 0; pure (.ref c, ← leafAbs c, tL)
      | 2 => if nested == 0 then do let c ← leafFor x 0; pure (.ref c, ← leafAbs c, tL)
          else do let c := leaves + (← draw nested); pure (.ref c, ← nestedAbs c, tN)
      | 3 => do
          let c ← leafFor x 0
          let d ← leafFor x 1
          pure (.record [.ref c, .ref d], .record [← leafAbs c, ← leafAbs d], tR)
      | 4 => do
          -- A closure over a closure over a list (`capApply` over `capGet`
          -- or `capPush`), described through both levels.
          let c ← leafFor x 0
          let inner ← pick [3, 5] 5
          -- Deliberately mislabel some inner closures too: matching the
          -- outer code and the inner footprint alone is insufficient.
          let swap ← coin 5
          let absInner := if swap then 8 - inner else inner
          let roots := if absInner == 3 then [Origin.site [2000 + x] 0] else []
          let innerAbs := Abstract.function roots [(absInner, [← leafAbs c])]
          pure (.closure 11 [.closure inner [.ref c]], .function roots [(11, [innerAbs])], fIL)
      | _ => do
          let c ← leafFor x 0
          let id ← pick [3, 4, 5, 10] 4
          let once ← coin 2
          -- A fifth of `capPush`/`capGet` closures are described as the
          -- other (same type): `ClosuresDescribed` must exclude them (P7).
          let swap ← coin 5
          let absId := if swap && (id == 3 || id == 5) then 8 - id else id
          let roots := if absId == 3 || absId == 10 || once then [Origin.site [2000 + x] 0] else []
          let t := if id == 4 then fII else if id == 10 then fLL else fIL
          pure (.closure id [.ref c], .function roots [(absId, [← leafAbs c])], t))
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
    match ← draw 22 with
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
    | 19 =>
      -- A factory returns a closure over a closure over the list.
      if !hasL then pure (.atom num, .int) else
      pure (.letE next (.closure 12 []) (.letE (next + 1) (.app (v next) [l])
        (.app (v (next + 1)) [num])), tL)
    | 20 =>
      -- A conditional returns a closure over the list or a function argument.
      match (atomsOf types fIL).head? with
      | some f =>
        if !hasL then pure (.atom num, .int) else
        pure (.letE next (.closure 13 []) (.app (v next) [num, l, f]), fIL)
      | none => pure (.atom num, .int)
    | 18 =>
      let (a, t) ← expr types (next + 10) depth
      let (b, u) ← expr ((next, t) :: types) (next + 20) depth
      pure (.letE next a b, u)
    | _ =>
      let (a, t) ← expr types (next + 10) depth
      let (b, u) ← expr types (next + 20) depth
      if t == u then pure (.branch num a b, t) else pure (a, t)

/-- A write to one variable (the target returned), for the write-heavy half
    of the samples: push, set, a push through a record field, a consuming
    focus, a consuming traversal, `update` and `map` with a writing callback. -/
def writeExpr (types : List (Var × Ty)) (next : Nat) : Generator.Gen (Expr × Option Var) := do
  let ls := (types.filter (·.2 == tL)).map Prod.fst
  let ns := (types.filter (·.2 == tN)).map Prod.fst
  let rs := (types.filter (·.2 == tR)).map Prod.fst
  let num := Atom.int (Int.ofNat (← draw 3))
  let idx := Atom.int (Int.ofNat (← draw 2))
  let l ← pick ls 0
  let n ← pick ns 0
  let r ← pick rs 0
  let none' : Expr × Option Var := (.atom (.int 0), none)
  -- Only the writes whose operand type the configuration has.
  let kinds := (if ls.isEmpty then [] else [0, 1]) ++ (if rs.isEmpty then [] else [2]) ++
    (if ns.isEmpty then [] else [3, 4, 5, 6])
  match ← pick kinds 7 with
  | 0 => pure (if ls.isEmpty then none' else (.prim .push [v l, num], some l))
  | 1 => pure (if ls.isEmpty then none' else (.prim .set [v l, idx, num], some l))
  | 2 => do let f ← draw 2; pure (if rs.isEmpty then none' else (.prim .push [.field (v r) f, num], some r))
  | 3 => pure (if ns.isEmpty then none' else (.focus (v n) idx next (.prim .push [v next, num]), some n))
  | 4 => pure (if ns.isEmpty then none' else
      (.traverse .list (v n) (.int 0) next (next + 1) (next + 2)
        (.letE (next + 3) (.prim .push [v (next + 1), num]) (.prim .length [v (next + 3)])), some n))
  | 5 => pure (if ns.isEmpty then none' else
      (.letE next (.closure 6 []) (.letE (next + 1) (.closure 2 []) (.app (v next) [v n, idx, v (next + 1)])), some n))
  | _ => pure (if ns.isEmpty then none' else
      (.letE next (.closure 0 []) (.letE (next + 1) (.closure 2 []) (.app (v next) [v n, v (next + 1)])), some n))

/-- One sample: a configuration, an expression and the continuation's uses.
    Two thirds are write-heavy (each variable its own arrays, one write to a
    variable the continuation does not use); a sixth of all drop one
    variable from the abstract environment (`covered` false). -/
def sample : Generator.Gen (Setup × Expr × Live × Bool) := do
  let writes := (← draw 3) != 0
  let cfg ← config writes
  let (e, target) ← if writes then writeExpr cfg.types 100
    else do let (e, _) ← expr cfg.types 100 (1 + (← draw 3)); pure (e, none)
  let mut after : Live := []
  for (x, ty) in cfg.types do
    if some x == target then continue
    let c1 ← coin 2
    let c2 ← coin 3
    let f ← draw 2
    if c1 then after := after ++ [(x, [])]
    else if ty == tR && c2 then after := after ++ [(x, [.field f])]
  -- A third of the write-heavy samples alias the written variable: another
  -- variable bound to the same value, with the same description, live
  -- afterwards half the time (the checker must then refuse the write).
  let alias ← coin 3
  let liveAlias ← coin 2
  let (cfg, after2, aliased) := match target with
    | some x =>
      if writes && alias then
        match cfg.env.lookup x, cfg.aenv.lookup x, cfg.types.lookup x with
        | some (o, w), some a, some ty =>
          let y := cfg.env.length + 50
          ({ cfg with env := cfg.env ++ [(y, o, w)], aenv := cfg.aenv ++ [(y, a)], types := cfg.types ++ [(y, ty)] },
           if liveAlias then after ++ [(y, [])] else after, true)
        | _, _, _ => (cfg, after, false)
      else (cfg, after, false)
    | none => (cfg, after, false)
  let drop ← coin 6
  let which ← draw cfg.aenv.length
  let cfg := if drop && !cfg.aenv.isEmpty then { cfg with aenv := cfg.aenv.eraseIdx which } else cfg
  pure (cfg, e, after2, aliased)

def program : Program := { declarations := decls, main := .atom (.int 0) }

structure Tally where
  tried : Nat := 0
  hypothesisFalse : Nat := 0
  uncovered : Nat := 0
  uncoveredAccepted : Nat := 0
  closureMislabeled : Nat := 0
  lowFuel : Nat := 0
  lowFuelBothFail : Nat := 0
  aliased : Nat := 0
  aliasedAccepted : Nat := 0
  nested : Nat := 0
  nestedAccepted : Nat := 0
  accepted : Nat := 0
  valueOk : Nat := 0
  withWrite : Nat := 0
  observational : Nat := 0
  naming : Nat := 0
  errorClause : Nat := 0
  deriving Repr

/-- The expression creates a closure of one of the declarations `ids`. -/
def mentionsDecl (ids : List Nat) : Expr → Bool
  | .closure d _ => ids.contains d
  | .resultCase _ _ _ a b | .chainCase _ _ _ a b | .entry a _ _ b
  | .letE _ a b | .branch _ a b => mentionsDecl ids a || mentionsDecl ids b
  | .traverse _ _ _ _ _ _ body | .focus _ _ _ body => mentionsDecl ids body
  | _ => false

def writeOps : Expr → Bool
  | .prim .push _ | .prim .set _ | .focus .. => true
  | .resultCase _ _ _ a b | .chainCase _ _ _ a b | .entry a _ _ b
  | .letE _ a b | .branch _ a b => writeOps a || writeOps b
  | .traverse _ _ _ _ _ _ body => writeOps body
  | .app .. => true
  | _ => false

/-- One configuration: `none` if fine or vacuous, otherwise what failed. -/
def tryOne (seed : Nat) (t : Tally) (checker : Ownership.Config := {}) : Tally × Option String := Id.run do
  let ((cfg, e, after, aliased), _) := sample.run seed
  -- A quarter of the samples run with fuel 1–8: the error clause (both runs
  -- fail, or neither) is exercised, not only the success clause.
  let fuel := if seed % 4 == 0 then 1 + (seed / 4) % 8 else 5000
  let nested := mentionsDecl [11, 12, 13] e || cfg.env.any fun (_, _, w) => match w with
    | .closure 11 _ => true
    | _ => false
  let mut t := { t with tried := t.tried + 1, lowFuel := t.lowFuel + (if fuel < 5000 then 1 else 0), aliased := t.aliased + (if aliased then 1 else 0), nested := t.nested + (if nested then 1 else 0) }
  let vs : ValueSemantics.State := { fuel, kept := cfg.keptObs.toArray }
  let hs : InPlaceSemantics.State := { fuel, heap := cfg.heap, kept := cfg.kept.toArray }
  -- `covered` false: the statement does not speak about the sample; the
  -- checker must still refuse it (a live use it cannot resolve).
  let covered := (union (uses e) after).all fun (x, _) =>
    (cfg.env.lookup x).isNone || (cfg.aenv.lookup x).isSome
  if !covered then
    let ctx0 : Context := { declarations := decls, config := checker }
    match (inferExpr ctx0.config.inferenceFuel ctx0 cfg.aenv e after [7]).run { facts := { escapes := cfg.escapes } } with
    | .error _ => return ({ t with uncovered := t.uncovered + 1 }, none)
    | .ok _ => return ({ t with uncovered := t.uncovered + 1, uncoveredAccepted := t.uncoveredAccepted + 1 },
        some "the checker accepted an expression whose live uses it cannot resolve")
  if let some why := invariantB vs hs cfg.env (union (uses e) after) cfg.aenv cfg.escapes cfg.γ then
    -- A closure described as another declaration is meant to fail here.
    if (why.splitOn "not one of").length > 1 then
      return ({ t with closureMislabeled := t.closureMislabeled + 1 }, none)
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some s!"hypothesis does not hold by construction: {why}")
  let typed := typedB decls cfg.heap cfg.env cfg.types e
  if !typed then
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some s!"hypothesis does not hold by construction: ill-typed ({repr (exprType decls (mainDecl e) cfg.types e)})")
  if !cfg.aenv.all (fun (_, a) => honestB decls a) then
    return ({ t with hypothesisFalse := t.hypothesisFalse + 1 }, some "hypothesis does not hold by construction: a closure is described as not once")
  let ctx : Context := { declarations := decls, config := checker }
  let st : St := { facts := { escapes := cfg.escapes } }
  match (inferExpr ctx.config.inferenceFuel ctx cfg.aenv e after [7]).run st with
  | .error _ => return (t, none)
  | .ok (r, st') =>
    t := { t with accepted := t.accepted + 1, aliasedAccepted := t.aliasedAccepted + (if aliased then 1 else 0), nestedAccepted := t.nestedAccepted + (if nested then 1 else 0) }
    let ve := (ValueSemantics.eval fuel decls none (valueEnv cfg.env) e).run vs
    let he := (InPlaceSemantics.eval fuel decls none (heapEnv cfg.env) e).run hs
    match ve, he with
    | .error _, .error _ => return ({ t with lowFuelBothFail := t.lowFuelBothFail + (if fuel < 5000 then 1 else 0) }, none)
    | .error m, .ok _ => return ({ t with errorClause := t.errorClause + 1 }, some s!"value run fails ({m}), in-place run succeeds")
    | .ok _, .error m => return ({ t with observational := t.observational + 1 }, some s!"in-place run fails: {m}")
    | .ok (o, vs'), .ok (w, hs') =>
      t := { t with valueOk := t.valueOk + 1, withWrite := t.withWrite + (if hs'.writes > 0 then 1 else 0) }
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
        let ((cfg, e, after, _), _) := sample.run s
        IO.println s!"FALSIFY invariant_preserved configuration {i} (state {s}): {why}\n  heap={repr cfg.heap}\n  env={repr (cfg.env.map fun (x, _, w) => (x, w))}\n  aenv={repr cfg.aenv}\n  kept={repr cfg.kept} escapes={repr cfg.escapes}\n  naming={repr cfg.γ}\n  expr={repr e}"
  IO.println s!"invariant_preserved: {repr t}"
  pure t

/-! ## Calls of generated programs against `summary_sound` -/

/-- The calls the real in-place interpreter made, recorded by its call log. -/
def loggedCalls (p : Program) (fuel := 100000) : Except String (Array CallRecord) := do
  let (_, s) ← (eval fuel p.declarations none [] p.main).run { fuel, logCalls := true }
  pure s.calls

def preOf (cr : CallRecord) : InPlaceSemantics.State :=
  { fuel := 0, heap := cr.preHeap, kept := cr.preKept, links := cr.preLinks }
def postOf (cr : CallRecord) : InPlaceSemantics.State := { fuel := 0, heap := cr.postHeap, kept := cr.postKept }

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
  resultsChecked : Nat := 0
  resultViolations : Nat := 0
  splitsTried : Nat := 0
  splitsExcluded : Nat := 0
  splitViolations : Nat := 0
  calls : Nat := 0
  checked : Nat := 0
  vacuous : Nat := 0
  guardsDiffer : Nat := 0
  violations : Nat := 0
  mapChecked : Nat := 0
  vacuousSeparating : Nat := 0
  vacuousDescribed : Nat := 0
  vacuousUnique : Nat := 0
  vacuousLinked : Nat := 0
  vacuousOther : Nat := 0
  deriving Repr

def holders (s : InPlaceSemantics.State) (c : Nat) : List Holder :=
  ((List.range s.heap.size).filter fun d => ((s.heap[d]?).getD []).any fun x => (valueRefs x).contains c).map .array ++
  (if s.kept.toList.any fun x => (valueRefs x).contains c then [.kept] else [])

/-- `WritePermitted` as a test. -/
def writePermittedB (s : Summary) (nargs i : Nat) (q : Path) : Bool :=
  rowHas (s.writes ++ s.consumes) (inputOrigin nargs i q) || (q == [.env] && (s.calls.lookup i).getD 0 ≥ 1)

/-- `LinkedWritesCovered` as a test: every input array a link connects to an
    input array at a permitted path is at a permitted path. -/
def linkedWritesCoveredB (s : Summary) (ins : List Abstract) (inputs : List Value) (nargs : Nat)
    (links : List (Nat × Nat × Bool)) (heap : Heap) : Bool :=
  let canonicalArrays := inputs.zipIdx.flatMap fun (w, i) =>
    let a := ins[i]?.getD .bottom
    (pathsOf heap depthFuel w []).filterMap fun (q, c) =>
      if (a.paths.map Prod.fst).contains q then some (i, q, c) else none
  canonicalArrays.all fun (i, q, c) =>
    !writePermittedB s nargs i q ||
      (linkComponent links c).all fun d =>
        canonicalArrays.all fun (j, p, d') => d' != d || writePermittedB s nargs j p

/-- Check one call against one cache entry: `none` if fine or vacuous. -/
def checkCall (decls : List Decl) (cr : CallRecord) (e : CacheEntry) (enforceArity := true) : Option String × Bool × Bool × String := Id.run do
  let some d := decls[e.decl]? | return (none, false, false, "declaration")
  if enforceArity && (cr.args.length != d.parameters.length || cr.caps.length != d.captures.length ||
      e.inputs.length != cr.args.length + cr.caps.length) then
    return (none, false, false, "arity")
  let inputs := cr.args ++ cr.caps
  let nargs := cr.args.length
  let heap := cr.preHeap
  -- The description's naming is independent of the concrete args/caps split.
  -- Using `nargs` here hid the wrongly-split calls of the old statement.
  let γ := canonicalNaming heap e.inputs inputs d.parameters.length
  if !separatingB γ then return (none, false, false, "separating")
  for (w, i) in inputs.zipIdx do
    if let some _ := describesB γ heap (e.inputs[i]?.getD .bottom) w then return (none, false, false, "described")
  -- The written-storage premise (#169, R1).
  if !linkedWritesCoveredB e.summary e.inputs inputs nargs cr.preLinks heap then
    return (none, false, false, "linked")
  -- classes: closures at the symbolic slots resolve the guards as recorded.
  let mut fs : List (Nat × Abstract) := []
  for (a, j) in e.inputs.zipIdx do
    if let .symbolic .. := a then
      let once := e.summary.guards.any fun g => g.query.slot == j && g.query.fact == .once && !g.answer.isEmpty
      fs := fs ++ [(j, (closureAbs heap (inputs[j]?.getD (.int 0)) once).1)]
  for g in e.summary.guards do
    match (answer ({} : Config).inferenceFuel decls {} [{ actuals := fs }] g.query).run {} with
    | .ok (ans, _) => if ans != g.answer then return (none, false, true, "guards")
    | .error _ => return (none, false, true, "guards")
  -- Clause 1.
  for (w, i) in inputs.zipIdx do
    let a := e.inputs[i]?.getD .bottom
    for (q, c) in pathsOf heap depthFuel w [] do
      if (a.paths.map Prod.fst).contains q then
        if !((cr.postHeap[c]?) == (heap[c]?)) &&
            !rowHas (e.summary.writes ++ e.summary.consumes) (inputOrigin nargs i q) &&
            !(q == [.env] && (e.summary.calls.lookup i).getD 0 ≥ 1) then
          return (some s!"clause 1: input {i} array {c} at {repr q} written, no W row", true, false, "")
        if !rowHas e.summary.escapes (inputOrigin nargs i q) then
          let after := cr.postKept.toList.any fun k => (reachArrays cr.postHeap depthFuel k).contains c
          let before := cr.preKept.toList.any fun k => (reachArrays heap depthFuel k).contains c
          if after && !before then
            return (some s!"clause 2: input {i} array {c} at {repr q} newly observed, no E row", true, false, "")
  -- Clause 3.
  for (q, c) in pathsOf cr.postHeap depthFuel cr.result [] do
    if c < heap.size then
      let cells := namesAt e.summary.result q
      let ok := cells.any (fun o => o == .shared || o == .unknown) ||
        inputs.zipIdx.any fun (w, i) =>
          let a := e.inputs[i]?.getD .bottom
          (pathsOf heap depthFuel w []).any fun (p, d) =>
            d == c && (a.paths.map Prod.fst).contains p && cells.any (·.base == inputOrigin nargs i p)
      if !ok then
        return (some s!"clause 3: result array {c} at {repr q} is old and res({repr q}) = {repr cells} names no input path holding it", true, false, "")
  -- map: the certificate of the result.
  if decls[e.decl]?.map (·.name) == some "map" then
    if let some why := certifiedB cr.postHeap e.summary.result cr.result then
      return (some s!"map certificate: {why}", true, false, "")
  pure (none, true, false, "")

/-- Every call of every accepted program of a campaign, against every summary
    of its declaration in the program's cache. -/
def summaryCampaign (count seed : Nat) (limit : Nat := 5) (checker : Ownership.Config := {}) : IO CallTally := do
  let mut state := seed
  let mut t : CallTally := {}
  let mut shown := 0
  let mut shownVacuous := 0
  for index in List.range count do
    let ((family, p), next) := (Oracle.generateVersion 5).run state
    state := next
    let .ok acc := check p checker | continue
    t := { t with resultsChecked := t.resultsChecked + 1 }
    if let .error problem := resultCertificates p acc then
      t := { t with resultViolations := t.resultViolations + 1 }
      IO.FS.createDirAll "regressions"
      IO.FS.writeFile s!"regressions/falsify-result-{seed}-{index}.txt" s!"{problem}\n{repr p}\n"
      if shown < limit then
        shown := shown + 1
        IO.println s!"FALSE result certificate program {index} family={family}: {problem}"
    let run := loggedCalls p
    let .ok log := run | continue
    for cr in log do
      t := { t with calls := t.calls + 1 }
      -- A call is checked if at least one summary of its declaration meets
      -- the hypotheses; otherwise it is vacuous, filed under the reason the
      -- first candidate summary gave (the others' inputs or guards differ).
      let mut anyChecked := false
      let mut reason := "no summary"
      for e in acc.cache.toList do
        if e.decl != cr.decl || e.inputs.length != cr.args.length + cr.caps.length then continue
        let inputs := cr.args ++ cr.caps
        for split in List.range (inputs.length + 1) do
          if split == cr.args.length then continue
          t := { t with splitsTried := t.splitsTried + 1 }
          let alternate := { cr with args := inputs.take split, caps := inputs.drop split }
          let (badSplit, splitChecked, _, splitReason) := checkCall p.declarations alternate e
          if splitReason == "arity" then
            t := { t with splitsExcluded := t.splitsExcluded + 1 }
          else if splitChecked || badSplit.isSome then
            t := { t with splitViolations := t.splitViolations + 1 }
        let (bad, checked, differ, why) := checkCall p.declarations cr e
        if differ then t := { t with guardsDiffer := t.guardsDiffer + 1 }
        if checked then
          anyChecked := true
          t := { t with checked := t.checked + 1,
                        mapChecked := t.mapChecked + (if (p.declarations[e.decl]?.map (·.name)) == some "map" then 1 else 0) }
        else if reason == "no summary" || reason == "guards" then reason := why
        if let some why := bad then
          t := { t with violations := t.violations + 1 }
          if shown < limit then
            shown := shown + 1
            IO.println s!"FALSIFY summary_sound program {index} family={family} decl={(p.declarations[cr.decl]?.map (·.name)).getD "?"}: {why}\n  args={repr cr.args} caps={repr cr.caps} result={repr cr.result}\n  inputs={repr e.inputs}\n  summary={repr e.summary.result} writes={repr e.summary.writes} escapes={repr e.summary.escapes}\n  main={repr p.main}"
      if !anyChecked then
        t := { t with vacuous := t.vacuous + 1 }
        t := match reason with
          | "separating" => { t with vacuousSeparating := t.vacuousSeparating + 1 }
          | "described" => { t with vacuousDescribed := t.vacuousDescribed + 1 }
          | "unique" => { t with vacuousUnique := t.vacuousUnique + 1 }
          | "linked" => { t with vacuousLinked := t.vacuousLinked + 1 }
          | _ => { t with vacuousOther := t.vacuousOther + 1 }
        if reason == "described" && shownVacuous < limit then
          shownVacuous := shownVacuous + 1
          IO.println s!"VACUOUS summary_sound program {index} decl={(p.declarations[cr.decl]?.map (·.name)).getD "?"}: no summary describes args={repr cr.args} caps={repr cr.caps}"
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

namespace Ownership.Falsify.NestedCaptureRegression

/-- Both callbacks capture the same array, but only declaration 3 writes.
    The outer declaration is accurate; its captured callback is mislabeled.
    The old shallow description admitted this configuration and the main
    expression, whose two resulting observations differ. -/
def cell : Abstract := .list [.site [99] 0] .scalar true
def inner : Abstract := .function [] [(5, [cell])]
def outer : Abstract := .function [] [(11, [inner])]
def heap : Array (List InPlaceSemantics.Value) := #[[.int 1]]
def concrete : InPlaceSemantics.Value := .closure 11 [.closure 3 [.ref 0]]
def observed : Observation := .closure 11 [.closure 3 [.list [.int 1]]]
def bindings : Bindings := [(0, observed, concrete), (1, .list [.int 1], .ref 0)]
def abstractEnv : Env Abstract := [(0, outer), (1, cell)]
def naming : FNaming := [(0, [.site [99] 0])]
def expression : Expr := .letE 2 (.app (.var 0) [.int 9]) (.prim .record [.var 1, .var 2])

#guard honestB decls outer
#guard (exprType decls (Soundness.mainDecl expression) [(0, fIL), (1, Generator.tL)] expression).isOk
#guard ((inferExpr 200 { declarations := decls, config := {} } abstractEnv expression [] []).run {}).isOk
#guard (invariantB { fuel := 100 } { fuel := 100, heap } bindings (uses expression) abstractEnv [] naming).isSome
#guard (describesB naming heap outer concrete).isSome
#guard match (ValueSemantics.eval 100 decls none (Soundness.valueEnv bindings) expression).run { fuel := 100 },
             (InPlaceSemantics.eval 100 decls none (Soundness.heapEnv bindings) expression).run { fuel := 100, heap } with
  | .ok (o, _), .ok (w, st) => (InPlaceSemantics.snapshot st.heap 100 w).toOption != some o
  | _, _ => false

end Ownership.Falsify.NestedCaptureRegression

namespace Ownership.Falsify.DeadSourceRegression

/-- A dead source's observation is a list, but its actual value is an int.
    The old invariant and value-only typing admitted it. `close` succeeds
    in the value interpreter and fails on the heap side. -/
def bindings : Bindings := [(0, .list [], .ref 0), (1, .list [], .int 0)]
def abstractEnv : Env Abstract := [(0, .list [.site [0] 0] .bottom true), (1, .list [.site [1] 0] .bottom false)]
def naming : FNaming := [(0, [.site [0] 0])]
def heap : Array (List InPlaceSemantics.Value) := #[[]]
def expression : Expr := .prim .close [.var 0, .var 1]
def types : Env Ty := [(0, .builder .int), (1, .list .int)]

#guard (invariantB { fuel := 100 } { fuel := 100, heap } bindings (uses expression) abstractEnv [] naming).isNone
#guard abstractEnv.all fun (_, a) => honestB [] a
#guard (exprType [] (Soundness.mainDecl expression) types expression).isOk
#guard ((inferExpr 200 { declarations := [], config := {} } abstractEnv expression [] []).run {}).isOk
#guard !typedB [] heap bindings types expression
#guard ((ValueSemantics.eval 100 [] none (Soundness.valueEnv bindings) expression).run { fuel := 100 }).isOk
#guard !((InPlaceSemantics.eval 100 [] none (Soundness.heapEnv bindings) expression).run { fuel := 100, heap }).isOk

end Ownership.Falsify.DeadSourceRegression

namespace Ownership.Falsify.NestedClassRegression

/-- The inner code is correct but its once marker is missing. An outer
    once marker formerly hid this from `HonestClosures`; the captured write
    could then evade the caller's demand. Honesty now descends into captures. -/
def cell : Abstract := .list [.site [99] 0] .scalar true
def inner : Abstract := .function [] [(3, [cell])]
def outer : Abstract := .function [.site [100] 0] [(11, [inner])]
def heap : Array (List InPlaceSemantics.Value) := #[[.int 1]]
def concrete : InPlaceSemantics.Value := .closure 11 [.closure 3 [.ref 0]]
def observed : Observation := .closure 11 [.closure 3 [.list [.int 1]]]
def bindings : Bindings := [(0, observed, concrete), (1, .list [.int 1], .ref 0)]
def abstractEnv : Env Abstract := [(0, outer), (1, cell)]
def naming : FNaming := [(0, [.site [99] 0])]
def expression : Expr := .letE 2 (.app (.var 0) [.int 9]) (.prim .record [.var 1, .var 2])

#guard (describesB naming heap outer concrete).isNone
#guard typedB decls heap bindings [(0, fIL), (1, Generator.tL)] expression
#guard !honestB decls outer

end Ownership.Falsify.NestedClassRegression

namespace Ownership.Falsify.CallSplitRegression

def decl : Decl := {
  name := "bump", parameters := [Generator.tL], result := Generator.tL,
  body := .prim .push [.var 0, .int 7] }
def program : Program := {
  declarations := [decl],
  main := .letE 0 (.prim (.literal .int) [.int 1]) (.letE 1 (.closure 0 []) (.app (.var 1) [.var 0])) }
def entry := (check program).toOption.bind (fun a => a.cache.toList.head?)
def wronglySplit : Option InPlaceSemantics.CallRecord := do
  let (r, post) ← (Soundness.callResult [decl] 0 [] [.ref 0] 100 { fuel := 100, heap := #[[.int 1]] }).toOption
  return ({
    decl := 0, args := [], caps := [.ref 0], preHeap := #[[.int 1]], preKept := #[],
    postHeap := post.heap, postKept := post.kept, result := r } : InPlaceSemantics.CallRecord)
#guard (check program).isOk
#guard match entry, wronglySplit with
  | some e, some cr => let (bad, checked, _, _) := checkCall [decl] cr e false
                      checked && bad.isSome
  | _, _ => false
#guard match entry, wronglySplit with
  | some e, some cr => (checkCall [decl] cr e).2.2.2 == "arity"
  | _, _ => false

end Ownership.Falsify.CallSplitRegression
