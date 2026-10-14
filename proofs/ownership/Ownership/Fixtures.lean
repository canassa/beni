import Ownership.Oracle
import Ownership.Smoke
import Ownership.GeneratedRegressions
import Ownership.Targeted

namespace Ownership.Fixtures

private def v := Atom.var
private def list : Expr := .prim (.literal .int) [.int 0]
private def push (a : Atom) : Expr := .prim .push [a,.int 9]
private def seq (rhs rest : Expr) : Expr := .letE 90 rhs rest

def retained (copy := false) : Program := {
  main := .letE 0 list <|
    .letE 1 (if copy then .prim .copy [v 0] else .atom (v 0)) <|
    .letE 2 (push (v 1)) (.prim .record [v 0,v 2]) }

def readThenWrite : Program := {
  main := .letE 0 list <| .letE 1 (.prim .length [v 0]) <|
    .letE 2 (push (v 0)) (.prim .record [v 1,v 2]) }

def shared : Program := {
  main := .letE 0 list <| .letE 1 (.prim .shared [v 0]) (push (v 1)) }

def calling (alias := false) : Program := {
  declarations := [{
    name := "grow", parameters := [.list .int,.list .int], result := .record [.list .int,.list .int],
    body := .letE 2 (push (v 0)) (.prim .record [v 2,v 1]) }]
  main := .letE 0 list <| .letE 1 list <| .letE 2 (.closure 0 [])
    (.app (v 2) [v 0,if alias then v 0 else v 1]) }
def argumentAlias : Program := calling true

def capture (consume twice : Bool) : Program := {
  declarations := [{
    name := "capture", parameters := [.int], captures := [.list .int],
    result := if consume then .list .int else .int,
    body := if consume then push (v 1) else .prim .length [v 1] }]
  main := .letE 0 list <| .letE 1 (.closure 0 [v 0]) <|
    if consume then .letE 2 (.app (v 1) [.int 0])
      (if twice then .app (v 1) [.int 1] else .atom (v 2))
    else seq (push (v 0)) (.app (v 1) [.int 0]) }

def recordSharing (duplicate := true) : Program := {
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim .record [v 0,if duplicate then v 0 else v 1]) <|
    .letE 3 (.prim (.literal (.record [.list .int,.list .int])) [v 2]) <|
    .focus (v 3) (.int 0) 4 <|
      .letE 5 (push (.field (v 4) 0)) (.prim .record [v 5,.field (v 4) 1]) }

def copiedContents : Program := {
  main := .letE 0 list <| .letE 1 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 2 (.prim .copy [v 1]) <|
    .letE 3 (.focus (v 2) (.int 0) 4 (push (v 4))) (.prim .record [v 1,v 3]) }

def returnCapture : Program := {
  declarations := [{
    name := "get", parameters := [], captures := [.list .int],
    result := .list .int, body := .atom (v 0) }]
  main := .letE 0 list <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.app (v 1) []) <| .letE 3 (push (v 2)) (.app (v 1) []) }

def mapCapture : Program := {
  declarations := [Library.map .int (.list .int),
    { name := "get", parameters := [.int], captures := [.list .int],
      result := .list .int, body := .atom (v 1) }]
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 1,.int 2]) <|
    .letE 2 (.closure 0 []) <| .letE 3 (.closure 1 [v 0]) <|
    .letE 4 (.app (v 2) [v 1,v 3]) (.focus (v 4) (.int 0) 5 (push (v 5))) }

def foldBorrow : Program := {
  declarations := [Library.foldl (.list .int) (.list .int),
    { name := "pick", parameters := [.list .int,.list .int], result := .list .int,
      body := .atom (v 0) }]
  main := .letE 0 list <| .letE 1 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 2 (.prim (.literal .int) []) <| .letE 3 (.closure 0 []) <|
    .letE 4 (.closure 1 []) <| .letE 5 (.app (v 3) [v 1,v 2,v 4]) <|
    .letE 6 (push (v 5)) (.prim .record [v 6,v 1]) }

def foldBranch (captureShared : Bool) : Program := {
  declarations := [Library.foldl .int (.list .int),
    { name := "step", parameters := [.int,.list .int], captures := [.list .int],
      result := .list .int, body := .branch (v 0) (.atom (v 2)) (push (v 1)) }]
  main := .letE 0 list <|
    .letE 1 (if captureShared then .prim .shared [v 0] else .atom (v 0)) <|
    .letE 2 (.prim (.literal .int) [.int 0,.int 1]) <|
    .letE 3 (.prim (.literal .int) []) <| .letE 4 (.closure 0 []) <|
    .letE 5 (.closure 1 [v 1]) <| .letE 6 (.app (v 4) [v 2,v 3,v 5])
      (.prim .record [v 6,v 1]) }

def nestedMap (sharing : Bool) : Program := {
  declarations := [Library.map .int (.list (.list .int)), Smoke.initializer sharing]
  main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
    .letE 8 (.prim (.literal .int) [.int 0]) <|
    .letE 2 (.app (v 0) [v 8,v 1]) <| .focus (v 2) (.int 0) 3 <|
      .focus (v 3) (.int 0) 4 (push (v 4)) }

def escapeCall : Program := {
  declarations := [{
    name := "publish", parameters := [], captures := [.list .int], result := .int,
    body := .letE 1 (.prim .shared [v 0]) (.atom (.int 0)) }]
  main := .letE 0 list <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.app (v 1) []) (push (v 0)) }

/-- Red regression: traversal must carry permanent escapes even when its
    accumulator/result does not mention the escaped capture. -/
def escapeTraversal : Program := {
  main := .letE 0 list <|
    .letE 1 (.traverse .range (.int 1) (.int 0) 2 3 4 <|
      .letE 5 (.prim .shared [v 0]) (.atom (v 4))) (push (v 0)) }

/-- Faithful ordinary-call projection of g xs k = k (push xs 1). -/
def callbackAlias : Program := {
  declarations := [
    { name := "g", parameters := [.list .int,.fn [.list .int] .int], result := .int,
      body := .letE 2 (push (v 0)) (.app (v 1) [v 2]) },
    { name := "readCaptured", parameters := [.list .int], captures := [.list .int], result := .int,
      body := .prim .length [v 1] }]
  main := .letE 0 list <| .letE 1 (.closure 0 []) <|
    .letE 2 (.closure 1 [v 0]) (.app (v 1) [v 0,v 2]) }

def foldAlias : Program := {
  declarations := [Library.foldl .int (.list .int),
    { name := "insert", parameters := [.int,.list .int], result := .list .int,
      body := .prim .push [v 1,v 0] }]
  main := .letE 0 list <| .letE 1 (.closure 0 []) <| .letE 2 (.closure 1 [])
    (.app (v 1) [v 0,v 0,v 2]) }

