import Ownership.Library

/-! Generator v4: a general typed ANF family.

Every program shares one fixed declaration table (`decls`), ordinary core
declarations only; the main expression is a chain of randomly chosen moves over
a typed environment. Unlike the v3 `anf-chain`, the chain ends with a record of
a random subset of its variables, so most earlier values are dead at the end
and writes to them can be accepted. Moves cover closures with shared captures
called once or many times, list and range traversals that consume elements,
accumulators or captures, focus bodies that keep or break the shape, shallow
copies of nested lists, literals with repeated elements, aliased call operands,
and spine writes after `map`. The checker is never consulted. -/

namespace Ownership.Generator

abbrev Gen := StateM Nat

def draw (bound : Nat) : Gen Nat := do
  let s ← get
  let next := (s * 1664525 + 1013904223) % 4294967296
  set next
  pure ((next / 65536) % (max 1 bound))

def pick (xs : List α) (fallback : α) : Gen α := do
  pure (xs[← draw xs.length]?.getD fallback)

private def v := Atom.var

def tL : Ty := .list .int
def tN : Ty := .list tL
def tR : Ty := .record [tL, tL]
def fLL : Ty := .fn [tL] tL
def fIL : Ty := .fn [.int] tL
def fII : Ty := .fn [.int] .int
def fLLL : Ty := .fn [tL, tL] tL
def tNN : Ty := .list tN
def fNN : Ty := .fn [tN] tN
def fIN : Ty := .fn [.int] tN

/-- Declaration indices used by the moves below. -/
def mapLL := 0
def identL := 1
def bump := 2
def capPush := 3
def capLen := 4
def capGet := 5
def mapIL := 6
def two := 7
def foldNL := 8
def borrowOrGrow := 9
def grow := 10
def initL := 11
def freshRow := 12
def updL := 13
def capStep := 14
def readTwo := 15
def capPick := 16
def applyThenRead := 17
def foldKeep := 18
def mapVia := 19
def twiceVia := 20
def applyN := 21
def headBump := 22
def publish := 23
def pairShared := 24
def pairFresh := 25
def initN := 26
def identN := 27
def capAppend := 28

def decls : List Decl := [
  Library.map tL tL,
  { name := "identL", parameters := [tL], result := tL, body := .atom (v 0) },
  { name := "bump", parameters := [tL], result := tL, body := .prim .push [v 0, .int 9] },
  { name := "capPush", parameters := [.int], captures := [tL], result := tL,
    body := .prim .push [v 1, v 0] },
  { name := "capLen", parameters := [.int], captures := [tL], result := .int,
    body := .prim .length [v 1] },
  { name := "capGet", parameters := [.int], captures := [tL], result := tL, body := .atom (v 1) },
  Library.map .int tL,
  { name := "two", parameters := [tL, tL], result := .int,
    body := .letE 2 (.prim .push [v 0, .int 7]) (.prim .length [v 1]) },
  Library.foldl tL tL,
  { name := "borrowOrGrow", parameters := [tL, tL], result := tL,
    body := .letE 2 (.prim .length [v 1]) (.branch (v 2) (.atom (v 0)) (.prim .push [v 1, .int 7])) },
  { name := "grow", parameters := [tL, tL], result := tL,
    body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) },
  Library.initialize tL,
  { name := "freshRow", parameters := [.int], result := tL, body := .prim (.literal .int) [v 0] },
  Library.update tL,
  { name := "capStep", parameters := [tL, tL], captures := [tL], result := tL,
    body := .letE 3 (.prim .length [v 1]) (.branch (v 3) (.atom (v 2)) (.prim .push [v 1, .int 7])) },
  { name := "readTwo", parameters := [tR], result := .int,
    body := .letE 1 (.prim .push [.field (v 0) 0, .int 5]) (.prim .length [.field (v 0) 1]) },
  { name := "capPick", parameters := [tL, tL], captures := [tL], result := tL,
    body := .letE 3 (.prim .length [v 0]) (.branch (v 3) (.atom (v 2)) (.prim .push [v 1, .int 7])) },
  -- Hands its list to the callback, then reads the list again.
  { name := "applyThenRead", parameters := [tL, fLL], result := tL,
    body := .letE 2 (.app (v 1) [v 0]) <| .letE 3 (.prim .length [v 0]) (.prim .push [v 2, v 3]) },
  -- A fold that reads its rows again after the loop.
  { name := "foldKeep", parameters := [tN, tL, fLLL], result := tL,
    body := .letE 3 (.traverse .list (v 0) (v 1) 4 5 6 (.app (v 2) [v 5, v 6])) <|
      .letE 7 (.prim (.literal .int) []) <| .letE 8 (.prim .at [v 0, .int 0, v 7]) <|
      .letE 9 (.prim .length [v 8]) (.prim .push [v 3, v 9]) },
  -- Higher-order wrappers: each passes its own callback on to another call,
  -- so the callee's guards and supplies are forwarded to the wrapper's input.
  { name := "mapVia", parameters := [tN, fLL], result := tN,
    body := .letE 2 (.closure 0 []) (.app (v 2) [v 0, v 1]) },
  { name := "twiceVia", parameters := [tL, fLL], result := tL,
    body := .letE 2 (.app (v 1) [v 0]) (.app (v 1) [v 2]) },
  { name := "applyN", parameters := [tN, fNN], result := tN, body := .app (v 1) [v 0] },
  -- Requires its argument's contents exclusive (xreq): it edits inside them.
  { name := "headBump", parameters := [tN], result := tN,
    body := .letE 1 (.closure 13 []) <| .letE 2 (.closure 2 []) (.app (v 1) [v 0, .int 0, v 2]) },
  -- Escapes its argument (E) and returns it shared.
  { name := "publish", parameters := [tL], result := tL, body := .prim .shared [v 0] },
  -- Internally shared fresh result ([c, c]: xres false) and a distinct one.
  { name := "pairShared", parameters := [.int], result := tN,
    body := .letE 1 (.prim (.literal .int) [v 0]) (.prim (.literal tL) [v 1, v 1]) },
  { name := "pairFresh", parameters := [.int], result := tN,
    body := .letE 1 (.prim (.literal .int) [v 0]) <| .letE 2 (.prim (.literal .int) [v 0])
      (.prim (.literal tL) [v 1, v 2]) },
  Library.initialize tN,
  { name := "identN", parameters := [tN], result := tN, body := .atom (v 0) },
  -- A once callback: it pushes onto its capture.
  { name := "capAppend", parameters := [tL], captures := [tL], result := tL,
    body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) }]

abbrev Env := List (Atom × Ty)

