import Ownership.Syntax

namespace Ownership

/-- Observations have no addresses and never refer back into a mutable heap. -/
inductive Observation where
  | int (n : Int)
  | record (fields : List Observation)
  | list (items : List Observation)
  | closure (decl : Nat) (captures : List Observation)
  deriving Repr, BEq, Inhabited

structure Trace where
  reads : List Observation
  finalValue : Observation
  deriving Repr, BEq, Inhabited

namespace ValueSemantics

abbrev Value := Observation
structure State where
  fuel : Nat
  reads : Array Observation := #[]
abbrev M := StateT State (Except String)

def tick : M Unit := do
  let s ← get
  if s.fuel == 0 then throw "value execution exhausted fuel"
  set { s with fuel := s.fuel - 1 }

def read (v : Value) : M Unit := modify fun s => { s with reads := s.reads.push v }

def atom (env : Env Value) : Atom → Except String Value
  | .int n => pure (.int n)
  | .var v => lookup env v
  | .field a i => do
    let .record xs ← atom env a | throw "value projection"
    xs[i]?.toExcept "value field"

def prim (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .add, [.int a, .int b] => pure (.int (a + b))
  | .sub, [.int a, .int b] => pure (.int (a - b))
  | .eq, [.int a, .int b] => pure (.int (if a == b then 1 else 0))
  | .lt, [.int a, .int b] => pure (.int (if a < b then 1 else 0))
  | .record, xs => pure (.record xs)
  | .literal _, xs => pure (.list xs)
  | .builder _, [] => pure (.list [])
  | .shared, [x] => pure x
  | .length, [.list xs] => do
    let n := Observation.int xs.length
    read n
    pure n
  | .at, [.list xs, .int i, fallback] => do
    let x := if i < 0 then fallback else xs[i.toNat]?.getD fallback
    read x
    pure x
  | .set, [.list xs, .int i, v] =>
    pure (.list (if i < 0 then xs else xs.set i.toNat v))
  | .push, [.list xs, x] | .put, [.list xs, x] => pure (.list (xs ++ [x]))
  | .copy, [.list xs] => pure (.list xs)
  | .close, [.list xs] | .close, [.list xs, .list _] => pure (.list xs)
  | _, _ => throw "value primitive shape"

partial def eval (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) : M Value := do
  tick
  match e with
  | .atom a => atom env a
  | .letE v rhs rest =>
    let x ← eval ds self env rhs
    eval ds self ((v, x) :: env) rest
  | .prim op args => prim op (← args.mapM (m := Except String) (atom env))
  | .closure id captures => pure (.closure id (← captures.mapM (m := Except String) (atom env)))
  | .app f args =>
    let .closure id caps ← atom env f | throw "value call"
    call ds id caps (← args.mapM (m := Except String) (atom env))
  | .recur args =>
    let some (id, caps) := self | throw "recursion outside function"
    call ds id caps (← args.mapM (m := Except String) (atom env))
  | .branch a yes no =>
    let .int n ← atom env a | throw "value condition"
    eval ds self env (if n == 0 then yes else no)
  | .traverse kind src init i x acc body =>
    let input ← atom env src
    let values ← match kind, input with
      | .list, .list xs => do read (.int xs.length); pure xs
      | .range, .int n => pure ((List.range n.toNat).map (fun i => .int i))
      | _, _ => throw "value traversal"
    let mut a ← atom env init
    for (v, n) in values.zipIdx do
      tick
      if kind == .list then read v
      a ← eval ds self ((i, .int n) :: (x, v) :: (acc, a) :: env) body
    pure a
  | .focus src index x body =>
    let .list xs ← atom env src | throw "value focus"
    let .int i ← atom env index | throw "value index"
    if i < 0 then return .list xs
    match xs[i.toNat]? with
    | none => pure (.list xs)
    | some v =>
      read v
      let w ← eval ds self ((x, v) :: env) body
      pure (.list (xs.set i.toNat w))
where
  call (ds : List Decl) (id : Nat) (caps args : List Value) : M Value := do
    let d ← ds[id]?.toExcept "value missing declaration"
    eval ds (some (id, caps)) (bindArgs (args ++ caps)) d.body

def run (p : Program) (fuel := 100000) : Except String Trace := do
  let (v, s) ← (eval p.declarations none [] p.main).run { fuel }
  pure { reads := s.reads.toList, finalValue := v }

end ValueSemantics

namespace InPlaceSemantics

inductive Value where
  | int (n : Int)
  | record (fields : List Value)
  | ref (address : Nat)
  | closure (decl : Nat) (captures : List Value)
  deriving Repr, BEq, Inhabited

structure State where
  fuel : Nat
  heap : Array (List Value) := #[]
  reads : Array Observation := #[]
abbrev M := StateT State (Except String)

def tick : M Unit := do
  let s ← get
  if s.fuel == 0 then throw "in-place execution exhausted fuel"
  set { s with fuel := s.fuel - 1 }

def alloc (xs : List Value) : M Value := do
  let s ← get
  set { s with heap := s.heap.push xs }
  pure (.ref s.heap.size)

def array (c : Nat) : M (List Value) := do
  (← get).heap[c]?.toExcept "dangling array reference"

def write (c : Nat) (xs : List Value) : M Value := do
  if c ≥ (← get).heap.size then throw "dangling write"
  modify fun s => { s with heap := s.heap.set! c xs }
  pure (.ref c)

def snapshot (heap : Array (List Value)) : Nat → Value → Except String Observation
  | 0, _ => throw "snapshot exhausted depth (possibly cyclic heap)"
  | n + 1, v => match v with
    | .int i => pure (.int i)
    | .record xs => return .record (← xs.mapM (snapshot heap n))
    | .closure id caps => return .closure id (← caps.mapM (snapshot heap n))
    | .ref c => do
      let xs ← heap[c]?.toExcept "snapshot dangling reference"
      return .list (← xs.mapM (snapshot heap n))

def read (v : Value) : M Unit := do
  let o ← snapshot (← get).heap 256 v
  modify fun s => { s with reads := s.reads.push o }

def atom (env : Env Value) : Atom → Except String Value
  | .int n => pure (.int n)
  | .var v => lookup env v
  | .field a i => do
    let .record xs ← atom env a | throw "in-place projection"
    xs[i]?.toExcept "in-place field"

def prim (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .add, [.int a, .int b] => pure (.int (a + b))
  | .sub, [.int a, .int b] => pure (.int (a - b))
  | .eq, [.int a, .int b] => pure (.int (if a == b then 1 else 0))
  | .lt, [.int a, .int b] => pure (.int (if a < b then 1 else 0))
  | .record, xs => pure (.record xs)
  | .literal _, xs => alloc xs
  | .builder _, [] => alloc []
  | .shared, [v] => pure v
  | .length, [.ref c] => do
    let n := Value.int (← array c).length
    read n
    pure n
  | .at, [.ref c, .int i, fallback] => do
    let xs ← array c
    let x := if i < 0 then fallback else xs[i.toNat]?.getD fallback
    read x
    pure x
  | .set, [.ref c, .int i, v] => do
    let xs ← array c
    write c (if i < 0 then xs else xs.set i.toNat v)
  | .push, [.ref c, v] | .put, [.ref c, v] => do write c ((← array c) ++ [v])
  | .copy, [.ref c] => do alloc (← array c)
  | .close, [.ref c] => pure (.ref c)
  | .close, [.ref c, .ref source] => do
    -- Dedicated, unobserved identity shortcut; both branches contain the same
    -- callback results. No ordinary user identity operation exists in this core.
    if (← array c) == (← array source) then pure (.ref source) else pure (.ref c)
  | _, _ => throw "in-place primitive shape"

partial def eval (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) : M Value := do
  tick
  match e with
  | .atom a => atom env a
  | .letE v rhs rest =>
    let x ← eval ds self env rhs
    eval ds self ((v, x) :: env) rest
  | .prim op args => prim op (← args.mapM (m := Except String) (atom env))
  | .closure id captures => pure (.closure id (← captures.mapM (m := Except String) (atom env)))
  | .app f args =>
    let .closure id caps ← atom env f | throw "in-place call"
    call ds id caps (← args.mapM (m := Except String) (atom env))
  | .recur args =>
    let some (id, caps) := self | throw "recursion outside function"
    call ds id caps (← args.mapM (m := Except String) (atom env))
  | .branch a yes no =>
    let .int n ← atom env a | throw "in-place condition"
    eval ds self env (if n == 0 then yes else no)
  | .traverse kind src init i x acc body =>
    let input ← atom env src
    let n ← match kind, input with
      | .list, .ref c => do
        let n := (← array c).length
        read (.int n)
        pure n
      | .range, .int n => pure n.toNat
      | _, _ => throw "in-place traversal"
    let mut a ← atom env init
    for j in List.range n do
      tick
      let v ← match input with
        | .ref c => do
          let v ← (← array c)[j]?.toExcept "traversal source changed length"
          read v
          pure v
        | _ => pure (.int j)
      a ← eval ds self ((i, .int j) :: (x, v) :: (acc, a) :: env) body
    pure a
  | .focus src index x body =>
    let .ref c ← atom env src | throw "in-place focus"
    let .int i ← atom env index | throw "in-place index"
    let xs ← array c
    if i < 0 then return .ref c
    match xs[i.toNat]? with
    | none => pure (.ref c)
    | some v =>
      read v
      let w ← eval ds self ((x, v) :: env) body
      write c (xs.set i.toNat w)
where
  call (ds : List Decl) (id : Nat) (caps args : List Value) : M Value := do
    let d ← ds[id]?.toExcept "in-place missing declaration"
    eval ds (some (id, caps)) (bindArgs (args ++ caps)) d.body

def run (p : Program) (fuel := 100000) : Except String Trace := do
  let (v, s) ← (eval p.declarations none [] p.main).run { fuel }
  let finalValue ← snapshot s.heap 256 v
  pure { reads := s.reads.toList, finalValue }

end InPlaceSemantics
end Ownership
