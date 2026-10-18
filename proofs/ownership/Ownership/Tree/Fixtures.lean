import Ownership.Tree.Checker
import Ownership.Tree.Semantics

/-! # The tree fixtures, with kernel-checked verdicts

`tests/pending/ownership/DeeperLevel.beni` (#379, CK-256: `inner`, `pick`,
`outer`), `tests/pending/ownership/ParamHole.beni` (CK-254: `hole`, `shared`)
and the known limit of §16.7's amendment (`deepShare`: two lists of one
region, refused however distinct they are), each translated to the
fragment's ANF with the same declarations in the same order. A `Leaf` arm
answers `( [], Leaf )` as the beni sources do.

Every verdict below is proved by `decide +kernel`, so the kernel runs the
checker. With the marker (`{}`): `inner` rejected, `pick` accepted, `outer`
rejected; `hole` accepted, `shared` refused at its call; `deepShare`
refused. Under `master`'s fold without the level condition (`master`), every
declaration of `DeeperLevel` and `ParamHole` is accepted and a main that
calls `inner`, `outer` or `shared` sees the two interpreters disagree: the
holes are real. -/

namespace Ownership.Tree.Fixtures

open Ownership.Tree

/-- `( [], Leaf )`, bound above every program variable. -/
def dflt : Expr := .letE 90 .nil (.letE 91 .leaf (.pair 90 91))

/-- `( [], [] )`. -/
def dflt2 : Expr := .letE 90 .nil (.letE 91 .nil (.pair 90 91))

def tLT : Ty := .pair .list .tree

/-- `inner t = case t of Node l _ _ → case l of Node _ zs _ → ( List.push zs 1, l )` -/
def inner : Decl :=
  { name := "inner", params := [.tree], result := tLT,
    body := .caseTree 0 10 11 12 dflt
      (.caseTree 10 13 14 15 dflt (.letE 16 (.push 14 1) (.pair 16 10))) }

/-- `pick t = case t of Node l _ _ → case l of Node _ zs _ → ( zs, l )` -/
def pick : Decl :=
  { name := "pick", params := [.tree], result := tLT,
    body := .caseTree 0 10 11 12 dflt (.caseTree 10 13 14 15 dflt (.pair 14 10)) }

/-- `outer s = case pick s of ( zs, l ) → ( List.push zs 1, l )` (`pick` is
    declaration 1). -/
def outer : Decl :=
  { name := "outer", params := [.tree], result := tLT,
    body := .letE 10 (.call 1 [0]) (.casePair 10 11 12 (.letE 13 (.push 11 1) (.pair 13 12))) }

/-- `hole t = case t of Node l ys _ → ( List.push ys 1, l )` -/
def hole : Decl :=
  { name := "hole", params := [.tree], result := tLT,
    body := .caseTree 0 10 11 12 dflt (.letE 13 (.push 11 1) (.pair 13 10)) }

/-- `shared xs = hole (Node (Node Leaf xs Leaf) xs Leaf)` (`hole` is
    declaration 0). -/
def shared : Decl :=
  { name := "shared", params := [.list], result := tLT,
    body := .letE 10 .leaf (.letE 11 (.node 10 0 10) (.letE 12 (.node 11 0 10) (.call 0 [12]))) }

/-- `case t of Node (Node _ a (Node _ b _)) _ _ → ( List.push a 1, b )` -/
def deepShare : Decl :=
  { name := "deepShare", params := [.tree], result := .pair .list .list,
    body := .caseTree 0 10 11 12 dflt2 (.caseTree 10 13 14 15 dflt2
      (.caseTree 15 16 17 18 dflt2 (.letE 19 (.push 14 1) (.pair 19 17)))) }

/-- `a = [1]; b = [2]; t = Node (Node Leaf a Leaf) b Leaf`, then `k t`. -/
def twoLevels (k : Expr) : Expr :=
  .letE 100 (.lit 1) (.letE 101 (.lit 2) (.letE 102 .leaf
    (.letE 103 (.node 102 100 102) (.letE 104 (.node 103 101 102) k))))

def deeperDecls : List Decl := [inner, pick, outer]
def paramHoleDecls : List Decl := [hole, shared]

def deeperLevel : Program := { decls := deeperDecls }
def paramHole : Program := { decls := paramHoleDecls }
def limit : Program := { decls := [deepShare] }

/-- Mains: `inner t` and `outer t` on a two-level tree, `shared [1]`, and
    `hole t` alone on a two-level tree whose levels hold distinct lists. -/
def innerMain : Program := { decls := deeperDecls, main := some (twoLevels (.call 0 [104])) }
def outerMain : Program := { decls := deeperDecls, main := some (twoLevels (.call 2 [104])) }
def sharedMain : Program := { decls := paramHoleDecls, main := some (.letE 100 (.lit 1) (.call 1 [100])) }
def holeMain : Program := { decls := [hole], main := some (twoLevels (.call 0 [104])) }