def returnedReader : Program := {
  declarations := [
    { name := "read", parameters := [], captures := [.list .int], result := .int,
      body := .prim .length [v 0] },
    { name := "mk", parameters := [.list .int], result := .fn [] .int,
      body := .closure 0 [v 0] }]
  main := .letE 0 list <| .letE 1 (.closure 1 []) <|
    .letE 2 (.app (v 1) [v 0]) <| seq (push (v 0)) (.app (v 2) []) }

def onceWrappers (variant : Nat) : Program := {
  declarations := [
    { name := "push1", parameters := [.int], captures := [.list .int], result := .list .int,
      body := .prim .push [v 1,v 0] },
    { name := "mk", parameters := [.list .int], result := .fn [.int] (.list .int),
      body := .closure 0 [v 0] },
    { name := "callCaptured", parameters := [.int], captures := [.fn [.int] (.list .int)],
      result := .list .int, body := .app (v 1) [v 0] },
    Library.map .int (.list .int),
    { name := "give", parameters := [], captures := [.fn [.int] (.list .int)],
      result := .fn [.int] (.list .int), body := .atom (v 0) }]
  main := .letE 0 list <| .letE 1 (.closure 1 []) <|
    .letE 2 (.app (v 1) [v 0]) <|
    if variant == 1 then
      .letE 3 (.closure 2 [v 2]) <| .letE 4 (.closure 3 []) <|
      .letE 5 (.prim (.literal .int) [.int 1,.int 2]) (.app (v 4) [v 5,v 3])
    else if variant == 2 then
      .letE 3 (.prim .record [v 2]) <| .letE 4 (.app (.field (v 3) 0) [.int 1])
        (.app (.field (v 3) 0) [.int 2])
    else if variant == 3 then
      .letE 3 (.closure 4 [v 2]) <| .letE 4 (.app (v 3) []) <|
      .letE 5 (.app (v 4) [.int 1]) <| .letE 6 (.app (v 3) []) (.app (v 6) [.int 2])
    else .letE 3 (.app (v 2) [.int 1]) (.app (v 2) [.int 2]) }

def freshInitializers : Program := {
  declarations := [{
    name := "init", parameters := [], result := .record [.list .int,.int],
    body := .letE 0 list (.prim .record [v 0,.int 0]) }]
  main := .letE 0 (.closure 0 []) <| .letE 1 (.app (v 0) []) <|
    .letE 2 (.app (v 0) []) <| .letE 3 (push (.field (v 1) 0))
      (.prim .record [v 3,v 2]) }

def recursiveAppend : Program := {
  declarations := [{
    name := "appendTo", parameters := [.int,.list .int], result := .list .int,
    body := .branch (v 0) (.atom (v 1)) <|
      .letE 2 (.prim .sub [v 0,.int 1]) <| .letE 3 (push (v 1)) (.recur [v 2,v 3]) }]
  main := .letE 0 list <| .letE 1 (.closure 0 []) <|
    .letE 2 (.app (v 1) [.int 2,v 0]) <| .letE 3 (push (v 2)) (.prim .record [v 3,v 0]) }

def recursiveCapture : Program := {
  declarations := [{
    name := "upTo", parameters := [.int], captures := [.list .int], result := .list .int,
    body := .branch (v 0) (.atom (v 1)) <|
      .letE 2 (.prim .sub [v 0,.int 1]) <| .letE 3 (.recur [v 2]) (.prim .push [v 3,v 0]) }]
  main := .letE 0 list <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.app (v 1) [.int 2]) (.app (v 1) [.int 1]) }

def conditionalMap (repeated : Bool) : Program := {
  declarations := [Library.map (.record [.int,.list .int]) (.record [.int,.list .int]),
    { name := "edit", parameters := [.record [.int,.list .int]], result := .record [.int,.list .int],
      body := .branch (.field (v 0) 0) (.atom (v 0)) <|
        .letE 1 (push (.field (v 0) 1)) (.prim .record [.field (v 0) 0,v 1]) }]
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim .record [.int 1,v 0]) <|
    .letE 3 (.prim .record [.int 0,if repeated then v 0 else v 1]) <|
    .letE 4 (.prim (.literal (.record [.int,.list .int])) [v 2,v 3]) <|
    .letE 5 (.closure 0 []) <| .letE 6 (.closure 1 []) (.app (v 5) [v 4,v 6]) }

def nestedUpdate (repeated : Bool) (outerRepeated := false) : Program := {
  declarations := [Library.update (.list (.list .int)), Library.update (.list .int),
    { name := "bump", parameters := [.list .int], result := .list .int, body := push (v 0) },
    { name := "bumpHead", parameters := [.list (.list .int)], result := .list (.list .int),
      body := .letE 1 (.closure 1 []) <| .letE 2 (.closure 2 []) (.app (v 1) [v 0,.int 0,v 2]) }]
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim (.literal (.list .int)) [v 0,if repeated then v 0 else v 1]) <|
    .letE 3 (.prim (.literal (.list (.list .int))) (if outerRepeated then [v 2,v 2] else [v 2])) <|
    .letE 4 (.closure 0 []) <| .letE 5 (.closure 3 []) (.app (v 4) [v 3,.int 0,v 5]) }

/-- T46 with two rows: the first iteration returns the borrowed first row and
    the second pushes onto it, so the retained rows observe the write. With one
    row the borrowed result is never written and the defect is invisible. -/
def borrowedAccumulator : Program := {
  declarations := [Library.foldl (.list .int) (.list .int),
    { name := "borrowOrGrow", parameters := [.list .int,.list .int], result := .list .int,
      body := .letE 2 (.prim .length [v 1]) (.branch (v 2) (.atom (v 0)) (push (v 1))) }]
  main := .letE 0 list <| .letE 9 (.prim (.literal .int) [.int 2]) <|
    .letE 1 (.prim (.literal (.list .int)) [v 0, v 9]) <|
    .letE 2 (.prim (.literal .int) []) <| .letE 3 (.closure 0 []) <| .letE 4 (.closure 1 []) <|
    .letE 5 (.app (v 3) [v 1,v 2,v 4]) (.prim .record [v 5,v 1]) }

/-! Negative-control probes: one hand-written program per deliberate checker
    hole. Each is rejected by the checker, accepted under its mutant, and then
    produces different value and in-place traces. -/

/-- Disjoint: one cell passed as both arguments; the callee pushes one and reads the other. -/
def probeDisjoint : Program := {
  declarations := [{
    name := "f", parameters := [.list .int, .list .int], result := .int,
    body := .letE 2 (push (v 0)) (.prim .length [v 1]) }]
  main := .letE 0 list (.letE 1 (.closure 0 []) (.app (v 1) [v 0, v 0])) }

/-- T46 where the rows die with the fold: `[r1, r2, r1]`. The first step
    returns the borrowed r1, the second pushes onto it, the third reads it
    again as an element. Only the traversal's borrowed-source rule rejects
    it; the caller sees no live row. -/
