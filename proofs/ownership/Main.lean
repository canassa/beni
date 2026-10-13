import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures
import Ownership.Report
import Ownership.Falsify
import Ownership.Enumerate

open Ownership

def flagValue (args : List String) (name : String) : Option String :=
  args.findSome? fun a => if a.startsWith s!"--{name}=" then some (a.drop (name.length + 3)).toString else none

def main (args : List String) : IO UInt32 := do
  let mode := args.head?.getD "all"
  let positional := args.filter (fun a => !a.startsWith "--" &&
    !["all", "oracle", "fixtures", "controls", "reasons", "ci", "summaries", "verdict-diff", "falsify", "accepted", "enumerate"].contains a)
  let count := positional[0]?.bind String.toNat? |>.getD 1000
  let seed := positional[1]?.bind String.toNat? |>.getD 20261011
  let version := (flagValue args "generator-version").bind String.toNat? |>.getD 5
  let mutant ← match flagValue args "mutant" with
    | none => pure none
    | some name => match Mutant.parse name with
      | some m => pure (some m)
      | none =>
        IO.println s!"unknown mutant {name}; known: {Mutant.all.map Mutant.name}"
        return 2
  -- Execute the unproved statements of Soundness.lean on concrete
  -- configurations (Falsify.lean): random states for the step lemma, and
  -- every call of the accepted programs of a campaign for Lemma 6.7.
  if mode == "falsify" then
    let a ← Falsify.invariantCampaign count seed (checker := { mutant })
    let b ← Falsify.summaryCampaign count seed (checker := { mutant })
    -- Vacuity is a failure past a stated bound: a call no summary describes
    -- for a reason other than one array at two input paths (the statement's
    -- documented exception) may be at most 0.5 % of calls, and that
    -- exception at most 5 %.
    let otherVacuous := b.vacuousDescribed + b.vacuousUnique + b.vacuousOther
    let vacuityOk := otherVacuous * 200 ≤ b.calls && b.vacuousSeparating * 20 ≤ b.calls
    if !vacuityOk then
      IO.println s!"FALSIFY summary_sound vacuous on too many calls: {otherVacuous} not described, {b.vacuousSeparating} one array at two paths, of {b.calls}"
    let clean := a.hypothesisFalse == 0 && a.observational == 0 && a.errorClause == 0 &&
      a.naming == 0 && a.uncoveredAccepted == 0 && b.violations == 0 && vacuityOk
    IO.println s!"falsify count={count} seed={seed} clean={clean}"
    return (if clean then 0 else 1)
  -- Every typed program of the enumeration grammar up to `bound` bindings
  -- (Enumerate.lean); with `--mutant=`, succeed only if one is caught.
  if mode == "enumerate" then
    let bound := positional[0]?.bind String.toNat? |>.getD 2
    let oldFreshRule := args.contains "--old-rule"
    let dropTraversalEscapes := args.contains "--old-escape-rule"
    let reinfer := args.contains "--reinfer"
    let config : Config := { mutant, oldFreshRule, dropTraversalEscapes, reinfer }
    if args.contains "--count-only" then
      IO.println s!"enumerate bound={bound} programs={← Enumerate.countOnly bound}"
      return 0
    -- `--skip-accepted=<file>`: this is a source-level mutant's build, and
    -- the file lists what the corrected build accepts (`--accepted-out=`).
    let mode ← match flagValue args "skip-accepted" with
      | some path => pure (Enumerate.Mode.skipping (← Enumerate.readKeys path))
      | none => pure (if mutant.isSome || oldFreshRule || dropTraversalEscapes then .control else .full)
    let acceptedOut := (flagValue args "accepted-out").map System.FilePath.mk
    let (ok, _) ← Enumerate.run bound config mode (acceptedOut := acceptedOut)
    return (if ok then 0 else 1)
  if mode == "reasons" then
    Oracle.reasons count seed ((flagValue args "family").getD "general") version
    return 0
  -- Print the published summaries of accepted fixtures whose id contains the
  -- `--fixture=` text: the derived rows of map, foldl, initialize and update.
  if mode == "summaries" then
    let wanted := (flagValue args "fixture").getD ""
    for f in Fixtures.all do
      if (f.id.splitOn wanted).length > 1 || wanted.isEmpty then
        match check f.program with
        | .ok a =>
          IO.println s!"== {f.id}: {a.computed} summaries computed, {a.reused} reused"
          for e in a.cache do IO.println (Report.entryS f.program.declarations e)
        | .error e => IO.println s!"== {f.id}: rejected ({e})"
    return 0
  -- The indices of the generated programs this build's checker accepts, one
  -- per line: two builds' lists differ exactly where a source-level edit
  -- changes a verdict (`verdict-diff` does this for the `--mutant=` flags).
  if mode == "accepted" then
    let mut state := seed
    for index in List.range count do
      let ((_, p), next) := (Oracle.generateVersion version).run state
      state := next
      if (check p).isOk then IO.println s!"{index}"
    return 0
  if mode == "verdict-diff" then
    match mutant with
    | some m => let _ ← Oracle.verdictDiff count seed m (args.contains "--reinfer") version
    | none => IO.println "verdict-diff needs --mutant="
    return 0
  if mode == "controls" then
    return (if ← Oracle.controls count seed version (args.contains "--reinfer") then 0 else 1)
  -- The CI-style check: fixtures, one normal campaign, every negative control.
  if mode == "ci" then
    let budget := positional[0]?.bind String.toNat? |>.getD 20000
    if !(← Fixtures.run) then return 1
    let r ← Oracle.runWith { count := budget, seed, version, quiet := true }
    if !r.ok then return 1
    -- The review's original defect was a general family none of whose accepted
    -- programs wrote. Require that at least 30 % of accepted programs do.
    if r.counts.withWrites * 10 < r.counts.accepted * 3 then
      IO.println s!"CI FAILED: only {r.counts.withWrites} of {r.counts.accepted} accepted programs write in place (< 30 %)"
      return 1
    IO.println s!"writes: {r.counts.withWrites} of {r.counts.accepted} accepted programs write in place"
    -- Every required control is required twice: through its fixed probe
    -- (`Fixtures.run` above), and through the generator alone within the
    -- budget (`Oracle.controls`; the stream is deterministic, so this is as
    -- reproducible as the probes). Controls the generator reaches rarely or
    -- never are reported, not required (`Mutant.generatorOptional`).
    -- `--strict` is still accepted and changes nothing.
    let caught ← Oracle.controls budget seed version
    IO.println s!"generator catches every required control within {budget} trials: {caught}"
    if !caught then return 1
    -- Every program of the enumeration grammar up to the bound (Enumerate.lean):
    -- no accepted one may disagree.
    let bound := (flagValue args "enumerate-bound").bind String.toNat? |>.getD 3
    let (ok, _) ← Enumerate.run bound
    return (if ok then 0 else 1)
  if mode != "oracle" && mode != "--generator-only" then
    if !(← Fixtures.run) then return 1
  if mode == "fixtures" then return 0
  let oldFreshRule := args.contains "--old-rule"
  let dropTraversalEscapes := args.contains "--old-escape-rule"
  let reinfer := args.contains "--reinfer"
  let config : Config := { oldFreshRule, dropTraversalEscapes, mutant, reinfer }
  let r ← Oracle.runWith { count, seed, version, config, crossCheck := args.contains "--cross-check" }
  pure (if r.ok then 0 else 1)
