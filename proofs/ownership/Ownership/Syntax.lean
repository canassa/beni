import Std

namespace Ownership

def _root_.Option.toExcept (o : Option α) (error : ε) : Except ε α :=
  match o with | some a => .ok a | none => .error error

abbrev Var := Nat

inductive Ty where
  | int
  | record (fields : List Ty)
  | list (element : Ty)
  | builder (element : Ty)
  | fn (parameters : List Ty) (result : Ty)
  deriving Repr, BEq, Inhabited

inductive Atom where
  | int (value : Int)
  | var (name : Var)
  | field (value : Atom) (index : Nat)
  deriving Repr, BEq, Inhabited

inductive Prim where
  | add | sub | eq | lt
  | record
  | literal (element : Ty)
  | length
  | at -- total indexed read: xs, index, default
  | set -- out of range: unchanged, still a demand
  | push
  | copy
  | shared -- declare a program-lifetime root (top-level value)
  | builder (element : Ty)
  | put
  | close -- optional second operand is map's identity-preserving source
  deriving Repr, BEq, Inhabited

inductive Source where
  | list | range
  deriving Repr, BEq, Inhabited

/-- Strict ANF. Traversal and focus bind only their explicitly named locals. -/
inductive Expr where
  | atom (value : Atom)
  | letE (name : Var) (rhs rest : Expr)
  | prim (op : Prim) (args : List Atom)
  | closure (decl : Nat) (captures : List Atom)
  | app (callee : Atom) (args : List Atom)
  | recur (args : List Atom)
  | branch (condition : Atom) (zero nonzero : Expr)
  | traverse (source : Source) (input initial : Atom)
      (index element accumulator : Var) (step : Expr)
  | focus (input index : Atom) (element : Var) (body : Expr)
  deriving Repr, BEq, Inhabited

structure Decl where
  name : String
  parameters : List Ty
  captures : List Ty := []
  result : Ty
  body : Expr
  deriving Repr, BEq, Inhabited

structure Program where
  declarations : List Decl := []
  main : Expr
  deriving Repr, BEq, Inhabited

abbrev Env (α : Type) := List (Var × α)

def lookup [Inhabited α] (env : Env α) (v : Var) : Except String α :=
  match env.lookup v with
  | some x => .ok x
  | none => .error s!"unbound variable {v}"

def bindArgs (xs : List α) (offset := 0) : Env α :=
  xs.zipIdx offset |>.map fun (x, i) => (i, x)

def atomType (env : Env Ty) : Atom → Except String Ty
  | .int _ => pure .int
  | .var v => lookup env v
  | .field a i => do
    let .record fs ← atomType env a | throw "projection of non-record"
    fs[i]?.toExcept "field out of range"

def primType (p : Prim) (ts : List Ty) : Except String Ty := do
  match p, ts with
  | .add, [.int, .int] | .sub, [.int, .int]
  | .eq, [.int, .int] | .lt, [.int, .int] => pure .int
  | .record, xs => pure (.record xs)
  | .literal t, xs =>
    if xs.all (· == t) then pure (.list t) else throw "heterogeneous list"
  | .length, [.list _] => pure .int
  | .at, [.list t, .int, d] =>
    if t == d then pure t else throw "incorrect at default"
  | .set, [.list t, .int, v] | .push, [.list t, v] =>
    if t == v then pure (.list t) else throw "incorrect stored type"
  | .copy, [.list t] => pure (.list t)
  | .shared, [t] => pure t
  | .builder t, [] => pure (.builder t)
  | .put, [.builder t, v] =>
    if t == v then pure (.builder t) else throw "incorrect builder element"
  | .close, [.builder t] => pure (.list t)
  | .close, [.builder t, .list u] =>
    if t == u then pure (.list t) else throw "incorrect close source"
  | _, _ => throw s!"ill-typed primitive {repr p} on {repr ts}"

partial def exprType (ds : List Decl) (self : Decl) (env : Env Ty) : Expr → Except String Ty
  | .atom a => atomType env a
  | .letE v rhs rest => do
    let t ← exprType ds self env rhs
    exprType ds self ((v, t) :: env) rest
  | .prim p args => do primType p (← args.mapM (atomType env))
  | .closure id caps => do
    let d ← ds[id]?.toExcept "missing declaration"
    let ts ← caps.mapM (atomType env)
    if ts != d.captures then throw "incorrect closure captures"
    pure (.fn d.parameters d.result)
  | .app f args => do
    let .fn ps result ← atomType env f | throw "call of non-function"
    if (← args.mapM (atomType env)) != ps then throw "incorrect call arguments"
    pure result
  | .recur args => do
    if (← args.mapM (atomType env)) != self.parameters then throw "incorrect recursion arguments"
    pure self.result
  | .branch c yes no => do
    if (← atomType env c) != .int then throw "non-integer condition"
    let a ← exprType ds self env yes
    let b ← exprType ds self env no
    if a == b then pure a else throw "branch type mismatch"
  | .traverse kind src init i x acc body => do
    let t ← atomType env src
    let elem ← match kind, t with
      | .list, .list e => pure e
      | .range, .int => pure Ty.int
      | _, _ => throw "incorrect traversal source"
    let a ← atomType env init
    let b ← exprType ds self ((i, .int) :: (x, elem) :: (acc, a) :: env) body
    if a == b then pure a else throw "traversal accumulator type mismatch"
  | .focus src idx x body => do
    let .list t ← atomType env src | throw "focus on non-list"
    if (← atomType env idx) != .int then throw "non-integer index"
    if (← exprType ds self ((x, t) :: env) body) != t then throw "focus type mismatch"
    pure (.list t)

def typecheck (p : Program) : Except String Ty := do
  for d in p.declarations do
    let t ← exprType p.declarations d (bindArgs (d.parameters ++ d.captures)) d.body
    if t != d.result then throw s!"incorrect result type in {d.name}"
  exprType p.declarations { name := "main", parameters := [], result := .int, body := p.main } [] p.main

end Ownership