def borrowedReread : Program := {
  declarations := [Library.foldl (.list .int) (.list .int),
    { name := "borrowOrGrow", parameters := [.list .int,.list .int], result := .list .int,
      body := .letE 2 (.prim .length [v 1]) (.branch (v 2) (.atom (v 0)) (push (v 1))) }]
  main := .letE 0 list <| .letE 9 (.prim (.literal .int) [.int 2]) <|
    .letE 1 (.prim (.literal (.list .int)) [v 0, v 9, v 0]) <|
    .letE 2 (.prim (.literal .int) []) <| .letE 3 (.closure 0 []) <| .letE 4 (.closure 1 []) <|
    .app (v 3) [v 1,v 2,v 4] }

/-- A recursive call inside a range step writes the captured `ys` on every
    iteration. The per-call checker analysed it with an empty summary and
    accepted (value 8, in place 11); both checkers now refuse it as a limit. -/
def recursionInStep : Program := {
  declarations := [{
    name := "rec", parameters := [.int, .list .int], result := .int,
    body := .branch (v 0) (.atom (.int 0)) <|
      .letE 2 (.prim .push [v 1, v 0]) <|
      .letE 3 (.prim .sub [v 0, .int 1]) <|
      .letE 4 (.traverse .range (.int 2) (.int 0) 5 6 7
          (.letE 8 (.recur [v 3, v 2]) (.prim .add [v 7, v 8]))) <|
      .letE 9 (.prim .length [v 2]) (.prim .add [v 9, v 4]) }]
  main := .letE 0 list <| .letE 1 (.closure 0 []) <| .app (v 1) [.int 2, v 0] }

/-- Traversal exclusive source: a consuming traversal over `[c, c]`. -/
def probeTraversalExclusive : Program := {
  main := .letE 0 list <| .letE 1 (.prim (.literal (.list .int)) [v 0, v 0]) <|
    .traverse .list (v 1) (.int 0) 2 3 4
      (.letE 5 (push (v 3)) (.letE 6 (.prim .length [v 5]) (.prim .add [v 4, v 6]))) }

/-- Many calls: a range step pushes onto a captured list on every iteration. -/
def probeManyCalls : Program := {
  main := .letE 0 list <|
    .traverse .range (.int 3) (.int 0) 1 2 3
      (.letE 4 (.prim .push [v 0, .int 9]) (.letE 5 (.prim .length [v 4]) (.prim .add [v 3, v 5]))) }

/-- Copy: the shallow copy of `[c, c]` is consumed at position 0. -/
def probeCopyExclusive : Program := {
  main := .letE 0 list <| .letE 1 (.prim (.literal (.list .int)) [v 0, v 0]) <|
    .letE 2 (.prim .copy [v 1]) <| .focus (v 2) (.int 0) 3 (push (v 3)) }

/-- Close: map identity returns its source; a spine push then reaches the live source. -/
def probeCloseSource : Program := {
  declarations := [Library.map (.list .int) (.list .int),
    { name := "identity", parameters := [.list .int], result := .list .int, body := .atom (v 0) }]
  main := .letE 0 list <| .letE 1 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 2 (.closure 0 []) <| .letE 3 (.closure 1 []) <|
    .letE 4 (.app (v 2) [v 1, v 3]) <| .letE 5 (.prim .push [v 4, v 0]) (.prim .record [v 5, v 1]) }

/-- Keeps shape: focus stores position 1's cell at position 0, then consumes position 0. -/
def probeKeepsShape : Program := {
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 2]) <|
    .letE 2 (.prim (.literal (.list .int)) [v 0, v 1]) <|
    .letE 9 (.prim (.literal .int) [.int 0]) <| .letE 3 (.prim .at [v 2, .int 1, v 9]) <|
    .letE 4 (.focus (v 2) (.int 0) 5 (.atom (v 3))) <|
    .focus (v 4) (.int 0) 6 (push (v 6)) }

/-! Probes for the summary rows, over the general family's declaration table. -/

open Generator in
/-- Two folds of the same live rows: `grow` then `borrowOrGrow`. Reusing the
    first call's summary for the second forgets that its result may be a row. -/
def probeGuardReuse : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 2]) <|
    .letE 2 (.prim (.literal tL) [v 0, v 1]) <|
    .letE 3 (.closure foldNL []) <| .letE 4 (.closure grow []) <| .letE 5 (.closure borrowOrGrow []) <|
    .letE 6 (.prim (.literal .int) []) <| .letE 7 (.prim (.literal .int) []) <|
    .letE 8 (.app (v 3) [v 2, v 6, v 4]) <| .letE 9 (.app (v 3) [v 2, v 7, v 5]) <|
    .letE 10 (.prim .push [v 9, .int 3]) (.prim .record [v 10, v 8, v 2]) }

open Generator in
/-- `applyThenRead xs bump`: the list is pushed by the callback and then read. -/
def probeSupplyEdge : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.closure applyThenRead []) <| .letE 2 (.closure bump []) <|
    .app (v 1) [v 0, v 2] }

open Generator in
/-- `foldKeep rows [] borrowOrGrow`: the borrowed first row is pushed by the
    second step and read again after the loop. Owned inside the step, not
    where the step ends. -/
def probeSupplyRecheck : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 2]) <|
    .letE 2 (.prim (.literal tL) [v 0, v 1]) <| .letE 3 (.prim (.literal .int) []) <|
    .letE 4 (.closure foldKeep []) <| .letE 5 (.closure borrowOrGrow []) <|
    .app (v 4) [v 2, v 3, v 5] }

open Generator in
/-- A once closure (it pushes its capture) handed to map, which calls it per element. -/
def probeCallsEdge : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 0, .int 1]) <|
    .letE 2 (.closure mapIL []) <| .letE 3 (.closure capPush [v 0]) <|
    .app (v 2) [v 1, v 3] }

open Generator in
/-- `applyN [e] headBump`, then `e` pushed onto the result: the callback
    writes the row inside its argument, so applyN must publish W there and the
    caller's `e` must be dead. Shrunk from the generator (seed 17, index 34). -/
def probeCallbackWrites : Program := {
  declarations := decls
  main := .letE 1 (.prim (.literal .int) []) <| .letE 2 (.prim (.literal tL) [v 1]) <|
    .letE 3 (.closure applyN []) <| .letE 4 (.closure headBump []) <|
    .letE 5 (.app (v 3) [v 2, v 4]) (.prim .push [v 5, v 1]) }

open Generator in
/-- `twiceVia xs identL` returns xs itself; pushing onto the result while xs
    is live must be refused. -/
def probeCallbackAliases : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.closure twiceVia []) <| .letE 2 (.closure identL []) <|
    .letE 3 (.app (v 1) [v 0, v 2]) <| .letE 4 (.prim .push [v 3, .int 3]) (.prim .record [v 4, v 0]) }

