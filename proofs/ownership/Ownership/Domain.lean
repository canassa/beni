import Ownership.Syntax

namespace Ownership

inductive Step where
  | field (i : Nat)
  | element
  | capture (i : Nat)
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

/-- Positions are deliberately merged. `exclusive` carries information that
    provenance sets cannot carry, including separation inside one position. -/
inductive Abstract where
  | bottom
  | scalar
  | record (fields : List Abstract)
  | list (roots : List Origin) (element : Abstract) (exclusive : Bool)
  | function (roots : List Origin) (alternatives : List (Nat × List Abstract))
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
  | _, _ => .bottom

def Abstract.roots : Abstract → List Origin
  | .list cs _ _ | .function cs _ => cs
  | _ => []

def Abstract.cellsAt (a : Abstract) (p : Path) : List Origin :=
  a.paths.foldl (fun cs (q, xs) => if p == q then union cs xs else cs) []

def Abstract.mapOrigins (f : Path → List Origin → List Origin) (a : Abstract)
    (path : Path := []) : Abstract :=
  match a with
  | .bottom => .bottom
  | .scalar => .scalar
  | .record xs => .record (xs.attach.zipIdx.map fun (x, i) => x.val.mapOrigins f (path ++ [.field i]))
  | .list cs x ex => .list (f path cs) (x.mapOrigins f (path ++ [.element])) ex
  | .function cs alts => .function (f path cs) (alts.attach.map fun alt =>
    (alt.val.1, alt.val.2.attach.zipIdx.map fun (x, i) => x.val.mapOrigins f (path ++ [.capture i])))
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
  | .list cs x ex, .list ds y ey => .list (union cs ds) (x.join y) (ex && ey)
  | .function cs xs, .function ds ys => .function (union cs ds) (union xs ys)
  | _, _ => .list [.unknown] .bottom false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals try have h₂ := List.sizeOf_lt_of_mem alt.property
  all_goals try have h₃ := sndSize alt.val
  all_goals simp_all +arith
  all_goals omega

def Abstract.deepExclusive : Abstract → Bool
  | .bottom | .scalar => true
  | .record xs => xs.attach.all (fun x => x.val.deepExclusive)
  | .list _ x ex => ex && x.deepExclusive
  | .function _ xs => xs.attach.all fun alt => alt.val.2.attach.all (fun x => x.val.deepExclusive)
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

def uses : Expr → Live
  | .atom a => atomUses a
  | .letE v rhs rest => union (uses rhs) (removeVars [v] (uses rest))
  | .prim .close (x :: _) => atomUses x
  | .prim _ xs | .closure _ xs | .recur xs => atomsUses xs
  | .app f xs => union (atomUses f) (atomsUses xs)
  | .branch c a b => union (atomUses c) (union (uses a) (uses b))
  | .traverse _ src init i x acc body =>
    union (atomsUses [src, init]) (removeVars [i, x, acc] (uses body))
  | .focus src i x body => union (atomsUses [src, i]) (removeVars [x] (uses body))

def isPrefix (a b : Path) : Bool := a == b.take a.length

def liveCells (env : Env Abstract) (l : Live) : List Origin :=
  l.foldl (fun cs (v, p) =>
    match env.lookup v with
    | none => cs
    | some a => a.paths.foldl (fun cs (q, ds) =>
        if isPrefix p q || isPrefix q p then union cs ds else cs) cs) []

structure Summary where
  result : Abstract := .bottom
  reads : List Origin := []
  writes : List Origin := []
  escapes : List Origin := []
  requiresExclusive : List Origin := []
  recursive : Bool := false
  deriving Repr, BEq, Inhabited

def Summary.join (a b : Summary) : Summary := {
  result := a.result.join b.result
  reads := union a.reads b.reads
  writes := union a.writes b.writes
  escapes := union a.escapes b.escapes
  requiresExclusive := union a.requiresExclusive b.requiresExclusive
  recursive := a.recursive || b.recursive
}

end Ownership
