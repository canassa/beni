import Ownership.Tree.Path

/-! # The tree fragment: the ownership checker

A path-based checker in the shape of `src/own/`'s: an abstract value is a list
of entries `(path, cell)`, a cell is a symbolic cell `param(j, q)` (the storage
at the canonical path `q` of parameter `j` and below it) or a site (a fresh
array). A write (`push`) of a list demands that no variable live after it
hold one of the list's cells. Two cells of parameters that do not conflict
are taken to be apart, and that is recorded as a separation condition the
caller discharges (`sep`; §16.7's amendment: `excl π1` of a tree includes `sep
π1#Node.1 π1#Node.0⟨Tree⟩#Node.1`). A summary publishes the parameter cells a
declaration writes, its conditions and its result's entries; a call
instantiates all three against its arguments.

Every demand is checked and recorded; a declaration is accepted when none
failed, and its summary is published either way, as the Zig checker does. -/

namespace Ownership.Tree

inductive Cell where
  | param (j : Nat) (path : List Step)
  | site (id : List Nat)
  deriving DecidableEq, Repr, Inhabited

abbrev AVal := List (List Step × Cell)

abbrev PCell := Nat × List Step

structure Summary where
  writes : List PCell := []
  seps : List (PCell × PCell) := []
  result : AVal := []
  deriving DecidableEq, Repr, Inhabited

structure St where
  writes : List PCell := []
  seps : List (PCell × PCell) := []
  next : Nat := 0
  errors : List String := []
  deriving Repr, Inhabited

def St.addWrite (st : St) (w : PCell) : St :=
  if st.writes.contains w then st else { st with writes := st.writes ++ [w] }

def St.addSep (st : St) (a b : PCell) : St :=
  if st.seps.contains (a, b) || st.seps.contains (b, a) then st else { st with seps := st.seps ++ [(a, b)] }

def St.fail (st : St) (e : String) : St := { st with errors := st.errors ++ [e] }

def Config.extendCell (c : Config) : Cell → Step → Cell
  | .param j p, s => .param j (c.extend p s)
  | cell, _ => cell

def Config.extendCellPath (c : Config) (cell : Cell) (q : List Step) : Cell :=
  q.foldl c.extendCell cell

/-- Projection along a field (§16.7's amendment, *Projection*). An entry whose
    first step is `s` is kept at the rest of its path. One whose first step
    is the marker stands for values at or below the root: it is kept whole
    when `s` is a subtree step, and at the rest of `r` when `r` begins with
    `s`. Every other entry is dropped, another field of the same level
    included. A symbolic cell is projected to the folded path. With
    `marker := false`, #341's rule: an entry whose first step is any
    constructor step of `Tree` is also kept whole along a subtree step. -/
def Config.proj (c : Config) (v : AVal) (s : Step) : AVal :=
  v.flatMap fun (p, cell) => match p with
    | [] => [([], c.extendCell cell s)]
    | a :: rest =>
      if c.marker then
        if a == s then [(rest, cell)]
        else if a == .mark then
          (if isT s then [(p, cell)] else []) ++
          (match rest with
           | b :: r => if b == s then [(r, cell)] else []
           | [] => [])
        else []
      else
        (if a == s then [(rest, cell)] else []) ++ (if isT s && isCtor a then [(p, cell)] else [])

/-- The cells of `v` that may hold storage at or below path `q`: an entry at
    the root is extended along `q`; any other entry is taken whole when its
    path conflicts with `q`. -/
def Config.cellsAt (c : Config) (v : AVal) (q : List Step) : List Cell :=
  v.flatMap fun (p, cell) =>
    if p.isEmpty then [c.extendCellPath cell q]
    else if c.conflict p q then [cell] else []

inductive Rel where
  | conflict
  | sep (a b : PCell)
  | apart
  deriving DecidableEq, Repr

/-- How two cells relate. Sites are fresh arrays: one site is itself, two
    are apart, and a site is apart from every parameter's storage. Two
    parameter cells that conflict may be one array; any other two are apart
    on condition. -/
def Config.rel (c : Config) : Cell → Cell → Rel
  | .site a, .site b => if a == b then .conflict else .apart
  | .param j p, .param k q =>
    if j == k && c.conflict p q then .conflict
    else if j == k && !c.levelSep then .apart
    else .sep (j, p) (k, q)
  | _, _ => .apart

def cellsOf (v : AVal) : List Cell := v.map (·.2)

def lookupA (env : List (Var × AVal)) (x : Var) : AVal := (env.lookup x).getD []

/-- One relation between cells, recorded in the state. -/
def Config.relate (c : Config) (st : St) (why : String) (a b : Cell) : St :=
  match c.rel a b with
  | .conflict => st.fail why
  | .sep x y => st.addSep x y
  | .apart => st

/-- A write of the cells `ws` while `live` stays live. -/
def Config.demand (c : Config) (env : List (Var × AVal)) (live : List Var) (ws : List Cell)
    (st : St) : St :=
  ws.foldl (fun st w =>
    let st := match w with
      | .param j p => st.addWrite (j, p)
      | _ => st
    live.foldl (fun st y =>
      (cellsOf (lookupA env y)).foldl (fun st h =>
        c.relate st s!"write of {repr w}: variable {y} holds {repr h}" w h) st) st) st

/-- The result of a call: a callee's parameter cell is the argument's cells
    there; a callee's site is a fresh site of this call. -/
def Config.instResult (c : Config) (args : List AVal) (call : Nat) (r : AVal) : AVal :=
  r.flatMap fun (path, cell) => match cell with
    | .param j q => (c.cellsAt (args.getD j []) q).map fun x => (path, x)
    | .site s => [(path, .site (call :: s))]

def Config.prefixAll (c : Config) (s : Step) (v : AVal) : AVal :=
  v.map fun (p, cell) => (c.prefixWith s p, cell)

def union (a b : List Var) : List Var := b.foldl (fun xs x => if xs.contains x then xs else xs ++ [x]) a

/-- Check an expression whose continuation keeps `live` live. -/
def Config.checkE (c : Config) (sums : List Summary) :
    List (Var × AVal) → List Var → Expr → St → AVal × St
  | env, _, .var x, st => (lookupA env x, st)
  | _, _, .nil, st | _, _, .lit _, st => ([([], .site [st.next])], { st with next := st.next + 1 })
  | _, _, .leaf, st => ([], st)
  | env, _, .node l x r, st =>
    (c.prefixAll .n0 (lookupA env l) ++ c.prefixAll .n1 (lookupA env x) ++ c.prefixAll .n2 (lookupA env r), st)
  | env, _, .pair a b, st => (c.prefixAll .p0 (lookupA env a) ++ c.prefixAll .p1 (lookupA env b), st)
  | env, live, .push xs _, st =>
    let v := lookupA env xs
    (v, c.demand env live (cellsOf v) st)
  | env, live, .call f args, st =>
    let s := sums.getD f {}
    let vs := args.map (lookupA env)
    let st := s.writes.foldl (fun st (j, q) => c.demand env live (c.cellsAt (vs.getD j []) q) st) st
    let st := s.seps.foldl (fun st ((j, p), (k, q)) =>
      (c.cellsAt (vs.getD j []) p).foldl (fun st a =>
        (c.cellsAt (vs.getD k []) q).foldl (fun st b =>
          c.relate st s!"call of {f}: argument {j} at {repr p} and argument {k} at {repr q} share {repr a}, {repr b}" a b) st) st) st
    (c.instResult vs st.next s.result, { st with next := st.next + 1 })
  | env, live, .letE x rhs rest, st =>
    let (v, st) := c.checkE sums env (union live ((fv rest).filter (· != x))) rhs st
    c.checkE sums ((x, v) :: env) live rest st
  | env, live, .caseTree t l x r a b, st =>
    let tv := lookupA env t
    let (va, st) := c.checkE sums env live a st
    let (vb, st) := c.checkE sums ((l, c.proj tv .n0) :: (x, c.proj tv .n1) :: (r, c.proj tv .n2) :: env) live b st
    (va ++ vb, st)
  | env, live, .casePair p a b body, st =>
    let pv := lookupA env p
    c.checkE sums ((a, c.proj pv .p0) :: (b, c.proj pv .p1) :: env) live body st

/-- A path's pair steps and its tree segment. -/
def splitPair : List Step → List Step × List Step
  | [] => ([], [])
  | s :: r =>
    if s == .p0 || s == .p1 then let (a, b) := splitPair r; (s :: a, b) else ([], s :: r)

/-- The canonical form (§16.7's amendment at 161f77eea): one fact written at
    `P r` and at `P s⟨T⟩r` for both region steps `s`, where `P` is in no
    region (here: pair steps only), is written once as `P⟨T⟩r`. A fact is a
    path with what is stated there (`b`); the merged facts must state the
    same. This fragment has one level of regions, so one pass reaches the
    fixpoint. -/
def canonForm {β : Type} [DecidableEq β] (fs : List (List Step × β)) : List (List Step × β) :=
  let merged := fs.filterMap fun (p, b) =>
    let (P, r) := splitPair p
    if !r.contains .mark && fs.contains (P ++ [.n0, .mark] ++ r, b) &&
        fs.contains (P ++ [.n2, .mark] ++ r, b) then some (P, r, b) else none
  let gone := merged.flatMap fun (P, r, b) =>
    [(P ++ r, b), (P ++ [.n0, .mark] ++ r, b), (P ++ [.n2, .mark] ++ r, b)]
  fs.filter (fun f => !gone.contains f) ++ merged.map fun (P, r, b) => (P ++ .mark :: r, b)

/-- A declaration's summary and the demands that failed in it. The writes and
    the result's entries are written in the canonical form unless
    `canonical := false`; the conditions are not (each names two paths, and
    the amendment's form is for facts stated per path). -/
def Config.checkDecl (c : Config) (sums : List Summary) (d : Decl) : Summary × List String :=
  let env := (List.range d.params.length).map fun j => (j, [([], Cell.param j [])])
  let (v, st) := c.checkE sums env [] d.body {}
  let writes := if c.canonical then (canonForm (st.writes.map fun (j, p) => (p, j))).map fun (p, j) => (j, p)
    else st.writes
  let result := if c.canonical then canonForm v else v
  ({ writes := writes, seps := st.seps, result := result }, st.errors)

/-- Per declaration, in order, its summary and its failed demands; then the
    failed demands of the main expression. -/
def Config.checkProgram (c : Config) (p : Program) : List (Summary × List String) × List String :=
  let sums := p.decls.foldl (fun acc d => acc ++ [c.checkDecl (acc.map (·.1)) d]) []
  let mainErrors := match p.main with
    | some m => (c.checkE (sums.map (·.1)) [] [] m {}).2.errors
    | none => []
  (sums, mainErrors)

/-- Each declaration's verdict, `true` for accepted. -/
def Config.verdicts (c : Config) (p : Program) : List Bool :=
  (c.checkProgram p).1.map (·.2.isEmpty)

def Config.accepts (c : Config) (p : Program) : Bool :=
  let (ds, m) := c.checkProgram p
  ds.all (·.2.isEmpty) && m.isEmpty

end Ownership.Tree
