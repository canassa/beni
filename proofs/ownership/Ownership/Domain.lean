import Ownership.Syntax

namespace Ownership

inductive Step where
  | field (i : Nat)
  | element
  | capture (i : Nat)
  /-- Every cell a function value's environment holds, merged. Only the path
      `[env]` of a function-typed input of a summarised declaration uses it. -/
  | env
  deriving Repr, BEq, Inhabited
abbrev Path := List Step

inductive Origin where
  | parameter (i : Nat) (path : Path)
  | capture (i : Nat) (path : Path)
  | site (instruction : List Nat) (slot : Nat)
  | fresh (slot : Nat)
  | position (scope : List Nat) (current : Bool) (origin : Origin)
  | shared
  | unknown
  deriving Repr, BEq, Inhabited

def union [BEq α] (a b : List α) : List α :=
  b.foldl (fun xs x => if xs.contains x then xs else xs ++ [x]) a

def overlap [BEq α] (a b : List α) : Bool := a.any b.contains

def Origin.base : Origin → Origin
  | .position _ _ c => c.base
  | c => c

def aliases (a b : Origin) : Bool :=
  match a, b with
  | .position s i x, .position t j y =>
    if s == t && i != j then false else x.base == y.base
  | a, b => a.base == b.base

def cellOverlap (a b : List Origin) : Bool := a.any fun x => b.any (aliases x)

/-- Deep ownership and separation of the element containers are independent.
    A tap's captured data may be shared while the list containing taps is unique. -/
structure Certificate where
  deep : Bool
  spine : Bool
  deriving Repr, BEq, Inhabited

instance : Coe Bool Certificate := ⟨fun b => ⟨b, b⟩⟩
instance : Coe Certificate Bool := ⟨Certificate.deep⟩

def Certificate.meet (a b : Certificate) : Certificate :=
  ⟨a.deep && b.deep, a.spine && b.spine⟩

/-- Positions are deliberately merged. `exclusive` carries information that
    provenance sets cannot carry, including separation inside one position.
    `symbolic` is a function-typed input of the declaration being summarised:
    its code is unknown there, and its class is asked through atoms that the
    call site answers (thesis §3.7, §4.7). `roots` is non-empty when the actual
    value may be once; `env` stands for every cell its environment holds. -/
inductive Abstract where
  | bottom
  | scalar
  | record (fields : List Abstract)
  | list (roots : List Origin) (element : Abstract) (exclusive : Certificate)
  | function (roots : List Origin) (alternatives : List (Nat × List Abstract))
  | symbolic (slot : Nat) (type : Ty) (roots env : List Origin)
  deriving Repr, Inhabited

private theorem sndSize [SizeOf α] [SizeOf β] (p : α × β) :
    sizeOf p.2 < sizeOf p := by
  cases p
  simp +arith

/-- Total comparison for the fixpoint domain, including captured alternatives. -/
def Abstract.equal (a b : Abstract) : Bool :=
  match a, b with
  | .bottom, .bottom | .scalar, .scalar => true
  | .record xs, .record ys =>
    xs.length == ys.length && (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | .list cs x ex, .list ds y ey => cs == ds && ex == ey && x.equal y
  | .function cs xs, .function ds ys => cs == ds && xs.length == ys.length &&
    (xs.attach.zip ys).all fun (alt, other) =>
      alt.val.1 == other.1 && alt.val.2.length == other.2.length &&
      (alt.val.2.attach.zip other.2).all (fun (x, y) => x.val.equal y)
  | .symbolic i t cs es, .symbolic j u ds fs => i == j && t == u && cs == ds && es == fs
  | _, _ => false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

instance : BEq Abstract := ⟨Abstract.equal⟩

def Abstract.paths : Abstract → List (Path × List Origin)
  | .bottom | .scalar => []
  | .record xs => xs.attach.zipIdx.flatMap fun (x, i) =>
    x.val.paths.map fun (p, cs) => (.field i :: p, cs)
  | .list cs x _ => ([], cs) :: x.paths.map (fun (p, cs) => (.element :: p, cs))
  | .function cs alts => ([], cs) :: alts.attach.flatMap fun alt =>
    alt.val.2.attach.zipIdx.flatMap fun (x, i) => x.val.paths.map fun (p, cs) => (.capture i :: p, cs)
  | .symbolic _ _ cs es => [([], cs), ([.env], es)]
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

def Abstract.cells (a : Abstract) : List Origin :=
  a.paths.foldl (fun cs (_, xs) => union cs xs) []

def Abstract.atPath (a : Abstract) (p : Path) : Abstract :=
  match p, a with
  | [], _ => a
  | .field i :: rest, .record xs => (xs[i]?.getD .bottom).atPath rest
  | .element :: rest, .list _ x _ => x.atPath rest
  | .capture i :: rest, .function _ alts =>
    -- Used only for origin substitution; collect cells across alternatives.
    .list (alts.flatMap fun (_, xs) => ((xs[i]?.getD .bottom).atPath rest).cells) .bottom false
  | .env :: _, .symbolic _ _ _ es => .list es .bottom false
  | _, _ => .bottom

def Abstract.roots : Abstract → List Origin
  | .list cs _ _ | .function cs _ | .symbolic _ _ cs _ => cs
  | _ => []

def Abstract.cellsAt (a : Abstract) (p : Path) : List Origin :=
  a.paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) []

