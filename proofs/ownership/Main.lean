import Ownership.Smoke
import Ownership.Oracle
import Ownership.Fixtures

open Ownership

def main (args : List String) : IO UInt32 := do
  let mode := args.head?.getD "all"
  if mode != "oracle" && mode != "--generator-only" then
    if !(← Fixtures.run) then return 1
  if mode == "fixtures" then return 0
  let positional := args.filter (fun a => !a.startsWith "--" && a != "all" && a != "oracle")
  let count := positional[0]?.bind String.toNat? |>.getD 1000
  let seed := positional[1]?.bind String.toNat? |>.getD 20261011
  pure (if ← Oracle.run count seed (args.contains "--old-rule")
    (args.contains "--generator-version=1") (args.contains "--old-escape-rule") then 0 else 1)
