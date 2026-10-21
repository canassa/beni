import Ownership.Domain
import Ownership.Semantics

/-! Concrete write diagnostics. This module checks a conservative superset of
q4's unsafe condition. Read-only view/source aliases remain legal. A hit needs
classification; an incomplete run never contributes a clean result. -/

namespace Ownership.Diagnostics

open InPlaceSemantics

inductive ReaderKind where
  | value (root : Value)
  | header (address : Nat)
  | suffix (address first : Nat)
  | siblings (address selected : Nat)
  deriving Repr

structure Reader where
  kind : ReaderKind
  site : List Nat := []
  reason : String
  binding : Option Var := none
  fieldPath : Path := []
  deriving Repr

structure Hit where
  site : List Nat
  operation : String
  receiver : Nat
  counterpart : Nat
  reader : Reader
  before : List Value
  after : List Value
  receiverChanged : Bool
  counterpartChanged : Bool
  deriving Repr

structure Report where
  attemptedWrites : Nat := 0
  changedWrites : Nat := 0
  linkedWrites : Nat := 0
  checkedReaders : Nat := 0
  hits : Array Hit := #[]
  incomplete : Array String := #[]
  deriving Repr

abbrev M := StateT Report InPlaceSemantics.M

/-- Lift a real runtime operation without a diagnostic mutation. -/
def runtime (action : InPlaceSemantics.M α) : M α := fun report => do
  let value ← action
  pure (value, report)

def fromExcept (action : Except String α) : M α := runtime fun state => do
  let value ← action
  pure (value, state)

/-- Direct array references, including nested records and closure captures. -/
def directRefs : Value → List Nat
  | .int _ => []
  | .ref c => [c]
  | .record xs | .closure _ xs => xs.attach.flatMap fun x => directRefs x.val
termination_by v => sizeOf v
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals omega

/-- A finite worklist. Each address enters the queue at most once. The bound
is the complete vertex set's size, not a depth cutoff. A remaining queue fails. -/
def graph (bound : Nat) (next : Nat → Except String (List Nat))
    (roots : List Nat) : Except String (List Nat) := do
  let mut pending := roots.eraseDups
  let mut seen : List Nat := []
  for _ in [0:bound + 1] do
    match pending with
    | [] => return seen
    | c :: rest =>
      pending := rest
      let children ← next c
      seen := c :: seen
      for d in children do
        if !seen.contains d && !pending.contains d then pending := pending ++ [d]
  if !pending.isEmpty then throw "diagnostic graph exceeds its complete vertex bound"
  pure seen

def reach (heap : Array (List Value)) (roots : List Value) : Except String (List Nat) :=
  graph heap.size (fun c => do
    let xs ← heap[c]?.toExcept s!"diagnostic dangling reference {c}"
    pure (xs.flatMap directRefs)) (roots.flatMap directRefs)

def component (heap : Array (List Value)) (links : List (Nat × Nat × Bool))
    (receiver : Nat) : Except String (List Nat) :=
  graph heap.size (fun c => do
    let _ ← heap[c]?.toExcept s!"diagnostic dangling link endpoint {c}"
    pure (links.flatMap fun (v, s, _) =>
      (if v == c then [s] else []) ++ (if s == c then [v] else []))) [receiver]

def readerReach (heap : Array (List Value)) (reader : Reader) : Except String (List Nat) := do
  match reader.kind with
  | .value v => reach heap [v]
  | .header c =>
    let _ ← heap[c]?.toExcept s!"diagnostic dangling reader header {c}"
    pure [c]
  | .suffix c first =>
    let xs ← heap[c]?.toExcept s!"diagnostic dangling suffix {c}"
    if first > xs.length then throw "diagnostic suffix starts beyond the current length"
    reach heap (xs.drop first)
  | .siblings c selected =>
    let xs ← heap[c]?.toExcept s!"diagnostic dangling siblings {c}"
    if selected ≥ xs.length then throw "diagnostic selected position no longer exists"
    reach heap (xs.zipIdx.filterMap fun (v, i) => if i == selected then none else some v)

/-- Live paths come from atom uses, so each step is a record field. Reject
an unsupported step instead of discarding a pending reader. -/
def project : Value → Path → Except String Value
  | v, [] => pure v
  | .record xs, .field i :: rest => do
    let v ← xs[i]?.toExcept "diagnostic pending field is absent"
    project v rest
  | _, _ => throw "diagnostic pending path has an unsupported shape"

def pending (env : Env Value) (after : Live) (site : List Nat) : M (List Reader) := do
  let mut readers : List Reader := []
  for (v, path) in after do
    match lookup env v >>= fun value => project value path with
    | .ok value => readers := readers ++ [{kind := .value value, site := site, reason := "continuation", binding := some v, fieldPath := path}]
    | .error error => modify fun r => {r with incomplete := r.incomplete.push s!"{site}: {error}"}
  pure readers