def ofTy (env : Env) (t : Ty) : List Atom := env.filterMap fun (a, u) => if u == t then some a else none

/-- Lists include record fields, so records share cells with plain variables. -/
def listsOf (env : Env) : List Atom :=
  ofTy env tL ++ (ofTy env tR).flatMap fun r => [.field r 0, .field r 1]

def number (env : Env) : Gen Atom := do
  let ints := ofTy env .int
  if !ints.isEmpty && (← draw 4) == 0 then pick ints (.int 0)
  else pure (.int (Int.ofNat (← draw 4)))

def index : Gen Atom := do
  match ← draw 8 with
  | 0 => pure (.int (-1))
  | 1 => pure (.int 3)
  | n => pure (.int (Int.ofNat (n % 2)))

/-- One move: bindings to append at `next`, `next+1`, … Each right-hand side may
    refer to the earlier bindings of the same move. Scoped binders use numbers
    above 10000 derived from `next`, so they never collide. -/
abbrev Move := Nat → Env → Gen (List (Expr × Ty))

def sv (next k : Nat) : Var := 10000 + next * 8 + k

/-- Operands prefer the most recent binding of their type (probability 1/2), so
    moves chain: copy then focus, map then spine push, focus then focus. -/
def pickRecent (xs : List Atom) : Gen Atom := do
  if (← draw 2) == 0 then pure (xs.head?.getD (.var 0)) else pick xs (.var 0)

def anyList (env : Env) : Gen Atom := pickRecent (listsOf env)

def nestedOrNew (env : Env) : Gen (Option Atom) := do
  let ns := ofTy env tN
  if ns.isEmpty then pure none else some <$> pickRecent ns

/-- An Int list literal of 0–3 items (empty with probability 1/4). -/
def litList (env : Env) : Gen Expr := do
  let n ← draw 4
  let mut xs := []
  for _ in List.range n do xs := xs ++ [← number env]
  pure (.prim (.literal .int) xs)

/-- A nested list of 1–3 items. Each item is a fresh inner literal (3/4), a
    repeat of the previous item (1/8), or an existing list (1/8); the inner
    literals are bound first, so the result's items are often distinct cells
    and sometimes one cell twice. -/
def nestedBindings (next : Nat) (env : Env) : Gen (List (Expr × Ty)) := do
  let single := (← draw 4) == 0
  let extra ← draw 2
  let count := if single then 1 else 2 + extra
  let mut bs : List (Expr × Ty) := []
  let mut items : List Atom := []
  for _ in List.range count do
    match ← draw 8 with
    | 0 =>
      match items.getLast? with
      | some a => items := items ++ [a]
      | none => items := items ++ [← anyList env]
    | 1 => items := items ++ [← anyList env]
    | _ =>
      bs := bs ++ [(← litList env, tL)]
      items := items ++ [v (next + bs.length - 1)]
  pure (bs ++ [(.prim (.literal tL) items, tN)])

/-- Run `k` on an existing nested list or, if there is none, on a fresh one
    bound first; `k` receives the next free variable number. -/
def withNested (next : Nat) (env : Env) (k : Nat → Atom → Gen (List (Expr × Ty))) :
    Gen (List (Expr × Ty)) := do
  match ← nestedOrNew env with
  | some n => k next n
  | none =>
    let bs ← nestedBindings next env
    let after := next + bs.length
    pure (bs ++ (← k after (v (after - 1))))

/-- A list callback: identity, a writer, one that escapes its argument, or a
    once closure that pushes onto a captured list. -/
def listCallback (env : Env) : Gen (Expr × Ty) := do
  match ← draw 4 with
  | 0 => pure (.closure identL [], fLL)
  | 1 => pure (.closure bump [], fLL)
  | 2 => pure (.closure publish [], fLL)
  | _ => pure (.closure capAppend [← anyList env], fLL)

/-- Focus bodies: consume the element, keep it, or replace it by another cell. -/
def focusBody (env : Env) (x : Var) (next : Nat) : Gen Expr := do
  match ← draw 5 with
  | 0 => pure (.prim .push [v x, ← number env])
  | 1 => pure (.prim .set [v x, ← index, ← number env])
  | 2 => pure (.atom (v x))
  | 3 => pure (.atom (← anyList env))
  | _ => pure (.letE (sv next 7) (.prim .length [v x]) (.prim .push [v x, v (sv next 7)]))

