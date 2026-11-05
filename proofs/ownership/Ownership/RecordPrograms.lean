import Ownership.Checker
import Ownership.Semantics

/-! # The record model's probe programs (#316, slice 1)

The programs `RecordProbes.lean` checks: record field assignment on record
objects (`Ty.object`, `Expr.assign`; `ownership-checker.md` §31), in the core's
strict ANF. They include #316's three ways one model record can have two
holders — a stored message payload, a captured `model.form`, and a `For` item
— each with an accepted control and a refused one. A record object is a
one-slot array whose element is the record, so a field read is `get` and an
update is `Expr.assign`. They are a module of their own so that a later slice
can name them in a theorem. -/

namespace Ownership.RecordPrograms

def v (n : Nat) : Atom := .var n
def tL : Ty := .list .int
/-- `{ a : Int, b : Int }`, and a form `{ name : Int, count : Int }`. -/
def tP : Ty := .object [.int, .int]
/-- A model `{ form : Form, total : Int }`. -/
def tM : Ty := .object [tP, .int]
/-- A model whose two fields hold forms: `{ form : Form, saved : Form }`. -/
def tS : Ty := .object [tP, tP]
/-- A record with a list field: `{ items : List Int, n : Int }`. -/
def tI : Ty := .object [tL, .int]

/-! ## Reads after an update (§31.4 item 5) -/

/-- `s = { r | a = 5 }` and then `r.b`, a field the update keeps: no use of
    the object. -/
def keptRead : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.assign 2 [0] (v 0) [.int 5]) <|
  .letE 2 (.prim (.get 1) [v 0]) <|
  .letE 3 (.prim (.get 0) [v 1]) <|
  .prim .add [v 2, v 3]) }

/-- `s = { r | a = 5 }` and then `r.a`, the written field, through the old
    holder. The Zig checker hoists the read before the write (§31.14); this
    core has no hoist, so its in-place run reads `5` where value semantics
    reads `1`. -/
def writtenRead : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.assign 2 [0] (v 0) [.int 5]) <|
  .letE 2 (.prim (.get 0) [v 0]) <|
  .letE 3 (.prim (.get 0) [v 1]) <|
  .prim .add [v 2, v 3]) }

/-- `writtenRead` as the lowering writes it: the read of `r.a` before the
    write. -/
def hoistedRead : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.prim (.get 0) [v 0]) <|
  .letE 2 (.assign 2 [0] (v 0) [.int 5]) <|
  .letE 3 (.prim (.get 0) [v 2]) <|
  .prim .add [v 1, v 3]) }

/-- `( r, { r | a = 5 } )`: the old holder used whole after the update. -/
def wholeUse : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.assign 2 [0] (v 0) [.int 5]) <|
  .prim .record [v 0, v 1]) }

/-- An update that writes every field: its base use reads nothing, and the
    old holder is dead. -/
def allFields : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.assign 2 [0, 1] (v 0) [.int 5, .int 6]) <|
  .prim (.get 1) [v 1]) }

/-- Declaration 0, a closure that captures a record and reads field `a`. -/
def readers : List Decl := [
  { name := "readA", parameters := [], captures := [tP], result := .int,
    body := .prim (.get 0) [v 0] }]

/-- `allFields` with the old holder captured whole after the update and read
    through the closure. -/
def allFieldsCaptured : Program := { declarations := readers, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.assign 2 [0, 1] (v 0) [.int 5, .int 6]) <|
  .letE 2 (.closure 0 [v 0]) <|
  .letE 3 (.app (v 2) []) <|
  .letE 4 (.prim (.get 1) [v 1]) <|
  .prim .add [v 3, v 4]) }

/-- A local bound to the record before the update (§31.0 item 7), read at a
    field the update keeps. -/
