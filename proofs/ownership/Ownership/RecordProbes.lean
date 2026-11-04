import Ownership.RecordPrograms
import Ownership.Reinfer

/-! # The record model's probes (#316, slice 1)

`#guard`s against the real `check` and both runs for the record objects:
`Ty.object`, `object`, `get`, `recordCopy` and `Expr.assign` (`Syntax.lean`,
`Semantics.lean`, `Checker.lean`; `ownership-checker.md` §31). The programs
are in `RecordPrograms.lean`. A finite check: these programs are checked,
nothing is proved.

An accepted program's two runs agree. A refused program's runs differ, except
where the comment says that the refusal is this core's imprecision:
`calleeKept` (a summary's write names the object, not its fields). Two
refusals differ from the Zig checker on purpose: `writtenRead` (the Zig
lowering hoists the read, §31.14; this core has no hoist) and `calleeKept`
(no `W{F}` yet). One acceptance differs: `sameFieldTwice` (Zig reads an
update's base as a whole use, §31.4 item 5; this core reads the fields the
update keeps, which is sound). -/

namespace Ownership.RecordProbes

open Ownership.RecordPrograms

/-- Both runs finish and agree. -/
def agree (p : Program) : Bool :=
  match ValueSemantics.run p 200, InPlaceSemantics.run p 200 with
  | .ok t, .ok t' => t == t'
  | _, _ => false

/-- The checker refuses `p` with `message`. -/
def refused (p : Program) (message : String) : Bool :=
  match check p with
  | .error m => m == message
  | .ok _ => false

def dead := "Dead: an old holder is live after the demand"

/-! ## Reads after an update -/

-- A field the update keeps, read through the old holder: accepted, one write.
#guard (check keptRead).isOk && agree keptRead && InPlaceSemantics.writeCount keptRead 200 == 1
#guard match ValueSemantics.run keptRead 200 with
  | .ok t => t.finalValue == .int 7 | _ => false

-- The written field, read through the old holder: refused (no hoist here);
-- the in-place run reads the new value.
#guard refused writtenRead dead
#guard match ValueSemantics.run writtenRead 200, InPlaceSemantics.run writtenRead 200 with
  | .ok t, .ok t' => t.finalValue == .int 6 && t'.finalValue == .int 10
  | _, _ => false

-- The same read placed before the write, as the lowering places it: accepted.
#guard (check hoistedRead).isOk && agree hoistedRead
#guard match ValueSemantics.run hoistedRead 200 with
  | .ok t => t.finalValue == .int 6 | _ => false

-- The old holder used whole: refused; in place both components are the new
-- record.
#guard refused wholeUse dead
#guard match ValueSemantics.run wholeUse 200, InPlaceSemantics.run wholeUse 200 with
  | .ok t, .ok t' =>
    t.finalValue == .record [.list [.record [.int 1, .int 2]], .list [.record [.int 5, .int 2]]] &&
    t'.finalValue == .record [.list [.record [.int 5, .int 2]], .list [.record [.int 5, .int 2]]]
  | _, _ => false

-- A local bound before the update, read at a kept field: accepted.
#guard (check aliasKept).isOk && agree aliasKept

/-! ## #316's three two-holder shapes -/

-- A stored payload read at the written field: refused; read at a kept field:
-- accepted.
#guard refused payloadRead dead
#guard match ValueSemantics.run payloadRead 200, InPlaceSemantics.run payloadRead 200 with
  | .ok t, .ok t' => (match t.finalValue, t'.finalValue with
    | .record [_, .int 1], .record [_, .int 7] => true
    | _, _ => false)
  | _, _ => false
#guard (check payloadKept).isOk && agree payloadKept

-- One form at two model paths, written through one: refused; two forms:
-- accepted.
#guard refused twoPaths dead
#guard match ValueSemantics.run twoPaths 200, InPlaceSemantics.run twoPaths 200 with
  | .ok t, .ok t' => t.finalValue == .int 1 && t'.finalValue == .int 7
  | _, _ => false
#guard (check twoForms).isOk && agree twoForms

-- A command that keeps the model whole: the form's write is refused
-- (escaped), and the kept closure observes the write in place. A command
-- that keeps the field's value: accepted.
#guard refused captureWhole "Unescaped: program-lifetime holder"
#guard match ValueSemantics.run captureWhole 200, InPlaceSemantics.run captureWhole 200 with
  | .ok t, .ok t' => t.finalValue == t'.finalValue && t.externalReads != t'.externalReads
  | _, _ => false
#guard (check captureField).isOk && agree captureField
#guard match ValueSemantics.run captureField 200 with
  | .ok t => t.finalValue == .int 10 | _ => false

-- A traversal whose step writes each record: accepted for two fresh rows,
-- refused for one row at two positions and for rows read afterwards.
#guard (check forItems).isOk && agree forItems && InPlaceSemantics.writeCount forItems 200 == 4
#guard match ValueSemantics.run forItems 200 with
  | .ok t => t.finalValue == .list [.list [.record [.int 1, .int 1]], .list [.record [.int 2, .int 1]]]
  | _ => false