def moves : List (String × Move) := [
  ("literal", fun _ env => do pure [(← litList env, tL)]),
  ("nested-literal", fun next env => nestedBindings next env),
  ("push", fun _ env => do pure [(.prim .push [← anyList env, ← number env], tL)]),
  ("spine-push", fun next env => withNested next env fun _ n => do
    pure [(.prim .push [n, ← anyList env], tN)]),
  ("set", fun _ env => do pure [(.prim .set [← anyList env, ← index, ← number env], tL)]),
  ("spine-set", fun next env => withNested next env fun _ n => do
    pure [(.prim .set [n, ← index, ← anyList env], tN)]),
  ("read", fun _ env => do pure [(.prim .at [← anyList env, ← index, .int 0], .int)]),
  ("read-element", fun next env => withNested next env fun _ n => do
    pure [(.prim .at [n, ← index, ← anyList env], tL)]),
  ("length", fun _ env => do pure [(.prim .length [← anyList env], .int)]),
  ("copy", fun _ env => do pure [(.prim .copy [← anyList env], tL)]),
  ("nested-copy", fun next env => withNested next env fun _ n => do pure [(.prim .copy [n], tN)]),
  ("record", fun _ env => do pure [(.prim .record [← anyList env, ← anyList env], tR)]),
  ("focus", fun next env => withNested next env fun next n => do
    let x := sv next 0
    pure [(.focus n (← index) x (← focusBody env x next), tN)]),
  ("element-move", fun next env => withNested next env fun next n => do
    let i ← draw 2
    let j ← if (← draw 4) == 0 then index else pure (Atom.int (Int.ofNat (1 - i)))
    pure [(.prim .at [n, j, ← anyList env], tL),
      (.focus n (.int (Int.ofNat i)) (sv next 0) (.atom (v next)), tN)]),
  ("traverse-consume", fun next env => withNested next env fun next n => do
    let (i, x, acc, y, k) := (sv next 0, sv next 1, sv next 2, sv next 3, sv next 4)
    pure [(.traverse .list n (.int 0) i x acc <|
      .letE y (.prim .push [v x, ← number env]) <|
      .letE k (.prim .length [v y]) (.prim .add [v acc, v k]), .int)]),
  ("traverse-read", fun next env => withNested next env fun next n => do
    let (i, x, acc, k) := (sv next 0, sv next 1, sv next 2, sv next 4)
    pure [(.traverse .list n (.int 0) i x acc <|
      .letE k (.prim .length [v x]) (.prim .add [v acc, v k]), .int)]),
  ("traverse-accumulate", fun next env => withNested next env fun next n => do
    let (i, x, acc, k) := (sv next 0, sv next 1, sv next 2, sv next 4)
    let fresh := (← draw 2) == 0
    let init ← if fresh then pure (v next) else anyList env
    let step ← match ← draw 4 with
      | 0 => pure (.letE k (.prim .length [v x]) (.prim .push [v acc, v k]))
      | 1 => pure (.letE k (.prim .length [v acc]) (.branch (v k) (.atom (v x)) (.prim .push [v acc, .int 7])))
      | 2 => pure (.prim .push [v acc, ← number env])
      | _ => do
        let c ← anyList env
        pure (.letE k (.prim .push [c, v i]) (.prim .push [v acc, .int 1]))
    let t : Expr := .traverse .list n init i x acc step
    pure (if fresh then [(.prim (.literal .int) [], tL), (t, tL)] else [(t, tL)])),
  ("traverse-range", fun next env => do
    let (i, x, acc, k) := (sv next 0, sv next 1, sv next 2, sv next 4)
    let count := Atom.int (Int.ofNat (1 + (← draw 3)))
    match ← draw 3 with
    | 0 => pure [(.prim (.literal .int) [], tL), (.traverse .range count (v next) i x acc (.prim .push [v acc, v i]), tL)]
    | 1 =>
      let c ← anyList env
      pure [(.traverse .range count (.int 0) i x acc <|
        .letE k (.prim .push [c, v i]) <| .letE (sv next 5) (.prim .length [v k])
          (.prim .add [v acc, v (sv next 5)]), .int)]
    | _ =>
      let c ← anyList env
      pure [(.traverse .range count (.int 0) i x acc <|
        .letE k (.prim .length [c]) (.prim .add [v acc, v k]), .int)]),
  ("traverse-list", fun next env => do
    let (i, x, acc) := (sv next 0, sv next 1, sv next 2)
    pure [(.traverse .list (← anyList env) (.int 0) i x acc (.prim .add [v acc, v x]), .int)]),
  ("closure", fun _ env => do
    let c ← anyList env
    match ← draw 3 with
    | 0 => pure [(.closure capPush [c], fIL)]
    | 1 => pure [(.closure capLen [c], fII)]
    | _ => pure [(.closure capGet [c], fIL)]),
  ("call", fun _ env => do
    let fs := ofTy env fIL ++ ofTy env fII
    if fs.isEmpty then pure [(.closure capGet [← anyList env], fIL)] else
    let f ← pick fs (.var 0)
    let t := if (ofTy env fIL).contains f then tL else .int
    pure [(.app f [← number env], t)]),
  ("map-lists", fun next env => withNested next env fun next n => do
    pure [(.closure mapLL [], .fn [tN, fLL] tN),
      (.closure (if (← draw 2) == 0 then identL else bump) [], fLL),
      (.app (v next) [n, v (next + 1)], tN)]),
  ("map-pipeline", fun next env => withNested next env fun next n => do
    -- Two calls of one map declaration with independently drawn callbacks,
    -- chained or over the same source: the second call meets a summary the
    -- first one computed.
    let chained := (← draw 2) == 0
    pure [(.closure mapLL [], .fn [tN, fLL] tN),
      (.closure (if (← draw 2) == 0 then identL else bump) [], fLL),
      (.closure (if (← draw 2) == 0 then identL else bump) [], fLL),
      (.app (v next) [n, v (next + 1)], tN),
      (.app (v next) [if chained then v (next + 3) else n, v (next + 2)], tN)]),
  ("fold-twice", fun next env => withNested next env fun next n => do
    -- Two reductions of the same rows with independently drawn steps, then
    -- possibly an edit of the second result.
    let step := fun (k : Nat) => if k == 0 then borrowOrGrow else grow
    let bs : List (Expr × Ty) := [(.closure foldNL [], .fn [tN, tL, fLLL] tL),
      (.closure (step (← draw 2)) [], fLLL), (.closure (step (← draw 2)) [], fLLL),
      (.prim (.literal .int) [], tL), (.prim (.literal .int) [], tL),
      (.app (v next) [n, v (next + 3), v (next + 1)], tL),
      (.app (v next) [n, v (next + 4), v (next + 2)], tL)]
    if (← draw 2) == 0 then pure (bs ++ [(.prim .push [v (next + 6), .int 3], tL)]) else pure bs),
  ("apply-read", fun next env => do
    pure [(.closure applyThenRead [], .fn [tL, fLL] tL), (← listCallback env),
      (.app (v next) [← anyList env, v (next + 1)], tL)]),
  ("map-via", fun next env => withNested next env fun next n => do
    pure [(.closure mapVia [], .fn [tN, fLL] tN), (← listCallback env),
      (.app (v next) [n, v (next + 1)], tN)]),
  ("twice-via", fun next env => do
    pure [(.closure twiceVia [], .fn [tL, fLL] tL), (← listCallback env),
      (.app (v next) [← anyList env, v (next + 1)], tL)]),
  ("apply-n", fun next env => withNested next env fun next n => do
    pure [(.closure applyN [], .fn [tN, fNN] tN),
      (.closure (if (← draw 3) == 0 then identN else headBump) [], fNN),
      (.app (v next) [n, v (next + 1)], tN)]),
  ("init-pairs", fun next env => do
    -- initialize over pairs, then an edit two levels down (T59's shape).
    let count := Atom.int (Int.ofNat (1 + (← draw 2)))
    let (x, y) := (sv next 0, sv next 1)
    pure [(.closure initN [], .fn [.int, fIN] tNN),
      (.closure (if (← draw 2) == 0 then pairShared else pairFresh) [], fIN),
      (.app (v next) [count, v (next + 1)], tNN),
      (.focus (v (next + 2)) (.int 0) x (.focus (v x) (.int 0) y (.prim .push [v y, .int 1])), tNN)]),
  ("fold-keep", fun next env => withNested next env fun next n => do
    let step ← match ← draw 3 with
      | 0 => pure (Expr.closure borrowOrGrow [])
      | 1 => pure (Expr.closure grow [])
      | _ => do pure (Expr.closure capPick [← anyList env])
    pure [(.prim (.literal .int) [], tL), (.closure foldKeep [], .fn [tN, tL, fLLL] tL), (step, fLLL),
      (.app (v (next + 1)) [n, v next, v (next + 2)], tL)]),
  ("map-ints", fun next env => do
    let fs := ofTy env fIL
    let src ← anyList env
    if !fs.isEmpty && (← draw 2) == 0 then
      pure [(.closure mapIL [], .fn [tL, fIL] tN), (.app (v next) [src, ← pick fs (.var 0)], tN)]
    else
      let g ← match ← draw 3 with
        | 0 => pure (Expr.closure freshRow [])
        | 1 => do pure (Expr.closure capGet [← anyList env])
        | _ => do pure (Expr.closure capPush [← anyList env])
      pure [(.closure mapIL [], .fn [tL, fIL] tN), (g, fIL), (.app (v next) [src, v (next + 1)], tN)]),
  ("aliased-call", fun next env => do
    let a ← anyList env
    let b ← if (← draw 2) == 0 then pure a else anyList env
    pure [(.closure two [], .fn [tL, tL] .int), (.app (v next) [a, b], .int)]),
  ("record-call", fun next env => do
    let a ← anyList env
    let b ← if (← draw 2) == 0 then pure a else anyList env
    pure [(.prim .record [a, b], tR), (.closure readTwo [], .fn [tR] .int), (.app (v (next + 1)) [v next], .int)]),
  ("fold", fun next env => withNested next env fun next n => do
    let fresh := (← draw 2) == 0
    let init ← if fresh then pure (v next) else anyList env
    let base := if fresh then next + 1 else next
    let step ← match ← draw 4 with
      | 0 => pure (Expr.closure borrowOrGrow [])
      | 1 => pure (Expr.closure grow [])
      | 2 => do pure (Expr.closure capStep [← anyList env])
      | _ => do pure (Expr.closure capPick [← anyList env])
    let call : List (Expr × Ty) := [(.closure foldNL [], .fn [tN, tL, fLLL] tL), (step, fLLL),
      (.app (v base) [n, init, v (base + 1)], tL)]
    pure (if fresh then (.prim (.literal .int) [], tL) :: call else call)),
  ("initialize", fun next env => do
    let fs := ofTy env fIL
    let count := Atom.int (Int.ofNat (1 + (← draw 3)))
    if !fs.isEmpty && (← draw 2) == 0 then
      pure [(.closure initL [], .fn [.int, fIL] tN), (.app (v next) [count, ← pick fs (.var 0)], tN)]
    else
      let g ← if (← draw 2) == 0 then pure (Expr.closure freshRow []) else do pure (Expr.closure capGet [← anyList env])
      pure [(.closure initL [], .fn [.int, fIL] tN), (g, fIL), (.app (v next) [count, v (next + 1)], tN)]),
  ("update", fun next env => withNested next env fun next n => do
    pure [(.closure updL [], .fn [tN, .int, fLL] tN),
      (.closure (if (← draw 2) == 0 then identL else bump) [], fLL),
      (.app (v next) [n, ← index, v (next + 1)], tN)]),
  ("shared", fun _ env => do pure [(.prim .shared [← anyList env], tL)]),
  ("branch", fun _ env => do
    pure [(.branch (← number env) (.prim .push [← anyList env, ← number env]) (.atom (← anyList env)), tL)])
]


/-- Container edits are drawn three times as often as other moves: they are
    where element sharing, focus shape and copies interact. -/
def weighted : List (String × Move) :=
  let heavy := ["focus", "element-move", "nested-literal", "nested-copy", "spine-push"]
  moves ++ (moves.filter (heavy.contains ·.1)) ++ (moves.filter (heavy.contains ·.1))

/-- The end of a chain keeps the latest binding and each other variable with
    probability 1/4. -/
def finish (env : Env) : Gen Expr := do
  let vars := env.filter fun (a, _) => match a with | .var _ => true | _ => false
  let mut kept : List Atom := (vars.head?.map Prod.fst).toList
  for (a, _) in vars.drop 1 do
    if (← draw 4) == 0 then kept := kept ++ [a]
  if kept.isEmpty then kept := [.int 0]
  pure (.prim .record kept)

/-- v5's end of a chain: as `finish`, but a function value is kept with
    probability 1/2, since observing a closure observes what it captured. -/
def finishV5 (env : Env) : Gen Expr := do
  let vars := env.filter fun (a, _) => match a with | .var _ => true | _ => false
  let mut kept : List Atom := (vars.head?.map Prod.fst).toList
  for (a, t) in vars.drop 1 do
    if (← draw (if containsFunction t then 2 else 4)) == 0 then kept := kept ++ [a]
  pure (.prim .record kept)

def atomRoot : Atom → Option Var
  | .var x => some x
  | .field a _ => atomRoot a
  | .int _ => none

/-- Argument positions a table declaration may write or keep: the list a map,
    update or `two` edits, a fold's accumulator. Sources a call only reads stay. -/
def handedArguments (d : Nat) : List Nat :=
  if d == two || d == readTwo || d == updL || d == applyThenRead || d == mapVia || d == twiceVia || d == applyN then [0]
  else if d == foldNL || d == foldKeep then [1] else []

/-- Operands a right-hand side may write or hand over: the target of a writer,
    a focus container and the cell a focus stores, a traversal's source and
    accumulator, a nested literal's items, the handed arguments of a call to a
    closure the same move made (`callee`), and the capture of a consuming
    closure. Purely syntactic; no checker involved. -/
def handedOver (callee : Var → Option Nat) : Expr → List Var
  | .prim .push (a :: _) | .prim .set (a :: _) => (atomRoot a).toList
  | .focus a _ _ body => (atomRoot a).toList ++
      (match body with | .atom b => (atomRoot b).toList | _ => [])
  | .traverse _ src init _ _ _ _ => (atomRoot src).toList ++ (atomRoot init).toList
  | .prim (.literal (.list _)) args => args.filterMap atomRoot
  | .app f args =>
    let positions := match atomRoot f >>= callee with
      | some d => if d < decls.length then handedArguments d else List.range args.length
      | none => List.range args.length
    positions.filterMap fun i => args[i]? >>= atomRoot
  | .closure d caps => if d == capPush then caps.filterMap atomRoot else []
  | .branch _ a b => handedOver callee a ++ handedOver callee b
  | _ => []

/-- After a move, each variable it handed over leaves the pool with probability
    3/4, so most generated programs use a written value linearly while a quarter
    of them reuse it. -/
def retire (env : Env) (gone : List Var) (protect := false) : Gen Env := do
  let mut out := env
  for x in gone do
    if (← draw 4) != 0 then
      let rest := out.filter fun (a, _) => atomRoot a != some x
      -- v5: never retire the last list, so a list operand always exists
      -- (in a declaration body variable 0 need not be a list).
      if !protect || !(listsOf rest).isEmpty then out := rest
  pure out

def bindAll (next : Nat) (env : Env) (bs : List (Expr × Ty))
    (rest : Nat → Env → Gen (List String × Expr)) : Gen (List String × Expr) :=
  match bs with
  | [] => rest next env
  | (rhs, t) :: more => do
    let (names, e) ← bindAll (next + 1) ((.var next, t) :: env) more rest
    return (names, .letE next rhs e)

/-- With probability 1/3 a move that ends in a nested list is followed at once
    by an in-place edit of that list: a consuming focus (2/3) or a spine push. -/
def followUp (next : Nat) (env : Env) (bs : List (Expr × Ty)) : Gen (List (Expr × Ty)) := do
  match bs.getLast? with
  | some (_, t) =>
    if t == tN && (← draw 3) == 0 then
      let n := v (next + bs.length - 1)
      let after := next + bs.length
      if (← draw 3) == 0 then
        pure (bs ++ [(.prim .push [n, ← anyList env], tN)])
      else
        let x := sv after 0
        let body ← match ← draw 3 with
          | 0 => pure (Expr.prim .push [v x, ← number env])
          | 1 => do pure (Expr.prim .set [v x, ← index, ← number env])
          | _ => pure (.letE (sv after 7) (.prim .length [v x]) (.prim .push [v x, v (sv after 7)]))
        pure (bs ++ [(.focus n (.int (Int.ofNat (← draw 2))) x body, tN)])
    else pure bs
  | none => pure bs


/-- A chain of moves drawn from `ms`, ended by `fin`. -/
def chainWith (ms : List (String × Move)) (protect : Bool) (fin : Nat → Env → Gen (List String × Expr)) :
    Nat → Nat → Env → Gen (List String × Expr)
  | 0, next, env => fin next env
  | fuel + 1, next, env => do
    let (name, move) ← pick ms ("literal", fun _ env => do pure [(← litList env, tL)])
    let bs ← move next env
    let bs ← followUp next env bs
    let callee := fun (x : Var) => match bs[x - next]? with
      | some (.closure d [], _) => if x ≥ next then some d else none
      | _ => none
    let gone := bs.flatMap (fun (rhs, _) => handedOver callee rhs)
    -- v5: a closure hands over its captures, and a function value passed
    -- to a call stays in the pool, so a callback may be used again after a
    -- callee called it.
    let gone := if !protect then gone else
      let fns := bs.zipIdx.filterMap fun ((_, t), i) => if containsFunction t then some (next + i) else none
      (gone.filter (!fns.contains ·)) ++
        bs.flatMap fun (rhs, _) => match rhs with | .closure _ cs => cs.filterMap atomRoot | _ => []
    let (names, e) ← bindAll next env bs fun next' env' => do
      chainWith ms protect fin fuel next' (← retire env' gone protect)
    return (name :: names, e)