def aliasKept : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.atom (v 0)) <|
  .letE 2 (.assign 2 [0] (v 0) [.int 5]) <|
  .letE 3 (.prim (.get 1) [v 1]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-! ## #316's three two-holder shapes -/

/-- A stored message payload: the model's form is also held by a message
    (`Saved form`, a tuple here), and the arm writes the form; the message is
    read afterwards (`RecordPayload`'s shape). -/
def payloadRead : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim .record [v 0]) <|
  .letE 3 (.prim (.get 0) [v 1]) <|
  .letE 4 (.assign 2 [0] (v 3) [.int 7]) <|
  .letE 5 (.assign 2 [0] (v 1) [v 4]) <|
  .letE 6 (.prim (.get 0) [.field (v 2) 0]) <|
  .prim .record [v 5, v 6]) }

/-- `payloadRead`'s control: the message reads only the count, a field the
    update keeps. -/
def payloadKept : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim .record [v 0]) <|
  .letE 3 (.prim (.get 0) [v 1]) <|
  .letE 4 (.assign 2 [0] (v 3) [.int 7]) <|
  .letE 5 (.assign 2 [0] (v 1) [v 4]) <|
  .letE 6 (.prim (.get 1) [.field (v 2) 0]) <|
  .prim .record [v 5, v 6]) }

/-- `RecordPayload`'s `Rename` after `Saved form`: one form at two model paths
    (`form` and `saved`), and the arm writes `model.saved`. -/
def twoPaths : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, v 0]) <|
  .letE 2 (.prim (.get 1) [v 1]) <|
  .letE 3 (.assign 2 [0] (v 2) [.int 7]) <|
  .letE 4 (.assign 2 [1] (v 1) [v 3]) <|
  .letE 5 (.prim (.get 0) [v 4]) <|
  .prim (.get 0) [v 5]) }

/-- `twoPaths`'s control: a fresh form at each model path. -/
def twoForms : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [.int 1, .int 0]) <|
  .letE 2 (.prim .object [v 0, v 1]) <|
  .letE 3 (.prim (.get 1) [v 2]) <|
  .letE 4 (.assign 2 [0] (v 3) [.int 7]) <|
  .letE 5 (.assign 2 [1] (v 2) [v 4]) <|
  .letE 6 (.prim (.get 0) [v 5]) <|
  .prim (.get 0) [v 6]) }

/-- Declaration 0, a command's closure that captures the model whole and
    reads its total (`RecordCapture`'s `Snapshot`); declaration 1, one that
    captures a number (`RecordCaptureField`'s `Save`, the field path read when
    the closure is made, §31.6). -/
def commands : List Decl := [
  { name := "snapshot", parameters := [], captures := [tM], result := .int,
    body := .prim (.get 1) [v 0] },
  { name := "save", parameters := [], captures := [.int], result := .int,
    body := .atom (v 0) }]

/-- A captured `model.form`: a command keeps a closure that captures the
    model whole (`shared`), and the arm writes the model's form through a
    nested update. -/
def captureWhole : Program := { declarations := commands, main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.closure 0 [v 1]) <|
  .letE 3 (.prim .shared [v 2]) <|
  .letE 4 (.prim (.get 0) [v 1]) <|
  .letE 5 (.assign 2 [0] (v 4) [.int 9]) <|
  .letE 6 (.assign 2 [0] (v 1) [v 5]) <|
  .app (v 3) []) }

/-- `captureWhole`'s control: the command captures `model.form.name`, read
    when the closure is made, so it keeps a number and not the model. -/
def captureField : Program := { declarations := commands, main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim (.get 0) [v 1]) <|
  .letE 3 (.prim (.get 0) [v 2]) <|
  .letE 4 (.closure 1 [v 3]) <|
  .letE 5 (.prim .shared [v 4]) <|
  .letE 6 (.prim (.get 0) [v 1]) <|
  .letE 7 (.assign 2 [0] (v 6) [.int 9]) <|
  .letE 8 (.assign 2 [0] (v 1) [v 7]) <|
  .letE 9 (.app (v 5) []) <|
  .letE 10 (.prim (.get 0) [v 8]) <|
  .letE 11 (.prim (.get 0) [v 10]) <|
  .prim .add [v 9, v 11]) }

/-- A `For` item: a traversal over a list of records whose step writes each
    record it is handed, `{ x | count = x.count + 1 }`, and collects them. -/