/-- Every cell a function value's environment may hold. -/
def Abstract.envCells : Abstract → List Origin
  | .function _ alts => alts.foldl (fun cs (_, xs) => xs.foldl (fun ds x => union ds x.cells) cs) []
  | .symbolic _ _ _ es => es
  | _ => []

def Abstract.mapOrigins (f : Path → List Origin → List Origin) (a : Abstract)
    (path : Path := []) : Abstract :=
  match a with
  | .bottom => .bottom
  | .scalar => .scalar
  | .record xs => .record (xs.attach.zipIdx.map fun (x, i) => x.val.mapOrigins f (path ++ [.field i]))
  | .list cs x ex => .list (f path cs) (x.mapOrigins f (path ++ [.element])) ex
  | .function cs alts => .function (f path cs) ((alts.attach.map fun alt =>
    (alt.val.1, alt.val.2.attach.zipIdx.map fun (x, i) => x.val.mapOrigins f (path ++ [.capture i]))).eraseDups)
  | .symbolic j t cs es => .symbolic j t (f path cs) (f (path ++ [.env]) es)
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

def Abstract.join (a b : Abstract) : Abstract :=
  match a, b with
  | .bottom, x | x, .bottom => x
  | .scalar, .scalar => .scalar
  | .record xs, .record ys => .record ((xs.attach.zip ys).map (fun (x, y) => x.val.join y))
  | .list cs x ex, .list ds y ey => .list (union cs ds) (x.join y) (ex.meet ey)
  | .function cs xs, .function ds ys => .function (union cs ds) (union xs ys)
  | .symbolic i t cs es, .symbolic j _ ds fs =>
    if i == j then .symbolic i t (union cs ds) (union es fs) else .list (union [.unknown] (union a.cells b.cells)) .bottom false
  -- Values of different shapes (a known closure and a function input, two
  -- function inputs): unknown, and holding every cell either side holds, so
  -- a live use of the join still keeps them (it used to drop them all).
  | _, _ => .list (union [.unknown] (union a.cells b.cells)) .bottom false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

/-- A symbolic function's environment is unknown, so it is never certified. -/
def Abstract.deepExclusive : Abstract → Bool
  | .bottom | .scalar => true
  | .record xs => xs.attach.all (fun x => x.val.deepExclusive)
  | .list _ x ex => ex && x.deepExclusive
  | .function _ xs => xs.attach.all fun alt => alt.val.2.attach.all (fun x => x.val.deepExclusive)
  | .symbolic .. => false
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

/-- The recursive consequence of an exclusive element loan, thesis §3.11. -/
def Abstract.grantExclusive : Abstract → Abstract
  | .list cs x _ => .list cs x.grantExclusive true
  | .record xs => .record (xs.attach.map (fun x => x.val.grantExclusive))
  | .function cs xs => .function cs (xs.attach.map fun alt => (alt.val.1, alt.val.2.attach.map (fun x => x.val.grantExclusive)))
  | x => x
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

/-- Change only must-facts, preserving the finite provenance shape. -/
def Abstract.mapCertificates (f : List Origin → Certificate → Certificate) : Abstract → Abstract
  | .list cs x ex => .list cs (x.mapCertificates f) (f cs ex)
  | .record xs => .record (xs.attach.map fun x => x.val.mapCertificates f)
  | .function cs xs => .function cs (xs.attach.map fun alt =>
      (alt.val.1, alt.val.2.attach.map fun x => x.val.mapCertificates f))
  | a => a
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

/-- Function-typed input slots a value mentions. -/
def Abstract.slots : Abstract → List Nat
  | .record xs => xs.attach.flatMap (fun x => x.val.slots)
  | .list _ x _ => x.slots
  | .function _ xs => xs.attach.flatMap fun alt => alt.val.2.attach.flatMap (fun x => x.val.slots)
  | .symbolic j .. => [j]
  | _ => []