def chain : Nat → Nat → Env → Gen (List String × Expr) :=
  chainWith weighted false (fun _ env => do return ([], ← finish env))

/-- A program of 1–12 moves after one fresh list (generator v4). -/
def general : Gen (List String × Program) := do
  let length ← draw 12
  let first ← litList []
  let (names, rest) ← chain (length + 1) 1 [(.var 0, tL)]
  return (names, { declarations := decls, main := .letE 0 first rest })

/-! ## Generator v5: conditionals over moves, and declarations of its own

Each program may carry a table of generated declarations after the fixed one:
functions over lists, nested lists and records that return a fresh value, a
parameter or a capture; higher-order functions that call their callback;
self-recursive functions with a decreasing counter; factories that return a
closure; rarely a mutually recursive pair (refused as a limit). Bodies are
chains of the same moves, and may call earlier generated declarations. A
conditional's arms are themselves chains of moves. -/

abbrev Table := List (Nat × Decl)

def fnTy (d : Decl) : Ty := .fn d.parameters d.result
def firstOrder (t : Ty) : Bool := !containsFunction t

/-- Bindings numbered from `next`, wrapped around `e`. -/
def wrap (next : Nat) (bs : List (Expr × Ty)) (e : Expr) : Expr :=
  bs.zipIdx.foldr (fun ((rhs, _), i) acc => .letE (next + i) rhs acc) e

