import Lean

/-! The audit executable (`lake exe audit`, run by `scripts/audit.sh`).

`Axioms.lean` audits inside the build, which is the build being audited: a
module could run code while it is elaborated and rewrite the audit, or hide
a command from a hand-written tokeniser (the fifth review did both). This
executable does not depend on any `Ownership` module to be built — it imports
only `Lean` and `Std` — and `scripts/audit.sh` builds it first, from a clean
checkout, and runs it before and after the full build:

* `audit sources`: every `.lean` file under the package is **parsed with
  Lean's own parser** (not tokenised by hand) and every command and syntax
  node is checked: only declarations, namespaces, sections, `open`,
  `set_option maxRecDepth`, `mutual`, module docs and `#guard` are allowed
  as commands (`#eval` only in `Axioms.lean`); `#guard` evaluates compiled
  terms during elaboration, subject to the source/binary integrity checks;
  no `unsafe` modifier or expression, no
  attribute but `simp`, no `admit` or `native_decide` tactic, no
  identifier whose any part names a kernel or compiler bypass, no import but
  `Std` and the package's own modules (`Lean` only in the two audit files),
  and exactly the pinned number of `sorry`s, all in `Soundness.lean`.
* `audit env`: the built `Ownership` modules are imported and every
  constant checked: axioms only `propext`, `Classical.choice`, `Quot.sound`
  and `sorryAx`, the `sorryAx` dependents exactly the pinned set, every
  constant replayed through the kernel, and no compiler attribute that swaps
  in an implementation (`implemented_by` other than a `partial def`'s own,
  `extern`, `csimp`, an initialiser). -/

open Lean

namespace Audit

def pinnedSorries : List Name := [
  `Ownership.Soundness.summary_sound,
  `Ownership.Soundness.map_summary_sound,
  `Ownership.Soundness.invariant_preserved,
  `Ownership.Soundness.accepted_traces_agree]

-- Three source sorries; the fourth pinned constant is their dependent main theorem.
def sorryCount : Nat := 3

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound, ``sorryAx]