termination_by a => sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

def separatedPaths (xs : List (Path × List Origin)) : Bool :=
  (xs.zipIdx).all fun ((_, cs), i) =>
    (xs.drop (i + 1)).all fun (_, ds) => !cellOverlap cs ds

def separatedValues (xs : List Abstract) : Bool :=
  (xs.zipIdx).all fun (x, i) =>
    separatedPaths x.paths && (xs.drop (i + 1)).all (fun y => !cellOverlap x.cells y.cells)

def abstractAtom (env : Env Abstract) : Atom → Except String Abstract
  | .int _ => pure .scalar
  | .var v => lookup env v
  | .field a i => do
    let .record xs ← abstractAtom env a | throw "abstract projection"
    xs[i]?.toExcept "abstract field"

abbrev Live := List (Var × Path)

def atomUses : Atom → Live
  | .int _ => []
  | .var v => [(v, [])]
  | .field a i => (atomUses a).map fun (v, p) => (v, p ++ [.field i])

def atomsUses (xs : List Atom) : Live := xs.flatMap atomUses

def removeVars (xs : List Var) (l : Live) : Live := l.filter fun (v, _) => !xs.contains v

/-- The captures of the closures an expression creates along its let chain
    and conditional arms (what the `branch-closure` control forgets). -/
def closureCapUses : Expr → Live
  | .closure _ xs => atomsUses xs
  | .letE _ a b | .branch _ a b => closureCapUses a ++ closureCapUses b
  | _ => []

/-- The uses of an expression. `nonzero := false` is the `branch-live`
    control's weakened liveness, which ignores a conditional's nonzero arm;
    one definition, so the control cannot drift from the rule it weakens. -/
def usesArms (nonzero : Bool) (armClosures : Bool := true) (prependRead : Bool := true) : Expr → Live
  | .atom a => atomUses a
  | .letE v rhs rest => union (usesArms nonzero armClosures prependRead rhs) (removeVars [v] (usesArms nonzero armClosures prependRead rest))
  | .prim .prepend [x, base] => if prependRead then atomsUses [x, base] else atomUses x
  | .prim .close (x :: _) => atomUses x
  | .prim _ xs | .recur xs => atomsUses xs
  | .closure _ xs => atomsUses xs
  | .app f xs => union (atomUses f) (atomsUses xs)
  | .entry initial retained model body => union (usesArms nonzero armClosures prependRead initial)
      (union (atomsUses retained) (removeVars [model] (usesArms nonzero armClosures prependRead body)))
  | .resultCase input err ok a b => union (atomUses input)
      (union (removeVars [err] (usesArms nonzero armClosures prependRead a))
        (removeVars [ok] (usesArms nonzero armClosures prependRead b)))
  | .chainCase input head tail a b => union (atomUses input)
      (union (usesArms nonzero armClosures prependRead a)
        (removeVars [head, tail] (usesArms nonzero armClosures prependRead b)))
  | .branch c a b =>
    -- The `branch-closure` control (`armClosures := false`) drops an arm's
    -- uses that are captures of the closures the arm creates.
    let ua := usesArms nonzero armClosures prependRead a
    let ub := if nonzero then usesArms nonzero armClosures prependRead b else []
    let ua := if armClosures then ua else ua.filter fun u => !(closureCapUses a).contains u
    let ub := if armClosures then ub else ub.filter fun u => !(closureCapUses b).contains u
    union (atomUses c) (union ua ub)
  | .traverse _ src init i x acc body =>
    union (atomsUses [src, init]) (removeVars [i, x, acc] (usesArms nonzero armClosures prependRead body))
  | .focus src i x body => union (atomsUses [src, i]) (removeVars [x] (usesArms nonzero armClosures prependRead body))

def uses (e : Expr) : Live := usesArms true true true e

def isPrefix (a b : Path) : Bool := a == b.take a.length

/-- Every live variable is bound: a checker refuses a continuation whose uses
    name a variable the environment does not bind, rather than read it as
    dead (third review, P1). -/
def liveScope (env : Env Abstract) (l : Live) : Except String Unit :=
  match l.find? (fun (x, _) => (env.lookup x).isNone) with
  | some (x, _) => throw s!"liveness: live variable {x} is not in scope"
  | none => pure ()

/-- The cells live uses hold. An unbound variable (never reached after
    `liveScope`) would hold anything: ⊤. -/