def forStep (x acc : Var) : Expr :=
  .letE (acc + 1) (.prim (.get 1) [v x]) <|
  .letE (acc + 2) (.prim .add [v (acc + 1), .int 1]) <|
  .letE (acc + 3) (.assign 2 [1] (v x) [v (acc + 2)]) <|
  .prim .push [v acc, v (acc + 3)]

/-- Two fresh rows: the step's writes are accepted. -/
def forItems : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [.int 2, .int 0]) <|
  .letE 2 (.prim (.literal tP) [v 0, v 1]) <|
  .letE 3 (.prim (.literal tP) []) <|
  .traverse .list (v 2) (v 3) 4 5 6 (forStep 5 6)) }

/-- One row at two positions, `[ r, r ]` (§31.4 item 6): the list is not
    exclusive, and in place the row is written twice. -/
def forShared : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim (.literal tP) [v 0, v 0]) <|
  .letE 2 (.prim (.literal tP) []) <|
  .traverse .list (v 1) (v 2) 3 4 5 (forStep 4 5)) }

/-- The rows read after the traversal wrote them (`List.map model.rows …` and
    then `model.rows`, §31.5). -/
def forLive : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [.int 2, .int 0]) <|
  .letE 2 (.prim (.literal tP) [v 0, v 1]) <|
  .letE 3 (.prim (.literal tP) []) <|
  .letE 4 (.traverse .list (v 2) (v 3) 5 6 7 (forStep 6 7)) <|
  .prim .record [v 2, v 4]) }

/-! ## The other conditions -/

/-- A top-level record (`shared`, §31.8): its write is refused (Unescaped). -/
def topLevel : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.prim .shared [v 0]) <|
  .letE 2 (.assign 2 [0] (v 1) [.int 5]) <|
  .prim (.get 0) [v 2]) }

/-- `{ Record.copy r | a = 5 }` with `r` kept (§31.15): the fix. -/
def copied : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.prim .recordCopy [v 0]) <|
  .letE 2 (.assign 2 [0] (v 1) [.int 5]) <|
  .prim .record [v 0, v 2]) }

/-- A nested update (§31.3), `{ model | form = { form | name = 7 } }` with
    `form = model.form`: two demands, both accepted. -/
def nested : Program := { main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim (.get 0) [v 1]) <|
  .letE 3 (.assign 2 [0] (v 2) [.int 7]) <|
  .letE 4 (.assign 2 [0] (v 1) [v 3]) <|
  .letE 5 (.prim (.get 0) [v 4]) <|
  .prim (.get 0) [v 5]) }

/-- Two updates through the old holder: `{ r | a = 1 }` and then
    `{ r | b = 2 }`. The second reads `r.a`, which the first wrote. -/
def twoUpdates : Program := { main := (
  .letE 0 (.prim .object [.int 0, .int 0]) <|
  .letE 1 (.assign 2 [0] (v 0) [.int 1]) <|
  .letE 2 (.assign 2 [1] (v 0) [.int 2]) <|
  .atom (v 2)) }

/-- Two updates of one field through the old holder, the first result dead:
    the second keeps only `b`, which neither writes. -/
def sameFieldTwice : Program := { main := (
  .letE 0 (.prim .object [.int 0, .int 0]) <|
  .letE 1 (.assign 2 [0] (v 0) [.int 1]) <|
  .letE 2 (.assign 2 [0] (v 0) [.int 2]) <|
  .atom (v 2)) }

/-- Declarations 0 and 1: a handler that returns `0`, and one that captures a
    record whole and reads its count; declaration 2 captures a number. A
    record `{ handler : ⊤ → Int, count : Int }`. -/
def handlers : List Decl := [
  { name := "zero", parameters := [], captures := [], result := .int, body := .atom (.int 0) },
  { name := "count", parameters := [], captures := [.object [.fn [] .int, .int]], result := .int,
    body := .prim (.get 1) [v 0] },
  { name := "number", parameters := [], captures := [.int], result := .int, body := .atom (v 0) }]

/-- `{ r | handler = λ⊤ → r.count }` with the closure capturing `r` whole
    (§31.4 item 3): the record would contain itself. -/
