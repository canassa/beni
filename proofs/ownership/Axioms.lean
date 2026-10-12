import Ownership
import Lean

/-! Axiom audit, built by `lake build` (target `AxiomCheck`).

Three checks, and **the build fails** unless all pass.

1. Every constant declared in an `Ownership` module — theorems, definitions,
   instances, structures, recursors and the auxiliary declarations Lean
   generates for them — has its axioms collected. Only `propext`,
   `Classical.choice`, `Quot.sound` and `sorryAx` are allowed, and the
   constants that depend on `sorryAx` must be exactly the pinned list below. A
   `def x : 1 + 1 = 3 := sorry` therefore fails the build, as does a proof that
   silently starts depending on a `sorry` or a declared `axiom`.
2. Every such constant is sent to the kernel again (`Lean.Environment.replay`,
   what lean4checker does), in a fresh environment holding only what the
   modules import: a declaration added with `debug.skipKernelTC` or by a raw
   `addDecl` is checked after all, and a false one fails the build.
3. An `example` adds no constant to the environment, so (1) cannot see it.
   The source of every `.lean` file under the package (every subdirectory,
   `.lake` excepted) is therefore scanned, outside comments and string and
   character literals, for tokens: `sorry` may occur exactly as often as there
   are pinned unproved statements; `admit`, `native_decide`, `axiom`,
   `skipKernelTC`, `addDecl`, `run_cmd`, `implemented_by` and `extern` never.

Removing a `sorry` requires shrinking the list on purpose. -/

open Lean

/-- The unproved statements, each with exactly one `sorry` in its proof. -/
def unproved : List Name := [
  `Ownership.Soundness.summary_sound,
  `Ownership.Soundness.map_summary_sound,
  `Ownership.Soundness.invariant_preserved]

/-- Constants allowed to depend on `sorryAx`: the unproved statements and the
    main theorem, which is proved from `invariant_preserved`. -/
def pinnedSorries : List Name := unproved ++ [`Ownership.Soundness.accepted_traces_agree]

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound, ``sorryAx]

/-- The source files the scan reads: every `.lean` file under the package
    root, in every subdirectory, except the build directory `.lake`. -/
def sources : IO (List System.FilePath) := do
  let all ← System.FilePath.walkDir "." (enter := fun d => pure (d.fileName != some ".lake"))
  let files := all.toList.filter fun p => p.extension == some "lean"
  pure (files.mergeSort (·.toString < ·.toString))

/-- Tokens no source may contain: what proves without proof (`admit`,
    `native_decide`, a declared `axiom`), and what reaches past the kernel or
    the elaborator (`debug.skipKernelTC`, a raw `addDecl` from `run_cmd`, an
    implementation swapped in by `implemented_by` or `extern`). -/
def banned : List String :=
  ["admit", "native_decide", "axiom", "skipKernelTC", "debug.skipKernelTC", "addDecl", "run_cmd",
   "implemented_by", "extern"]

/-- The identifier-like tokens of Lean source outside comments (`--`, nested
    `/- -/`) and string and character literals. -/
