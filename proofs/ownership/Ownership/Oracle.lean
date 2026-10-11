import Ownership.Library
import Ownership.OracleLegacy
import Ownership.Semantics

namespace Ownership.Oracle

abbrev Gen := StateM Nat

def draw (bound : Nat) : Gen Nat := do
  let s ← get
  let next := (s * 1664525 + 1013904223) % 4294967296
  set next
  pure ((next / 65536) % (max 1 bound))

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

/-- A callback publishes a captured cell without returning it. Escape effects
    must survive traversal independently of the accumulator provenance. -/
def escapedProgram : Gen Program := do
  let count ← draw 3
  let cell ← number
  return {
    main := .letE 0 (.prim (.literal .int) [cell]) <|
      .letE 1 (.traverse .range (.int (count + 1)) (.int 0) 2 3 4 <|
        .letE 5 (.prim .shared [.var 0]) (.atom (.var 4))) <|
      .prim .push [.var 0, cell] }

def generate : Gen Program := do
  match ← draw 6 with
  | 0 => nested
  | 1 => captureProgram
  | 2 => identityMap
  | 3 => loopProgram
  | 4 => escapedProgram
  | _ =>
    let depth ← draw 8
    pure {
      main := .letE 0 (.prim (.literal .int) [← number])
        (← chain (depth + 1) 1 [(.var 0,.list .int)]) }

inductive Outcome where
  | equal | mismatch (value inPlace : Trace) | inconclusive (message : String)
  deriving Repr

def compare (p : Program) : Outcome :=
  match ValueSemantics.run p, InPlaceSemantics.run p with
  | .ok a, .ok b => if a == b then .equal else .mismatch a b
  | a,b => .inconclusive s!"value={repr a}; in-place={repr b}"

def disagrees (p : Program) (config : Config) : Bool :=
  (typecheck p).isOk && (check p config).isOk &&
    match compare p with | .mismatch .. => true | _ => false

partial def reductions : Expr → List Expr
  | .letE v rhs rest => [rhs, rest] ++
      (reductions rhs).map (fun r => .letE v r rest) ++
      (reductions rest).map (fun r => .letE v rhs r)
  | .branch c yes no => [yes,no] ++
      (reductions yes).map (fun y => .branch c y no) ++
      (reductions no).map (fun n => .branch c yes n)
  | .prim (.literal t) args => (List.range args.length).map fun i =>
      .prim (.literal t) (args.take i ++ args.drop (i+1))
  | .traverse k src init i x acc body => [.atom init] ++
      (reductions body).map (fun b => .traverse k src init i x acc b)
  | .focus src i x body => [.atom src] ++ (reductions body).map (fun b => .focus src i x b)
  | _ => []

/-- Greedy local minimum over syntax deletion and branch/list reduction. Every
    proposed reduction must remain ordinarily typed, accepted and disagreeing. -/
partial def shrink (p : Program) (config : Config) : Program :=
  let mains := (reductions p.main).map (fun e => { p with main := e })
  let bodies := p.declarations.zipIdx.flatMap fun (d,i) =>
    (reductions d.body).map fun e => { p with declarations := p.declarations.set i { d with body := e } }
  match (mains ++ bodies).find? (fun q => q != p && disagrees q config) with
  | none => p
  | some q => shrink q config

structure Counts where
  candidates : Nat := 0
  typed : Nat := 0
  accepted : Nat := 0
  rejected : Nat := 0
  typeErrors : Nat := 0
  limits : Nat := 0
  executionErrors : Nat := 0
  mismatches : Nat := 0
  deriving Repr

def run (count seed : Nat) (old := false) (legacy := false) : IO Bool := do
  let start ← IO.monoMsNow
  let config : Config := { oldFreshRule := old }
  let mut state := seed
  let mut counts : Counts := {}
  let mut oldFound := false
  for index in List.range count do
    let (p, next) := (if legacy then OracleLegacy.generate else generate).run state
    state := next
    counts := { counts with candidates := counts.candidates + 1 }
    match typecheck p with
    | .error msg =>
      counts := { counts with typeErrors := counts.typeErrors + 1 }
      IO.println s!"TYPE GENERATION ERROR seed={seed} index={index}: {msg}\n{repr p}"
      return false
    | .ok _ => counts := { counts with typed := counts.typed + 1 }
    match check p config with
    | .error msg =>
      counts := { counts with
        rejected := counts.rejected + 1,
        limits := counts.limits + (if msg.startsWith "limit:" then 1 else 0) }
    | .ok _ =>
      counts := { counts with accepted := counts.accepted + 1 }
      match compare p with
      | .equal => pure ()
      | .inconclusive msg =>
        counts := { counts with executionErrors := counts.executionErrors + 1 }
        IO.println s!"INCONCLUSIVE seed={seed} index={index}: {msg}"
        return false
      | .mismatch _ _ =>
        counts := { counts with mismatches := counts.mismatches + 1 }
        let minimal := shrink p config
        let report := s!"generator-version={if legacy then 1 else 2} seed={seed} index={index} old-rule={old}\nAST:\n{repr minimal}\n{repr (compare minimal)}\ncorrected checker: {repr (check minimal)}\n"
        IO.FS.createDirAll "regressions"
        IO.FS.writeFile s!"regressions/{if old then "old" else "soundness"}-{seed}-{index}.txt" report
        IO.println report
        if !old then
          IO.println s!"STOP corrected-rule soundness finding: {repr counts}"
          return false
        if (check minimal).isOk then
          IO.println "STOP old-rule mismatch also accepted by corrected rule"
          return false
        oldFound := true
  IO.println s!"generator-version={if legacy then 1 else 2} seed={seed} old-rule={old} {repr counts} elapsed-ms={(← IO.monoMsNow)-start}"
  if old && !oldFound then
    IO.println "NEGATIVE CONTROL FAILED: no generated accepted disagreement"
    return false
  pure (counts.accepted > 0 && counts.typeErrors == 0 && counts.executionErrors == 0)

end Ownership.Oracle
