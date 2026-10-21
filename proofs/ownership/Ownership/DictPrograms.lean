import Ownership.Checker
import Ownership.Semantics

/-! # The dictionary model's probe programs (#522, slice 1)

The programs `DictProbes.lean` checks: `tests/corpus/ownership/DictFocus.beni`
(T32, T44, T51), `DictValueWritten.beni` and #474's tuple payload, in the core's
strict ANF with the focus callback inlined. They are a module of their own so
that a later slice can name them in a theorem. -/

namespace Ownership.DictPrograms

def v (n : Nat) : Atom := .var n
def tL : Ty := .list .int
def tR : Ty := .record [tL, .int]

/-- The focus body of `DictFocus.grow`, `twice` and `readLater`,
    `λm → Maybe.map m λv → List.push v 9`, on `found` bound to `f`. -/
def pushNine (f : Var) : Expr :=
  .resultCase (v f) (f + 1) (f + 2) (.prim (.err tL) [v (f + 1)]) <|
    .letE (f + 3) (.prim .push [v (f + 2), .int 9]) <| .prim (.ok .int) [v (f + 3)]

/-- `grow`: two fresh lists at two keys and a focus that pushes onto the value
    at key 1; the dictionary is the result. -/
def grow : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.literal .int) [.int 2]) <|
  .letE 2 (.prim (.dictEmpty tL) []) <|
  .letE 3 (.prim .dictInsert [v 2, .int 1, v 0]) <|
  .letE 4 (.prim .dictInsert [v 3, .int 2, v 1]) <|
  .dictFocus (v 4) (.int 1) 5 (pushNine 5)) }

/-- `twice`: one list at two keys and a focus that pushes onto one of them. -/
def twice : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.dictEmpty tL) []) <|
  .letE 2 (.prim .dictInsert [v 1, .int 1, v 0]) <|
  .letE 3 (.prim .dictInsert [v 2, .int 2, v 0]) <|
  .dictFocus (v 3) (.int 1) 4 (pushNine 4)) }

/-- `readLater`, with the value read through the old dictionary afterwards,
    so that the two runs differ. -/
def valueLater : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.dictEmpty tL) []) <|
  .letE 2 (.prim .dictInsert [v 1, .int 1, v 0]) <|
  .letE 3 (.dictFocus (v 2) (.int 1) 4 (pushNine 4)) <|
  .letE 8 (.prim .dictGet [v 2, .int 1]) <|
  .resultCase (v 8) 9 10 (.atom (.int 0)) (.prim .length [v 10])) }

/-- `reads`: the body reads the found value and answers a fresh list, which
    the focus stores at the key; the old dictionary and the new one are read
    afterwards through their sizes, which a replace does not change. -/
def reads : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.dictEmpty tL) []) <|
  .letE 2 (.prim .dictInsert [v 1, .int 1, v 0]) <|
  .letE 3 (.dictFocus (v 2) (.int 1) 4
    (.resultCase (v 4) 5 6
      (.letE 7 (.prim (.literal .int) [.int 0]) <| .prim (.ok .int) [v 7])
      (.letE 7 (.prim .length [v 6]) <| .letE 8 (.prim (.literal .int) [v 7]) <| .prim (.ok .int) [v 8]))) <|
  .letE 9 (.prim .dictSize [v 2]) <|
  .letE 10 (.prim .dictSize [v 3]) <|
  .prim .add [v 9, v 10]) }

/-- `groups` (T44): a traversal over `[1, 2, 3, 4]` from an empty dictionary
    that focuses on the key `x < 3` and pushes `x` onto the group, or starts
    the group with `[x]`. -/
def groups : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1, .int 2, .int 3, .int 4]) <|
  .letE 1 (.prim (.dictEmpty tL) []) <|
  .traverse .list (v 0) (v 1) 2 3 4
    (.letE 5 (.prim .lt [v 3, .int 3]) <|
     .dictFocus (v 4) (v 5) 6
       (.resultCase (v 6) 7 8
         (.letE 9 (.prim (.literal .int) [v 3]) <| .prim (.ok .int) [v 9])
         (.letE 9 (.prim .push [v 8, v 3]) <| .prim (.ok .int) [v 9])))) }

