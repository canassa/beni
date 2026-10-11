import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures

open Ownership

def flagValue (args : List String) (name : String) : Option String :=
  args.findSome? fun a => if a.startsWith s!"--{name}=" then some (a.drop (name.length + 3)).toString else none

def main (args : List String) : IO UInt32 := do
  let mode := args.head?.getD "all"
  let positional := args.filter (fun a => !a.startsWith "--" &&
    !["all", "oracle", "fixtures", "controls", "reasons", "ci"].contains a)
  let count := positional[0]?.bind String.toNat? |>.getD 1000
  let seed := positional[1]?.bind String.toNat? |>.getD 20261011
  let version := (flagValue args "generator-version").bind String.toNat? |>.getD 4
  let mutant ← match flagValue args "mutant" with
    | none => pure none
    | some name => match Mutant.parse name with
      | some m => pure (some m)
      | none =>
        IO.println s!"unknown mutant {name}; known: {Mutant.all.map Mutant.name}"
        return 2
  if mode == "reasons" then
    Oracle.reasons count seed ((flagValue args "family").getD "general") version
    return 0
  if mode == "controls" then
    return (if ← Oracle.controls count seed version then 0 else 1)
  -- The CI-style check: fixtures, one normal campaign, every negative control.
  if mode == "ci" then
    let budget := positional[0]?.bind String.toNat? |>.getD 20000
    if !(← Fixtures.run) then return 1
    if !(← Oracle.runWith { count := budget, seed, version, quiet := true }).ok then return 1
    return (if ← Oracle.controls budget seed version then 0 else 1)
  if mode != "oracle" && mode != "--generator-only" then
    if !(← Fixtures.run) then return 1
  if mode == "fixtures" then return 0
  let oldFreshRule := args.contains "--old-rule"
  let dropTraversalEscapes := args.contains "--old-escape-rule"
  let config : Config := { oldFreshRule, dropTraversalEscapes, mutant }
  let r ← Oracle.runWith { count, seed, version, config }
  pure (if r.ok then 0 else 1)