def selfHandler : Program := { declarations := handlers, main := (
  .letE 0 (.closure 0 []) <|
  .letE 1 (.prim .object [v 0, .int 2]) <|
  .letE 2 (.closure 1 [v 1]) <|
  .letE 3 (.assign 2 [0] (v 1) [v 2]) <|
  .atom (v 3)) }

/-- `selfHandler`'s control: the closure captures `r.count`, read when it is
    made (§31.6). -/
def fieldHandler : Program := { declarations := handlers, main := (
  .letE 0 (.closure 0 []) <|
  .letE 1 (.prim .object [v 0, .int 2]) <|
  .letE 2 (.prim (.get 1) [v 1]) <|
  .letE 3 (.closure 2 [v 2]) <|
  .letE 4 (.assign 2 [0] (v 1) [v 3]) <|
  .letE 5 (.prim (.get 0) [v 4]) <|
  .app (v 5) []) }

/-- Declaration 0, `shift p = { p | a = p.a + 3 }`: a callee that writes its
    record parameter. -/
def shifts : List Decl := [
  { name := "shift", parameters := [tP], result := tP,
    body := .letE 1 (.prim (.get 0) [v 0]) <| .letE 2 (.prim .add [v 1, .int 3]) <|
      .assign 2 [0] (v 0) [v 2] }]

/-- `shift r`, its result read. -/
def callee : Program := { declarations := shifts, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .prim (.get 0) [v 2]) }