open Generator in
/-- `map [0, 1] (capGet c)`: both elements are the captured c, so consuming
    one position reaches the other. -/
def probeCallbackEnv : Program := {
  declarations := decls
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 0, .int 1]) <|
    .letE 2 (.closure mapIL []) <| .letE 3 (.closure capGet [v 0]) <|
    .letE 4 (.app (v 2) [v 1, v 3]) <| .focus (v 4) (.int 0) 5 (push (v 5)) }

open Generator in
/-- `mapVia (mapVia [e] identL) publish`, then `e` pushed: `publish` escapes
    its argument, so `e` is shared. mapVia only reaches `publish` through map,
    so the E guard must be forwarded to mapVia's own input. Shrunk from the
    generator (seed 17, index 471). -/
def probePublishVia : Program := {
  declarations := decls
  main := .letE 0 (.prim (.literal .int) [.int 0]) <| .letE 1 (.prim (.literal tL) [v 0]) <|
    .letE 2 (.closure mapVia []) <| .letE 3 (.closure identL []) <|
    .letE 4 (.app (v 2) [v 1, v 3]) <| .letE 5 (.closure mapVia []) <|
    .letE 6 (.closure publish []) <| .letE 7 (.app (v 5) [v 4, v 6]) (.prim .push [v 0, .int 0]) }

open Generator in
/-- `applyThenRead xs (capAppend c)`: the once callback pushes its capture and
    returns it, and applyThenRead pushes the result again. The closure is dead
    afterwards, so this is accepted; the summary checker once rejected it by
    counting the closure's captures as another operand of the write through
    its environment. From seed 20261011, index 13920. -/
def envThroughWrapper : Program := {
  declarations := decls
  main := .letE 0 (.prim (.literal .int) [.int 3]) <| .letE 2 (.prim (.literal .int) [.int 3, .int 0]) <|
    .letE 6 (.closure applyThenRead []) <| .letE 7 (.closure capAppend [v 2]) <|
    .letE 8 (.app (v 6) [v 0, v 7]) <| .letE 9 (.prim .set [v 8, .int 1, .int 2]) (.prim .record [v 9]) }

/-- The reverse of `envThroughWrapper`: the callee writes through its
    callback's environment and then calls the callback again, which returns
    the written capture. The callee's own Dead check must refuse it (the
    closure is live after the write); the caller no longer counts the
    closure's captures as another operand. -/
def envWriteThenCall : Program := {
  declarations := [
    { name := "capReturn", parameters := [.list .int], captures := [.list .int], result := .list .int,
      body := .atom (v 1) },
    { name := "writeEnvThenCall", parameters := [.list .int, .fn [.list .int] (.list .int)],
      result := .list .int,
      body := .letE 2 (.app (v 1) [v 0]) <| .letE 3 (push (v 2)) <|
        .letE 4 (.app (v 1) [v 0]) (.prim .push [v 4, .int 1]) }]
  main := .letE 0 list <| .letE 1 (.prim (.literal .int) [.int 5]) <|
    .letE 2 (.closure 0 [v 1]) <| .letE 3 (.closure 1 []) (.app (v 3) [v 0, v 2]) }

/-- A focus body pushes onto the focused container through a capture. The
    in-place interpreter used to store the element into the array as it was
    before the body ran, discarding the push, so the two runs agreed even with
    Disjoint dropped; the write-back now re-reads the container. -/
def focusStale : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) <|
    .letE 1 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 2 (.prim (.literal .int) [.int 5]) <|
    .focus (v 1) (.int 0) 3 (.letE 4 (.prim .push [v 1, v 2]) (.atom (v 3))) }

/-- A once closure (it pushes onto its capture) is handed to a callee that
    calls it once, and is then observed in the result. A direct call consumes
    a once closure; the summary checker did not consume it when the call was
    made by a callee, and accepted a program whose runs disagree (value: the
    closure still captures `[1]`; in place: `[1, 1]`). -/
def onceThroughCallee : Program := {
  declarations := [
    { name := "capAppend", parameters := [.list .int], captures := [.list .int], result := .list .int,
      body := .letE 2 (.prim .length [v 0]) (.prim .push [v 1, v 2]) },
    { name := "apply1", parameters := [.list .int, .fn [.list .int] (.list .int)],
      result := .list .int, body := .app (v 1) [v 0] }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.prim (.literal .int) [.int 7]) <| .letE 3 (.closure 1 []) <|
    .letE 4 (.app (v 3) [v 2, v 1]) (.prim .record [v 4, v 1]) }

/-- Branch liveness: `x` is read only in the nonzero arm, after it was pushed. -/
def probeBranchLive : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) <|
    .letE 1 (.prim .push [v 0, .int 5]) <|
    .branch (.int 1) (.atom (v 1)) (.atom (v 0)) }

/-- `close b xs` with an empty builder returns `xs`'s own array (equal
    contents); `xs` is the written capture of a once closure, which a callee
    then calls. `close`'s source is not a use, so creating the closure did not
    keep `xs` from being named again; demanding the closure's roots at the
    callee's call is not enough, its written captures must be demanded too,
    as a direct call demands them (value: `[]`, in place: `[1]`). -/
def closeThenOnceThroughCallee : Program := {
  declarations := onceThroughCallee.declarations
  main := .letE 0 (.prim (.literal .int) []) <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.prim (.builder .int) []) <| .letE 3 (.prim .close [v 2, v 0]) <|
    .letE 4 (.prim (.literal .int) [.int 7]) <| .letE 5 (.closure 1 []) <|
    .letE 6 (.app (v 5) [v 4, v 1]) (.prim .record [v 3, v 6]) }

/-- Shadowing (third review): `let 0 = [1]; let 6 = (let 5 = 0; let 0 = [];
    push 5 1); length 0`. The continuation's `0` is the outer list, but the
    checker resolved it inside the inner `let`, where `0` is the new empty
    list, so the push's Dead test passed (value reads 1, in place 2). Refused
    as shadowing; liveness also resolves it against the outer binding now. -/
def shadowedLive : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) <|
    .letE 6 (.letE 5 (.atom (v 0)) (.letE 0 (.prim (.literal .int) []) (.prim .push [v 5, .int 1])))
      (.prim .length [v 0]) }

/-- The same inside a declaration body, over its parameter `0`. -/
def shadowedLiveInDecl : Program := {
  declarations := [{
      name := "f", parameters := [.list .int], result := .int,
      body := .letE 6 (.letE 5 (.atom (v 0)) (.letE 0 (.prim (.literal .int) []) (.prim .push [v 5, .int 1])))
        (.prim .length [v 0]) }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) (.letE 1 (.closure 0 []) (.app (v 1) [v 0])) }