/-- A three-level left spine holding one list at levels 1 and 2. -/
def deepMain : Program :=
  { decls := [deepShare],
    main := some (.letE 100 (.lit 1) (.letE 101 (.lit 2) (.letE 102 .leaf
      (.letE 103 (.node 102 100 102) (.letE 104 (.node 102 100 103)
        (.letE 105 (.node 104 101 102) (.call 0 [105]))))))) }

/-- The two holes together: `master`'s fold and no condition between two
    paths of one parameter. This is `src/own/` before the marker. -/
def master : Config := { marker := false, levelSep := false }

theorem fixtures_typed :
    (typecheck innerMain).isOk ∧ (typecheck outerMain).isOk ∧ (typecheck sharedMain).isOk ∧
    (typecheck holeMain).isOk ∧ (typecheck deepMain).isOk := by
  decide +kernel

/-- The expected verdicts, one source for the kernel and the CLI. -/
def expected : List (String × Program × List Bool) :=
  [("DeeperLevel (inner, pick, outer)", deeperLevel, [false, true, false]),
   ("ParamHole (hole, shared)", paramHole, [true, false]),
   ("Limit (deepShare)", limit, [false])]

theorem expected_verdicts : expected.all (fun (_, p, w) => ({} : Config).verdicts p == w) = true := by
  decide +kernel

/-! ## The verdicts with the marker -/

/-- `inner` rejected, `pick` accepted, `outer` rejected. -/
theorem deeperLevel_verdicts : ({} : Config).verdicts deeperLevel = [false, true, false] := by
  decide +kernel

/-- `hole` accepted (on condition that its root's list is apart from its
    left subtree's), `shared` refused at its call. -/
theorem paramHole_verdicts : ({} : Config).verdicts paramHole = [true, false] := by
  decide +kernel

theorem hole_summary :
    ((({} : Config).checkProgram paramHole).1.head?.map (·.1.seps)) =
      some [((0, [.n1]), (0, [.n0]))] := by
  decide +kernel

/-- The known limit: two lists of one region are one cell. -/
theorem deepShare_refused : ({} : Config).verdicts limit = [false] := by
  decide +kernel

/-- `hole` on a tree whose levels hold distinct lists is accepted, and the two
    interpreters agree. -/
theorem holeMain_accepted : ({} : Config).accepts holeMain = true ∧ agree holeMain = true := by
  decide +kernel

/-! ## The holes are real -/

theorem master_accepts : master.verdicts deeperLevel = [true, true, true] ∧
    master.verdicts paramHole = [true, true] := by
  decide +kernel

theorem master_inner_disagrees : master.accepts innerMain = true ∧ agree innerMain = false := by
  decide +kernel

theorem master_outer_disagrees : master.accepts outerMain = true ∧ agree outerMain = false := by
  decide +kernel

theorem master_shared_disagrees : master.accepts sharedMain = true ∧ agree sharedMain = false := by
  decide +kernel

/-- The marker alone is not enough: without the level condition `shared`'s
    call is accepted and disagrees (`paramHole`). -/
theorem noLevelSep_shared_disagrees :
    ({ levelSep := false } : Config).accepts sharedMain = true ∧ agree sharedMain = false := by
  decide +kernel

/-- Nor is the condition alone: `master`'s fold with the condition still
    accepts `inner` and `outer`, and its call of `inner` on a tree with two
    levels, whose instantiation finds no list below `#Node.0` because the
    fold moved the left subtree's list to `#Node.1`. -/
theorem noMarker_inner_disagrees :
    ({ marker := false } : Config).verdicts deeperLevel = [true, true, true] ∧
    ({ marker := false } : Config).accepts innerMain = true ∧ agree innerMain = false := by
  decide +kernel

/-- The limit refuses a program that is unsafe when one list sits at levels 1
    and 2 of one region, as in `deepMain`, and refuses it as well when the
    lists are distinct (`deepDistinct`), where the two runs agree: the refusal
    of safe code §16.7's amendment names. -/
theorem deepMain_shares : ({} : Config).accepts deepMain = false ∧ agree deepMain = false := by
  decide +kernel

def deepDistinct : Program :=
  { decls := [deepShare],
    main := some (.letE 100 (.lit 1) (.letE 101 (.lit 2) (.letE 102 .leaf
      (.letE 103 (.node 102 101 102) (.letE 104 (.node 102 100 103)
        (.letE 105 (.node 104 101 102) (.call 0 [105]))))))) }

theorem deepDistinct_refused : ({} : Config).accepts deepDistinct = false ∧ agree deepDistinct = true := by
  decide +kernel

end Ownership.Tree.Fixtures
