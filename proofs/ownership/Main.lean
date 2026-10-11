import Ownership
import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures

open Ownership

def main (args : List String) : IO UInt32 := do
  if !args.contains "--generator-only" && !(← Fixtures.run) then return 1
  if args.contains "--generator-only" then
    IO.println "Generator only: fixed suite skipped explicitly; known-red escape-traversal regression remains unresolved."
  let old := args.contains "--old-rule"
  let positional := args.filter (fun a => !a.startsWith "--")
  let count := positional[0]?.bind String.toNat? |>.getD 1000
  let seed := positional[1]?.bind String.toNat? |>.getD 20261011
  pure (if ← Oracle.run count seed old (args.contains "--generator-version=1") then 0 else 1)