partial def tokens (s : String) : List String := Id.run do
  let cs := s.toList.toArray
  let mut out : Array String := #[]
  let mut i := 0
  let mut depth := 0
  let mut word := ""
  while i < cs.size do
    let c := cs[i]!
    let next := cs[i + 1]?.getD ' '
    if depth > 0 then
      if c == '/' && next == '-' then depth := depth + 1; i := i + 2
      else if c == '-' && next == '/' then depth := depth - 1; i := i + 2
      else i := i + 1
      continue
    -- A prime inside a word is part of the name (`h'`); one that starts a
    -- token opens a character literal, skipped whole (`'"'`, `'\n'`).
    if c == '\'' && word.isEmpty then
      if next == '\\' then
        i := i + 3
        while i < cs.size && cs[i]! != '\'' do i := i + 1
        i := i + 1
      else i := i + 3
      continue
    -- A raw string `r"…"` or `r#"…"#`, skipped whole.
    if word == "r" && (c == '"' || c == '#') then
      let mut hashes := 0
      while i < cs.size && cs[i]! == '#' do hashes := hashes + 1; i := i + 1
      i := i + 1
      let mut closed := false
      while i < cs.size && !closed do
        if cs[i]! == '"' && (List.range hashes).all (fun k => cs[i + 1 + k]? == some '#') then
          closed := true; i := i + 1 + hashes
        else i := i + 1
      word := ""
      continue
    -- A guillemet name `«sorry»` is the token it spells.
    if c == '«' then
      if !word.isEmpty then out := out.push word; word := ""
      i := i + 1
      let mut inner := ""
      while i < cs.size && cs[i]! != '»' do inner := inner.push cs[i]!; i := i + 1
      out := out.push inner
      i := i + 1
      continue
    let isWord := c.isAlphanum || c == '_' || c == '.' || c == '\''
    if isWord then word := word.push c; i := i + 1; continue
    if !word.isEmpty then out := out.push word; word := ""
    if c == '/' && next == '-' then depth := 1; i := i + 2
    else if c == '-' && next == '-' then
      while i < cs.size && cs[i]! != '\n' do i := i + 1
    else if c == '"' then
      i := i + 1
      while i < cs.size && cs[i]! != '"' do
        i := i + (if cs[i]! == '\\' then 2 else 1)
      i := i + 1
    else i := i + 1
  if !word.isEmpty then out := out.push word
  pure out.toList

#eval show CoreM Unit from do
  let env ← getEnv
  let mut names : Array Name := #[]
  for (n, _) in env.constants.toList do
    match env.getModuleIdxFor? n with
    | some i =>
      if (env.header.moduleNames[i.toNat]!).toString.startsWith "Ownership" then
        names := names.push n
    | none => pure ()
  let sorted := names.qsort (·.toString < ·.toString)
  let mut withSorry : Array Name := #[]
  let mut theorems := 0
  for n in sorted do
    if let some (.thmInfo _) := env.find? n then theorems := theorems + 1
    let axs ← collectAxioms n
    if !axs.isEmpty && !n.isInternalDetail then IO.println s!"{n}: {axs.toList}"
    for a in axs do
      unless allowedAxioms.contains a do
        throwError "{n} depends on the axiom {a}"
    if axs.contains ``sorryAx then withSorry := withSorry.push n
  IO.println s!"{sorted.size} constants ({theorems} theorems); {withSorry.size} depend on sorryAx: {withSorry.toList}"
  for n in withSorry do
    unless pinnedSorries.contains n do throwError "{n} depends on sorryAx and is not pinned"
  for n in pinnedSorries do
    unless withSorry.contains n do
      throwError "{n} is pinned but no longer depends on sorryAx: shrink the list"
  -- Kernel replay: every Ownership constant is sent to the kernel again, in a
  -- fresh environment holding only what the Ownership modules import (Std),
  -- as lean4checker does; `debug.skipKernelTC` cannot have let one through.
  let base ← importModules #[{ module := `Std }] {}
  let mut fresh : Std.HashMap Name ConstantInfo := {}
  for n in sorted do
    -- The auxiliary recursors of nested inductives (`rec_1`, …) are not
    -- replayed: the kernel generates them again when it accepts the
    -- inductive, and every constant that uses them is checked against those.
    let aux := match n with
      | .str _ s => s.startsWith "rec_"
      | _ => false
    if aux then continue
    if let some ci := env.find? n then fresh := fresh.insert n ci
  let _ ← Lean.Environment.replay fresh base
  IO.println s!"kernel replay: {fresh.size} constants re-checked"
  -- The source scan, for what adds no constant (an `example`).
  let mut sorries := 0
  let files ← sources
  for path in files do
    let ts := tokens (← IO.FS.readFile path)
    for t in banned do
      if ts.contains t then throwError "{path} uses `{t}`"
    let n := (ts.filter (· == "sorry")).length
    if n > 0 then IO.println s!"{path}: {n} sorry"
    sorries := sorries + n
  if sorries != unproved.length then
    throwError "{sorries} `sorry` in the sources; exactly {unproved.length} (one per unproved statement) are allowed"
  IO.println s!"source scan: {files.length} files, {sorries} sorry, no banned token ({banned})"
