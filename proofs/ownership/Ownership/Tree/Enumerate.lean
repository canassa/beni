import Ownership.Tree.Fixtures

/-! # The tree enumerator

Every program of a bounded product, independent of any seed. A program is a
family of declarations reading two places of a tree parameter, and a main
that builds a tree and calls it.

* The places: a subtree at a run of at most `depth` subtree steps, or that
  subtree's own list. A declaration writes one list place `w` and keeps one
  place `h` (`( List.push w 1, h )`), destructuring `h` first.
* The families: `direct` (that declaration), `pick` (`pick` returns `( w, h
  )` and `outer` pushes the first component, as `DeeperLevel` does), `wrap`
  (a declaration that forwards its tree to `direct`), `inline` (the same body
  in main over the tree it built, `FoldLevels`' twin) and `two` (a second,
  list, parameter is kept: `( List.push w 1, ys )`).
* The trees: every shape with at most `nodes` nodes, each node's list one of
  two pool lists `a = [1]`, `b = [2]` or a fresh one; main returns the call's
  result, or the result beside `a`.

The corrected checker must accept no program whose two interpreters
disagree. Each hole in `Config` must be caught: some program it accepts
disagrees. -/

namespace Ownership.Tree.Enumerate

open Ownership.Tree Fixtures

/-- Bind what lies at `steps` below `t` (`false` is left), and that subtree's
    list when `list`; continue with `k v next`. A `Leaf` on the way answers
    `d`. -/
def descend (d : Expr) (t : Var) : List Bool → Bool → Nat → (Var → Nat → Expr) → Expr
  | [], false, n, k => k t n
  | [], true, n, k => .caseTree t n (n + 1) (n + 2) d (k (n + 1) (n + 3))
  | b :: rest, list, n, k =>
    .caseTree t n (n + 1) (n + 2) d (descend d (if b then n + 2 else n) rest list (n + 3) k)

def runs : Nat → List (List Bool)
  | 0 => [[]]
  | n + 1 => [] :: ((runs n).flatMap fun r => [false :: r, true :: r])

/-- A place: a run of subtree steps, and whether it is that subtree's list. -/
abbrev Place := List Bool × Bool

def places (depth : Nat) (list : Bool) : List Place := (runs depth).map (·, list)

def Place.ty (p : Place) : Ty := if p.2 then .list else .tree

def Place.name (p : Place) : String :=
  String.join (p.1.map fun b => if b then "R" else "L") ++ (if p.2 then "x" else "")

def defaultOf : Ty → Expr
  | .tree => dflt
  | _ => dflt2

/-- `( List.push w 1, h )` over the tree `t`, or `( w, h )` when not `write`. -/
def body (t : Var) (w h : Place) (write : Bool) (n : Nat) : Expr :=
  let d := defaultOf h.ty
  descend d t h.1 h.2 n fun hv n =>
    descend d t w.1 w.2 n fun wv n =>
      if write then .letE n (.push wv 1) (.pair n hv) else .pair wv hv

inductive Family where
  | direct | pick | wrap | inline | two
  deriving DecidableEq, Repr, Inhabited

def Family.all : List Family := [.direct, .pick, .wrap, .inline, .two]

def Family.name : Family → String
  | .direct => "direct" | .pick => "pick" | .wrap => "wrap" | .inline => "inline" | .two => "two"

/-- Tree shapes. -/
inductive Shape where
  | leaf
  | node (l r : Shape)
  deriving DecidableEq, Repr, Inhabited

def Shape.size : Shape → Nat
  | .leaf => 0
  | .node l r => l.size + r.size + 1

/-- Every shape with at most `n` nodes. -/
def shapes : Nat → List Shape
  | 0 => [.leaf]
  | n + 1 =>
    let smaller := shapes n
    .leaf :: ((smaller.flatMap fun l => smaller.map fun r => Shape.node l r).filter
      (fun s => s.size ≤ n + 1 && s.size ≥ 1)).eraseDups

