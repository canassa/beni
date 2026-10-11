import Ownership.Checker

namespace Ownership
namespace Library

private def v := Atom.var

/-- These are ordinary core declarations. There is no map/initialize/foldl
    constructor in Expr or branch for them in the checker. Types are monomorphized. -/
def map (a b : Ty) : Decl := {
  name := "map"
  parameters := [.list a, .fn [a] b]
  result := .list b
  body := .letE 2 (.prim (.builder b) []) <|
    .letE 3 (.traverse .list (v 0) (v 2) 4 5 6 <|
      .letE 7 (.app (v 1) [v 5]) <|
      .prim .put [v 6, v 7]) <|
    -- The identity shortcut applies only at equal core representations.
    .prim .close (if a == b then [v 3, v 0] else [v 3])
}

def «initialize» (a : Ty) : Decl := {
  name := "initialize"
  parameters := [.int, .fn [.int] a]
  result := .list a
  body := .letE 2 (.prim (.builder a) []) <|
    .letE 3 (.traverse .range (v 0) (v 2) 4 5 6 <|
      .letE 7 (.app (v 1) [v 4]) <|
      .prim .put [v 6, v 7]) <|
    .prim .close [v 3]
}

def foldl (a b : Ty) : Decl := {
  name := "foldl"
  parameters := [.list a, b, .fn [a, b] b]
  result := b
  body := .traverse .list (v 0) (v 1) 3 4 5 (.app (v 2) [v 4, v 5])
}

def update (a : Ty) : Decl := {
  name := "update"
  parameters := [.list a, .int, .fn [a] a]
  result := .list a
  body := .focus (v 0) (v 1) 3 (.app (v 2) [v 3])
}

end Library
end Ownership