def liveCells (env : Env Abstract) (l : Live) : List Origin :=
  l.foldl (fun cs (v, p) =>
    match env.lookup v with
    | none => union cs [.unknown]
    | some a => a.paths.foldl (fun cs (q, ds) =>
        if isPrefix p q || isPrefix q p then union cs ds else cs) cs) []

/-! ## The summary layer's vocabulary (thesis §3.7, §4.5–§4.7)

A function-typed input of a summarised declaration is `symbolic`; the body
learns its class only by asking `Fact`s about one call of it. A `Query` names
the input (`slot`), the state of the arguments at that call (σ: their canonical
shapes, which carry exclusivity, and the argument paths unique there), and the
fact. The answer is a list of numbers: `[]`/`[1]` for a yes/no fact, the fresh
numbers at a result path for `fresh`. A summary records every query it made
with its answer as a `Guard`; it is reused only where every guard answers the
same, which is the thesis's guarded value resolved at a call. -/

inductive Fact where
  | writes (k : Nat) (p : Path)      -- W ∈ use(k, p)
  | escapes (k : Nat) (p : Path)     -- E ∈ use(k, p)
  | requires (k : Nat) (p : Path)    -- xreq(k, p)
  | aliases (k : Nat) (p q : Path)   -- π_k.p ∈ res(q)
  | env (q : Path)                   -- env ∈ res(q)
  | fresh (q : Path)                 -- the fresh numbers in res(q)
  | shared (q : Path)                -- shared or esc ∈ res(q)
  | top (q : Path)                   -- ⊤ ∈ res(q)
  | spine (q : Path)                 -- separated element containers
  | requiresSpine (k : Nat) (p : Path)
  | xres (q : Path)                  -- xres(q)
  | escapesEnv                       -- E on its own environment
  | once                             -- the value may be once
  deriving Repr, BEq, Inhabited

structure Query where
  slot : Nat
  args : List Abstract
  owned : List Origin
  fact : Fact
  deriving Repr, BEq, Inhabited

structure Guard where
  query : Query
  answer : List Nat
  deriving Repr, BEq, Inhabited

/-- One call of a function-typed input: what is passed (in the vocabulary of
    the scope that recorded it), the callee's environment cells, the σ its
    class was asked under, and the argument paths supplied owned (they pass
    Known, Unescaped, Dead and Disjoint at the call) and exclusive. -/
structure Supply where
  slot : Nat
  site : List Nat
  state : List Abstract × List Origin
  args : List Abstract
  env : List Origin
  owned : List (Nat × Path)
  exclusive : List (Nat × Path)
  spine : List (Nat × Path) := []
  deriving Repr, BEq, Inhabited

/-- Slot ↦ the actual function value at the call, in the next frame's
    vocabulary. -/
structure Frame where
  actuals : List (Nat × Abstract) := []
  deriving Repr, BEq, Inhabited

structure Summary where
  result : Abstract := .bottom
  reads : List Origin := []
  writes : List Origin := []
  escapes : List Origin := []
  requiresExclusive : List Origin := []
  requiresSpine : List Origin := []
  recursive : Bool := false
  /-- W through a supply: cells handed to a callback that writes them. They
      are checked by the supply's owned bit and the call-site edge, and become
      `W` on the declaration's own parameters. -/
  consumes : List Origin := []
  supplies : List Supply := []
  /-- Slot ↦ 0, 1 or 2 (many) calls. -/
  calls : List (Nat × Nat) := []
  guards : List Guard := []
  deriving Repr, BEq, Inhabited

def mergeCalls (combine : Nat → Nat → Nat) (a b : List (Nat × Nat)) : List (Nat × Nat) :=
  b.foldl (fun xs (j, n) => match xs.lookup j with
    | some m => xs.map fun (i, k) => if i == j then (i, min 2 (combine m n)) else (i, k)
    | none => xs ++ [(j, min 2 n)]) a

/-- The fixpoint join: the more pessimistic of two summaries. -/
def Summary.join (a b : Summary) : Summary := {
  result := a.result.join b.result
  reads := union a.reads b.reads
  writes := union a.writes b.writes
  escapes := union a.escapes b.escapes
  requiresExclusive := union a.requiresExclusive b.requiresExclusive
  requiresSpine := union a.requiresSpine b.requiresSpine
  recursive := a.recursive || b.recursive
  consumes := union a.consumes b.consumes
  supplies := union a.supplies b.supplies
  calls := mergeCalls max a.calls b.calls
  guards := union a.guards b.guards
}

end Ownership