/-- `shared` on a nested list must escape its elements too (third review):
    the element `[1]` is pushed after its container was published. -/
def sharedNested : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 2 (.prim .shared [v 1]) <| .letE 3 (.prim .push [v 0, .int 7]) (.prim .length [v 3]) }

/-- A closure created in a conditional arm captures a list that was pushed
    before: the capture is a use of the old list (third review). -/
def branchArmCapture : Program := {
  declarations := Generator.decls
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim .push [v 0, .int 5]) <|
    .letE 2 (.branch (.int 0) (.closure Generator.capLen [v 0]) (.closure Generator.capLen [v 0])) <|
    .app (v 2) [.int 0] }

/-- foldl over two rows calls a once closure (it pushes onto its capture)
    once per step (fourth review, p9c): the step's single call is many calls. -/
def onceThroughFold : Program := {
  declarations := [Library.foldl (.list .int) .int,
    { name := "pushCap2", parameters := [.list .int, .int], captures := [.list .int], result := .int,
      body := .letE 3 (.prim .push [v 2, v 1]) (.prim .length [v 3]) }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim (.literal .int) [.int 5]) <|
    .letE 3 (.prim (.literal (.list .int)) [v 1, v 1]) <| .letE 4 (.closure 1 [v 0]) <|
    .letE 5 (.closure 0 []) (.app (v 5) [v 3, .int 0, v 4]) }

/-- `shared` on a record holding a closure over a list must escape the list
    (fourth review, p9d); the list is then pushed. -/
def sharedClosureInRecord : Program := {
  declarations := [{
      name := "capLen", parameters := [.int], captures := [.list .int], result := .int,
      body := .prim .length [v 1] }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.closure 0 [v 0]) <|
    .letE 2 (.prim .record [v 1, .int 0]) <| .letE 3 (.prim .shared [v 2]) <|
    .letE 4 (.prim .push [v 0, .int 9]) (.prim .length [v 4]) }

/-- The third review's P1, at the checker: a live variable (`1`, the same
    array as `0`) that the abstract environment does not bind. No typed
    program reaches this (every live variable of a typed program is bound),
    so only this probe can see the `no-scope` control: the checker must
    refuse it; with the refusal dropped it accepts, and the push changes the
    array the live `1` holds. Returns (accepted, the runs disagree). -/
def unboundLive (config : Config) : Bool × Bool :=
  let heap : Array (List InPlaceSemantics.Value) := #[[.int 0]]
  let aenv : Env Abstract := [(0, .list [.site [99] 0] .scalar true)]
  let e : Expr := .prim .push [v 0, .int 1]
  let accepted := ((inferExpr 200 { declarations := [], config } aenv e [(1, [])] [7]).run {}).isOk
  let vEnv : Env Observation := [(0, .list [.int 0]), (1, .list [.int 0])]
  let hEnv : Env InPlaceSemantics.Value := [(0, .ref 0), (1, .ref 0)]
  let disagree := match (ValueSemantics.eval 50 [] none vEnv e).run { fuel := 50 },
      (InPlaceSemantics.eval 50 [] none hEnv e).run { fuel := 50, heap } with
    | .ok _, .ok (_, hs) => (InPlaceSemantics.snapshot hs.heap 10 (.ref 0)).toOption != some (.list [.int 0])
    | _, _ => false
  (accepted, disagree)

/-- A loop over a non-exclusive source returns one of its elements as the
    accumulator, which is then edited in place: the element is not exclusive
    (the source-level `xres` and `tsupplyexcl` holes both accept it). -/
def loopPicksElement : Program := {
  main := .letE 0 (.prim (.literal .int) [.int 1]) <|
    .letE 1 (.prim (.literal (.list .int)) [v 0, v 0]) <|
    .letE 2 (.prim (.literal (.list (.list .int))) [v 1]) <|
    .letE 3 (.prim (.literal (.list .int)) []) <|
    .letE 4 (.traverse .list (v 2) (v 3) 10 11 12 (.atom (v 11))) <|
    .focus (v 4) (.int 0) 5 (.prim .push [v 5, .int 9]) }

/-- Fifth review, P4: one list is `set` into both slots of a nested list,
    and `map bump` then pushes onto each row. The rows are one array, so the
    nested list is not exclusive; a `set` that keeps exclusivity whatever it
    stores (`set-exclusive`) lets map push the array twice. -/
def setBothSlots : Program := {
  declarations := [Library.map (.list .int) (.list .int),
    { name := "bump", parameters := [.list .int], result := .list .int, body := .prim .push [v 0, .int 9] }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim (.literal .int) [.int 2]) <|
    .letE 2 (.prim (.literal (.list .int)) [v 0, v 1]) <| .letE 3 (.prim (.literal .int) [.int 7]) <|
    .letE 4 (.prim .set [v 2, .int 0, v 3]) <| .letE 5 (.prim .set [v 4, .int 1, v 3]) <|
    .letE 6 (.closure 1 []) <| .letE 7 (.closure 0 []) (.app (v 7) [v 5, v 6]) }

/-- Fifth review, P5: a closure captures a list `xs` beside a once closure
    (it pushes onto its own capture); `xs` is pushed, then the closure is
    called and reads `xs`. The once closure's capture paths still hold `xs`;
    liveness that drops them (`once-live`) lets the push through. -/
def onceCapturedBeside : Program := {
  declarations := [
    { name := "capPush", parameters := [.int], captures := [.list .int], result := .list .int,
      body := .prim .push [v 1, v 0] },
    { name := "readCall", parameters := [.int], captures := [.list .int, .fn [.int] (.list .int)], result := .int,
      body := .letE 3 (.app (v 2) [v 0]) (.prim .length [v 1]) }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim (.literal .int) [.int 5]) <|
    .letE 2 (.closure 0 [v 1]) <| .letE 3 (.closure 1 [v 0, v 2]) <|
    .letE 4 (.prim .push [v 0, .int 9]) <| .letE 5 (.app (v 3) [.int 0]) (.prim .record [v 5, v 4]) }

/-- A declaration returns either a closure over its list argument or its
    function argument (fifth review, P6). The checker joined the two shapes
    to an unknown value holding no cells, so the list stayed writable while
    the returned closure over it was live (value: the closure captures `[1]`;
    in place: `[1, 9]`). The join now keeps both sides' cells. -/