def values (site : List Nat) (reason : String) (vs : List Value) : List Reader :=
  vs.map fun v => {kind := .value v, site, reason}

/-- Compare a complete real write, including all linked refreshes. Diagnostic
records never alter the runtime state, reads, ticks, or write counter. -/
def writeEvent (site : List Nat) (operation : String) (receiver : Nat)
    (readers : List Reader) (action : InPlaceSemantics.M Value) : M Value := do
  let pre ← runtime get
  let result ← runtime action
  let post ← runtime get
  modify fun r => {r with attemptedWrites := r.attemptedWrites + 1}
  let members ← match component pre.heap pre.links receiver with
    | .ok members => pure members
    | .error error =>
      modify fun r => {r with incomplete := r.incomplete.push s!"{site}: {error}"}
      pure []
  let changed := members.filter fun c => pre.heap[c]? != post.heap[c]?
  if !changed.isEmpty then
    modify fun r => {r with changedWrites := r.changedWrites + 1}
  if members.length > 1 then
    modify fun r => {r with linkedWrites := r.linkedWrites + 1}
  let allReaders := readers ++ values site "permanent observer" pre.kept.toList
  for reader in allReaders do
    match readerReach pre.heap reader with
    | .error error => modify fun r => {r with incomplete := r.incomplete.push s!"{site}: {error}"}
    | .ok reachable =>
      modify fun r => {r with checkedReaders := r.checkedReaders + 1}
      -- Even a no-op or a disjoint write produces a conservative hit.
      -- Classification uses both change flags; no live counterpart is hidden.
      for c in members do
        if c != receiver && reachable.contains c then
          modify fun r => {r with hits := r.hits.push {
            site, operation, receiver, counterpart := c, reader,
            before := pre.heap[c]?.getD [], after := post.heap[c]?.getD [],
            receiverChanged := pre.heap[receiver]? != post.heap[receiver]?,
            counterpartChanged := pre.heap[c]? != post.heap[c]?}}
  pure result

/-- The construction helper supplies pending operands at each real append. -/
def constructionReaders (site : List Nat) (reads : ConstructionReads) : List Reader :=
  values site "construction operand" reads.values ++
  (reads.header.toList.map fun c => {kind := .header c, site, reason := "spread length"}) ++
  (reads.suffix.toList.map fun (c, first) => {kind := .suffix c first, site, reason := "spread suffix"})

def primitive (site : List Nat) (held : List Reader) (op : Prim) (vs : List Value) : M Value := do
  match op, vs with
  | .set, [.ref c, .int i, v] => do
    let xs ← runtime (array c)
    writeEvent site "set" c (held ++ values site "stored operand" [v])
      (writeCounted c (if i < 0 then xs else xs.set i.toNat v))
  | .push, [.ref c, v] => do
    let xs ← runtime (array c)
    writeEvent site "push" c (held ++ values site "stored operand" [v]) (writeCounted c (xs ++ [v]))
  | .dictInsert, [.ref c, .int k, v] => do
    let es ← runtime (array c)
    writeEvent site "dict-insert" c (held ++ values site "stored operand" [v])
      (writeCounted c (dictPut entryKey es k (.record [.int k, v])))
  | .dictRemove, [.ref c, .int k] => do
    let es ← runtime (array c)
    writeEvent site "dict-remove" c held (writeCounted c (dictDrop entryKey es k))
  | .put, [.ref c, v] => do
    let xs ← runtime (array c)
    writeEvent site "put" c (held ++ values site "stored operand" [v]) (write c (xs ++ [v]))
  | .construct spreads, operands =>
    constructWith (fun c => runtime (array c))
      (fun reads c xs => writeEvent site "construct" c (held ++ constructionReaders site reads) (writeCounted c xs))
      spreads operands
  | _, _ => runtime (InPlaceSemantics.prim op vs)

/-- Recursive calls reuse captures even when no explicit argument names them. -/
def containsRecur : Expr → Bool
  | .recur _ => true
  | .letE _ a b | .branch _ a b | .entry a _ _ b |
    .resultCase _ _ _ a b | .chainCase _ _ _ a b => containsRecur a || containsRecur b
  | .traverse _ _ _ _ _ _ body | .focus _ _ _ body | .dictFocus _ _ _ body => containsRecur body
  | _ => false

/-- Pin inherited uses before a local binder changes their environment. -/
def shadowed (env : Env Value) (after : Live) (binders : List Var)
    (site : List Nat) : M (List Reader) :=
  pending env (after.filter fun (v, _) => binders.contains v) site