def allowedCommands : List Name := [
  `Lean.Parser.Command.declaration, `Lean.Parser.Command.namespace, `Lean.Parser.Command.section,
  `Lean.Parser.Command.end, `Lean.Parser.Command.open, `Lean.Parser.Command.mutual,
  `Lean.Parser.Command.moduleDoc, `Lean.Parser.Command.in, `Lean.Parser.Command.guardCmd,
  `Lean.Parser.Command.set_option, `Lean.Parser.Command.eoi]

/-- Declaration grammar nodes, not executable commands. All other Command
    nodes, including commands underneath `in` or `mutual`, fail closed. -/
def declarationNodes : List Name := [
  `Lean.Parser.Command.whereStructInst, `Lean.Parser.Command.instance,
  `Lean.Parser.Command.private, `Lean.Parser.Command.ctor, `Lean.Parser.Command.inductive,
  `Lean.Parser.Command.derivingClass, `Lean.Parser.Command.declSig,
  `Lean.Parser.Command.theorem, `Lean.Parser.Command.declValEqns,
  `Lean.Parser.Command.abbrev, `Lean.Parser.Command.optDeriving,
  `Lean.Parser.Command.structSimpleBinder, `Lean.Parser.Command.structFields,
  `Lean.Parser.Command.structureTk, `Lean.Parser.Command.structure,
  `Lean.Parser.Command.openOnly, `Lean.Parser.Command.partial,
  `Lean.Parser.Command.docComment, `Lean.Parser.Command.declValSimple,
  `Lean.Parser.Command.optDeclSig, `Lean.Parser.Command.declId,
  `Lean.Parser.Command.definition, `Lean.Parser.Command.declModifiers,
  `Lean.Parser.Command.openSimple]

def executableTokens := ["unsafe", "run_cmd", "run_tac", "run_elab", "run_meta", "by_elab",
  "elab", "elab_rules", "macro", "macro_rules", "initialize", "builtin_initialize"]

/-- Names a part of an identifier may never be. -/
def bannedNames : List String :=
  ["addDecl", "addAndCompile", "setEnv", "modifyEnv", "skipKernelTC", "implementedByAttr",
   "externAttr", "setParam", "implemented_by", "extern", "native_decide", "ofReduceBool",
   "ofReduceNat", "unsafeCast", "unsafeBaseIO", "unsafeIO", "unsafeEIO", "evalConst"]

def sources : IO (List System.FilePath) := do
  let all ← System.FilePath.walkDir "." (enter := fun d => pure (d.fileName != some ".lake"))
  pure ((all.toList.filter fun p => p.extension == some "lean").mergeSort (·.toString < ·.toString))

/-- Every syntax node of a command, with every atom and identifier. -/
partial def nodes (s : Syntax) (acc : Array Syntax) : Array Syntax :=
  match s with
  | .node _ _ args => args.foldl (fun a x => nodes x a) (acc.push s)
  | _ => acc.push s

def checkSources : IO Unit := do
  let env ← importModules #[{ module := `Lean }, { module := `Std }] {} (loadExts := true)
  let files ← sources
  let mut sorries : List String := []
  for path in files do
    let name := path.fileName.getD ""
    let auditFile := ["./Axioms.lean", "Axioms.lean", "./Audit.lean", "Audit.lean"].contains path.toString
    let src ← IO.FS.readFile path
    let stx ← Parser.testParseModule env path.toString src
    -- Imports.
    for i in stx.raw[0][1].getArgs do
      let m := i[2].getId
      unless m == `Std || (`Ownership).isPrefixOf m || (auditFile && m == `Lean) do
        throw <| IO.userError s!"{path}: imports {m}"
    for c in stx.raw[1].getArgs do
      let k := c.getKind
      unless allowedCommands.contains k || (k == `Lean.Parser.Command.eval && name == "Axioms.lean") do
        throw <| IO.userError s!"{path}: command {k} is not allowed"
      for n in nodes c #[] do
        match n with
        | .node _ k' _ =>
          if k'.toString.startsWith "Lean.Parser.Command." then
            unless allowedCommands.contains k' || declarationNodes.contains k' ||
              (auditFile && name == "Axioms.lean" && k' == `Lean.Parser.Command.eval && n == c) do
              throw <| IO.userError s!"{path}: nested command {k'} is not allowed"
          if k' == `Lean.Parser.Command.unsafe then throw <| IO.userError s!"{path}: unsafe"
          if k' == `Lean.Parser.Term.attrInstance then
            let attr := n[1].getKind
            unless attr == `Lean.Parser.Attr.simp do
              throw <| IO.userError s!"{path}: attribute {attr} is not allowed"
          if k' == `Lean.Parser.Command.set_option then
            let o := n[1].getId
            unless o == `maxRecDepth || (`linter).isPrefixOf o do
              throw <| IO.userError s!"{path}: set_option {o} is not allowed"
          if k' == `Lean.Parser.Tactic.tacticSorry || k' == `Lean.Parser.Term.sorry then
            sorries := sorries ++ [path.toString]
          let ks := k'.toString
          if ks.endsWith "admit" || (ks.splitOn "nativeDecide").length > 1 || (ks.splitOn "native_decide").length > 1 then
            throw <| IO.userError s!"{path}: tactic {k'} is not allowed"
        | .ident _ _ val _ =>
          for part in val.components do
            if bannedNames.contains part.toString then
              throw <| IO.userError s!"{path}: identifier {val} names {part}"
        | .missing => throw <| IO.userError s!"{path}: unparsed syntax"
        | .atom _ token =>
          if executableTokens.contains token then throw <| IO.userError s!"{path}: executable syntax {token}"
  unless sorries.length == sorryCount && sorries.all (·.endsWith "Soundness.lean") do
    throw <| IO.userError s!"sorry in {sorries}; exactly {sorryCount} are allowed, in Soundness.lean"
  IO.println s!"audit sources: {files.length} files parsed, {sorries.length} sorry, every command and node allowed"

def checkEnv : IO Unit := do
  -- Include the executable's modules too: importing only the library
  -- omitted the generator, fixtures, enumerator and executable falsifier.
  let env ← importModules #[{ module := `Ownership }, { module := `Main }] {} (loadExts := true)
  let mut names : Array Name := #[]
  for (n, _) in env.constants.toList do
    if let some i := env.getModuleIdxFor? n then
      if (env.header.moduleNames[i.toNat]!).toString.startsWith "Ownership" || env.header.moduleNames[i.toNat]! == `Main then names := names.push n
  let mut withSorry : Array Name := #[]
  for n in names do
    let (_, s) := ((CollectAxioms.collect n).run env).run {}
    for a in s.axioms do
      unless allowedAxioms.contains a do throw <| IO.userError s!"{n} depends on the axiom {a}"
    if s.axioms.contains ``sorryAx then withSorry := withSorry.push n
  for n in withSorry do
    unless pinnedSorries.contains n do throw <| IO.userError s!"{n} depends on sorryAx and is not pinned"
  for n in pinnedSorries do
    unless withSorry.contains n do throw <| IO.userError s!"{n} is pinned but proved: shrink the list"
  let mut partials := 0
  for n in names do
    if let some impl := Compiler.getImplementedBy? env n then
      if impl == Name.str n "_unsafe_rec" then partials := partials + 1
      else throw <| IO.userError s!"{n} is implemented by {impl}"
    if isExtern env n then throw <| IO.userError s!"{n} is extern"
    if Compiler.hasCSimpAttribute env n then throw <| IO.userError s!"{n} has @[csimp]"
    if hasInitAttr env n then throw <| IO.userError s!"{n} runs at initialisation"
  -- Module by module, as lean4checker does: each module's constants are sent
  -- to the kernel again in a fresh environment holding only its imports.
  let mut replayed := 0
  for (m, i) in env.header.moduleNames.zipIdx do
    unless m.toString.startsWith "Ownership" || m == `Main do continue
    let some data := env.header.moduleData[i]? | continue
    let base ← importModules data.imports {}
    let mut fresh : Std.HashMap Name ConstantInfo := {}
    let mut recursors : Array RecursorVal := #[]
    for n in names do
      unless (env.getModuleIdxFor? n).map (·.toNat) == some i do continue
      if let some ci := env.find? n then
        match ci with
        | .recInfo r => recursors := recursors.push r
        | _ => fresh := fresh.insert n ci
    let rebuilt ← Environment.replay fresh base
    -- Replay's metadata lookup omits nested auxiliary recursors. The kernel
    -- did regenerate them: compare every complete RecursorVal directly in
    -- its kernel environment. Ordinary rec_* names have no exemption.
    for original in recursors do
      match rebuilt.toKernelEnv.find? original.name with
      | some (.recInfo regenerated) =>
        unless regenerated == original do throw <| IO.userError s!"invalid regenerated recursor {original.name}"
      | _ => throw <| IO.userError s!"missing regenerated recursor {original.name}"
    replayed := replayed + fresh.size + recursors.size
  IO.println s!"audit env: {names.size} constants, {withSorry.size} on sorryAx (pinned), {replayed} replayed through the kernel module by module, no compiler attribute swapped in ({partials} partial definitions)"

end Audit

def main (args : List String) : IO UInt32 := do
  initSearchPath (← findSysroot)

  match args with
  | [] => Audit.checkSources; Audit.checkEnv
  | ["sources"] => Audit.checkSources
  | ["env"] => Audit.checkEnv
  | _ =>
    IO.eprintln "usage: audit [sources|env]"
    return 2
  pure 0