def closureJoinedWithInput : Program := {
  declarations := [
    { name := "capGet", parameters := [.int], captures := [.list .int], result := .list .int, body := .atom (v 1) },
    { name := "choose", parameters := [.int, .list .int, .fn [.int] (.list .int)], result := .fn [.int] (.list .int),
      body := .branch (v 0) (.closure 0 [v 1]) (.atom (v 2)) }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <| .letE 1 (.prim (.literal .int) [.int 2]) <|
    .letE 2 (.closure 0 [v 1]) <| .letE 3 (.closure 1 []) <| .letE 4 (.app (v 3) [.int 0, v 0, v 2]) <|
    .letE 5 (.prim .push [v 0, .int 9]) (.prim .record [v 4, v 5]) }

/-- A callee invokes an outer closure, which calls its captured once
    closure. `close` revives the written array after closure creation; the
    callee must demand the nested write while that old array is live. -/
def nestedOnceThroughCallee : Program := {
  declarations := [
    { name := "push", parameters := [.int], captures := [.list .int], result := .list .int,
      body := .prim .push [.var 1, .var 0] },
    { name := "wrap", parameters := [.int], captures := [.fn [.int] (.list .int)], result := .list .int,
      body := .app (.var 1) [.var 0] },
    { name := "invoke", parameters := [.fn [.int] (.list .int)], result := .list .int,
      body := .app (.var 0) [.int 9] }]
  main := .letE 0 (.prim (.literal .int) [.int 1]) <|
    .letE 1 (.closure 0 [.var 0]) <| .letE 2 (.closure 1 [.var 1]) <|
    .letE 3 (.prim (.builder .int) []) <| .letE 4 (.prim .put [.var 3, .int 1]) <|
    .letE 5 (.prim .close [.var 4, .var 0]) <| .letE 6 (.closure 2 []) <|
    .letE 7 (.app (.var 6) [.var 2]) (.prim .record [.var 5, .var 7]) }

/-- Probes: name, program, mutant, and whether the control is meaningful only
    for the per-call checker (see COVERAGE.md, "Borrowed supply"). -/
def probes : List (String × Program × Mutant × Bool) := [
  ("a callee invokes a closure calling a captured once closure", nestedOnceThroughCallee, .onceThroughCall, false),
  ("one list set into both slots, then map bump", setBothSlots, .setExclusive, false),
  ("a list captured beside a once closure, pushed, then the closure called", onceCapturedBeside, .onceLive, false),
  ("disjoint", probeDisjoint, .disjoint, false),
  ("focus body pushes its own container", focusStale, .disjoint, false),
  ("read only in the nonzero arm after a push", probeBranchLive, .branchLive, false),
  ("a let shadows a variable its continuation uses", shadowedLive, .shadowing, false),
  ("the same in a declaration body", shadowedLiveInDecl, .shadowing, false),
  ("shared on a nested list, then an element pushed", sharedNested, .sharedRoots, false),
  ("a closure in a conditional arm captures a pushed list", branchArmCapture, .branchClosure, false),
  ("T46 two rows", borrowedAccumulator, .borrowedSupply, true),
  ("traversal over [c, c]", probeTraversalExclusive, .traversalExclusive, false),
  ("captured push per iteration", probeManyCalls, .manyCalls, false),
  ("copy of [c, c]", probeCopyExclusive, .copyExclusive, false),
  ("map identity then spine push", probeCloseSource, .closeSource, false),
  ("focus breaks shape", probeKeepsShape, .keepsShape, false),
  ("two folds of the same rows", probeGuardReuse, .guardReuse, false),
  ("T59 map shared", nestedMap true, .callbackXres, false),
  ("callback writes a list read later", probeSupplyEdge, .supplyEdge, false),
  ("fold reads its rows after the loop", probeSupplyRecheck, .supplyRecheck, false),
  ("once closure handed to map", probeCallsEdge, .callsEdge, false),
  ("callback edits inside its argument", probeCallbackWrites, .callbackWrites, false),
  ("wrapper returns its argument", probeCallbackAliases, .callbackAliases, false),
  ("map over a captured list", probeCallbackEnv, .callbackEnv, false),
  ("mapVia publishes a row, then the row is pushed", probePublishVia, .callbackEscapes, false),
  ("mapVia forwards map's guards about its callback", probePublishVia, .forwardGuards, false),
  ("once closure called by a callee, then observed", onceThroughCallee, .onceThroughCall, false),
  ("close returns a once closure's capture, a callee calls it", closeThenOnceThroughCallee, .onceThroughCall, false),
  ("foldl calls a once closure on two rows", onceThroughFold, .manyOff, false),
  ("shared on a record holding a closure over a list", sharedClosureInRecord, .sharedFn, false)]

def scalarIndexOrder : Program := {
  main := .letE 0 list <| .letE 1 (.prim .at [v 0,.int 0,.int 0]) <|
    .prim .set [v 0,v 1,.int 9] }

/-- Ordinary concatenation: consumes only its first spine, reads the second. -/
def concatDecl : Decl := {
  name := "appendCells", parameters := [.list .int,.list .int], result := .list .int,
  body := .traverse .list (v 1) (v 0) 2 3 4 (.prim .push [v 4,v 3]) }

def constructionFold (consumeRows : Bool) : Program := {
  declarations := [Library.foldl (.record [.list .int]) (.list .int), concatDecl,
    { name := "joinRow", parameters := [.record [.list .int],.list .int], result := .list .int,
      body := .letE 2 (.closure 1 []) <|
        .letE 3 (.app (v 2) (if consumeRows then [.field (v 0) 0,v 1] else [v 1,.field (v 0) 0]))
          (.prim .push [v 3,.int 9]) }]
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim .record [v 0]) <| .letE 3 (.prim .record [v 1]) <|
    .letE 4 (.prim (.literal (.record [.list .int])) [v 2,v 3]) <|
    .letE 5 (.prim (.literal .int) []) <| .letE 6 (.closure 0 []) <|
    .letE 7 (.closure 2 []) <| .letE 8 (.app (v 6) [v 4,v 5,v 7]) <|
    if consumeRows then .prim .record [v 8,v 4] else .atom (v 8) }

/-- The previous version is restored from a history element, then copied (or
    aliased) before the next edit. Entry merging itself belongs to TEA. -/
def historyRestore (copied : Bool) : Program := {
  main := .letE 0 list <| .letE 1 (.prim .copy [v 0]) <|
    .letE 2 (.prim (.literal (.list .int)) [v 1]) <|
    .letE 3 (.prim .at [v 2,.int 0,v 0]) <|
    .letE 4 (if copied then .prim .copy [v 3] else .atom (v 3)) <|
    .letE 5 (push (v 4)) (.prim .record [v 5,v 2]) }

def compareHeld : Program := {
  declarations := [{
    name := "compareLengths", parameters := [.list .int,.list .int], result := .int,
    body := .letE 2 (.prim .length [v 0]) <| .letE 3 (.prim .length [v 1]) (.prim .sub [v 2,v 3]) }]
  main := .letE 0 list <| .letE 1 (.closure 0 []) <|
    .letE 2 (push (v 0)) (.app (v 1) [v 0,v 2]) }

def modelHeld : Program := {
  main := .letE 0 list <| .letE 1 (.prim .record [v 0,.int 0]) <|
    .letE 2 (push (.field (v 1) 0)) (.prim .record [.field (v 1) 0,v 2]) }