/-- A node's list: `a`, `b`, or fresh. -/
inductive Pick where
  | a | b | fresh
  deriving DecidableEq, Repr, Inhabited

def picks : Nat → List (List Pick)
  | 0 => [[]]
  | n + 1 => (picks n).flatMap fun ps => [.a :: ps, .b :: ps, .fresh :: ps]

/-- Bindings that build a shape, the variable of the tree, the unused picks
    and the next variable. `a`, `b` and the shared `Leaf` are 100, 101, 102. -/
def build : Shape → List Pick → Nat → List (Var × Expr) × Var × List Pick × Nat
  | .leaf, ps, n => ([], 102, ps, n)
  | .node l r, ps, n =>
    let (bl, vl, ps, n) := build l ps n
    let (br, vr, ps, n) := build r ps n
    match ps with
    | p :: ps =>
      let (bx, vx, n) := match p with
        | .a => ([], 100, n)
        | .b => ([], 101, n)
        | .fresh => ([(n, Expr.lit (Int.ofNat n))], n, n + 1)
      (bl ++ br ++ bx ++ [(n, .node vl vx vr)], n, ps, n + 1)
    | [] => (bl ++ br, 102, [], n)

def lets (bs : List (Var × Expr)) (k : Expr) : Expr := bs.foldr (fun (x, e) k => .letE x e k) k

def prelude (bs : List (Var × Expr)) (k : Expr) : Expr :=
  .letE 100 (.lit 1) (.letE 101 (.lit 2) (.letE 102 .leaf (lets bs k)))

structure Case where
  family : Family
  w : Place
  h : Place
  shape : Shape
  picks : List Pick
  keepA : Bool
  program : Program

def resultTy (h : Place) : Ty := .pair .list h.ty

/-- The program of one case. Main's call result is 199; with `keepA` main
    returns it beside `a`. -/
def program (f : Family) (w h : Place) (sh : Shape) (ps : List Pick) (keepA : Bool) : Program :=
  let (bs, tv, _, _) := build sh ps 110
  let finish (call : Expr) : Expr :=
    .letE 199 call (if keepA then .letE 198 (.pair 199 100) (.var 198) else .var 199)
  let direct : Decl := { name := "f", params := [.tree], result := resultTy h, body := body 0 w h true 10 }
  match f with
  | .direct => { decls := [direct], main := some (prelude bs (finish (.call 0 [tv]))) }
  | .pick =>
    let pk : Decl := { name := "pick", params := [.tree], result := resultTy h, body := body 0 w h false 10 }
    let ou : Decl :=
      { name := "outer", params := [.tree], result := resultTy h,
        body := .letE 10 (.call 0 [0]) (.casePair 10 11 12 (.letE 13 (.push 11 1) (.pair 13 12))) }
    { decls := [pk, ou], main := some (prelude bs (finish (.call 1 [tv]))) }
  | .wrap =>
    let wr : Decl := { name := "wrap", params := [.tree], result := resultTy h, body := .call 0 [0] }
    { decls := [direct, wr], main := some (prelude bs (finish (.call 1 [tv]))) }
  | .inline => { decls := [], main := some (prelude bs (finish (body tv w h true 10))) }
  | .two =>
    let tw : Decl :=
      { name := "two", params := [.tree, .list], result := .pair .list .list,
        body := descend dflt2 0 w.1 w.2 10 fun wv n => .letE n (.push wv 1) (.pair n 1) }
    -- `h` chooses the kept list: `a` when its run is empty, else `b`
    { decls := [tw], main := some (prelude bs (finish (.call 0 [tv, if h.1.isEmpty then 100 else 101]))) }

