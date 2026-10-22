import Std

/-! # The tree fragment: syntax and typing

A self-contained fragment for `ownership-checker.md` §16.7's level marker
`⟨T⟩` (issue #379, the amendment "the level marker `⟨T⟩` replaces (d)"). It
has one recursive type, `Tree = Leaf | Node Tree (List Int) Tree`, integer
lists, pairs, `case` over trees and pairs, `List.push` and calls of earlier
declarations (no recursion, so the declaration table is a DAG). It shares no
definition with the main core (`Ownership.Syntax`): that core's recursive
`Chain` merges every payload into a list's element shape and has no paths
with folds, so the marker has nothing to act on there. -/

namespace Ownership.Tree

/-- A step of a path. `n0`, `n1`, `n2` are `#Node.0` (the left subtree),
    `#Node.1` (the level's own list) and `#Node.2` (the right subtree); `p0`,
    `p1` the components of a pair; `mark` the level marker `⟨Tree⟩`. A
    concrete path never holds `mark`. -/
inductive Step where
  | n0 | n1 | n2 | p0 | p1 | mark
  deriving DecidableEq, Repr, Inhabited

inductive Ty where
  | list
  | tree
  | pair (a b : Ty)
  deriving DecidableEq, Repr, Inhabited

abbrev Var := Nat

/-- Strict ANF over variables. `caseTree t l x r onLeaf onNode` binds the
    three fields of a `Node`; `call f args` calls declaration `f`, which must
    come before the caller in the table. -/
inductive Expr where
  | var (x : Var)
  | nil
  | lit (n : Int)
  | leaf
  | node (l x r : Var)
  | pair (a b : Var)
  | push (xs : Var) (n : Int)
  | call (f : Nat) (args : List Var)
  | letE (x : Var) (rhs rest : Expr)
  | caseTree (t : Var) (l x r : Var) (onLeaf onNode : Expr)
  | casePair (p : Var) (a b : Var) (body : Expr)
  deriving DecidableEq, Repr, Inhabited

/-- Parameters are the variables `0 … n-1`. -/
structure Decl where
  name : String
  params : List Ty
  result : Ty
  body : Expr
  deriving DecidableEq, Repr, Inhabited

/-- A module: its declarations, and an optional main expression whose value
    both interpreters observe. -/
structure Program where
  decls : List Decl
  main : Option Expr := none
  deriving DecidableEq, Repr, Inhabited

def lookupT (env : List (Var × Ty)) (x : Var) : Except String Ty :=
  match env.lookup x with
  | some t => .ok t
  | none => .error "unbound variable"

/-- Ordinary typing; `self` is the index of the declaration being typed (a
    call may only reach a smaller index) and `bound` every variable in
    scope, for the no-shadowing rule. -/
def typeOf (ds : List Decl) (self : Nat) : List (Var × Ty) → Expr → Except String Ty
  | env, .var x => lookupT env x
  | _, .nil | _, .lit _ => .ok .list
  | _, .leaf => .ok .tree
  | env, .node l x r => do
    let tl ← lookupT env l
    let tx ← lookupT env x
    let tr ← lookupT env r
    if tl == .tree && tx == .list && tr == .tree then .ok .tree else .error "ill-typed node"
  | env, .pair a b => do .ok (.pair (← lookupT env a) (← lookupT env b))
  | env, .push xs _ => do
    if (← lookupT env xs) == .list then .ok .list else .error "push of a non-list"
  | env, .call f args => do
    if f ≥ self then throw "call of a later declaration"
    let some d := ds[f]? | throw "missing declaration"
    let ts ← args.mapM (lookupT env)
    if ts == d.params then .ok d.result else .error "ill-typed call"
  | env, .letE x rhs rest => do
    if (env.lookup x).isSome then throw "shadowing"
    let t ← typeOf ds self env rhs
    typeOf ds self ((x, t) :: env) rest
  | env, .caseTree t l x r a b => do
    if (← lookupT env t) != .tree then throw "case of a non-tree"
    if [l, x, r].any (fun v => (env.lookup v).isSome) || l == x || x == r || l == r then throw "shadowing"
    let ta ← typeOf ds self env a
    let tb ← typeOf ds self ((l, .tree) :: (x, .list) :: (r, .tree) :: env) b
    if ta == tb then .ok ta else .error "case arms differ"
  | env, .casePair p a b body => do
    let .pair ta tb ← lookupT env p | throw "case of a non-pair"
    if (env.lookup a).isSome || (env.lookup b).isSome || a == b then throw "shadowing"
    typeOf ds self ((a, ta) :: (b, tb) :: env) body

def paramEnv (ts : List Ty) : List (Var × Ty) := ts.zipIdx.map fun (t, i) => (i, t)

def typecheck (p : Program) : Except String Unit := do
  for (d, i) in p.decls.zipIdx do
    let t ← typeOf p.decls i (paramEnv d.params) d.body
    if t != d.result then throw s!"result type of {d.name}"
  if let some m := p.main then
    let _ ← typeOf p.decls p.decls.length [] m

/-- Free variables. -/
def fv : Expr → List Var
  | .var x => [x]
  | .nil | .lit _ | .leaf => []
  | .node l x r => [l, x, r]
  | .pair a b => [a, b]
  | .push xs _ => [xs]
  | .call _ args => args
  | .letE x rhs rest => fv rhs ++ (fv rest).filter (· != x)
  | .caseTree t l x r a b => t :: fv a ++ (fv b).filter (fun v => v != l && v != x && v != r)
  | .casePair p a b body => p :: (fv body).filter (fun v => v != a && v != b)

end Ownership.Tree