/-- Reverse-order fold is ordinary range traversal plus total indexed reads.
    No ownership-aware library constructor is involved. -/
def foldRightBorrow : Program := {
  declarations := [concatDecl,
    { name := "prepend", parameters := [.list .int,.list .int], result := .list .int,
      body := .letE 2 (.closure 0 []) (.app (v 2) [v 0,v 1]) },
    { name := "foldr", parameters := [.list (.list .int),.list .int,.fn [.list .int,.list .int] (.list .int)], result := .list .int,
      body := .letE 3 (.prim .length [v 0]) <| .letE 4 (.prim (.literal .int) []) <|
        .traverse .range (v 3) (v 1) 5 6 7 <|
          .letE 8 (.prim .sub [v 3,v 5]) <| .letE 9 (.prim .sub [v 8,.int 1]) <|
          .letE 10 (.prim .at [v 0,v 9,v 4]) (.app (v 2) [v 10,v 7]) }]
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim (.literal (.list .int)) [v 0,v 1]) <|
    .letE 3 (.prim (.literal .int) []) <| .letE 4 (.closure 2 []) <|
    .letE 5 (.closure 1 []) <| .letE 6 (.app (v 4) [v 2,v 3,v 5]) (.prim .record [v 6,v 2]) }

def transparentColumn : Program := {
  main := .letE 0 list <| .letE 1 (.prim .record [v 0]) <|
    .letE 2 (.prim (.literal (.record [.list .int])) [v 1]) <|
    .focus (v 2) (.int 0) 3 <| .letE 4 (push (.field (v 3) 0)) (.prim .record [v 4]) }

def concatContents : Program := {
  declarations := [{
    name := "concatRows", parameters := [.list (.list .int),.list (.list .int)], result := .list (.list .int),
    body := .traverse .list (v 1) (v 0) 2 3 4 (.prim .push [v 4,v 3]) }]
  main := .letE 0 list <| .letE 1 list <|
    .letE 2 (.prim (.literal (.list .int)) [v 0]) <|
    .letE 3 (.prim (.literal (.list .int)) [v 1]) <| .letE 4 (.closure 0 []) <|
    .letE 5 (.app (v 4) [v 2,v 3]) <|
    .letE 6 (.focus (v 5) (.int 1) 7 (push (v 7))) (.prim .record [v 6,v 3]) }

def initializedGridSet : Program := {
  declarations := [Library.initialize (.list .int),
    { name := "row", parameters := [.int], result := .list .int,
      body := .prim (.literal .int) [.int 0,.int 0,.int 0] },
    Library.update (.list .int),
    { name := "reveal", parameters := [.list .int], result := .list .int,
      body := .prim .set [v 0,.int 1,.int 1] }]
  main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
    .letE 2 (.app (v 0) [.int 3,v 1]) <| .letE 3 (.closure 2 []) <|
    .letE 4 (.closure 3 []) (.app (v 3) [v 2,.int 1,v 4]) }

structure Fixture where
  id : String
  program : Program
  accepted : Bool

/-- Expected verdicts are transcribed from Table 6.2, never checker-generated. -/
def all : List Fixture := [
  ⟨"captured once callback called twice",Targeted.countBoundary 1 2,false⟩,
  ⟨"captured once callback called once",Targeted.countBoundary 1 1,true⟩,
  ⟨"captured writer consumes revived capture",Targeted.consumingCapture 1 Generator.bump,false⟩,
  ⟨"captured reader shares revived capture",Targeted.consumingCapture 1 Generator.identL,true⟩,
  ⟨"right-hand join capture kept as data",Targeted.shapeJoin 1 1 .eq 1,false⟩,
  ⟨"T11 ordinary concat contents",concatContents,false⟩,
  ⟨"T37 initialized grid set",initializedGridSet,true⟩,
  ⟨"generated v3 tower old-rule regression",GeneratedRegressions.oldTowerSeed20261011Index7,false⟩,
  ⟨"generated v3 external escape regression",GeneratedRegressions.escapeSeed20261011Index1,false⟩,
  ⟨"T43 reverse consuming fold",foldRightBorrow,false⟩,
  ⟨"T17 compare",compareHeld,false⟩, ⟨"T17 model record",modelHeld,false⟩,
  ⟨"T41 restored alias projection",historyRestore false,false⟩,
  ⟨"T41 restored copy projection",historyRestore true,true⟩,
  ⟨"T43 accumulator construction fold",constructionFold false,true⟩,
  ⟨"T43 consuming row fold projection",constructionFold true,false⟩,
  ⟨"T1 fold alias",foldAlias,false⟩, ⟨"T1 callback alias",callbackAlias,false⟩,
  ⟨"T7 returned reader",returnedReader,false⟩,
  ⟨"T8 A returned",onceWrappers 0,false⟩, ⟨"T8 B captured many",onceWrappers 1,false⟩,
  ⟨"T8 C stored",onceWrappers 2,false⟩, ⟨"T26 captured returned",onceWrappers 3,false⟩,
  ⟨"T12 recursive append",recursiveAppend,false⟩, ⟨"T25 recursive capture",recursiveCapture,false⟩,
  ⟨"T14 fresh init",freshInitializers,true⟩, ⟨"T30 independent init projection",freshInitializers,true⟩,
  ⟨"T53 fresh init alternative",freshInitializers,true⟩,
  ⟨"T42 distinct conditional map",conditionalMap false,true⟩,
  ⟨"T42 repeated conditional map",conditionalMap true,false⟩,
  ⟨"T46 empty accumulator",borrowedAccumulator,false⟩,
  ⟨"T47 transparent wrapper projection",transparentColumn,true⟩,
  ⟨"T57 distinct update calls",nestedUpdate false,true⟩,
  ⟨"T57 repeated update calls",nestedUpdate true,false⟩,
  ⟨"T57 repeated outer rows update calls",nestedUpdate false true,false⟩,
  ⟨"T58 scalar index order projection",scalarIndexOrder,true⟩,
  ⟨"T1 arguments",argumentAlias,false⟩,
  ⟨"T1 capture",capture false false,false⟩,
  ⟨"T2",readThenWrite,true⟩, ⟨"T3",shared,false⟩,
  ⟨"T5",capture true true,false⟩, ⟨"T7",capture false false,false⟩,
  ⟨"T8 A",capture true true,false⟩, ⟨"T8 C",capture true true,false⟩,
  ⟨"T10",recordSharing true,false⟩, ⟨"T11",copiedContents,false⟩,
  ⟨"T12",retained false,false⟩, ⟨"T15",foldBorrow,false⟩,
  ⟨"T17 record",retained false,false⟩, ⟨"T17 operand",argumentAlias,false⟩,
  ⟨"T21",shared,false⟩, ⟨"T23",returnCapture,false⟩,
  ⟨"T24",mapCapture,false⟩, ⟨"T31",capture true true,false⟩,
  ⟨"T32 key/value projection",recordSharing true,false⟩,
  ⟨"T33 kept version",retained false,false⟩, ⟨"T33 copied version",retained true,true⟩,
  ⟨"T37 grid ownership",Smoke.nested false,true⟩,
  ⟨"T40 record shape",recordSharing false,true⟩,
  ⟨"T46 shared",foldBranch true,false⟩, ⟨"T46 capture",foldBranch false,false⟩,
  ⟨"T46 borrowed element",foldBorrow,false⟩,
  ⟨"T48 duplicate slots",recordSharing true,false⟩,
  ⟨"T48 distinct slots",recordSharing false,true⟩,
  ⟨"T52 spine identity projection",retained false,false⟩,
  ⟨"T52 copied spine projection",retained true,true⟩,
  ⟨"T53 top-level",shared,false⟩,
  ⟨"T55 explicit call projection",argumentAlias,false⟩,
  ⟨"T56 mapping projection",recordSharing true,false⟩,
  ⟨"T57 distinct",Smoke.nested false,true⟩, ⟨"T57 repeated",Smoke.nested true,false⟩,
  ⟨"T59 initialize shared",Smoke.nested true,false⟩,
  ⟨"T59 initialize distinct",Smoke.nested false,true⟩,
  ⟨"T59 map shared",nestedMap true,false⟩,
  ⟨"T59 map distinct",nestedMap false,true⟩,
  ⟨"generated map old-rule regression",GeneratedRegressions.oldSeed20261011Index8,false⟩,
  ⟨"generated initialize old-rule regression",GeneratedRegressions.oldSeed20261011Index10,false⟩,
  ⟨"escape ordinary call",escapeCall,false⟩,
  ⟨"escape traversal",escapeTraversal,false⟩,
  ⟨"recursion inside a step (per-call checker accepted it)",recursionInStep,false⟩,
  ⟨"T46 borrowed row read again",borrowedReread,false⟩,
  ⟨"wrapper writes its callback's returned capture",envThroughWrapper,true⟩,
  ⟨"write through a callback's environment, then call it again",envWriteThenCall,false⟩,
  ⟨"focus body pushes its own container",focusStale,false⟩,
  ⟨"once closure called by a callee, then observed",onceThroughCallee,false⟩,
  ⟨"close returns a once closure's capture, a callee calls it",closeThenOnceThroughCallee,false⟩,
  ⟨"read only in the nonzero arm after a push",probeBranchLive,false⟩,
  ⟨"a let shadows a variable its continuation uses",shadowedLive,false⟩,
  ⟨"the same in a declaration body",shadowedLiveInDecl,false⟩,
  ⟨"shared on a nested list, then an element pushed",sharedNested,false⟩,
  ⟨"a closure in a conditional arm captures a pushed list",branchArmCapture,false⟩,
  ⟨"foldl calls a once closure on two rows",onceThroughFold,false⟩,
  ⟨"shared on a record holding a closure over a list",sharedClosureInRecord,false⟩,
  ⟨"a loop over a non-exclusive source returns an element, then edited",loopPicksElement,false⟩,
  ⟨"a closure joined with a function input stays live",closureJoinedWithInput,false⟩,
  ⟨"a callee invokes a closure calling a captured once closure",nestedOnceThroughCallee,false⟩,
  ⟨"one list set into both slots, then map bump",setBothSlots,false⟩,
  ⟨"a list captured beside a once closure, pushed, then the closure called",onceCapturedBeside,false⟩ ]

