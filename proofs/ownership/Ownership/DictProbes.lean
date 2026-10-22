import Ownership.DictPrograms

/-! # The dictionary model's probes (#522, slice 1)

`#guard`s against the real `check` and both runs for the dictionary forms:
`Ty.dict`, `dictEmpty`, `dictInsert`, `dictRemove`, `dictGet`, `dictSize` and
`Expr.dictFocus` (`Syntax.lean`, `Semantics.lean`, `Checker.lean`). The
programs (`DictPrograms.lean`) are `tests/corpus/ownership/DictFocus.beni` (T32, T44, T51),
`DictValueWritten.beni` and #474's tuple payload, in the core's strict ANF
with the focus callback inlined. A finite check: these programs are checked,
nothing is proved.

Every dictionary write (`dictInsert`, `dictRemove`, the focus write-back) is
an in-place write of the entries (#294: a dictionary is its entries in
insertion order, edited in place where the checker accepts the write). So
`reads`, whose body reads the found value and stores a new list at the key, is
refused: the old dictionary is read after the write-back. The Zig checker
accepts `DictFocus.reads` today because core's `Dict.update` builds a new tree
(the old fold, until #294 lands). -/

namespace Ownership.DictProbes

open Ownership.DictPrograms

-- `grow`: accepted, three in-place writes, both runs end at the two entries
-- with the read of the value at key 1.
#guard (check grow).isOk
#guard match ValueSemantics.run grow 100, InPlaceSemantics.run grow 100 with
  | .ok t, .ok t' => t == t' &&
      t.finalValue == .list [.record [.int 1, .list [.int 1, .int 9]], .record [.int 2, .list [.int 2]]] &&
      t.reads == [.list [.int 1]]
  | _, _ => false
#guard InPlaceSemantics.writeCount grow 100 == 3

-- `twice`: refused (the values may share one list; the push is at a
-- container path, so the spine test speaks); the runs end at different
-- dictionaries.
#guard match check twice with
  | .error message => message == "container contents: positions may share"
  | .ok _ => false
#guard match ValueSemantics.run twice 100, InPlaceSemantics.run twice 100 with
  | .ok t, .ok t' => t.reads == t'.reads &&
      t.finalValue == .list [.record [.int 1, .list [.int 1, .int 9]], .record [.int 2, .list [.int 1]]] &&
      t'.finalValue == .list [.record [.int 1, .list [.int 1, .int 9]], .record [.int 2, .list [.int 1, .int 9]]]
  | _, _ => false

-- `valueLater`: refused (the old dictionary holds the value and is read
-- afterwards); the runs read different lengths.
#guard match check valueLater with
  | .error message => message == "exclusive contents: outside live holder"
  | .ok _ => false
#guard match ValueSemantics.run valueLater 100, InPlaceSemantics.run valueLater 100 with
  | .ok t, .ok t' => t.finalValue == .int 1 && t'.finalValue == .int 2
  | _, _ => false

-- `reads`: refused (Dead: the old dictionary is read after the write of its
-- entries), although both runs agree.
#guard match check reads with
  | .error message => message == "Dead: an old holder is live after the demand"
  | .ok _ => false
#guard match ValueSemantics.run reads 100, InPlaceSemantics.run reads 100 with
  | .ok t, .ok t' => t == t' && t.finalValue == .int 2
  | _, _ => false

-- `groups` (T44): accepted, four in-place writes, both runs end at the two
-- groups in insertion order.
#guard (check groups).isOk
#guard match ValueSemantics.run groups 100, InPlaceSemantics.run groups 100 with
  | .ok t, .ok t' => t == t' &&
      t.finalValue == .list [.record [.int 1, .list [.int 1, .int 2]], .record [.int 0, .list [.int 3, .int 4]]] &&
      t.reads == [.int 4, .int 1, .int 2, .list [.int 1], .int 3, .int 4, .list [.int 3]]
  | _, _ => false
#guard InPlaceSemantics.writeCount groups 100 == 4

-- #474: the shared tuple is refused (its positions may share), the fresh
-- tuples are accepted; the shared runs end at different dictionaries.
#guard match check tupleShared with
  | .error message => message == "container contents: positions may share"
  | .ok _ => false
#guard match ValueSemantics.run tupleShared 100, InPlaceSemantics.run tupleShared 100 with
  | .ok t, .ok t' => t.reads == t'.reads &&
      t.finalValue == .list [.record [.int 1, .record [.list [.int 1, .int 9], .int 0]],
        .record [.int 2, .record [.list [.int 1], .int 0]]] &&
      t'.finalValue == .list [.record [.int 1, .record [.list [.int 1, .int 9], .int 0]],
        .record [.int 2, .record [.list [.int 1, .int 9], .int 0]]]
  | _, _ => false
#guard (check tupleFresh).isOk
#guard match ValueSemantics.run tupleFresh 100, InPlaceSemantics.run tupleFresh 100 with
  | .ok t, .ok t' => t == t' &&
      t.finalValue == .list [.record [.int 1, .record [.list [.int 1, .int 9], .int 0]],
        .record [.int 2, .record [.list [.int 1], .int 0]]] &&
      t.reads == [.record [.list [.int 1], .int 0]]
  | _, _ => false
#guard InPlaceSemantics.writeCount tupleFresh 100 == 3

-- `valueWritten`: refused (Dead: the dictionary holds the pushed value and
-- is read afterwards); the runs read different lengths.
#guard match check valueWritten with
  | .error message => message == "Dead: an old holder is live after the demand"
  | .ok _ => false
#guard match ValueSemantics.run valueWritten 100, InPlaceSemantics.run valueWritten 100 with
  | .ok t, .ok t' => t.finalValue == .int 1 && t'.finalValue == .int 2
  | _, _ => false

-- T51: accepted, one in-place write (the added key), no value read by the focus.
#guard (check emptyFocus).isOk
#guard match ValueSemantics.run emptyFocus 100, InPlaceSemantics.run emptyFocus 100 with
  | .ok t, .ok t' => t == t' && t.finalValue == .int 1 && t.reads == [.int 1, .list [.int 5], .int 1]
  | _, _ => false
#guard InPlaceSemantics.writeCount emptyFocus 100 == 1

-- `removeOps`: accepted; the removal of an absent key is not a write.
#guard (check removeOps).isOk
#guard match ValueSemantics.run removeOps 100, InPlaceSemantics.run removeOps 100 with
  | .ok t, .ok t' => t == t' && t.finalValue == .list [.record [.int 2, .list [.int 2, .int 9]]] &&
      t.reads == [.list [.int 2]]
  | _, _ => false
#guard InPlaceSemantics.writeCount removeOps 100 == 4

-- `replaceOps`: accepted; the replaced entry keeps its position.
#guard (check replaceOps).isOk
#guard match ValueSemantics.run replaceOps 100, InPlaceSemantics.run replaceOps 100 with
  | .ok t, .ok t' => t == t' &&
      t.finalValue == .list [.record [.int 1, .list [.int 3]], .record [.int 2, .list [.int 2]]] &&
      t.reads == [.int 0]
  | _, _ => false
#guard InPlaceSemantics.writeCount replaceOps 100 == 3

end Ownership.DictProbes
