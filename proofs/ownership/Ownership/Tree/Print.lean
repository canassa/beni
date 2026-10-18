import Ownership.Tree.Enumerate

/-! # The tree fragment in beni source, for the shipping checker

`ownership tree-export --out=DIR` writes each module of the tree product as
a beni module, beside a manifest of the oracle's verdict for every
declaration and the lines it spans, so `src/own/`'s verdicts (`beni dump
--stage=ownership`) can be compared with the oracle's declaration by
declaration (`scripts/tree-bridge.mjs`). The main expression becomes a
declaration `main : ⊤ → …`. A binder no arm reads is printed `_`. -/

namespace Ownership.Tree.Print

open Ownership.Tree

def tyName : Ty → String
  | .list => "List Int"
  | .tree => "Tree"
  | .pair a b => s!"{tyArg a} × {tyArg b}"
where
  tyArg : Ty → String
    | .pair a b => s!"({tyName (.pair a b)})"
    | t => tyName t

def v (x : Var) : String := s!"v{x}"

def binder (used : List Var) (x : Var) : String := if used.contains x then v x else "_"

def pad (n : Nat) : String := String.ofList (List.replicate (4 * n) ' ')

/-- The expression at indentation `n`, as lines. -/
def expr (names : List String) (n : Nat) : Expr → List String
  | .var x => [pad n ++ v x]
  | .nil => [pad n ++ "[]"]
  | .lit k => [pad n ++ s!"[ {k} ]"]
  | .leaf => [pad n ++ "Leaf"]
  | .node l x r => [pad n ++ s!"Node {v l} {v x} {v r}"]
  | .pair a b => [pad n ++ s!"( {v a}, {v b} )"]
  | .push xs k => [pad n ++ s!"List.push {v xs} {k}"]
  | .call f args => [pad n ++ String.intercalate " " (names.getD f s!"f{f}" :: args.map v)]
  | .letE x rhs rest =>
    let r := expr names (n + 1) rhs
    match r with
    | [one] => (pad n ++ s!"{v x} = " ++ (one.dropWhile (· == ' ')).toString) :: expr names n rest
    | _ => (pad n ++ s!"{v x} =") :: r ++ expr names n rest
  | .caseTree t l x r a b =>
    let used := fv b
    [pad n ++ s!"case {v t} of",
     pad (n + 1) ++ s!"Node {binder used l} {binder used x} {binder used r} →"] ++
    expr names (n + 2) b ++ [""] ++ [pad (n + 1) ++ "Leaf →"] ++ expr names (n + 2) a
  | .casePair p a b body =>
    let used := fv body
    [pad n ++ s!"case {v p} of", pad (n + 1) ++ s!"( {binder used a}, {binder used b} ) →"] ++
    expr names (n + 2) body

structure Module where
  source : String
  /-- Per declaration: its name, first and last line, and the oracle's verdict. -/
  decls : List (String × Nat × Nat × Bool)

def module (name : String) (p : Program) (cfg : Config := {}) : Module := Id.run do
  let names := p.decls.map (·.name)
  let (sums, mainErrors) := cfg.checkProgram p
  let mut lines : Array String := #[s!"-- {name}: the tree fragment of the ownership oracle (Tree/Print.lean).", "",
    "type Tree", "    = Leaf", "    | Node Tree (List Int) Tree", ""]
  let mut out : List (String × Nat × Nat × Bool) := []
  for (d, i) in p.decls.zipIdx do
    lines := lines.push ""
    let start := lines.size + 1
    let ps := String.intercalate ", " (d.params.map tyName)
    lines := lines.push s!"pub {d.name} : {ps} → {tyName d.result}"
    let args := (List.range d.params.length).map v
    lines := lines.push s!"{d.name} {String.intercalate " " args} ="
    for l in expr names 1 d.body do lines := lines.push l
    out := out ++ [(d.name, start, lines.size, (sums[i]?.map (·.2.isEmpty)).getD false)]
    lines := lines.push ""
  if let some m := p.main then
    lines := lines.push ""
    let start := lines.size + 1
    let t := (typeOf p.decls p.decls.length [] m).toOption.getD .list
    lines := lines.push s!"pub run : ⊤ → {tyName t}"
    lines := lines.push "run ⊤ ="
    for l in expr names 1 m do lines := lines.push l
    out := out ++ [("run", start, lines.size, mainErrors.isEmpty)]
  return { source := String.intercalate "\n" lines.toList ++ "\n", decls := out }

def json (s : String) : String := "\"" ++ (s.replace "\\" "\\\\").replace "\"" "\\\"" ++ "\""

/-- The fixtures and one module per case of the product. -/
def exportAll (dir : System.FilePath) (depth nodes : Nat) : IO Nat := do
  IO.FS.createDirAll dir
  let fixtures : List (String × Program) :=
    [("DeeperLevel", Fixtures.deeperLevel), ("ParamHole", Fixtures.paramHole),
     ("Limit", Fixtures.limit), ("HoleMain", Fixtures.holeMain), ("SharedMain", Fixtures.sharedMain)]
  let cases := (Enumerate.cases depth nodes).zipIdx.map fun (c, i) => (s!"Case{i}", c.program)
  let mut manifest : Array String := #[]
  for (name, p) in fixtures ++ cases do
    let m := module name p
    IO.FS.writeFile (dir / s!"{name}.beni") m.source
    let ds := m.decls.map fun (d, a, b, ok) =>
      s!"\{\"name\":{json d},\"first\":{a},\"last\":{b},\"accepted\":{ok}}"
    manifest := manifest.push s!"\{\"module\":{json name},\"decls\":[{String.intercalate "," ds}]}"
  IO.FS.writeFile (dir / "manifest.jsonl") (String.intercalate "\n" manifest.toList ++ "\n")
  return manifest.size

end Ownership.Tree.Print