/-- The focus body of #474: push onto the tuple's list and rebuild the tuple. -/
def pushTuple (f : Var) : Expr :=
  .resultCase (v f) (f + 1) (f + 2) (.prim (.err tR) [v (f + 1)]) <|
    .letE (f + 3) (.prim .push [.field (v (f + 2)) 0, .int 9]) <|
    .letE (f + 4) (.prim .record [v (f + 3), .field (v (f + 2)) 1]) <|
    .prim (.ok .int) [v (f + 4)]

/-- #474: one tuple `(xs, 0)` at two keys and a focus that pushes onto its list. -/
def tupleShared : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim .record [v 0, .int 0]) <|
  .letE 2 (.prim (.dictEmpty tR) []) <|
  .letE 3 (.prim .dictInsert [v 2, .int 1, v 1]) <|
  .letE 4 (.prim .dictInsert [v 3, .int 2, v 1]) <|
  .dictFocus (v 4) (.int 1) 5 (pushTuple 5)) }

/-- #474's control: a fresh tuple at each key. -/
def tupleFresh : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim .record [v 0, .int 0]) <|
  .letE 2 (.prim (.literal .int) [.int 1]) <|
  .letE 3 (.prim .record [v 2, .int 0]) <|
  .letE 4 (.prim (.dictEmpty tR) []) <|
  .letE 5 (.prim .dictInsert [v 4, .int 1, v 1]) <|
  .letE 6 (.prim .dictInsert [v 5, .int 2, v 3]) <|
  .dictFocus (v 6) (.int 1) 7 (pushTuple 7)) }

/-- `DictValueWritten`: a value got out of the dictionary is pushed while the
    dictionary is read afterwards. -/
def valueWritten : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.dictEmpty tL) []) <|
  .letE 2 (.prim .dictInsert [v 1, .int 1, v 0]) <|
  .letE 3 (.prim .dictGet [v 2, .int 1]) <|
  .resultCase (v 3) 4 5 (.atom (.int 0))
    (.letE 6 (.prim .push [v 5, .int 1]) <|
     .letE 7 (.prim .dictGet [v 2, .int 1]) <|
     .resultCase (v 7) 8 9 (.atom (.int 0)) (.prim .length [v 9]))) }

/-- T51: a focus on an absent key of an empty dictionary adds the key; the
    result is read and the new value counted. -/
def emptyFocus : Program := { main := (
  .letE 0 (.prim (.dictEmpty tL) []) <|
  .letE 1 (.dictFocus (v 0) (.int 7) 2
    (.resultCase (v 2) 3 4
      (.letE 5 (.prim (.literal .int) [.int 5]) <| .prim (.ok .int) [v 5])
      (.prim (.ok .int) [v 4]))) <|
  .letE 6 (.prim .dictSize [v 1]) <|
  .letE 7 (.prim .dictGet [v 1, .int 7]) <|
  .resultCase (v 7) 8 9 (.atom (.int 0)) (.prim .length [v 9])) }

/-- Two keys, one removed, one absent key removed, a push onto the other. -/
def removeOps : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.literal .int) [.int 2]) <|
  .letE 2 (.prim (.dictEmpty tL) []) <|
  .letE 3 (.prim .dictInsert [v 2, .int 1, v 0]) <|
  .letE 4 (.prim .dictInsert [v 3, .int 2, v 1]) <|
  .letE 5 (.prim .dictRemove [v 4, .int 1]) <|
  .letE 6 (.prim .dictRemove [v 5, .int 3]) <|
  .dictFocus (v 6) (.int 2) 7 (pushNine 7)) }

/-- An insert at a key already in replaces the entry in place, and a lookup of
    an absent key reads `0`. -/
def replaceOps : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim (.literal .int) [.int 2]) <|
  .letE 2 (.prim (.literal .int) [.int 3]) <|
  .letE 3 (.prim (.dictEmpty tL) []) <|
  .letE 4 (.prim .dictInsert [v 3, .int 1, v 0]) <|
  .letE 5 (.prim .dictInsert [v 4, .int 2, v 1]) <|
  .letE 6 (.prim .dictInsert [v 5, .int 1, v 2]) <|
  .letE 7 (.prim .dictGet [v 6, .int 9]) <|
  .resultCase (v 7) 8 9 (.atom (v 6)) (.atom (v 6))) }

end Ownership.DictPrograms
