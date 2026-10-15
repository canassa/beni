import Std

namespace Ownership

def _root_.Option.toExcept (o : Option α) (error : ε) : Except ε α :=
  match o with | some a => .ok a | none => .error error

abbrev Var := Nat

inductive Ty where
  | int
  | result (error success : Ty)
  | chain (payload : Ty) -- End | Link payload (Chain payload)
  | record (fields : List Ty)
  | list (element : Ty)
  | builder (element : Ty)
  | fn (parameters : List Ty) (result : Ty)
  deriving Repr, Inhabited

/-- Explicitly total: Lean's derived BEq for nested inductives is opaque. -/
def Ty.equal (a b : Ty) : Bool :=
  match a, b with
  | .int, .int => true
  | .record xs, .record ys =>
    xs.length == ys.length && (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | .result e a, .result f b => e.equal f && a.equal b
  | .chain x, .chain y | .list x, .list y | .builder x, .builder y => x.equal y
  | .fn xs x, .fn ys y => x.equal y && xs.length == ys.length &&
    (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | _, _ => false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

instance : BEq Ty := ⟨Ty.equal⟩

inductive Atom where
  | int (value : Int)
  | var (name : Var)
  | field (value : Atom) (index : Nat)
  deriving Repr, BEq, Inhabited

inductive Prim where
  | ok (error : Ty) | err (success : Ty)
  | endChain (payload : Ty) | link
  | privateRoot -- a closed, unexported initialization binding
  | add | sub | eq | lt
  | record
  | literal (element : Ty)
  | length
  | at -- total indexed read: xs, index, default
  | set -- out of range: unchanged, still a demand
  | push
  | copy
  | prepend -- front item, base; may share the base's backing array
  /-- A construction (`ownership-checker.md` §3.2): one operand per flag, a
      spread (`true`, a list) or an item (`false`). Its base is the first
      spread, which it consumes and writes in place; a later spread is read
      while the base grows. `a ++ b ++ c` is `[true, true, true]`. -/
  | construct (spreads : List Bool)
  /-- A list pattern's spread binding (§5, *Views*): `front` is the `rest`
      of `[ x, …rest ]`, otherwise the `init` of `[ …init, last ]`. It is a
      view sharing its source's array; an empty source gives a fresh `[]`. -/
  | view (front : Bool)
  | events -- projection of the event slot of a two-slot markup record
  | owned (forwarded : Bool := false) -- result, retained callback: an owned-result boundary
  | shared -- declare a program-lifetime root (top-level value)
  | builder (element : Ty)
  | put
  | close -- optional second operand is map's identity-preserving source
  deriving Repr, BEq, Inhabited

inductive Source where
  | list | range | model -- a finite sequence of model updates
  deriving Repr, BEq, Inhabited

/-- Strict ANF. Traversal and focus bind only their explicitly named locals. -/
inductive Expr where
  | atom (value : Atom)
  | letE (name : Var) (rhs rest : Expr)
  | prim (op : Prim) (args : List Atom)
  | closure (decl : Nat) (captures : List Atom)
  | app (callee : Atom) (args : List Atom)
  | recur (args : List Atom)
  | entry (initial : Expr) (retained : List Atom) (model : Var) (body : Expr)
  | resultCase (input : Atom) (error success : Var) (onError onSuccess : Expr)
  | chainCase (input : Atom) (head tail : Var) (onEnd onLink : Expr)
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
  | .ok e, [a] => pure (.result e a)
  | .err a, [e] => pure (.result e a)
  | .endChain t, [] => pure (.chain t)
  | .link, [a, .chain t] => if a == t then pure (.chain t) else throw "incorrect chain payload"
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
  | .prepend, [t, .list u] =>
    if t == u then pure (.list t) else throw "incorrect prepend element"
  | .construct spreads, ts => do
    -- A demand: a base (the first spread) with an operand after it. A
    -- spread-free literal allocates and a prepend only reads (§3.2).
    if spreads.length != ts.length then throw "construction shape"
    let b := spreads.idxOf true
    if b + 1 ≥ spreads.length then throw "construction without a base and a later operand"
    let .list t := ts[b]?.getD .int | throw "construction base is not a list"
    for (u, spread) in ts.zip spreads do
      if spread && u != .list t then throw "incorrect spread operand"
      if !spread && u != t then throw "incorrect construction item"
    pure (.list t)
  | .view _, [.list t] => pure (.list t)
  | .events, [.record [_, events]] => pure events
  | .owned _, [t, .fn _ _] => pure t
  | .copy, [.list t] => pure (.list t)
  | .shared, [t] | .privateRoot, [t] => pure t
  | .builder t, [] => pure (.builder t)
  | .put, [.builder t, v] =>
    if t == v then pure (.builder t) else throw "incorrect builder element"
  | .close, [.builder t] => pure (.list t)
  | .close, [.builder t, .list u] =>
    if t == u then pure (.list t) else throw "incorrect close source"
  | _, _ => throw s!"ill-typed primitive {repr p} on {repr ts}"

def exprType (ds : List Decl) (self : Decl) (env : Env Ty) : Expr → Except String Ty
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
  | .entry initial retained model body => do
    let t ← exprType ds self env initial
    let _ ← retained.mapM (atomType env)
    exprType ds self ((model, t) :: env) body
  | .resultCase input err ok onError onSuccess => do
    let .result e a ← atomType env input | throw "case of non-result"
    let left ← exprType ds self ((err, e) :: env) onError
    let right ← exprType ds self ((ok, a) :: env) onSuccess
    if left == right then pure left else throw "result case type mismatch"
  | .chainCase input head tail onEnd onLink => do
    let .chain t ← atomType env input | throw "case of non-chain"
    let left ← exprType ds self env onEnd
    let right ← exprType ds self ((head, t) :: (tail, .chain t) :: env) onLink
    if left == right then pure left else throw "chain case type mismatch"
  | .branch c yes no => do
    if (← atomType env c) != .int then throw "non-integer condition"
    let a ← exprType ds self env yes
    let b ← exprType ds self env no
    if a == b then pure a else throw "branch type mismatch"
  | .traverse kind src init i x acc body => do
    let t ← atomType env src
    let elem ← match kind, t with
      | .list, .list e => pure e
      | .range, .int | .model, .int => pure Ty.int
      | _, _ => throw "incorrect traversal source"
    let a ← atomType env init
    let b ← exprType ds self ((i, .int) :: (x, elem) :: (acc, a) :: env) body
    if a == b then pure a else throw "traversal accumulator type mismatch"
  | .focus src idx x body => do
    let .list t ← atomType env src | throw "focus on non-list"
    if (← atomType env idx) != .int then throw "non-integer index"
    if (← exprType ds self ((x, t) :: env) body) != t then throw "focus type mismatch"
    pure (.list t)

/-- Ordinary typing only: every declaration body and the main expression. -/
def typesOf (p : Program) : Except String Ty := do
  for d in p.declarations do
    let t ← exprType p.declarations d (bindArgs (d.parameters ++ d.captures)) d.body
    if t != d.result then throw s!"incorrect result type in {d.name}"
  exprType p.declarations { name := "main", parameters := [], result := .int, body := p.main } [] p.main

/-- No binder rebinds a variable already in scope. beni forbids shadowing, and
    this core mirrors it: the checker's liveness names variables, and a
    continuation that uses an outer `x` must not be read as the inner one. A
    conditional's two arms are separate scopes. -/
def shadowFree (bound : List Var) : Expr → Except String Unit
  | .letE v rhs rest => do
    if bound.contains v then throw s!"shadowing: variable {v} is bound twice"
    shadowFree bound rhs
    shadowFree (v :: bound) rest
  | .entry initial _ model body => do
    if bound.contains model then throw "shadowing: entry model binder"
    shadowFree bound initial
    shadowFree (model :: bound) body
  | .resultCase _ err ok a b => do
    if bound.contains err || bound.contains ok then throw "shadowing: result case binder"
    shadowFree (err :: bound) a
    shadowFree (ok :: bound) b
  | .chainCase _ head tail a b => do
    if bound.contains head || bound.contains tail || head == tail then throw "shadowing: chain case binder"
    shadowFree bound a
    shadowFree (head :: tail :: bound) b
  | .branch _ a b => do shadowFree bound a; shadowFree bound b
  | .traverse _ _ _ i x acc body => do
    for v in [i, x, acc] do
      if bound.contains v then throw s!"shadowing: variable {v} is bound twice"
    if i == x || x == acc || i == acc then throw "shadowing: a traversal binds one variable twice"
    shadowFree (i :: x :: acc :: bound) body
  | .focus _ _ x body => do
    if bound.contains x then throw s!"shadowing: variable {x} is bound twice"
    shadowFree (x :: bound) body
  | _ => pure ()

def noShadowing (p : Program) : Except String Unit := do
  for d in p.declarations do
    shadowFree (List.range (d.parameters.length + d.captures.length)) d.body
  shadowFree [] p.main

/-- The core's static check: ordinary typing and no shadowing. -/
def typecheck (p : Program) : Except String Ty := do
  let t ← typesOf p
  noShadowing p
  pure t

end Ownership
