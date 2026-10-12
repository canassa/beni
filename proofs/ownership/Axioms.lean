import Ownership
import Lean

/-! Axiom audit, built by `lake build` (target `AxiomCheck`).

Prints the axioms of every theorem declared in an `Ownership` module and
**fails the build** unless the theorems that depend on `sorryAx` are exactly
the pinned list below, and no theorem depends on an axiom other than
`propext`, `Classical.choice`, `Quot.sound` and `sorryAx`. A new `sorry`, a
proof that silently starts depending on one, or a declared `axiom` breaks the
build; removing a `sorry` requires shrinking the list on purpose. -/

open Lean

/-- Theorems allowed to depend on `sorryAx`: the three unproved statements and
    the main theorem, which is proved from `invariant_preserved`. -/
def pinnedSorries : List Name := [
  `Ownership.Soundness.summary_sound,
  `Ownership.Soundness.map_summary_sound,
  `Ownership.Soundness.invariant_preserved,
  `Ownership.Soundness.accepted_traces_agree]

def allowedAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound, ``sorryAx]

#eval show CoreM Unit from do
  let env ← getEnv
  let mut theorems : Array Name := #[]
  for (n, ci) in env.constants.toList do
    if let .thmInfo _ := ci then
      if n.isInternalDetail then continue
      match env.getModuleIdxFor? n with
      | some i =>
        if (env.header.moduleNames[i.toNat]!).toString.startsWith "Ownership" then
          theorems := theorems.push n
      | none => pure ()
  let sorted := theorems.qsort (·.toString < ·.toString)
  let mut withSorry : Array Name := #[]
  for n in sorted do
    let axs ← collectAxioms n
    IO.println s!"{n}: {axs.toList}"
    for a in axs do
      unless allowedAxioms.contains a do
        throwError "{n} depends on the axiom {a}"
    if axs.contains ``sorryAx then withSorry := withSorry.push n
  IO.println s!"{sorted.size} theorems; {withSorry.size} depend on sorryAx"
  for n in withSorry do
    unless pinnedSorries.contains n do throwError "{n} depends on sorryAx and is not pinned"
  for n in pinnedSorries do
    unless withSorry.contains n do
      throwError "{n} is pinned but no longer depends on sorryAx: shrink the list"
