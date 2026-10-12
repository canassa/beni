import Ownership.Oracle

/-! # Bounded-exhaustive enumeration (SmallCheck style)

The random generator draws programs from hand-written shapes, and reviewers
kept finding shapes it does not draw. This module enumerates **every** typed
program of a small grammar up to a bound on its length, and runs each one the
checker accepts in both interpreters: an accepted disagreement is a failure.

A program is a fixed prelude `let 0 = [1]; let 1 = [2]; let 2 = [0, 1]; let 3 =
[3]` followed by `bound` or
fewer bindings, each a right-hand side drawn from the templates below over
every in-scope operand of the right type, and ends in one of three
observations: the last binding, the last two bindings as a record, or every
binding as a record. The declarations are generator v5's fixed table
(`Generator.decls`), which holds plain list functions, capturing closures, once
closures, a closure over a closure, a closure beside a once closure, a factory
of nested closures, a declaration returning either a closure or its function
input, higher-order callees and map, update and foldl. Programs that differ
only in a binding the observation never reaches are still enumerated: the
enumeration is over syntax, not over behaviour. A template that needs a helper
closure (map's callee, a nested closure) binds it in a `let` inside the
right-hand side, numbered above every program variable, so it never shadows. -/

namespace Ownership.Enumerate

open Generator (tL tN tR fIL fII fLL)

private def v := Atom.var

/-- Atoms of a type: variables, and for lists also the fields of records. -/
def operands (env : List (Var × Ty)) (t : Ty) : List Atom :=
  let vars := env.filterMap fun (x, u) => if u == t then some (v x) else none
  if t == tL then vars ++ env.flatMap fun (x, u) => if u == tR then [.field (v x) 0, .field (v x) 1] else []
  else vars

def ints : List Atom := [.int 0, .int 1]

/-- Every right-hand side of one binding over `env`; helper closures are
    numbered from `tmp`. -/
def choices (env : List (Var × Ty)) (tmp : Nat) : List (Expr × Ty) :=
  let ls := operands env tL
  let ns := operands env tN
  let rs := operands env tR
  let fil := operands env fIL
  let fii := operands env fII
  let fll := operands env fLL
  let t0 := tmp
  let t1 := tmp + 1
  let pairs := fun (xs : List Atom) => xs.flatMap fun x => xs.map fun y => (x, y)
  -- `branch 0 x y` behaves as `branch 1 y x` and the checker treats both
  -- arms alike, and `branch c x x` as `x`: one canonical form each, the
  -- condition 1 over ordered pairs of different operands.
  let arms := fun (xs : List Atom) => (pairs xs).filter fun (x, y) => x != y
  -- lists
  [(.prim (.literal .int) [.int 1], tL)] ++
  ls.map (fun x => (.prim .push [x, .int 1], tL)) ++
  ls.map (fun x => (.prim .set [x, .int 0, .int 3], tL)) ++
  ls.map (fun x => (.prim .copy [x], tL)) ++
  ls.map (fun x => (.prim .length [x], Ty.int)) ++
  ls.map (fun x => (.prim .shared [x], tL)) ++
  ls.map (fun x => (.letE t0 (.prim (.builder .int) []) (.prim .close [v t0, x]), tL)) ++
  (pairs ls).map (fun (x, y) => (.prim (.literal tL) [x, y], tN)) ++
  (pairs ls).map (fun (x, y) => (.prim .record [x, y], tR)) ++
  -- nested lists
  ns.flatMap (fun n => ls.map fun x => (.prim .push [n, x], tN)) ++
  ns.flatMap (fun n => ints.flatMap fun i => ls.map fun x => (.prim .set [n, i, x], tN)) ++
  ns.flatMap (fun n => ls.map fun x => (.prim .at [n, .int 0, x], tL)) ++
  ns.map (fun n => (.prim .copy [n], tN)) ++
  ns.map (fun n => (.prim .shared [n], tN)) ++
  ns.map (fun n => (.focus n (.int 0) t0 (.prim .push [v t0, .int 1]), tN)) ++
  ns.flatMap (fun n => ls.map fun x => (.focus n (.int 0) t0 (.atom x), tN)) ++
  ns.map (fun n => (.traverse .list n (.int 0) t0 t1 (t0 + 2)
    (.letE (t0 + 3) (.prim .push [v t1, .int 1]) (.letE (t0 + 4) (.prim .length [v (t0 + 3)])
      (.prim .add [v (t0 + 2), v (t0 + 4)]))), .int)) ++
  rs.map (fun r => (.prim .shared [r], tR)) ++
  -- closures
  ls.flatMap (fun x => [(.closure Generator.capGet [x], fIL), (.closure Generator.capPush [x], fIL),
    (.closure Generator.capLen [x], fII), (.closure Generator.capAppend [x], fLL)]) ++
  [(.closure Generator.bump [], fLL), (.closure Generator.identL [], fLL), (.closure Generator.publish [], fLL)] ++
  ls.flatMap (fun x => [Generator.capGet, Generator.capPush].map fun i =>
    (.letE t0 (.closure i [x]) (.closure Generator.capApply [v t0]), fIL)) ++
  (pairs ls).flatMap (fun (x, y) => [Generator.capGet, Generator.capPush].map fun i =>
    (.letE t0 (.closure i [y]) (.closure Generator.readCall [x, v t0]), fII)) ++
  ls.map (fun x => (.letE t0 (.closure Generator.mkNested []) (.app (v t0) [x]), fIL)) ++
  ints.flatMap (fun c => ls.flatMap fun x => fil.map fun f =>
    (.letE t0 (.closure Generator.chooseFn []) (.app (v t0) [c, x, f]), fIL)) ++
  fil.map (fun f => (.letE t0 (.prim .record [f, .int 0]) (.letE t1 (.prim .shared [v t0]) (.atom (.int 0))), .int)) ++
  -- calls
  fil.map (fun f => (.app f [.int 1], tL)) ++
  fii.map (fun f => (.app f [.int 1], .int)) ++
  fll.flatMap (fun h => ls.map fun x => (.app h [x], tL)) ++
  fll.flatMap (fun h => ls.map fun x => (.letE t0 (.closure Generator.apply1 []) (.app (v t0) [x, h]), tL)) ++
  fll.flatMap (fun h => ns.map fun n => (.letE t0 (.closure Generator.mapLL []) (.app (v t0) [n, h]), tN)) ++
  -- The same callees with a fixed callback made inline (one binding).
  [Generator.bump, Generator.identL].flatMap (fun cb => ns.flatMap fun n =>
    [(.letE t0 (.closure Generator.mapLL []) (.letE t1 (.closure cb []) (.app (v t0) [n, v t1])), tN),
     (.letE t0 (.closure Generator.updL []) (.letE t1 (.closure cb []) (.app (v t0) [n, .int 0, v t1])), tN)]) ++
  ls.flatMap (fun x => ls.map fun y =>
    (.letE t0 (.closure Generator.apply1 []) (.letE t1 (.closure Generator.capAppend [y]) (.app (v t0) [x, v t1])), tL)) ++
  fll.flatMap (fun h => ns.map fun n => (.letE t0 (.closure Generator.updL []) (.app (v t0) [n, .int 0, h]), tN)) ++
  ls.flatMap (fun x => ns.map fun n => (.letE t0 (.closure Generator.capCount [x])
    (.letE t1 (.closure Generator.foldLI []) (.app (v t1) [n, .int 0, v t0])), .int)) ++
  -- first-order callees over two lists, a record, a fold
  (pairs ls).map (fun (x, y) => (.letE t0 (.closure Generator.two []) (.app (v t0) [x, y]), .int)) ++
  rs.map (fun r => (.letE t0 (.closure Generator.readTwo []) (.app (v t0) [r]), .int)) ++
  [Generator.borrowOrGrow, Generator.grow].flatMap (fun s => ns.flatMap fun n => ls.map fun x =>
    (.letE t0 (.closure Generator.foldNL []) (.letE t1 (.closure s []) (.app (v t0) [n, x, v t1])), tL)) ++
  fll.flatMap (fun h => ls.map fun x => (.letE t0 (.closure Generator.applyThenRead []) (.app (v t0) [x, h]), tL)) ++
  fll.flatMap (fun h => ls.map fun x => (.letE t0 (.closure Generator.twiceVia []) (.app (v t0) [x, h]), tL)) ++
  -- a focus whose body writes its own container
  ns.flatMap (fun n => ls.map fun x => (.focus n (.int 0) t0 (.letE t1 (.prim .push [n, x]) (.atom (v t0))), tN)) ++
  -- conditionals
  (arms ls).map (fun (x, y) => (.branch (.int 1) (.atom x) (.atom y), tL)) ++
  (arms ns).map (fun (x, y) => (.branch (.int 1) (.atom x) (.atom y), tN)) ++
  (arms fil).map (fun (x, y) => (.branch (.int 1) (.atom x) (.atom y), fIL)) ++
  (arms ls).map (fun (x, y) =>
    (.branch (.int 1) (.closure Generator.capGet [x]) (.closure Generator.capGet [y]), fIL))

/-- The observations a program may end in. -/
def finals (bound : List Var) : List Expr :=
  match bound with
  | [] => [.atom (.int 0)]
  | [x] => [.atom (v x)]
  | x :: _ => [.atom (v x), .prim .record (bound.reverse.map v)]

structure Counts where
  enumerated : Nat := 0
  typed : Nat := 0
  accepted : Nat := 0
  withWrite : Nat := 0
  mismatches : Nat := 0
  deriving Repr

/-- Two flat lists, a nested list holding both (rows a program may edit
    through the nested list or directly), and a third list nothing holds. -/
def prelude (rest : Expr) : Expr :=
  .letE 0 (.prim (.literal .int) [.int 1]) (.letE 1 (.prim (.literal .int) [.int 2])
    (.letE 2 (.prim (.literal tL) [v 0, v 1]) (.letE 3 (.prim (.literal .int) [.int 3]) rest)))

/-- The prelude's variables: the first enumerated binding is numbered after them. -/
def preludeSize : Nat := 4

/-- Visit every program of at most `bound` bindings after the prelude. -/
partial def walk (bound : Nat) (env : List (Var × Ty)) (vars : List Var) (next : Nat)
    (wrapE : Expr → Expr) (visit : Expr → IO Bool) : IO Bool := do
  for f in finals vars do
    if !(← visit (wrapE f)) then return false
  if bound == 0 then return true
  for (rhs, t) in choices env (1000 + 10 * next) do
    let ok ← walk (bound - 1) ((next, t) :: env) (next :: vars) (next + 1)
      (fun rest => wrapE (.letE next rhs rest)) visit
    if !ok then return false
  return true


def preludeEnv : List (Var × Ty) := [(3, tL), (2, tN), (1, tL), (0, tL)]

/-- How many programs `bound` enumerates (no checking). -/
def countOnly (bound : Nat) : IO Nat := do
  let n ← IO.mkRef 0
  let _ ← walk bound preludeEnv [] preludeSize prelude fun _ => do n.modify (· + 1); pure true
  n.get

def Counts.add (a b : Counts) : Counts :=
  { enumerated := a.enumerated + b.enumerated, typed := a.typed + b.typed,
    accepted := a.accepted + b.accepted, withWrite := a.withWrite + b.withWrite,
    mismatches := a.mismatches + b.mismatches }

/-- Check and run one subtree of the enumeration (`walk` from `wrapE`), with
    its own counters; stop when `stop` is set or a disagreement is found. -/
def subtree (config : Config) (stop : IO.Ref Bool) (bound : Nat) (env : List (Var × Ty)) (vars : List Var)
    (next : Nat) (wrapE : Expr → Expr) : IO (Counts × Option Program) := do
  let counts ← IO.mkRef ({} : Counts)
  let found ← IO.mkRef (none : Option Program)
  let visit := fun (main : Expr) => do
    if ← stop.get then return false
    let p : Program := { declarations := Generator.decls, main }
    counts.modify fun c => { c with enumerated := c.enumerated + 1 }
    if !(typesOf p).isOk then return true
    counts.modify fun c => { c with typed := c.typed + 1 }
    if !(Oracle.verdictOf p config).isOk then return true
    counts.modify fun c => { c with accepted := c.accepted + 1 }
    match Oracle.compare p 20000 with
    | .equal =>
      if InPlaceSemantics.writeCount p 20000 > 0 then counts.modify fun c => { c with withWrite := c.withWrite + 1 }
      return true
    | .inconclusive _ => return true
    | _ =>
      counts.modify fun c => { c with mismatches := c.mismatches + 1 }
      found.set (some p)
      stop.set true
      return false
  let _ ← walk bound env vars next wrapE visit
  pure (← counts.get, ← found.get)

/-- Enumerate, check and run, one task per first binding. Under a negative
    control (`config` with a mutant or an old rule) the run succeeds only on
    an accepted disagreement that the corrected checker rejects; otherwise
    any accepted disagreement fails. -/
def run (bound : Nat) (config : Config := {}) (quiet := false) (sourceMutant := false) : IO (Bool × Counts) := do
  -- In a source-mutant build the binary's own checker is the mutated one,
  -- so a disagreement cannot be re-checked here: it is the catch.
  let negative := sourceMutant || config.mutant.isSome || config.oldFreshRule || config.dropTraversalEscapes
  let start ← IO.monoMsNow
  let stop ← IO.mkRef false
  -- The programs with no binding after the prelude, here; every first
  -- binding's subtree in its own task.
  let (c0, f0) ← subtree config stop 0 preludeEnv [] preludeSize prelude
  let mut total := c0
  let mut found := f0
  if bound > 0 && found.isNone then
    let tasks ← (choices preludeEnv (1000 + 10 * preludeSize)).mapM fun (rhs, t) =>
      IO.asTask (prio := .dedicated) <|
        subtree config stop (bound - 1) ((preludeSize, t) :: preludeEnv) [preludeSize] (preludeSize + 1)
          (fun rest => prelude (.letE preludeSize rhs rest))
    for task in tasks do
      match ← IO.wait task with
      | .ok (c, f) =>
        total := total.add c
        if found.isNone then found := f
      | .error e => throw e
  let elapsed := (← IO.monoMsNow) - start
  let corrected := match found with
    | some p => !sourceMutant && (Oracle.verdictOf p { reinfer := config.reinfer }).isOk
    | none => false
  if let some p := found then
    IO.println s!"enumerate: accepted disagreement ({if sourceMutant then "source-mutant build, not re-checked" else if corrected then "the corrected checker ACCEPTS it too" else "the corrected checker rejects it"}):\n{repr p.main}"
  let ok := if negative then found.isSome && !corrected else found.isNone
  if !quiet || !ok then
    IO.println s!"enumerate bound={bound} enumerated={total.enumerated} typed={total.typed} accepted={total.accepted} with-write={total.withWrite} mismatches={total.mismatches} caught={found.isSome} elapsed-ms={elapsed}"
  pure (ok, total)

end Ownership.Enumerate
