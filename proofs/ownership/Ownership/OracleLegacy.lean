import Ownership.Library

namespace Ownership.OracleLegacy

abbrev Gen := StateM Nat

def draw (bound : Nat) : Gen Nat := do
  let s ← get
  let next := (s * 1664525 + 1013904223) % 4294967296
  set next
  pure (next % (max 1 bound))

def number : Gen Atom := do pure (.int (Int.ofNat (← draw 5)))
def choose (xs : List α) (fallback : α) : Gen α := do
  pure (xs[← draw xs.length]?.getD fallback)

/-- Compositional typed ANF generator. Every choice extends a typed environment;
    the checker is not consulted while constructing syntax. Sharing is selected
    by reusing existing atoms, including cells below record/container paths. -/
partial def chain (depth next : Nat) (env : List (Atom × Ty)) : Gen Expr := do
  let lists := env.filterMap fun (a,t) => if t == .list .int then some a else none
  if depth == 0 then
    return .prim .record (env.map Prod.fst)
  let choice ← draw 8
  let (rhs, ty) ← match choice with
    | 0 => pure (.prim (.literal .int) [← number, ← number], Ty.list .int)
    | 1 => pure (.prim .push [← choose lists (.var 0), ← number], Ty.list .int)
    | 2 => pure (.prim .copy [← choose lists (.var 0)], Ty.list .int)
    | 3 => pure (.prim .record [← choose lists (.var 0), ← choose lists (.var 0)],
                  Ty.record [.list .int, .list .int])
    | 4 => pure (.prim (.literal (.list .int)) [← choose lists (.var 0), ← choose lists (.var 0)],
                  Ty.list (.list .int))
    | 5 => pure (.prim .length [← choose lists (.var 0)], Ty.int)
    | 6 => pure (.branch (← number)
                  (.prim .push [← choose lists (.var 0), ← number])
                  (.atom (← choose lists (.var 0))), Ty.list .int)
    | _ => pure (.atom (← choose lists (.var 0)), Ty.list .int)
  return .letE next rhs (← chain (depth - 1) (next + 1) ((.var next,ty)::env))

/-- Fresh callbacks are built from independently selected numbers, lengths,
    multiplicities and sharing decisions. This is not the fixed T59 fixture. -/
def nested : Gen Program := do
  let sharing ← draw 3
  let n ← draw 3
  let count := n + 1
  let cell ← number
  let write ← number
  let index ← draw count
  let useMap ← draw 2
  let callback : Decl := {
    name := "generatedFresh"
    parameters := [.int]
    result := .list (.list .int)
    body := .letE 1 (.prim (.literal .int) [cell]) <|
      .letE 2 (if sharing < 2 then .atom (.var 1) else .prim (.literal .int) [cell]) <|
      .prim (.literal (.list .int)) [.var 1, .var 2] }
  let invoke : Expr := if useMap == 0 then .app (.var 0) [.int count, .var 1] else
    .letE 8 (.prim (.literal .int) ((List.range count).map (fun i => .int (Int.ofNat i)))) <|
    .app (.var 0) [.var 8, .var 1]
  return {
    declarations := [if useMap == 0 then Library.initialize (.list (.list .int))
                               else Library.map .int (.list (.list .int)), callback]
    main := .letE 0 (.closure 0 []) <| .letE 1 (.closure 1 []) <|
      .letE 2 invoke <| .focus (.var 2) (.int index) 3 <|
        .focus (.var 3) (.int 0) 4 (.prim .push [.var 4, write]) }

def captureProgram : Gen Program := do
  let consuming ← draw 2
  let duplicate ← draw 2
  let cell ← number
  let d : Decl := {
    name := "captured", parameters := [.int], captures := [.list .int],
    result := if consuming == 0 then .int else .list .int,
    body := if consuming == 0 then .prim .length [.var 1] else .prim .push [.var 1, .var 0] }
  return {
    declarations := [d]
    main := .letE 0 (.prim (.literal .int) [cell]) <|
      .letE 1 (.closure 0 [.var 0]) <|
      .letE 2 (.closure 0 [.var 0]) <|
      .letE 3 (.app (.var 1) [cell]) <|
      if duplicate == 0 then .app (.var 2) [cell] else .prim .record [.var 3, .var 0] }

def identityMap : Gen Program := do
  let live ← draw 2
  let count ← draw 4
  let d : Decl := {
    name := "identity", parameters := [.list .int], result := .list .int,
    body := .atom (.var 0) }
  return {
    declarations := [Library.map (.list .int) (.list .int), d]
    main := .letE 0 (.prim (.literal .int) [.int count]) <|
      .letE 1 (.prim (.literal (.list .int)) [.var 0]) <|
      .letE 2 (.closure 0 []) <| .letE 3 (.closure 1 []) <|
      .letE 4 (.app (.var 2) [.var 1,.var 3]) <|
      .letE 5 (.focus (.var 4) (.int 0) 6 (.prim .push [.var 6,.int 9])) <|
      if live == 0 then .atom (.var 5) else .prim .record [.var 5,.var 1] }

def loopProgram : Gen Program := do
  let n ← draw 5
  let borrowed ← draw 2
  return {
    main := .letE 0 (.prim (.literal .int) [.int 0]) <|
      .letE 1 (.traverse .range (.int n) (.var 0) 2 3 4 <|
        .branch (.var 2) (.atom (.var 4)) (.prim .push [.var 4,.var 3])) <|
      if borrowed == 0 then .atom (.var 1) else .prim .record [.var 0,.var 1] }

def generate : Gen Program := do
  match ← draw 5 with
  | 0 => nested
  | 1 => captureProgram
  | 2 => identityMap
  | 3 => loopProgram
  | _ =>
    let depth ← draw 8
    pure {
      main := .letE 0 (.prim (.literal .int) [← number])
        (← chain (depth + 1) 1 [(.var 0,.list .int)]) }

end Ownership.OracleLegacy
