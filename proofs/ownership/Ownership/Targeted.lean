import Ownership.Enumerate
import Ownership.Sync

namespace Ownership.Targeted
open Generator (tL tN tR fIL fIR)
private def v := Atom.var

def countBoundary (n : Int) (calls : Nat) : Program := Id.run do
  let body := (List.range calls).foldr (fun i rest => .letE (2+i) (.app (v 1) [v 0]) rest)
    (.prim .record [v 2, v (1+calls)])
  let d : Decl := { name := "countBoundary", parameters := [.int], captures := [fIL], result := tR, body }
  return {
    declarations := Generator.decls ++ [d]
    main := .letE 0 (.prim (.literal .int) [.int n]) <| .letE 1 (.closure Generator.capPush [v 0]) <|
      .letE 2 (.closure Generator.decls.length [v 1]) <| .letE 3 (.closure Generator.invokePair [])
        (.app (v 3) [v 2]) }

def consumingCapture (n : Int) (writer : Nat) : Program := {
  declarations := Generator.decls
  main := .letE 0 (.prim (.literal .int) [.int n]) <| .letE 1 (.closure writer []) <|
    .letE 2 (.closure Generator.capturedWriter [v 0, v 1]) <|
    .letE 3 (.prim (.builder .int) []) <| .letE 4 (.prim .put [v 3, .int n]) <|
    .letE 5 (.prim .close [v 4, v 0]) <| .letE 6 (.closure Generator.invokeIL []) <|
    .letE 7 (.app (v 6) [v 2]) (.prim .record [v 5, v 7]) }

def transitiveCapture (n : Int) : Program := {
  declarations := Generator.decls
  main := .letE 0 (.prim (.literal .int) [.int n]) <| .letE 1 (.closure Generator.capPush [v 0]) <|
    .letE 2 (.closure Generator.capApply [v 1]) <|
    .letE 3 (.prim (.builder .int) []) <| .letE 4 (.prim .put [v 3, .int n]) <|
    .letE 5 (.prim .close [v 4, v 0]) <| .letE 6 (.closure Generator.invokeIL []) <|
    .letE 7 (.app (v 6) [v 2]) (.prim .record [v 5, v 7]) }

def shapeJoin (n c : Int) (comparison : Prim) (written : Nat) : Program := {
  declarations := Generator.decls
  main := .letE 0 (.prim (.literal .int) [.int n]) <|
    .letE 1 (.prim (.literal .int) [.int (n+1)]) <| .letE 2 (.closure Generator.capGet [v 1]) <|
    .letE 3 (.closure Generator.chooseFn []) <| .letE 4 (.prim comparison [.int c, .int 1]) <|
    .letE 5 (.app (v 3) [v 4, v 0, v 2]) <|
    .letE 6 (.prim .push [v written, .int (n+2)]) (.prim .record [v 5, v 6]) }

def setExclusive (n : Int) (index : Nat) : Program := {
  declarations := Generator.decls
  main := .letE 0 (.prim (.literal .int) [.int n]) <|
    .letE 1 (.prim (.literal .int) [.int (n+1)]) <| .letE 2 (.prim (.literal tL) [v 0, v 1]) <|
    .letE 3 (.prim (.literal .int) []) <| .letE 4 (.prim .at [v 2, .int 0, v 3]) <|
    .letE 5 (.prim .set [v 2, .int (Int.ofNat index), v 4]) <|
    .letE 6 (.closure Generator.mapLL []) <| .letE 7 (.closure Generator.bump []) (.app (v 6) [v 5, v 7]) }

def recursion (n : Int) (steps : Nat) (comparison : Prim) (keep : Bool) : Program := Id.run do
  let d : Decl := {
    name := "recursiveCounter", parameters := [.int, tL], result := tL
    body := .letE 2 (.prim comparison [v 0, .int (if comparison == .lt then 1 else 0)]) <|
      .branch (v 2) (.letE 3 (.prim .push [v 1, .int n]) <|
        .letE 4 (.prim .add [v 0, .int (-1)]) (.recur [v 4, v 3])) (.atom (v 1)) }
  return {
    declarations := Generator.decls ++ [d]
    main := .letE 0 (.prim (.literal .int) [.int n]) <| .letE 1 (.closure Generator.decls.length []) <|
      .letE 2 (.app (v 1) [.int (Int.ofNat steps), v 0])
        (if keep then .prim .record [v 0, v 2] else .atom (v 2)) }

/-- Cartesian products of the displayed templates, complete at these bounds.
    These complement the small grammar; they are not all core programs. -/
def programs : List Program :=
  let ints : List Int := [-1, 0, 1, 2]
  Sync.legacyPrograms ++ ints.flatMap (fun n => [1,2,3].map (countBoundary n)) ++
  ints.flatMap (fun n => [Generator.bump, Generator.identL].map (consumingCapture n)) ++
  ints.map transitiveCapture ++
  ints.flatMap (fun n => ints.flatMap fun c => [Prim.eq, Prim.lt].flatMap fun op => [0,1].map (shapeJoin n c op)) ++
  ints.flatMap (fun n => [0,1].map (setExclusive n)) ++
  ints.flatMap (fun n => [0,1,2].flatMap fun steps => [Prim.eq, Prim.lt].flatMap fun op => [false,true].map (recursion n steps op)) ++ Sync.extraPrograms

def run (config : Config := {}) (mode : Enumerate.Mode := .full)
    (acceptedOut : Option System.FilePath := none) : IO Bool := do
  let mut keys : Array UInt64 := #[]
  let mut accepted := 0
  let mut changed := 0
  let mut mismatches := 0
  let mut inconclusive := 0
  for (p, i) in programs.zipIdx do
    unless (typesOf p).isOk do throw <| IO.userError s!"ill-typed targeted program {i}"
    if !(Oracle.verdictOf p config).isOk then continue
    accepted := accepted + 1
    if config.mutant.isNone && !config.oldFreshRule && !config.dropTraversalEscapes && !config.reinfer then
      if let .ok a := check p config then
        if let .error problem := Falsify.resultCertificates p a then
          throw <| IO.userError s!"targeted certificate failure {i}: {problem}"
    keys := keys.push i.toUInt64
    let checkIt := match mode with
      | .full => true
      | .control => !(Oracle.verdictOf p { reinfer := config.reinfer }).isOk
      | .skipping baseline => !baseline.contains i.toUInt64
    if !checkIt then continue
    if !(mode matches .full) then changed := changed + 1
    IO.FS.createDirAll "regressions"
    IO.FS.writeFile "regressions/targeted-current.txt" s!"index={i}\n{repr p}\n"
    match Oracle.compare p with
      | .equal => pure ()
      | .inconclusive reason => inconclusive := inconclusive + 1; IO.println s!"targeted error {i}: {reason}"
      | outcome =>
        mismatches := mismatches + 1
        IO.FS.createDirAll "regressions"
        IO.FS.writeFile s!"regressions/targeted-{i}-unshrunk.txt" s!"{repr p}\n{repr outcome}\n"
        IO.println s!"targeted mismatch index={i}: {repr outcome}"
        (← IO.getStdout).flush
  if let some path := acceptedOut then IO.FS.writeFile path (String.intercalate "\n" (keys.toList.map toString))
  let caught := mismatches != 0
  IO.println s!"targeted programs={programs.length} typed={programs.length} accepted={accepted} changed-verdicts={changed} mismatches={mismatches} inconclusive={inconclusive} caught={caught}"
  return inconclusive == 0 && (if mode matches .full then !caught else caught)

end Ownership.Targeted
