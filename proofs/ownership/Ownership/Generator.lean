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
      .letE 9 (.prim .length [v 8]) (.prim .push [v 3, v 9]) }]

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
    pure [(.closure applyThenRead [], .fn [tL, fLL] tL),
      (.closure (if (← draw 2) == 0 then identL else bump) [], fLL),
      (.app (v next) [← anyList env, v (next + 1)], tL)]),
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

def atomRoot : Atom → Option Var
  | .var x => some x
  | .field a _ => atomRoot a
  | .int _ => none

/-- Argument positions a table declaration may write or keep: the list a map,
    update or `two` edits, a fold's accumulator. Sources a call only reads stay. -/
def handedArguments (d : Nat) : List Nat :=
  if d == two || d == readTwo || d == updL || d == applyThenRead then [0]
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
      | some d => handedArguments d
      | none => List.range args.length
    positions.filterMap fun i => args[i]? >>= atomRoot
  | .closure d caps => if d == capPush then caps.filterMap atomRoot else []
  | .branch _ a b => handedOver callee a ++ handedOver callee b
  | _ => []

/-- After a move, each variable it handed over leaves the pool with probability
    3/4, so most generated programs use a written value linearly while a quarter
    of them reuse it. -/
def retire (env : Env) (gone : List Var) : Gen Env := do
  let mut out := env
  for x in gone do
    if (← draw 4) != 0 then
      out := out.filter fun (a, _) => atomRoot a != some x
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

def chain : Nat → Nat → Env → Gen (List String × Expr)
  | 0, _, env => do return ([], ← finish env)
  | fuel + 1, next, env => do
    let (name, move) ← pick weighted ("literal", fun _ env => do pure [(← litList env, tL)])
    let bs ← move next env
    let bs ← followUp next env bs
    let callee := fun (x : Var) => match bs[x - next]? with
      | some (.closure d [], _) => if x ≥ next then some d else none
      | _ => none
    let gone := bs.flatMap (fun (rhs, _) => handedOver callee rhs)
    let (names, e) ← bindAll next env bs fun next' env' => do
      chain fuel next' (← retire env' gone)
    return (name :: names, e)

/-- A program of 1–12 moves after one fresh list. -/
def general : Gen (List String × Program) := do
  let length ← draw 12
  let first ← litList []
  let (names, rest) ← chain (length + 1) 1 [(.var 0, tL)]
  return (names, { declarations := decls, main := .letE 0 first rest })

end Ownership.Generator