def atomsOf (env : Env) (t : Ty) : List Atom :=
  if t == tL then listsOf env else ofTy env t

def extend (next : Nat) (bs : List (Expr × Ty)) (env : Env) : Env :=
  (bs.zipIdx.map fun ((_, u), i) => (Atom.var (next + i), u)).reverse ++ env

/-- A value of a first-order type the generator builds (Int, list, nested
    list, record of two lists): an existing one (2/3, preferring recent
    ones) or a fresh one bound first. -/
def valueOf (fresh : Bool) (next : Nat) (env : Env) (t : Ty) : Gen (List (Expr × Ty) × Atom) := do
  if t == .int then return ([], ← number env)
  let xs := atomsOf env t
  if !fresh && !xs.isEmpty && (← draw 3) != 0 then return ([], ← pickRecent xs)
  let bs ← if t == tN then nestedBindings next env
    else if t == tR then do pure [(.prim .record [← anyList env, ← anyList env], tR)]
    else do pure [(← litList env, tL)]
  return (bs, .var (next + bs.length - 1))

def firstOrderValues (fresh : Bool) (next : Nat) (env : Env) : List Ty → Gen (List (Expr × Ty) × List Atom)
  | [] => pure ([], [])
  | t :: ts => do
    let (bs, a) ← valueOf fresh next env t
    let (more, as) ← firstOrderValues fresh (next + bs.length) (extend next bs env) ts
    pure (bs ++ more, a :: as)

/-- Closures of the fixed table of type `t`, capturing lists from `env`. -/
def fixedCallbacks (env : Env) (t : Ty) : Gen (List Expr) := do
  if t == fLL then pure [.closure identL [], .closure bump [], .closure publish [], .closure capAppend [← anyList env]]
  else if t == fNN then pure [.closure identN [], .closure headBump []]
  else if t == fIL then pure [.closure capPush [← anyList env], .closure capGet [← anyList env], .closure freshRow []]
  else if t == fII then pure [.closure capLen [← anyList env]]
  else if t == fLLL then pure [.closure borrowOrGrow [], .closure grow [],
    .closure capStep [← anyList env], .closure capPick [← anyList env]]
  else if t == fIN then pure [.closure pairShared [], .closure pairFresh []]
  else pure []

