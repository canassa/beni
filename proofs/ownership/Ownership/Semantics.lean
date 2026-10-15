import Ownership.Syntax

namespace Ownership

/-- Observations have no addresses and never refer back into a mutable heap. -/
inductive Observation where
  | int (n : Int)
  | record (fields : List Observation)
  | list (items : List Observation)
  | closure (decl : Nat) (captures : List Observation)
  deriving Repr, Inhabited

/-- A total structural comparison, also reducible by the proof kernel. -/
def Observation.equal (a b : Observation) : Bool :=
  match a, b with
  | .int x, .int y => x == y
  | .record xs, .record ys =>
    xs.length == ys.length && (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | .list xs, .list ys =>
    xs.length == ys.length && (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | .closure i xs, .closure j ys => i == j && xs.length == ys.length &&
    (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | _, _ => false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

instance : BEq Observation := ⟨Observation.equal⟩

/-- The nesting depth of an observation: exactly the fuel the in-place
    `snapshot` needs to produce it (an integer needs 1, a container one more
    than its deepest item). -/
def Observation.depth : Observation → Nat
  | .int _ => 1
  | .record xs | .list xs | .closure _ xs => 1 + (xs.attach.map fun x => x.val.depth).foldl max 0
termination_by o => sizeOf o
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals omega

/-- Both interpreters observe values only up to this depth and fail beyond
    it: the in-place `snapshot` runs out of fuel, and the value interpreter
    checks the same bound, so a deep value is an explicit failure of both runs
    rather than a disagreement (or a step the invariant could not relate). -/
def observationDepth : Nat := 256

structure Trace where
  reads : List Observation
  finalValue : Observation
  externalReads : List (List Observation) := []
  deriving Repr, BEq, Inhabited

namespace ValueSemantics

abbrev Value := Observation
structure State where
  fuel : Nat
  reads : Array Observation := #[]
  kept : Array Value := #[]
  externalReads : Array (List Observation) := #[]
abbrev M := StateT State (Except String)

def tick : M Unit := do
  let s ← get
  if s.fuel == 0 then throw "value execution exhausted fuel"
  set { s with fuel := s.fuel - 1 }

def observable (v : Value) : Except String Unit :=
  if v.depth > observationDepth then throw "snapshot exhausted depth" else pure ()

def read (v : Value) : M Unit := do
  observable v
  modify fun s => { s with reads := s.reads.push v }

/-- A permanent outside reader observes every completed expression. -/
def observeKept : M Unit := do
  let s ← get
  if !s.kept.isEmpty then
    s.kept.toList.forM (m := Except String) observable
    set { s with externalReads := s.externalReads.push s.kept.toList }

def atom (env : Env Value) : Atom → Except String Value
  | .int n => pure (.int n)
  | .var v => lookup env v
  | .field a i => do
    let .record xs ← atom env a | throw "value projection"
    xs[i]?.toExcept "value field"

def prim (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .ok _, [x] => pure (.record [.int 1, .int 0, x])
  | .err _, [x] => pure (.record [.int 0, x, .int 0])
  | .endChain _, [] => pure (.list [])
  | .link, [x, .list xs] => pure (.list (x :: xs))
  | .add, [.int a, .int b] => pure (.int (a + b))
  | .sub, [.int a, .int b] => pure (.int (a - b))
  | .eq, [.int a, .int b] => pure (.int (if a == b then 1 else 0))
  | .lt, [.int a, .int b] => pure (.int (if a < b then 1 else 0))
  | .privateRoot, [x] => pure x
  | .record, xs => pure (.record xs)
  | .literal _, xs => pure (.list xs)
  | .builder _, [] => pure (.list [])
  | .shared, [x] => do
    modify fun s => { s with kept := s.kept.push x }
    pure x
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
  | .prepend, [x, .list xs] => do
    read (.list xs)
    pure (.list (x :: xs))
  | .events, [.record [_, events]] => pure events
  | .owned _, [x, _] => pure x
  | .copy, [.list xs] => pure (.list xs)
  | .close, [.list xs] | .close, [.list xs, .list _] => pure (.list xs)
  | .construct spreads, vs => do
    let mut out : List Value := []
    for (v, spread) in vs.zip spreads do
      if spread then
        let .list xs := v | throw "value construction operand"
        out := out ++ xs
      else out := out ++ [v]
    pure (.list out)
  | .view front, [.list xs] => pure (.list (if front then xs.drop 1 else xs.dropLast))
  | _, _ => throw "value primitive shape"

def eval (depth : Nat) (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) : M Value := do
  if depth = 0 then throw "value execution exhausted depth"
  else
    tick
    let result ← do
      match e with
      | .atom a => atom env a
      | .letE v rhs rest =>
        let x ← eval (depth - 1) ds self env rhs
        eval (depth - 1) ds self ((v, x) :: env) rest
      | .prim op args => prim op (← args.mapM (m := Except String) (atom env))
      | .closure id captures => pure (.closure id (← captures.mapM (m := Except String) (atom env)))
      | .app f args =>
        let .closure id caps ← atom env f | throw "value call"
        let actuals ← args.mapM (m := Except String) (atom env)
        let d ← ds[id]?.toExcept "value missing declaration"
        eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
      | .recur args =>
        let some (id, caps) := self | throw "recursion outside function"
        let actuals ← args.mapM (m := Except String) (atom env)
        let d ← ds[id]?.toExcept "value missing declaration"
        eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
      | .entry initial retained model body =>
        let value ← eval (depth - 1) ds self env initial
        let kept ← retained.mapM (m := Except String) (atom env)
        modify fun s => {s with kept := s.kept ++ kept.toArray}
        eval (depth - 1) ds self ((model, value) :: env) body
      | .resultCase input err ok onError onSuccess =>
        let .record [.int tag, e, a] ← atom env input | throw "value result case"
        if tag == 0 then eval (depth - 1) ds self ((err, e) :: env) onError
        else eval (depth - 1) ds self ((ok, a) :: env) onSuccess
      | .chainCase input head tail onEnd onLink =>
        let .list xs ← atom env input | throw "value chain case"
        match xs with
        | [] => eval (depth - 1) ds self env onEnd
        | h :: t => eval (depth - 1) ds self ((head, h) :: (tail, .list t) :: env) onLink
      | .branch a yes no =>
        let .int n ← atom env a | throw "value condition"
        eval (depth - 1) ds self env (if n == 0 then yes else no)
      | .traverse kind src init i x acc body =>
        let input ← atom env src
        let values ← match kind, input with
          | .list, .list xs => do read (.int xs.length); pure xs
          | .range, .int n | .model, .int n => pure ((List.range n.toNat).map (fun i => .int i))
          | _, _ => throw "value traversal"
        let mut a ← atom env init
        for (v, n) in values.zipIdx do
          tick
          if kind == .list then read v
          a ← eval (depth - 1) ds self ((i, .int n) :: (x, v) :: (acc, a) :: env) body
        pure a
      | .focus src index x body =>
        let .list xs ← atom env src | throw "value focus"
        let .int i ← atom env index | throw "value index"
        if i < 0 then return .list xs
        match xs[i.toNat]? with
        | none => pure (.list xs)
        | some v =>
          read v
          let w ← eval (depth - 1) ds self ((x, v) :: env) body
          pure (.list (xs.set i.toNat w))
    observeKept
    pure result
termination_by depth
decreasing_by all_goals simp_wf; omega

def run (p : Program) (fuel := 100000) : Except String Trace := do
  let (v, s) ← (eval fuel p.declarations none [] p.main).run { fuel }
  observable v
  pure { reads := s.reads.toList, finalValue := v, externalReads := s.externalReads.toList }

end ValueSemantics

namespace InPlaceSemantics

inductive Value where
  | int (n : Int)
  | record (fields : List Value)
  | ref (address : Nat)
  | closure (decl : Nat) (captures : List Value)
  deriving Repr, Inhabited

/-- A total structural comparison, also reducible by the proof kernel. -/
def Value.equal (a b : Value) : Bool :=
  match a, b with
  | .int x, .int y => x == y
  | .record xs, .record ys =>
    xs.length == ys.length && (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | .ref x, .ref y => x == y
  | .closure i xs, .closure j ys => i == j && xs.length == ys.length &&
    (xs.attach.zip ys).all (fun (x, y) => x.val.equal y)
  | _, _ => false
termination_by sizeOf a
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem x.property
  all_goals simp_all +arith
  all_goals omega

instance : BEq Value := ⟨Value.equal⟩

/-- One call of a declaration, as the in-place run made it: the heap and the
    permanent observers before and after, the inputs and the result. -/
structure CallRecord where
  decl : Nat
  args : List Value
  caps : List Value
  preHeap : Array (List Value)
  preKept : Array Value
  postHeap : Array (List Value)
  postKept : Array Value
  result : Value

structure State where
  fuel : Nat
  heap : Array (List Value) := #[]
  reads : Array Observation := #[]
  kept : Array Value := #[]
  externalReads : Array (List Observation) := #[]
  /-- Program-level in-place writes that changed an array (`set`, `push`,
      focus write-back); builder `put` is excluded. A campaign statistic only,
      never compared. -/
  writes : Nat := 0
  /-- When set, every call of a declaration is recorded in `calls` (for the
      falsifier and campaign statistics); never compared, never read by the
      interpreter itself. -/
  logCalls : Bool := false
  calls : Array CallRecord := #[]
  /-- Views (`Prim.view`): `(view, source, front)`. A view is a heap array of
      its own whose contents are kept equal to its source's suffix (`front`)
      or prefix at every write, so every reader below is unchanged. A write to
      either side is seen by the other: the most aliased in-place lowering.
      Invariant: a view is linked only when made of a nonempty list (an empty
      one is a fresh `[]`), and no writer shortens an array, so a source keeps
      the element its view leaves out. A shortening writer (`pop`, `removeAt`)
      would need `viewOf` and `spliceUp` revisited. -/
  links : List (Nat × Nat × Bool) := []
abbrev M := StateT State (Except String)

def countWrite : M Unit := modify fun s => { s with writes := s.writes + 1 }

/-- Record a finished call of declaration `id` in the call log, when the run
    asked for one (`pre` is the state before the call). Calls are recorded as
    they return, so nested calls come before the call that made them. -/
def logCall (pre : State) (id : Nat) (actuals caps : List Value) (r : Value) : M Unit :=
  if pre.logCalls then
    modify fun s => { s with calls := s.calls.push (CallRecord.mk id actuals caps pre.heap pre.kept s.heap s.kept r) }
  else pure ()

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

/-- What a view of `source` holds: all but its first element, or all but its
    last. A view is made only of a nonempty list, and no writer shortens one. -/
def viewOf (front : Bool) (source : List Value) : List Value :=
  if front then source.drop 1 else source.dropLast

/-- After a write through a view, write its source to match, up to the
    array no view is made of; that array is returned. -/
def spliceUp : Nat → Nat → M Nat
  | 0, _ => throw "view chain exhausted fuel"
  | n + 1, c => do
    match (← get).links.find? (·.1 == c) with
    | none => pure c
    | some (_, source, front) =>
      let base ← array source
      let xs ← array c
      let _ ← write source (if front then base.take 1 ++ xs else xs ++ base.drop (base.length - 1))
      spliceUp n source

/-- Refresh every view of `c`, and theirs, from what `c` now holds. -/
def refreshDown : Nat → Nat → M Unit
  | 0, _ => throw "view chain exhausted fuel"
  | n + 1, c => do
    for (view, source, front) in (← get).links do
      if source == c then
        let _ ← write view (viewOf front (← array c))
        refreshDown n view

/-- A write that every view of the array, and every array it is a view of,
    sees. Without views it is exactly `write`. -/
def writeLinked (c : Nat) (xs : List Value) : M Value := do
  let r ← write c xs
  let s ← get
  if s.links.isEmpty then return r
  let root ← spliceUp (s.heap.size + 1) c
  refreshDown (s.heap.size + 1) root
  pure r

/-- A program-level write (`set`, `push`, focus write-back), counted only
    when it changes the array: an out-of-range `set` or a focus that stores
    the same element back is not an in-place write anyone could see. -/
def writeCounted (c : Nat) (xs : List Value) : M Value := do
  let old ← array c
  if !(old == xs) then countWrite
  writeLinked c xs

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
  let o ← snapshot (← get).heap observationDepth v
  modify fun s => { s with reads := s.reads.push o }

/-- Keep actual references, not snapshots made when a holder was registered. -/
def observeKept : M Unit := do
  let s ← get
  if !s.kept.isEmpty then
    let observations ← s.kept.toList.mapM (m := Except String) (snapshot s.heap observationDepth)
    set { s with externalReads := s.externalReads.push observations }

def atom (env : Env Value) : Atom → Except String Value
  | .int n => pure (.int n)
  | .var v => lookup env v
  | .field a i => do
    let .record xs ← atom env a | throw "in-place projection"
    xs[i]?.toExcept "in-place field"

def prim (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .ok _, [x] => pure (.record [.int 1, .int 0, x])
  | .err _, [x] => pure (.record [.int 0, x, .int 0])
  | .endChain _, [] => alloc []
  | .link, [x, .ref c] => do alloc (x :: (← array c))
  | .add, [.int a, .int b] => pure (.int (a + b))
  | .sub, [.int a, .int b] => pure (.int (a - b))
  | .eq, [.int a, .int b] => pure (.int (if a == b then 1 else 0))
  | .lt, [.int a, .int b] => pure (.int (if a < b then 1 else 0))
  | .privateRoot, [x] => pure x
  | .record, xs => pure (.record xs)
  | .literal _, xs => alloc xs
  | .builder _, [] => alloc []
  | .shared, [v] => do
    modify fun s => { s with kept := s.kept.push v }
    pure v
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
    writeCounted c (if i < 0 then xs else xs.set i.toNat v)
  | .push, [.ref c, v] => do writeCounted c ((← array c) ++ [v])
  | .put, [.ref c, v] => do write c ((← array c) ++ [v])
  | .prepend, [x, .ref c] => do
    let xs ← array c
    read (.ref c)
    alloc (x :: xs)
  | .events, [.record [_, events]] => pure events
  | .owned _, [x, _] => pure x
  | .copy, [.ref c] => do alloc (← array c)
  | .close, [.ref c] => pure (.ref c)
  | .close, [.ref c, .ref source] => do
    -- Dedicated, unobserved identity shortcut; both branches contain the same
    -- callback results. No ordinary user identity operation exists in this core.
    if (← array c) == (← array source) then pure (.ref source) else pure (.ref c)
  | .construct spreads, vs => do
    -- From the base, left to right (§3.2, thesis Change 1): the items before
    -- it go in front of it in one write, then each later operand is
    -- appended. A later spread is read as it is appended, element by element
    -- and with its length read each time. Nothing else runs meanwhile, so a
    -- spread grows during its own loop only if it shares the base's array,
    -- and then it grows forever: that run fails at once, as it would when
    -- any amount of fuel ran out.
    let b := spreads.idxOf true
    let .ref c := vs[b]?.getD (.int 0) | throw "in-place construction base"
    let before := vs.take b
    if !before.isEmpty then
      let _ ← writeCounted c (before ++ (← array c))
    for (v, spread) in (vs.zip spreads).drop (b + 1) do
      if spread then
        let .ref d := v | throw "in-place construction operand"
        let length := (← array d).length
        for j in [0:length] do
          let source ← array d
          if source.length != length then
            throw "in-place construction: a spread operand grows with its base"
          tick
          let x ← source[j]?.toExcept "construction operand changed length"
          let _ ← writeCounted c ((← array c) ++ [x])
        if (← array d).length != length then
          throw "in-place construction: a spread operand grows with its base"
      else
        let _ ← writeCounted c ((← array c) ++ [v])
    pure (.ref c)
  | .view front, [.ref c] => do
    let xs ← array c
    if xs.isEmpty then alloc []
    else
      let address := (← get).heap.size
      let r ← alloc (viewOf front xs)
      modify fun s => { s with links := s.links ++ [(address, c, front)] }
      pure r
  | _, _ => throw "in-place primitive shape"

def eval (depth : Nat) (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) : M Value := do
  if depth = 0 then throw "in-place execution exhausted depth"
  else
    tick
    let result ← do
      match e with
      | .atom a => atom env a
      | .letE v rhs rest =>
        let x ← eval (depth - 1) ds self env rhs
        eval (depth - 1) ds self ((v, x) :: env) rest
      | .prim op args => prim op (← args.mapM (m := Except String) (atom env))
      | .closure id captures => pure (.closure id (← captures.mapM (m := Except String) (atom env)))
      | .app f args =>
        let .closure id caps ← atom env f | throw "in-place call"
        let actuals ← args.mapM (m := Except String) (atom env)
        let d ← ds[id]?.toExcept "in-place missing declaration"
        let pre ← get
        let r ← eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
        logCall pre id actuals caps r
        pure r
      | .recur args =>
        let some (id, caps) := self | throw "recursion outside function"
        let actuals ← args.mapM (m := Except String) (atom env)
        let d ← ds[id]?.toExcept "in-place missing declaration"
        let pre ← get
        let r ← eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
        logCall pre id actuals caps r
        pure r
      | .entry initial retained model body =>
        let value ← eval (depth - 1) ds self env initial
        let kept ← retained.mapM (m := Except String) (atom env)
        modify fun s => {s with kept := s.kept ++ kept.toArray}
        eval (depth - 1) ds self ((model, value) :: env) body
      | .resultCase input err ok onError onSuccess =>
        let .record [.int tag, e, a] ← atom env input | throw "in-place result case"
        if tag == 0 then eval (depth - 1) ds self ((err, e) :: env) onError
        else eval (depth - 1) ds self ((ok, a) :: env) onSuccess
      | .chainCase input head tail onEnd onLink =>
        let .ref c ← atom env input | throw "in-place chain case"
        match (← array c) with
        | [] => eval (depth - 1) ds self env onEnd
        | h :: t =>
          let rest ← alloc t
          eval (depth - 1) ds self ((head, h) :: (tail, rest) :: env) onLink
      | .branch a yes no =>
        let .int n ← atom env a | throw "in-place condition"
        eval (depth - 1) ds self env (if n == 0 then yes else no)
      | .traverse kind src init i x acc body =>
        let input ← atom env src
        let n ← match kind, input with
          | .list, .ref c => do
            let n := (← array c).length
            read (.int n)
            pure n
          | .range, .int n | .model, .int n => pure n.toNat
          | _, _ => throw "in-place traversal"
        let mut a ← atom env init
        -- A list source is read as a runtime iterates an array: its length
        -- and element `j` are read before step `j`, never taken from a copy
        -- made when the loop began. If a step grows the source the loop runs
        -- on, until fuel ends it (each step ticks).
        for j in [0:n + (← get).fuel + 1] do
          let more ← match input with
            | .ref c => do pure (decide (j < (← array c).length))
            | _ => pure (decide (j < n))
          if !more then break
          -- Every step that does not break ticks first: that, not the bound
          -- above, is what ends a loop over a source that keeps growing.
          tick
          let v ← match input with
            | .ref c => do
              let v ← (← array c)[j]?.toExcept "traversal source changed length"
              read v
              pure v
            | _ => pure (.int j)
          a ← eval (depth - 1) ds self ((i, .int j) :: (x, v) :: (acc, a) :: env) body
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
          let w ← eval (depth - 1) ds self ((x, v) :: env) body
          -- Re-read the container: the body may have written it (through a
          -- capture), and a runtime stores the element into the array as it
          -- is now, not into a copy taken before the body ran.
          writeCounted c ((← array c).set i.toNat w)
    observeKept
    pure result
termination_by depth
decreasing_by all_goals simp_wf; omega

def run (p : Program) (fuel := 100000) : Except String Trace := do
  let (v, s) ← (eval fuel p.declarations none [] p.main).run { fuel }
  let finalValue ← snapshot s.heap observationDepth v
  pure { reads := s.reads.toList, finalValue, externalReads := s.externalReads.toList }

/-- Number of program-level in-place writes an execution performs. -/
def writeCount (p : Program) (fuel := 100000) : Nat :=
  match (eval fuel p.declarations none [] p.main).run { fuel } with
  | .ok (_, s) => s.writes
  | .error _ => 0

end InPlaceSemantics
end Ownership
