import Ownership.Oracle

namespace Ownership.GeneratedRegressions

def oldSeed20261011Index8 : Program :=
{ declarations := [{ name := "map",
                     parameters := [Ownership.Ty.list (Ownership.Ty.int),
                                    Ownership.Ty.fn
                                      [Ownership.Ty.int]
                                      (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int)))],
                     captures := [],
                     result := Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int))),
                     body := Ownership.Expr.letE
                               2
                               (Ownership.Expr.prim
                                 (Ownership.Prim.builder (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int))))
                                 [])
                               (Ownership.Expr.letE
                                 3
                                 (Ownership.Expr.traverse
                                   (Ownership.Source.list)
                                   (Ownership.Atom.var 0)
                                   (Ownership.Atom.var 2)
                                   4
                                   5
                                   6
                                   (Ownership.Expr.letE
                                     7
                                     (Ownership.Expr.app (Ownership.Atom.var 1) [Ownership.Atom.var 5])
                                     (Ownership.Expr.prim
                                       (Ownership.Prim.put)
                                       [Ownership.Atom.var 6, Ownership.Atom.var 7])))
                                 (Ownership.Expr.prim (Ownership.Prim.close) [Ownership.Atom.var 3])) },
                   { name := "generatedFresh",
                     parameters := [Ownership.Ty.int],
                     captures := [],
                     result := Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int)),
                     body := Ownership.Expr.letE
                               1
                               (Ownership.Expr.prim (Ownership.Prim.literal (Ownership.Ty.int)) [])
                               (Ownership.Expr.letE
                                 2
                                 (Ownership.Expr.atom (Ownership.Atom.var 1))
                                 (Ownership.Expr.prim
                                   (Ownership.Prim.literal (Ownership.Ty.list (Ownership.Ty.int)))
                                   [Ownership.Atom.var 1, Ownership.Atom.var 2])) }],
  main := Ownership.Expr.letE
            0
            (Ownership.Expr.closure 0 [])
            (Ownership.Expr.letE
              1
              (Ownership.Expr.closure 1 [])
              (Ownership.Expr.letE
                2
                (Ownership.Expr.letE
                  8
                  (Ownership.Expr.prim
                    (Ownership.Prim.literal (Ownership.Ty.int))
                    [Ownership.Atom.int 0, Ownership.Atom.int 1, Ownership.Atom.int 2])
                  (Ownership.Expr.app (Ownership.Atom.var 0) [Ownership.Atom.var 8, Ownership.Atom.var 1]))
                (Ownership.Expr.focus
                  (Ownership.Atom.var 2)
                  (Ownership.Atom.int 2)
                  3
                  (Ownership.Expr.focus
                    (Ownership.Atom.var 3)
                    (Ownership.Atom.int 0)
                    4
                    (Ownership.Expr.prim (Ownership.Prim.push) [Ownership.Atom.var 4, Ownership.Atom.int 2]))))) }

def oldSeed20261011Index10 : Program :=
{ declarations := [{ name := "initialize",
                     parameters := [Ownership.Ty.int,
                                    Ownership.Ty.fn
                                      [Ownership.Ty.int]
                                      (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int)))],
                     captures := [],
                     result := Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int))),
                     body := Ownership.Expr.letE
                               2
                               (Ownership.Expr.prim
                                 (Ownership.Prim.builder (Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int))))
                                 [])
                               (Ownership.Expr.letE
                                 3
                                 (Ownership.Expr.traverse
                                   (Ownership.Source.range)
                                   (Ownership.Atom.var 0)
                                   (Ownership.Atom.var 2)
                                   4
                                   5
                                   6
                                   (Ownership.Expr.letE
                                     7
                                     (Ownership.Expr.app (Ownership.Atom.var 1) [Ownership.Atom.var 4])
                                     (Ownership.Expr.prim
                                       (Ownership.Prim.put)
                                       [Ownership.Atom.var 6, Ownership.Atom.var 7])))
                                 (Ownership.Expr.prim (Ownership.Prim.close) [Ownership.Atom.var 3])) },
                   { name := "generatedFresh",
                     parameters := [Ownership.Ty.int],
                     captures := [],
                     result := Ownership.Ty.list (Ownership.Ty.list (Ownership.Ty.int)),
                     body := Ownership.Expr.letE
                               1
                               (Ownership.Expr.prim (Ownership.Prim.literal (Ownership.Ty.int)) [])
                               (Ownership.Expr.letE
                                 2
                                 (Ownership.Expr.atom (Ownership.Atom.var 1))
                                 (Ownership.Expr.prim
                                   (Ownership.Prim.literal (Ownership.Ty.list (Ownership.Ty.int)))
                                   [Ownership.Atom.var 1, Ownership.Atom.var 2])) }],
  main := Ownership.Expr.letE
            0
            (Ownership.Expr.closure 0 [])
            (Ownership.Expr.letE
              1
              (Ownership.Expr.closure 1 [])
              (Ownership.Expr.letE
                2
                (Ownership.Expr.app (Ownership.Atom.var 0) [Ownership.Atom.int 2, Ownership.Atom.var 1])
                (Ownership.Expr.focus
                  (Ownership.Atom.var 2)
                  (Ownership.Atom.int 1)
                  3
                  (Ownership.Expr.focus
                    (Ownership.Atom.var 3)
                    (Ownership.Atom.int 0)
                    4
                    (Ownership.Expr.prim (Ownership.Prim.push) [Ownership.Atom.var 4, Ownership.Atom.int 3]))))) }

/-- Frozen v3 seed 20261011 index 7, reduced without using T59 syntax. -/
def oldTowerSeed20261011Index7 : Program := {
  declarations := [Library.initialize (.list (.list (.list .int))),
    { name := "freshTower", parameters := [.int], result := .list (.list (.list .int)),
      body := .letE 1
        (.letE 3 (.prim (.literal .int) []) <|
          .letE 4 (.atom (.var 3)) (.prim (.literal (.list .int)) [.var 4])) <|
        .letE 2 (.atom (.var 1)) (.prim (.literal (.list (.list .int))) [.var 1,.var 2]) }]
  main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
    .letE 2 (.app (.var 0) [.int 1,.var 1]) <| .focus (.var 2) (.int 0) 3 <|
      .focus (.var 3) (.int 0) 4 <| .focus (.var 4) (.int 0) 5 (.prim .push [.var 5,.int 0]) }

/-- Frozen v3 seed 20261011 index 1. Final values agree; external observers differ. -/
def escapeSeed20261011Index1 : Program := {
  main := .letE 0 (.prim (.literal .int) []) <|
    .letE 1 (.traverse .range (.int 1) (.int 0) 2 3 4 <|
      .letE 5 (.prim .shared [.var 0]) (.atom (.var 4))) (.prim .push [.var 0,.int 0]) }

end Ownership.GeneratedRegressions