def generatedOfType (table : Table) (t : Ty) : Table :=
  table.filter fun (_, d) => fnTy d == t && d.captures.all firstOrder

def hasCallback (table : Table) (t : Ty) : Bool :=
  [fLL, fNN, fIL, fII, fLLL, fIN].any (· == t) || !(generatedOfType table t).isEmpty

/-- A closure of type `t`: a fixed one, or a generated declaration of that
    type whose captures are chosen like arguments (often the same list the
    call passes, so a callback may capture its own argument). -/
def callbackOf (table : Table) (next : Nat) (env : Env) (t : Ty) : Gen (List (Expr × Ty) × Atom) := do
  let fixed ← fixedCallbacks env t
  let generated := generatedOfType table t
  let k ← draw (fixed.length + generated.length)
  match fixed[k]? with
  | some e => return ([(e, t)], .var next)
  | none =>
    match generated[k - fixed.length]? with
    | some (i, d) =>
      let (bs, caps) ← firstOrderValues false next env d.captures
      return (bs ++ [(.closure i caps, t)], .var (next + bs.length))
    | none => return ([(.closure identL [], fLL)], .var next)  -- unreachable: callers check hasCallback

def valuesOf (table : Table) (fresh : Bool) (next : Nat) (env : Env) : List Ty → Gen (List (Expr × Ty) × List Atom)
  | [] => pure ([], [])
  | t :: ts => do
    let (bs, a) ← if firstOrder t then valueOf fresh next env t else callbackOf table next env t
    let (more, as) ← valuesOf table fresh (next + bs.length) (extend next bs env) ts
    pure (bs ++ more, a :: as)

/-- Call `f : ps → r`, binding fresh arguments and callbacks first. A leading
    Int parameter may be a recursion counter: it gets a literal 0–3. -/
def callWith (table : Table) (fresh : Bool) (next : Nat) (env : Env) (f : Atom) (ps : List Ty) (r : Ty) (dup := true) :
    Gen (List (Expr × Ty)) := do
  let (bs, args) ← valuesOf table fresh next env ps
  let args ← if ps.head? == some .int then do pure (Atom.int (Int.ofNat (← draw 4)) :: args.drop 1)
    else pure args
  -- Half the time, a later argument repeats an earlier one of the same
  -- type: the callee then sees one array at two parameters.
  let args ← if dup && (← draw 2) == 0 then do
      let pairs := (ps.zip args).zipIdx.filter fun ((t, _), _) => firstOrder t && t != .int
      match pairs with
      | ((t, a), _) :: more =>
        match more.find? (fun ((u, _), _) => u == t) with
        | some (_, j) => pure (args.set j a)
        | none => pure args
      | [] => pure args
    else pure args
  pure (bs ++ [(.app f args, r)])

/-- Close over generated declaration `i` and call it. -/
def callDecl (table : Table) (fresh : Bool) (next : Nat) (env : Env) (i : Nat) (d : Decl) (dup := true) : Gen (List (Expr × Ty)) := do
  let (bs, caps) ← firstOrderValues fresh next env d.captures
  let at_ := next + bs.length
  let call ← callWith table fresh (at_ + 1) (extend next bs env) (.var at_) d.parameters d.result dup
  pure (bs ++ [(.closure i caps, fnTy d)] ++ call)

/-- Close over a generated declaration and call it. -/
def callGenerated (table : Table) : Move := fun next env => do
  let (i, d) ← pick table (0, default)
  callDecl table false next env i d

/-- The same with fresh arguments and captures: no live holder outside the
    call, so a generated declaration's own rows decide the verdict. -/
def callGeneratedFresh (table : Table) : Move := fun next env => do
  let (i, d) ← pick table (0, default)
  callDecl table true next env i d

/-- A fresh list first (the most recent list, so a callback built for the
    call often captures it), then a call of a generated declaration or a
    function value that takes a callback. -/
