import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures

open Ownership

def flagValue (args : List String) (name : String) : Option String :=
  args.findSome? fun a => if a.startsWith s!"--{name}=" then some (a.drop (name.length + 3)).toString else none

def main (args : List String) : IO UInt32 := do
  let mode := args.head?.getD "all"
  let positional := args.filter (fun a => !a.startsWith "--" &&
    !["all", "oracle", "fixtures", "reasons"].contains a)
  let count := positional[0]?.bind String.toNat? |>.getD 1000
  let seed := positional[1]?.bind String.toNat? |>.getD 20261011
  let version := (flagValue args "generator-version").bind String.toNat? |>.getD 4
  if mode == "reasons" then
    Oracle.reasons count seed ((flagValue args "family").getD "general") version
    return 0
  if mode != "oracle" && mode != "--generator-only" then
    if !(← Fixtures.run) then return 1
  if mode == "fixtures" then return 0
  let oldFreshRule := args.contains "--old-rule"
  let dropTraversalEscapes := args.contains "--old-escape-rule"
  let config : Config := { oldFreshRule, dropTraversalEscapes }
  let r ← Oracle.runWith { count, seed, version, config }
  pure (if r.ok then 0 else 1)