#guard refused forShared "exclusive contents: positions or nested paths may share"
#guard match ValueSemantics.run forShared 200, InPlaceSemantics.run forShared 200 with
  | .ok t, .ok t' =>
    t.finalValue == .list [.list [.record [.int 1, .int 1]], .list [.record [.int 1, .int 1]]] &&
    t'.finalValue == .list [.list [.record [.int 1, .int 2]], .list [.record [.int 1, .int 2]]]
  | _, _ => false
#guard refused forLive "exclusive contents: outside live holder"
#guard match ValueSemantics.run forLive 200, InPlaceSemantics.run forLive 200 with
  | .ok t, .ok t' => (match t.finalValue, t'.finalValue with
    | .record [rows, _], .record [rows', _] =>
      rows == .list [.list [.record [.int 1, .int 0]], .list [.record [.int 2, .int 0]]] &&
      rows' == .list [.list [.record [.int 1, .int 1]], .list [.record [.int 2, .int 1]]]
    | _, _ => false)
  | _, _ => false

/-! ## The other conditions -/

-- A top-level record: refused (Unescaped); the program-lifetime holder
-- observes the write in place.
#guard refused topLevel "Unescaped: shared cell"
#guard match ValueSemantics.run topLevel 200, InPlaceSemantics.run topLevel 200 with
  | .ok t, .ok t' => t.finalValue == t'.finalValue && t.externalReads != t'.externalReads
  | _, _ => false

-- `Record.copy` as the fix: accepted, the old record unchanged.
#guard (check copied).isOk && agree copied
#guard match ValueSemantics.run copied 200 with
  | .ok t => t.finalValue == .record [.list [.record [.int 1, .int 2]], .list [.record [.int 5, .int 2]]]
  | _ => false

-- A nested update: accepted. The outer store puts back the object the field
-- already holds, so only the inner write changes an array.
#guard (check nested).isOk && agree nested && InPlaceSemantics.writeCount nested 200 == 1

-- Two updates through the old holder: the second reads a field the first
-- wrote, refused; the same field twice, the first result dead: accepted.
#guard refused twoUpdates dead
#guard match ValueSemantics.run twoUpdates 200, InPlaceSemantics.run twoUpdates 200 with
  | .ok t, .ok t' => t.finalValue == .list [.record [.int 0, .int 2]] &&
    t'.finalValue == .list [.record [.int 1, .int 2]]
  | _, _ => false
#guard (check sameFieldTwice).isOk && agree sameFieldTwice

-- A record made to hold itself through a closure that captures it whole:
-- refused before Disjoint, because a closure capturing a record with a
-- function field is a limit of the summaries; the in-place heap is cyclic,
-- so its run fails. The closure that captures a field's value: accepted.
#guard refused selfHandler "limit: function value below an input path"
#guard match ValueSemantics.run selfHandler 200, InPlaceSemantics.run selfHandler 200 with
  | .ok _, .error _ => true
  | _, _ => false
#guard (check fieldHandler).isOk && agree fieldHandler

-- A callee that writes its record parameter: accepted where the argument is
-- dead after the call, refused where the caller reads the written field, and
-- refused where it reads a kept field (this core's imprecision: no `W{F}`),
-- although those runs agree.
#guard (check callee).isOk && agree callee
#guard refused calleeWritten dead
#guard match ValueSemantics.run calleeWritten 200, InPlaceSemantics.run calleeWritten 200 with
  | .ok t, .ok t' => t.finalValue == .int 5 && t'.finalValue == .int 8
  | _, _ => false
#guard refused calleeKept dead && agree calleeKept

/-! ## Write extent (#670) -/

-- An update writes the object's slot, not the list in it: the old list is
-- pushed afterwards, accepted, two writes.
#guard (check heldField).isOk && agree heldField && InPlaceSemantics.writeCount heldField 200 == 2
-- The twin keeps the list in the new record: the push is refused, and in
-- place the record sees it.
#guard refused heldFieldKept dead
#guard match ValueSemantics.run heldFieldKept 200, InPlaceSemantics.run heldFieldKept 200 with
  | .ok t, .ok t' =>
    t.finalValue == .record [.list [.record [.list [.int 1], .int 1]], .list [.int 1, .int 2]] &&
    t'.finalValue == .record [.list [.record [.list [.int 1, .int 2], .int 1]], .list [.int 1, .int 2]]
  | _, _ => false

/-! ## A closure that writes its captured record -/

-- Called once: accepted. Called twice: refused; in place the second call
-- sees the first one's write.
#guard (check bumpOnce).isOk && agree bumpOnce
#guard refused bumpTwice dead
#guard match ValueSemantics.run bumpTwice 200, InPlaceSemantics.run bumpTwice 200 with
  | .ok t, .ok t' => t.finalValue == .int 2 && t'.finalValue == .int 4
  | _, _ => false

/-! ## The frozen per-call checker refuses the record forms as a limit -/

#guard match Reinfer.check keptRead with
  | .error m => m == "limit: record object in frozen per-call checker"
  | .ok _ => false
#guard match Reinfer.check callee with
  | .error m => m == "limit: record object in frozen per-call checker"
  | .ok _ => false

end Ownership.RecordProbes