def cases (depth nodes : Nat) : List Case :=
  let ws := places depth true
  let hs := places depth false ++ places depth true
  let trees := (shapes nodes).flatMap fun sh => (picks sh.size).map (sh, ·)
  Family.all.flatMap fun f =>
    let pairs := if f == .two then ws.flatMap fun w => [(w, ([], true)), (w, ([false], true))]
      else ws.flatMap fun w => hs.map (w, ·)
    pairs.flatMap fun (w, h) => trees.flatMap fun (sh, ps) => [false, true].map fun keepA =>
      { family := f, w := w, h := h, shape := sh, picks := ps, keepA := keepA, program := program f w h sh ps keepA }

/-- A list in the observation longer than one: an in-place write reached it. -/
def written : Val → Bool
  | .list xs => xs.length > 1
  | .leaf => false
  | .node l x r => written l || written x || written r
  | .pair a b => written a || written b

structure Counts where
  programs : Nat := 0
  accepted : Nat := 0
  written : Nat := 0
  disagree : Nat := 0
  firstDisagreement : Option String := none
  deriving Inhabited

def Case.describe (c : Case) : String :=
  s!"{c.family.name} w={c.w.1.length}:{Place.name c.w} h={Place.name c.h} shape={repr c.shape} picks={repr c.picks} keepA={c.keepA}"

def count (cfg : Config) (cs : List Case) : Except String Counts :=
  cs.foldlM (fun acc c => do
    if let .error e := typecheck c.program then throw s!"ill-typed program ({e}): {c.describe}"
    let acc := { acc with programs := acc.programs + 1 }
    if !cfg.accepts c.program then return acc
    let acc := { acc with accepted := acc.accepted + 1 }
    let acc := match runValue c.program with
      | .ok v => if written v then { acc with written := acc.written + 1 } else acc
      | .error _ => acc
    if agree c.program then return acc
    return { acc with disagree := acc.disagree + 1,
                      firstDisagreement := acc.firstDisagreement.orElse fun _ => some c.describe }) {}

/-- The holes the enumerator must catch, and why each is one. -/
def holes : List (String × Config) :=
  [("master", master), ("no-marker", { marker := false }), ("no-level-sep", { levelSep := false }),
   ("no-approx", { approx := false })]

def run (depth nodes : Nat) : IO Bool := do
  let cs := cases depth nodes
  let mut ok := true
  match count {} cs with
  | .error e => IO.println s!"tree FAILED: {e}"; return false
  | .ok r =>
    IO.println s!"tree enumerate depth={depth} nodes={nodes}: {r.programs} programs, {r.accepted} accepted, {r.written} accepted show an in-place write, {r.disagree} disagree"
    if r.disagree != 0 then
      IO.println s!"tree FAILED: an accepted program disagrees: {r.firstDisagreement.getD ""}"
      ok := false
    if r.written == 0 then
      IO.println "tree FAILED: no accepted program writes"
      ok := false
  for f in Family.all do
    match count {} (cs.filter (·.family == f)) with
    | .ok r => IO.println s!"  {f.name}: {r.programs} programs, {r.accepted} accepted, {r.written} write"
    | .error _ => pure ()
  for (name, cfg) in holes do
    match count cfg cs with
    | .error e => IO.println s!"tree FAILED: {e}"; ok := false
    | .ok r =>
      IO.println s!"tree hole {name}: {r.accepted} accepted, {r.disagree} disagree; first: {r.firstDisagreement.getD "none"}"
      if r.disagree == 0 then
        IO.println s!"tree FAILED: hole {name} is not caught"
        ok := false
  -- The fixtures, through the same checker the kernel checked.
  let fx : List (String × Program × List Bool) :=
    [("DeeperLevel (inner, pick, outer)", deeperLevel, [false, true, false]),
     ("ParamHole (hole, shared)", paramHole, [true, false]),
     ("Limit (deepShare)", limit, [false])]
  for (name, p, want) in fx do
    let got := ({} : Config).verdicts p
    IO.println s!"tree fixture {name}: {got.map fun b => if b then "accepted" else "rejected"}"
    if got != want then
      IO.println s!"tree FAILED: fixture {name} expected {want}"
      ok := false
  return ok

end Ownership.Tree.Enumerate