/-- `shift r`, then `r.a`, the field the callee wrote. -/
def calleeWritten : Program := { declarations := shifts, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.prim (.get 0) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `shift r`, then `r.b`, a field the callee keeps. The summary's write names
    its field, `π1 W{a}` (§31.7, #1872), so the call's Dead test reads the
    later `r.b` per field: no use of the object. -/
def calleeKept : Program := { declarations := shifts, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.prim (.get 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `s = { r | a = 5 }`, then `shift r`: the callee reads `r.a`, the field
    the update wrote. An argument is a whole use, so the update is refused. -/
def updateThenCallee : Program := { declarations := shifts, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.assign 2 [0] (v 0) [.int 5]) <|
  .letE 3 (.app (v 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .letE 5 (.prim (.get 0) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-- `shift r` twice: the second call hands `r` whole to a callee that reads
    `r.a`, which the first call wrote (§31.7's `(shift 3 origin).x`). The
    first call is refused. -/
def calleeTwice : Program := { declarations := shifts, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.app (v 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .letE 5 (.prim (.get 0) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-- `{ a : Int, b : Int, c : Int }`. -/
def tQ : Ty := .object [.int, .int, .int]

/-- Declaration 0, `shiftA p = { p | a = p.a + 3 }`; declaration 1,
    `shiftAB p = { shiftA p | b = 9 }`, which writes `a` through its callee
    and `b` itself: `π1 W{a, b}`. Declaration 2, `either c p`, which writes
    `a` in one arm and `b` in the other: the arms join to `π2 W{a, b}`. -/
def layers : List Decl := [
  { name := "shiftA", parameters := [tQ], result := tQ,
    body := .letE 1 (.prim (.get 0) [v 0]) <| .letE 2 (.prim .add [v 1, .int 3]) <|
      .assign 3 [0] (v 0) [v 2] },
  { name := "shiftAB", parameters := [tQ], result := tQ,
    body := .letE 1 (.closure 0 []) <| .letE 2 (.app (v 1) [v 0]) <|
      .assign 3 [1] (v 2) [.int 9] },
  { name := "either", parameters := [.int, tQ], result := tQ,
    body := .branch (v 0) (.assign 3 [0] (v 1) [.int 7]) (.assign 3 [1] (v 1) [.int 8]) }]

/-- `s = shiftAB r`, then `r.c`: neither layer writes `c`. -/
def layersKept : Program := { declarations := layers, main := (
  .letE 0 (.prim .object [.int 1, .int 2, .int 3]) <|
  .letE 1 (.closure 1 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.prim (.get 2) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `s = shiftAB r`, then `r.b`: the outer layer wrote `b`. -/
def layersWritten : Program := { declarations := layers, main := (
  .letE 0 (.prim .object [.int 1, .int 2, .int 3]) <|
  .letE 1 (.closure 1 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.prim (.get 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `s = either 0 r`, then `r.c`: no arm writes `c`. -/
def eitherKept : Program := { declarations := layers, main := (
  .letE 0 (.prim .object [.int 1, .int 2, .int 3]) <|
  .letE 1 (.closure 2 []) <|
  .letE 2 (.app (v 1) [.int 0, v 0]) <|
  .letE 3 (.prim (.get 2) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `s = either 0 r`, then `r.a`: the arm that the run takes writes `a`. -/
def eitherWritten : Program := { declarations := layers, main := (
  .letE 0 (.prim .object [.int 1, .int 2, .int 3]) <|
  .letE 1 (.closure 2 []) <|
  .letE 2 (.app (v 1) [.int 0, v 0]) <|
  .letE 3 (.prim (.get 0) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- Declaration 0, `shift`; declaration 1, `applyTo f p = f p`. A write
    through a callback is a consume row, which has no field set. -/
def applies : List Decl := shifts ++ [
  { name := "applyTo", parameters := [.fn [tP] tP, tP], result := tP,
    body := .app (v 0) [v 1] }]

/-- `s = applyTo shift r`, then `r.b`: the consume is whole, so the later
    read of the kept field is a use. Refused, although the runs agree. -/
def callbackKept : Program := { declarations := applies, main := (
  .letE 0 (.prim .object [.int 1, .int 2]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.closure 1 []) <|
  .letE 3 (.app (v 2) [v 1, v 0]) <|
  .letE 4 (.prim (.get 1) [v 0]) <|
  .letE 5 (.prim (.get 0) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-! ## Write extent (#670): an update is a storage write of the object -/

/-- `t = r.items; s = { r | items = [] }; List.push t 2`: the update replaces
    the object's slot and writes no value in it, so the old list `t` holds is
    still the program's own after it. -/
def heldField : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim (.get 0) [v 1]) <|
  .letE 3 (.prim (.literal .int) []) <|
  .letE 4 (.assign 2 [0] (v 1) [v 3]) <|
  .letE 5 (.prim .push [v 2, .int 2]) <|
  .prim .record [v 4, v 5]) }

/-- `heldField`'s twin: the update keeps `items`, so the new record still
    holds the list that the push writes. -/
def heldFieldKept : Program := { main := (
  .letE 0 (.prim (.literal .int) [.int 1]) <|
  .letE 1 (.prim .object [v 0, .int 0]) <|
  .letE 2 (.prim (.get 0) [v 1]) <|
  .letE 3 (.assign 2 [1] (v 1) [.int 1]) <|
  .letE 4 (.prim .push [v 2, .int 2]) <|
  .prim .record [v 3, v 4]) }

/-! ## A closure that writes its captured record (§31.4 item 4) -/

/-- Declaration 0, `λ⊤ → { r | count = r.count + 1 }`, capturing `r`. -/
def bumps : List Decl := [
  { name := "bump", parameters := [], captures := [tP], result := tP,
    body := .letE 1 (.prim (.get 1) [v 0]) <| .letE 2 (.prim .add [v 1, .int 1]) <|
      .assign 2 [1] (v 0) [v 2] }]

/-- The writing closure called once. -/
def bumpOnce : Program := { declarations := bumps, main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.closure 0 [v 0]) <|
  .letE 2 (.app (v 1) []) <|
  .prim (.get 1) [v 2]) }

/-- The writing closure called twice: it is once. -/
def bumpTwice : Program := { declarations := bumps, main := (
  .letE 0 (.prim .object [.int 1, .int 0]) <|
  .letE 1 (.closure 0 [v 0]) <|
  .letE 2 (.app (v 1) []) <|
  .letE 3 (.app (v 1) []) <|
  .letE 4 (.prim (.get 1) [v 2]) <|
  .letE 5 (.prim (.get 1) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-! ## The targeted product (#1872)

Templates of the record rules, over a starting value `n`: a read after an
update, at the written field or the kept one; two updates through one holder;
a read after a call that writes a field, at that field or the kept one; an
update and then a call that reads the written field; two calls in turn. Under
the record controls (`record-dead`, `update-base`, `call-fields`) the refused
ones are accepted and their runs differ. -/

/-- `r = { a = n, b = n + 1 }; s = { r | f_written = n + 5 }`, then `r.f_later`. -/
def readAfter (n : Int) (written later : Nat) : Program := { main := (
  .letE 0 (.prim .object [.int n, .int (n + 1)]) <|
  .letE 1 (.assign 2 [written] (v 0) [.int (n + 5)]) <|
  .letE 2 (.prim (.get later) [v 0]) <|
  .letE 3 (.prim (.get 0) [v 1]) <|
  .prim .add [v 2, v 3]) }

/-- `{ r | f_first = n + 5 }`, the result dead, then `{ r | f_second = n + 7 }`. -/
def updateTwice (n : Int) (first second : Nat) : Program := { main := (
  .letE 0 (.prim .object [.int n, .int (n + 1)]) <|
  .letE 1 (.assign 2 [first] (v 0) [.int (n + 5)]) <|
  .letE 2 (.assign 2 [second] (v 0) [.int (n + 7)]) <|
  .atom (v 2)) }

/-- Declaration 0, `p ↦ { p | f_written = p.f_written + 3 }`. -/
def writerOf (written : Nat) : List Decl := [
  { name := "writeField", parameters := [tP], result := tP,
    body := .letE 1 (.prim (.get written) [v 0]) <| .letE 2 (.prim .add [v 1, .int 3]) <|
      .assign 2 [written] (v 0) [v 2] }]

/-- `s = writeField r`, then `r.f_later`. -/
def callRead (n : Int) (written later : Nat) : Program := { declarations := writerOf written, main := (
  .letE 0 (.prim .object [.int n, .int (n + 1)]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.prim (.get later) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .prim .add [v 3, v 4]) }

/-- `s = { r | a = n + 5 }`, then `writeField r`, which reads `r.a`. -/
def updateThenCall (n : Int) : Program := { declarations := writerOf 0, main := (
  .letE 0 (.prim .object [.int n, .int (n + 1)]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.assign 2 [0] (v 0) [.int (n + 5)]) <|
  .letE 3 (.app (v 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .letE 5 (.prim (.get 0) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-- `writeField r` twice. -/
def callTwice (n : Int) : Program := { declarations := writerOf 0, main := (
  .letE 0 (.prim .object [.int n, .int (n + 1)]) <|
  .letE 1 (.closure 0 []) <|
  .letE 2 (.app (v 1) [v 0]) <|
  .letE 3 (.app (v 1) [v 0]) <|
  .letE 4 (.prim (.get 0) [v 2]) <|
  .letE 5 (.prim (.get 0) [v 3]) <|
  .prim .add [v 4, v 5]) }

/-- The product, complete at these bounds: 14 programs per starting value. -/
def product : List Program := [-1, 0, 1, 2].flatMap fun n =>
  [0, 1].flatMap (fun w => [0, 1].map (readAfter n w)) ++
  [0, 1].flatMap (fun f => [0, 1].map (updateTwice n f)) ++
  [0, 1].flatMap (fun w => [0, 1].map (callRead n w)) ++
  [updateThenCall n, callTwice n]

/-- Every probe program, in the order of this file: the bridge exports them as
    the fixed `record` family (#1872), after every earlier fixed family. -/
def all : List Program := [
  keptRead, writtenRead, hoistedRead, wholeUse, allFields, allFieldsCaptured, aliasKept,
  payloadRead, payloadKept, twoPaths, twoForms, captureWhole, captureField, forItems,
  forShared, forLive, topLevel, copied, nested, twoUpdates, sameFieldTwice, selfHandler,
  fieldHandler, callee, calleeWritten, calleeKept, updateThenCallee, calleeTwice,
  layersKept, layersWritten, eitherKept, eitherWritten, callbackKept, heldField,
  heldFieldKept, bumpOnce, bumpTwice]

end Ownership.RecordPrograms