def higherCall (table : Table) : Move := fun next env => do
  let first := (← litList env, tL)
  let env' := (Atom.var next, tL) :: env
  let takesFn := fun (ps : List Ty) => ps.any (!firstOrder ·) && ps.all (fun p => firstOrder p || hasCallback table p)
  let gens := table.filter fun (_, d) => takesFn d.parameters
  let fs := env.filterMap fun (a, t) => match t with
    | .fn ps r => if takesFn ps then some (a, ps, r) else none
    | _ => none
  if !gens.isEmpty && (fs.isEmpty || (← draw 2) == 0) then
    let (i, d) ← pick gens (0, default)
    return first :: (← callDecl table false (next + 1) env' i d)
  if fs.isEmpty then return [first]
  let (f, ps, r) ← pick fs (.int 0, [], .int)
  return first :: (← callWith table false (next + 1) env' f ps r)

/-- Call any function value in scope: a closure made earlier, one a
    generated factory returned, or a function parameter of the body. -/
def applyAny (table : Table) : Move := fun next env => do
  let fs := env.filterMap fun (a, t) => match t with
    | .fn ps r => if ps.all (fun p => firstOrder p || hasCallback table p) then some (a, ps, r) else none
    | _ => none
  if fs.isEmpty then return [(← litList env, tL)]
  let (f, ps, r) ← pick fs (.int 0, [], .int)
  callWith table false next env f ps r

/-- `shared` on a nested list, then an element read out of it and pushed:
    the element is published with its container. -/
def sharedNested : Move := fun next env => withNested next env fun next n => do
  pure [(.prim .shared [n], tN), (.prim .at [n, .int 0, ← anyList env], tL),
    (.prim .push [v (next + 1), ← number env], tL)]

/-- `shared` on a record of lists, then a push onto one of its fields. -/
def sharedRecord : Move := fun next env => do
  let a ← anyList env
  let b ← anyList env
  pure [(.prim .record [a, b], tR), (.prim .shared [v next], tR),
    (.prim .push [.field (v next) (← draw 2), ← number env], tL)]

/-- Closures created in a conditional's arms capture a list written just
    before (or one written just after), and the chosen closure is called. -/
def branchClosure : Move := fun next env => do
  let a ← anyList env
  let other ← if (← draw 3) == 0 then anyList env else pure a
  let c ← number env
  let (id, t, r) ← pick [(capLen, fII, Ty.int), (capGet, fIL, tL)] (capLen, fII, .int)
  let br : Expr := .branch c (.closure id [a]) (.closure id [other])
  if (← draw 3) == 0 then
    pure [(br, t), (.prim .push [a, ← number env], tL), (.app (v next) [.int 0], r)]
  else
    pure [(.prim .push [a, ← number env], tL), (br, t), (.app (v (next + 1)) [.int 0], r)]

/-- A list and its pushed version, then a conditional choosing between them:
    the list written in place is read again only in one arm. -/
def branchWritten : Move := fun next env => do
  let a ← anyList env
  let n ← number env
  let other ← if (← draw 4) == 0 then anyList env else pure a
  let c ← number env
  let (yes, no) := if (← draw 2) == 0 then (Expr.atom other, Expr.atom (v next))
    else (.atom (v next), .atom other)
  pure [(.prim .push [a, n], tL), (.branch c yes no, tL)]

def finTy (t : Ty) : Nat → Env → Gen (List String × Expr) := fun next env => do
  let (bs, a) ← valueOf false next env t
  pure ([], wrap next bs (.atom a))

/-- A chain of `fuel` moves from `next`, ending in a value of type `t`. -/
def blockOf (ms : List (String × Move)) (fuel next : Nat) (env : Env) (t : Ty) : Gen Expr := do
  pure (← chainWith ms true (finTy t) fuel next env).2

/-- A conditional whose arms are chains of 0–2 moves. -/
def branchBlock (ms : List (String × Move)) : Move := fun next env => do
  let t ← pick [tL, tL, tN, .int] tL
  let c ← number env
  let yes ← blockOf ms (← draw 3) (next + 1) env t
  let no ← blockOf ms (← draw 3) (next + 1) env t
  pure [(.branch c yes no, t)]

/-- The moves of a v5 chain: v4's, conditionals, calls of any function value
    in scope, and (three times as often) calls of generated declarations. -/
def movesFor (table : Table) : List (String × Move) :=
  let gen := if table.isEmpty then [] else List.replicate 3 ("call-generated", callGenerated table) ++
    List.replicate 2 ("call-generated-fresh", callGeneratedFresh table)
  weighted ++ [("branch-written", branchWritten), ("branch-block", branchBlock weighted),
    ("apply-any", applyAny table), ("higher-call", higherCall table), ("higher-call", higherCall table),
    ("shared-nested", sharedNested), ("shared-record", sharedRecord),
    ("branch-closure", branchClosure)] ++ gen

/-- The environment of a body: parameters and captures, and a fresh list
    bound first at their count (so every list move has an operand). -/
def bodyEnv (inputs : List Ty) : Env :=
  (inputs.zipIdx.map fun (t, i) => (Atom.var i, t)).reverse ++ [(.var inputs.length, tL)]

def plainDecl (table : Table) (name : String) : Gen Decl := do
  let (ps, caps, r) ← if (← draw 2) == 0 then pure ([tL], [tL], tL)  -- a list callback with a capture
    else do
      let k := 1 + (← draw 3)
      let mut ps := []
      for _ in List.range k do ps := ps ++ [← pick [tL, tL, tN, tR, .int] tL]
      let caps ← match ← draw 3 with | 0 => pure [tL] | 1 => pure [tN] | _ => pure []
      pure (ps, caps, ← pick [tL, tL, tN, .int] tL)
  let n := ps.length + caps.length
  let env := bodyEnv (ps ++ caps)
  let first ← litList env
  let rest ← blockOf (movesFor table) (← draw 4) (n + 1) env r
  return { name := name, parameters := ps, captures := caps, result := r, body := .letE n first rest }

/-- Writes its first parameter in place before anything else: a push or set
    of a flat list, an element edit or a spine push of a nested list (storing
    the second parameter), then a chain of moves; returns the written list or
    a length. Calls of it change an array the caller passed. -/
def writerDecl (table : Table) (name : String) : Gen Decl := do
  let nested := (← draw 3) == 0
  let p0 := if nested then tN else tL
  let ps := [p0, tL]
  let env := bodyEnv ps
  let first ← litList env
  let n := ps.length
  let w : Expr ← if nested then
      match ← draw 2 with
      | 0 => pure (.prim .push [v 0, v 1])
      | _ => do pure (.focus (v 0) (.int 0) (sv (n + 1) 0) (.prim .push [v (sv (n + 1) 0), ← number env]))
    else
      match ← draw 3 with
      | 0 => pure (.letE (sv (n + 1) 1) (.prim .length [v 1]) (.prim .push [v 0, v (sv (n + 1) 1)]))
      | 1 => do pure (.prim .set [v 0, .int 0, ← number env])
      | _ => do pure (.prim .push [v 0, ← number env])
  let r ← pick [p0, p0, .int] p0
  let env' := (Atom.var (n + 1), p0) :: env
  let rest ← if (← draw 2) == 0 then
      pure (if r == .int then Expr.prim .length [v (n + 1)] else .atom (v (n + 1)))
    else blockOf (movesFor table) (← draw 3) (n + 2) env' r
  return { name := name, parameters := ps, result := r, body := .letE n first (.letE (n + 1) w rest) }

/-- Two lists of one type it only reads (lengths, an element, a copy), so
    a call may pass one array at both parameters and still be accepted. -/
def readerDecl (name : String) : Gen Decl := do
  let t := if (← draw 3) == 0 then tN else tL
  let ps := [t, t]
  let r ← pick [tL, .int] .int
  let body : Expr := .letE 2 (.prim .length [v 0]) <| .letE 3 (.prim .length [v 1]) <|
    .letE 4 (.prim .add [v 2, v 3]) <|
    if r == .int then .atom (v 4)
    else if t == tL then .letE 5 (.prim .copy [v 1]) (.prim .push [v 5, v 4])
    else .prim (.literal .int) [v 4]
  return { name := name, parameters := ps, result := r, body := body }

/-- Takes a list and a callback over it, and calls the callback first. -/
def higherOrderDecl (table : Table) (name : String) : Gen Decl := do
  let t := if (← draw 4) == 0 then tN else tL
  let g : Ty := .fn [t] t
  let env := bodyEnv [t, g]
  let first ← litList env
  let arg ← if (← draw 3) == 0 then pickRecent (atomsOf env t) else pure (Atom.var 0)
  let r ← pick [t, t, .int] t
  let rest ← blockOf (movesFor table) (← draw 3) 4 ((.var 3, t) :: env) r
  return { name := name, parameters := [t, g], result := r,
           body := .letE 2 first (.letE 3 (.app (.var 1) [arg]) rest) }

/-- Self-recursion on a counter: `0 < k` selects the step, which recurs with
    `k - 1` and the list parameters (permuted among equal types, one of them
    possibly pushed first), then continues with the recursive result. -/
def recursiveDecl (table : Table) (name : String) : Gen Decl := do
  let k := 1 + (← draw 2)
  let mut ts := []
  for _ in List.range k do ts := ts ++ [← pick [tL, tL, tN] tL]
  let ps := Ty.int :: ts
  let caps ← if (← draw 4) == 0 then pure [tL] else pure []
  let r ← pick [tL, .int] tL
  let n := ps.length + caps.length
  let env := bodyEnv (ps ++ caps)
  -- Half the bodies use only flat list moves, so that more recursive
  -- declarations are accepted and their recursive writes are exercised.
  let ms := if (← draw 2) == 0 then movesFor table
    else moves.filter fun (name, _) => ["literal", "push", "set", "read", "length", "copy"].contains name
  let first ← litList env
  let base ← blockOf ms (← draw 3) (n + 2) env r
  let pushed ← draw (ts.length + 1)
  let pushes : List (Expr × Ty) ← match ts[pushed]? with
    | some t => if t == tL then do pure [(.prim .push [v (pushed + 1), ← number env], tL)]
                else do pure [(.prim .push [v (pushed + 1), ← anyList env], tN)]
    | none => pure []
  let mut args : List Atom := [v (n + 2)]
  for (t, j) in ts.zipIdx do
    if j == pushed then args := args ++ [v (n + 3)]
    else
      let same := (ts.zipIdx.filter fun (u, _) => u == t).map fun (_, i) => v (i + 1)
      args := args ++ [← if (← draw 3) == 0 then pick same (v (j + 1)) else pure (v (j + 1))]
  let call := n + 3 + pushes.length
  let stepEnv := (Atom.var call, r) :: extend (n + 3) pushes env
  -- Half the time the step reads the lists it passed to the recursive call
  -- after it returns, then returns the recursive result.
  let rest ← if (← draw 2) == 0 then
      let lists := (args.drop 1).zip ts |>.filter (fun (_, t) => t == tL) |>.map Prod.fst
      pure (wrap (call + 1) (lists.map fun a => (.prim .length [a], .int)) (.atom (v call)))
    else blockOf ms (← draw 3) (call + 1) stepEnv r
  let step : Expr := .letE (n + 2) (.prim .sub [v 0, .int 1]) <|
    wrap (n + 3) pushes (.letE call (.recur args) rest)
  return { name := name, parameters := ps, captures := caps, result := r,
           body := .letE n first <| .letE (n + 1) (.prim .lt [.int 0, v 0]) <| .branch (v (n + 1)) base step }

/-- Returns a closure over its list argument or a fresh list. -/
def factoryDecl (table : Table) (name : String) : Gen Decl := do
  let options : List (Nat × Ty) := [(capPush, fIL), (capGet, fIL), (capLen, fII), (capAppend, fLL)] ++
    table.filterMap fun (i, d) =>
      if d.captures == [tL] && d.parameters.all firstOrder && firstOrder d.result then some (i, fnTy d) else none
  let (target, t) ← pick options (capGet, fIL)
  let first ← litList (bodyEnv [tL])
  let cap := if (← draw 2) == 0 then Atom.var 0 else Atom.var 1
  return { name := name, parameters := [tL], result := t, body := .letE 1 first (.closure target [cap]) }

/-- Two declarations that recurse through each other's closures. -/
def mutualOne (name : String) (other : Nat) : Decl where
  name := name
  parameters := [.int, tL]
  result := tL
  body := .letE 2 (.prim .lt [.int 0, v 0]) <| .branch (v 2) (.atom (v 1)) <|
    .letE 3 (.prim .sub [v 0, .int 1]) <| .letE 4 (.closure other []) <|
    .letE 5 (.prim .push [v 1, v 0]) <| .app (v 4) [v 3, v 5]

def mutualPair (i : Nat) : List Decl :=
  [mutualOne s!"mutualA{i}" (i + 1), mutualOne s!"mutualB{i}" i]

/-- One to three generated declarations (a mutual pair counts as one draw). -/
def generatedTable : Gen Table := do
  let count := 1 + (← draw 3)
  let mut t : Table := []
  for _ in List.range count do
    let i := decls.length + t.length
    let kind ← draw 16
    if kind == 0 then
      t := t ++ (mutualPair i).zipIdx.map fun (d, k) => (i + k, d)
    else
      let d ← if kind ≤ 3 then recursiveDecl t s!"rec{i}"
        else if kind ≤ 5 then higherOrderDecl t s!"higher{i}"
        else if kind ≤ 7 then factoryDecl t s!"factory{i}"
        else if kind ≤ 11 then writerDecl t s!"writer{i}"
        else if kind ≤ 13 then readerDecl s!"reader{i}"
        else plainDecl t s!"plain{i}"
      t := t ++ [(i, d)]
  pure t

/-- Generator v5's general families: 1–12 moves, including conditionals over
    moves; with `declarations`, after a generated table the moves may call. -/
def generalV5 (declarations : Bool) : Gen (List String × Program) := do
  let t ← if declarations then generatedTable else pure []
  -- With a table, chains are shorter (1–6 moves): the table is what the
  -- family is for, and a long chain mostly adds unrelated rejections.
  let length ← draw (if declarations then 6 else 12)
  let first ← litList []
  -- With a table, the chain ends by calling one or two generated
  -- declarations (on fresh arguments half the time), so most programs of
  -- the family run one, then reads the lists the calls were given.
  let fin := fun (next : Nat) (env : Env) => do
    if t.isEmpty then return ([], ← finishV5 env)
    let mut next := next
    let mut env := env
    let mut bs : List (Expr × Ty) := []
    -- A mutual pair is always a limit; it is called by the moves only.
    let callable := t.filter fun (_, d) => !d.name.startsWith "mutual"
    if callable.isEmpty then return ([], ← finishV5 env)
    for _ in List.range (if (← draw 4) == 0 then 2 else 1) do
      -- Half the time a declaration that writes its parameters, if any.
      let writers := callable.filter fun (_, d) => d.name.startsWith "writer" || d.name.startsWith "rec"
      let pool := if !writers.isEmpty && (← draw 2) == 0 then writers else callable
      let (i, d) ← pick pool (0, default)
      let isWriter := writers.any (·.1 == i)
      let more ← callDecl t (isWriter || (← draw 3) != 0) next env i d (dup := !isWriter)
      env := extend next more env
      next := next + more.length
      bs := bs ++ more
    return ([], wrap (next - bs.length) bs (← finishV5 env))
  let (names, rest) ← chainWith (movesFor t) true fin (length + 1) 1 [(.var 0, tL)]
  return (names, { declarations := decls ++ t.map Prod.snd, main := .letE 0 first rest })

end Ownership.Generator