/-- The ordinary control flow, with pending readers around real operations.
`held` crosses runtime frames. `after` names uses in the current environment. -/
def eval (depth : Nat) (ds : List Decl) (self : Option (Nat × List Value))
    (env : Env Value) (e : Expr) (after : Live) (held : List Reader)
    (site : List Nat) : M Value := do
  if depth = 0 then throw "in-place execution exhausted depth"
  else
    runtime tick
    -- This overestimate also protects an unselected recursive arm. Hits retain
    -- their reason for classification; no implicit capture can disappear.
    let held := held ++ (match self with
      | some (_, caps) => if containsRecur e then values site "future recursion capture" caps else []
      | none => [])
    let result ← do
      match e with
      | .atom a => fromExcept (atom env a)
      | .letE v rhs rest =>
        let x ← eval (depth - 1) ds self env rhs
          (union after (removeVars [v] (uses rest))) held (site ++ [0])
        let pinned ← shadowed env after [v] site
        eval (depth - 1) ds self ((v, x) :: env) rest (removeVars [v] after)
          (held ++ pinned) (site ++ [1])
      | .prim op args =>
        let operands ← fromExcept (args.mapM (m := Except String) (atom env))
        let readers ← pending env after site
        primitive site (held ++ readers) op operands
      | .closure id captures =>
        pure (.closure id (← fromExcept (captures.mapM (m := Except String) (atom env))))
      | .app f args =>
        let .closure id caps ← fromExcept (atom env f) | throw "in-place call"
        let actuals ← fromExcept (args.mapM (m := Except String) (atom env))
        let d ← fromExcept (ds[id]?.toExcept "in-place missing declaration")
        let pre ← runtime get
        let readers ← pending env after site
        let r ← eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
          [] (held ++ readers) (site ++ [2, id])
        runtime (logCall pre id actuals caps r)
        pure r
      | .recur args =>
        let some (id, caps) := self | throw "recursion outside function"
        let actuals ← fromExcept (args.mapM (m := Except String) (atom env))
        let d ← fromExcept (ds[id]?.toExcept "in-place missing declaration")
        let pre ← runtime get
        let readers ← pending env after site
        let r ← eval (depth - 1) ds (some (id, caps)) (bindArgs (actuals ++ caps)) d.body
          [] (held ++ readers) (site ++ [3, id])
        runtime (logCall pre id actuals caps r)
        pure r
      | .entry initial retained model body =>
        let initialAfter := union after (union (atomsUses retained) (removeVars [model] (uses body)))
        let value ← eval (depth - 1) ds self env initial initialAfter held (site ++ [4])
        let kept ← fromExcept (retained.mapM (m := Except String) (atom env))
        runtime (modify fun s => {s with kept := s.kept ++ kept.toArray})
        let pinned ← shadowed env after [model] site
        eval (depth - 1) ds self ((model, value) :: env) body (removeVars [model] after)
          (held ++ pinned) (site ++ [5])
      | .resultCase input err ok onError onSuccess =>
        let .record [.int tag, e, a] ← fromExcept (atom env input) | throw "in-place result case"
        if tag == 0 then
          let pinned ← shadowed env after [err] site
          eval (depth - 1) ds self ((err, e) :: env) onError (removeVars [err] after)
            (held ++ pinned) (site ++ [6])
        else
          let pinned ← shadowed env after [ok] site
          eval (depth - 1) ds self ((ok, a) :: env) onSuccess (removeVars [ok] after)
            (held ++ pinned) (site ++ [7])
      | .chainCase input head tail onEnd onLink =>
        let .ref c ← fromExcept (atom env input) | throw "in-place chain case"
        match (← runtime (array c)) with
        | [] => eval (depth - 1) ds self env onEnd after held (site ++ [8])
        | h :: t =>
          let rest ← runtime (alloc t)
          let pinned ← shadowed env after [head, tail] site
          eval (depth - 1) ds self ((head, h) :: (tail, rest) :: env) onLink
            (removeVars [head, tail] after) (held ++ pinned) (site ++ [9])
      | .branch a yes no =>
        let .int n ← fromExcept (atom env a) | throw "in-place condition"
        eval (depth - 1) ds self env (if n == 0 then yes else no) after held (site ++ [if n == 0 then 10 else 11])
      | .traverse kind src init i x acc body =>
        let input ← fromExcept (atom env src)
        let n ← match kind, input with
          | .list, .ref c => do
            let n := (← runtime (array c)).length
            runtime (read (.int n))
            pure n
          | .range, .int n | .model, .int n => pure n.toNat
          | _, _ => throw "in-place traversal"
        let mut a ← fromExcept (atom env init)
        let readers ← pending env (union after (removeVars [i, x, acc] (uses body))) site
        for j in [0:n + (← runtime get).fuel + 1] do
          let more ← match input with
            | .ref c => do pure (decide (j < (← runtime (array c)).length))
            | _ => pure (decide (j < n))
          if !more then break
          runtime tick
          let v ← match input with
            | .ref c => do
              let source ← runtime (array c)
              let v ← fromExcept (source[j]?.toExcept "traversal source changed length")
              runtime (read v)
              pure v
            | _ => pure (.int j)
          let loopReaders := match input with
            | .ref c => [{kind := .header c, site, reason := "traversal length"},
                {kind := .suffix c (j + 1), site, reason := "traversal suffix"}]
            | _ => []
          a ← eval (depth - 1) ds self ((i, .int j) :: (x, v) :: (acc, a) :: env) body
            [] (held ++ readers ++ loopReaders) (site ++ [12, j])
        pure a
      | .focus src index x body =>
        let .ref c ← fromExcept (atom env src) | throw "in-place focus"
        let .int i ← fromExcept (atom env index) | throw "in-place index"
        let xs ← runtime (array c)
        if i < 0 then return .ref c
        match xs[i.toNat]? with
        | none => pure (.ref c)
        | some v =>
          runtime (read v)
          let readers ← pending env after site
          let container := [{kind := .header c, site, reason := "focus container"},
            {kind := .siblings c i.toNat, site, reason := "focus siblings"}]
          let w ← eval (depth - 1) ds self ((x, v) :: env) body
            [] (held ++ readers ++ container) (site ++ [13])
          let current ← runtime (array c)
          writeEvent site "focus" c
            (held ++ readers ++ container ++ values site "stored operand" [w])
            (writeCounted c (current.set i.toNat w))
      | .dictFocus src key found body =>
        let .ref c ← fromExcept (atom env src) | throw "in-place dictionary focus"
        let .int k ← fromExcept (atom env key) | throw "in-place key"
        let current := (dictFind entryKey (← runtime (array c)) k).map entryValue
        if let some v := current then runtime (read v)
        let readers ← pending env after site
        let container := [{kind := .header c, site, reason := "dictionary focus container"}]
        let answer ← eval (depth - 1) ds self ((found, maybe current) :: env) body
          [] (held ++ readers ++ container) (site ++ [14])
        let entries ← runtime (array c)
        match answer with
        | .record [.int 1, _, w] =>
          writeEvent site "dict-focus" c
            (held ++ readers ++ container ++ values site "stored operand" [w])
            (writeCounted c (dictPut entryKey entries k (.record [.int k, w])))
        | .record [.int 0, _, _] =>
          writeEvent site "dict-focus" c (held ++ readers ++ container)
            (writeCounted c (dictDrop entryKey entries k))
        | _ => throw "in-place dictionary focus answer"
    runtime observeKept
    pure result
