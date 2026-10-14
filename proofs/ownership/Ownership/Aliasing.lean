import Ownership.Semantics

/-! A campaign metric, from the second review's instrumentation: does an
accepted program ever write in place to an array that more than one name
reaches? A copy of the in-place interpreter (same writes, same order) that, at
every program-level write (`set`, `push`, focus write-back), counts the names
reaching the written array: bindings of the current frame and of every
calling frame, and the program-lifetime roots of `shared`. A write is
*aliased* when two or more names reach the array. Without such writes a
campaign tests only programs where in-place and copying cannot differ. Never
compared, never used by the checker. -/

namespace Ownership.Aliasing
open InPlaceSemantics (Value)

structure State where
  fuel : Nat
  heap : Array (List Value) := #[]
  kept : Array Value := #[]
  /-- Environments of the calling frames, innermost first. -/
  stack : List (Env Value) := []
  writes : Nat := 0
  /-- Writes to an array two or more names reach. -/
  aliased : Nat := 0
abbrev M := StateT State (Except String)

/-- Arrays reachable from a value (bounded depth). -/
def reach (heap : Array (List Value)) : Nat → Value → List Nat
  | 0, _ => []
  | n + 1, v => match v with
    | .int _ => []
    | .record xs => xs.flatMap (reach heap n)
    | .closure _ xs => xs.flatMap (reach heap n)
    | .ref c => c :: ((heap[c]?.getD []).flatMap (reach heap n))

/-- The visible binding of each name (shadowed ones are gone). -/
def visible (env : Env Value) : Env Value :=
  env.foldl (fun acc (x, v) => if acc.any (·.1 == x) then acc else acc ++ [(x, v)]) []

def noteWrite (env : Env Value) (c : Nat) : M Unit := do
  let s ← get
  let reaches := fun (v : Value) => (reach s.heap 64 v).contains c
  let names := ((env :: s.stack).map fun e => ((visible e).filter fun (_, v) => reaches v).length).sum +
    (s.kept.toList.filter reaches).length
  set { s with writes := s.writes + 1, aliased := s.aliased + (if names ≥ 2 then 1 else 0) }

def tick : M Unit := do
  let s ← get
  if s.fuel == 0 then throw "fuel"
  set { s with fuel := s.fuel - 1 }

def alloc (xs : List Value) : M Value := do
  let s ← get
  set { s with heap := s.heap.push xs }
  pure (.ref s.heap.size)

def array (c : Nat) : M (List Value) := do (← get).heap[c]?.toExcept "dangling"

def write (c : Nat) (xs : List Value) : M Value := do
  modify fun s => { s with heap := s.heap.set! c xs }
  pure (.ref c)

/-- A program-level write, noted only when it changes the array (as the
    interpreter's own write count). -/
def writeNoted (env : Env Value) (c : Nat) (xs : List Value) : M Value := do
  if !((← array c) == xs) then noteWrite env c
  write c xs

def prim (env : Env Value) (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .add, [.int a, .int b] => pure (.int (a + b))
  | .sub, [.int a, .int b] => pure (.int (a - b))
  | .eq, [.int a, .int b] => pure (.int (if a == b then 1 else 0))
  | .lt, [.int a, .int b] => pure (.int (if a < b then 1 else 0))
  | .record, xs => pure (.record xs)
  | .literal _, xs => alloc xs
  | .builder _, [] => alloc []
  | .shared, [v] => do modify fun s => { s with kept := s.kept.push v }; pure v
  | .length, [.ref c] => do pure (Value.int (← array c).length)
  | .at, [.ref c, .int i, fallback] => do
    let xs ← array c
    pure (if i < 0 then fallback else xs[i.toNat]?.getD fallback)
  | .set, [.ref c, .int i, v] => do
    let xs ← array c
    writeNoted env c (if i < 0 then xs else xs.set i.toNat v)
  | .push, [.ref c, v] => do writeNoted env c ((← array c) ++ [v])
  | .put, [.ref c, v] => do write c ((← array c) ++ [v])
  | .copy, [.ref c] => do alloc (← array c)
  | .close, [.ref c] => pure (.ref c)
  | .close, [.ref c, .ref source] => do
    if (← array c) == (← array source) then pure (.ref source) else pure (.ref c)
  | _, _ => throw "shape"

def call (env : Env Value) (m : M Value) : M Value := do
  modify fun s => { s with stack := env :: s.stack }
  let r ← m
  modify fun s => { s with stack := s.stack.drop 1 }
  pure r

def eval (depth : Nat) (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) : M Value := do
  if depth = 0 then throw "depth"
  else
    tick
    match e with
    | .atom a => InPlaceSemantics.atom env a
    | .letE v rhs rest =>
      let x ← eval (depth - 1) ds self env rhs
      eval (depth - 1) ds self ((v, x) :: env) rest
    | .prim op args => prim env op (← args.mapM (m := Except String) (InPlaceSemantics.atom env))
    | .closure id captures => pure (.closure id (← captures.mapM (m := Except String) (InPlaceSemantics.atom env)))
    | .app f args =>
      let .closure id caps ← InPlaceSemantics.atom env f | throw "call"
      let actuals ← args.mapM (m := Except String) (InPlaceSemantics.atom env)
      let d ← ds[id]?.toExcept "decl"
      call env (eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body)
    | .recur args =>
      let some (id, caps) := self | throw "recursion outside function"
      let actuals ← args.mapM (m := Except String) (InPlaceSemantics.atom env)
      let d ← ds[id]?.toExcept "decl"
      call env (eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body)
    | .branch a yes no =>
      let .int n ← InPlaceSemantics.atom env a | throw "condition"
      eval (depth - 1) ds self env (if n == 0 then yes else no)
    | .traverse kind src init i x acc body =>
      let input ← InPlaceSemantics.atom env src
      let n ← match kind, input with
        | .list, .ref c => do pure (← array c).length
        | .range, .int n => pure n.toNat
        | _, _ => throw "traversal"
      let mut a ← InPlaceSemantics.atom env init
      for j in [0:n + (← get).fuel + 1] do
        let more ← match input with
          | .ref c => do pure (decide (j < (← array c).length))
          | _ => pure (decide (j < n))
        if !more then break
        tick
        let v ← match input with
          | .ref c => do (← array c)[j]?.toExcept "length"
          | _ => pure (.int j)
        a ← eval (depth - 1) ds self ((i, .int j) :: (x, v) :: (acc, a) :: env) body
      pure a
    | .focus src index x body =>
      let .ref c ← InPlaceSemantics.atom env src | throw "focus"
      let .int i ← InPlaceSemantics.atom env index | throw "index"
      let xs ← array c
      if i < 0 then return .ref c
      match xs[i.toNat]? with
      | none => pure (.ref c)
      | some v =>
        let w ← eval (depth - 1) ds self ((x, v) :: env) body
        writeNoted env c ((← array c).set i.toNat w)
termination_by depth
decreasing_by all_goals simp_wf; omega

/-- Whether the in-place run of `p` writes an array two names reach. -/
def aliasedWrite (p : Program) (fuel := 100000) : Bool :=
  match (eval fuel p.declarations none [] p.main).run { fuel } with
  | .ok (_, s) => s.aliased > 0
  | .error _ => false

end Ownership.Aliasing
