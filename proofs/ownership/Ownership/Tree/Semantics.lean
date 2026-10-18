import Ownership.Tree.Syntax

/-! # The tree fragment: two interpreters

The value interpreter copies a list on every `push`; the in-place
interpreter keeps lists in a heap and appends to the array the receiver
names, as an in-place lowering would. A tree is immutable in both: only its
lists can change. Both observe the main expression's value, the in-place one
by reading every array it reaches at the end. An accepted program whose two
observations differ is a soundness failure of the checker. -/

namespace Ownership.Tree

inductive Val where
  | list (xs : List Int)
  | leaf
  | node (l x r : Val)
  | pair (a b : Val)
  deriving DecidableEq, Repr, Inhabited

def getV (env : List (Var × Val)) (x : Var) : Except String Val :=
  match env.lookup x with
  | some v => .ok v
  | none => .error "unbound variable"

/-- Fuel decreases at every step, so the definition is structural. -/
def evalV (ds : List Decl) : Nat → List (Var × Val) → Expr → Except String Val
  | 0, _, _ => .error "fuel"
  | _ + 1, env, .var x => getV env x
  | _ + 1, _, .nil => .ok (.list [])
  | _ + 1, _, .lit n => .ok (.list [n])
  | _ + 1, _, .leaf => .ok .leaf
  | _ + 1, env, .node l x r => do .ok (.node (← getV env l) (← getV env x) (← getV env r))
  | _ + 1, env, .pair a b => do .ok (.pair (← getV env a) (← getV env b))
  | _ + 1, env, .push xs n => do
    let .list v ← getV env xs | throw "push of a non-list"
    .ok (.list (v ++ [n]))
  | f + 1, env, .call g args => do
    let some d := ds[g]? | throw "missing declaration"
    let vs ← args.mapM (getV env)
    evalV ds f (vs.zipIdx.map fun (v, i) => (i, v)) d.body
  | f + 1, env, .letE x rhs rest => do
    let v ← evalV ds f env rhs
    evalV ds f ((x, v) :: env) rest
  | f + 1, env, .caseTree t l x r a b => do
    match ← getV env t with
    | .leaf => evalV ds f env a
    | .node lv xv rv => evalV ds f ((l, lv) :: (x, xv) :: (r, rv) :: env) b
    | _ => throw "case of a non-tree"
  | f + 1, env, .casePair p a b body => do
    let .pair av bv ← getV env p | throw "case of a non-pair"
    evalV ds f ((a, av) :: (b, bv) :: env) body

/-- A heap value: lists are addresses. -/
inductive HVal where
  | ref (a : Nat)
  | leaf
  | node (l x r : HVal)
  | pair (a b : HVal)
  deriving DecidableEq, Repr, Inhabited

abbrev Heap := List (List Int)

def getH (env : List (Var × HVal)) (x : Var) : Except String HVal :=
  match env.lookup x with
  | some v => .ok v
  | none => .error "unbound variable"

def alloc (h : Heap) (xs : List Int) : HVal × Heap := (.ref h.length, h ++ [xs])

def evalH (ds : List Decl) : Nat → List (Var × HVal) → Heap → Expr → Except String (HVal × Heap)
  | 0, _, _, _ => .error "fuel"
  | _ + 1, env, h, .var x => do .ok (← getH env x, h)
  | _ + 1, _, h, .nil => .ok (alloc h [])
  | _ + 1, _, h, .lit n => .ok (alloc h [n])
  | _ + 1, _, h, .leaf => .ok (.leaf, h)
  | _ + 1, env, h, .node l x r => do .ok (.node (← getH env l) (← getH env x) (← getH env r), h)
  | _ + 1, env, h, .pair a b => do .ok (.pair (← getH env a) (← getH env b), h)
  | _ + 1, env, h, .push xs n => do
    let .ref a ← getH env xs | throw "push of a non-list"
    let some v := h[a]? | throw "dangling address"
    .ok (.ref a, h.set a (v ++ [n]))
  | f + 1, env, h, .call g args => do
    let some d := ds[g]? | throw "missing declaration"
    let vs ← args.mapM (getH env)
    evalH ds f (vs.zipIdx.map fun (v, i) => (i, v)) h d.body
  | f + 1, env, h, .letE x rhs rest => do
    let (v, h) ← evalH ds f env h rhs
    evalH ds f ((x, v) :: env) h rest
  | f + 1, env, h, .caseTree t l x r a b => do
    match ← getH env t with
    | .leaf => evalH ds f env h a
    | .node lv xv rv => evalH ds f ((l, lv) :: (x, xv) :: (r, rv) :: env) h b
    | _ => throw "case of a non-tree"
  | f + 1, env, h, .casePair p a b body => do
    let .pair av bv ← getH env p | throw "case of a non-pair"
    evalH ds f ((a, av) :: (b, bv) :: env) h body

/-- Read every array a heap value reaches. -/
def observe (h : Heap) : HVal → Val
  | .ref a => .list (h[a]?.getD [])
  | .leaf => .leaf
  | .node l x r => .node (observe h l) (observe h x) (observe h r)
  | .pair a b => .pair (observe h a) (observe h b)

def fuel : Nat := 10000

def runValue (p : Program) : Except String Val :=
  match p.main with
  | some m => evalV p.decls fuel [] m
  | none => .error "no main"

def runInPlace (p : Program) : Except String Val :=
  match p.main with
  | some m => (evalH p.decls fuel [] [] m).map fun (v, h) => observe h v
  | none => .error "no main"

/-- The two observations agree: the same value, or both fail. -/
def agree (p : Program) : Bool :=
  match runValue p, runInPlace p with
  | .ok a, .ok b => a == b
  | .error _, .error _ => true
  | _, _ => false

end Ownership.Tree