termination_by depth
decreasing_by all_goals simp_wf; omega

/-- Compare every runtime state field, including the complete call log. -/
def callEqual (a b : CallRecord) : Bool :=
  a.decl == b.decl && a.args == b.args && a.caps == b.caps &&
  a.preHeap == b.preHeap && a.preKept == b.preKept && a.preLinks == b.preLinks &&
  a.postHeap == b.postHeap && a.postKept == b.postKept && a.result == b.result

def stateEqual (a b : InPlaceSemantics.State) : Bool :=
  a.fuel == b.fuel && a.heap == b.heap && a.links == b.links && a.reads == b.reads &&
  a.kept == b.kept && a.externalReads == b.externalReads && a.writes == b.writes &&
  a.logCalls == b.logCalls && a.calls.size == b.calls.size &&
  (a.calls.toList.zip b.calls.toList).all (fun (x, y) => callEqual x y)

structure Options where
  enabled : Bool := false
  fuel : Nat := 100000
  logCalls : Bool := true

/-- The default executes the ordinary interpreter. Enabled diagnostics return
all runtime fields plus their separate report; failures retain the exact error. -/
def run (p : Program) (options : Options := {}) : Except String ((Value × InPlaceSemantics.State) × Report) :=
  if !options.enabled then do
    let valueState ← (InPlaceSemantics.eval options.fuel p.declarations none [] p.main).run
      {fuel := options.fuel, logCalls := options.logCalls}
    pure (valueState, {})
  else do
    let ((value, report), state) ← (eval options.fuel p.declarations none [] p.main [] [] []).run {} |>.run
      {fuel := options.fuel, logCalls := options.logCalls}
    pure ((value, state), report)

end Ownership.Diagnostics