def run : IO Bool := do
  let mut ok := true
  for (f, index) in all.zipIdx do
    let typed := typesOf f.program
    let verdict := check f.program
    IO.println s!"{f.id}: expected={f.accepted} actual={verdict.isOk} {if verdict.isOk then "" else toString (repr verdict)}"
    if !typed.isOk || verdict.isOk != f.accepted then
      IO.println s!"UNEXPECTED VERDICT; intended verdict retained. types={repr typed}"
      IO.FS.createDirAll "regressions"
      IO.FS.writeFile s!"regressions/fixture-{index}-failure.txt"
        s!"{f.id}\nexpected={f.accepted}\nactual={repr verdict}\ntypes={repr typed}\n{repr f.program}\n"
      ok := false
    if verdict.isOk then
      match Oracle.compare f.program with
      | .equal => pure ()
      | result =>
        IO.FS.createDirAll "regressions"
        IO.FS.writeFile s!"regressions/fixture-{index}-failure.txt" s!"{f.id}\n{repr f.program}\n{repr result}\n"
        IO.println s!"STOP fixture observational failure {f.id}: {repr result}"
        return false
  for p in [GeneratedRegressions.oldSeed20261011Index8, GeneratedRegressions.oldSeed20261011Index10, GeneratedRegressions.oldTowerSeed20261011Index7] do
    if !Oracle.disagrees p { oldFreshRule := true } || (check p).isOk then
      IO.println "FROZEN NEGATIVE CONTROL FAILED"
      ok := false
  for p in [escapeTraversal, GeneratedRegressions.escapeSeed20261011Index1] do
    if !Oracle.disagrees p { dropTraversalEscapes := true } || (check p).isOk then
      IO.println "ESCAPE NEGATIVE CONTROL FAILED"
      ok := false
  for (name, p, m, reinfer) in probes do
    let corrected := Oracle.verdictOf p { reinfer }
    let caught := Oracle.disagrees p { mutant := some m, reinfer } && !corrected.isOk
    IO.println s!"probe {name} under mutant {m.name}{if reinfer then " (per-call checker)" else ""}: corrected={repr corrected} disagrees={caught}"
    if !caught then
      IO.println s!"MUTANT NEGATIVE CONTROL FAILED: {m.name}"
      ok := false
  -- `no-scope` at the checker: no program reaches it (see `unboundLive`).
  let (correctedAccepts, _) := unboundLive {}
  let (mutantAccepts, mutantDisagrees) := unboundLive { mutant := some .noScope }
  IO.println s!"probe unbound live variable under mutant no-scope: corrected accepts={correctedAccepts} mutant accepts={mutantAccepts} disagrees={mutantDisagrees}"
  if correctedAccepts || !mutantAccepts || !mutantDisagrees then
    IO.println "MUTANT NEGATIVE CONTROL FAILED: no-scope"
    ok := false
  -- Both checkers on every verdict fixture: the per-call checker is the
  -- cross-check, and must agree with the intended verdicts too.
  for f in all do
    if (Reinfer.check f.program).isOk != f.accepted then
      IO.println s!"PER-CALL CHECKER VERDICT DIFFERS: {f.id} expected={f.accepted}"
      ok := false
  IO.println s!"fixtures={all.length} passed={ok}"
  pure ok

end Ownership.Fixtures
