import Ownership.Config

namespace Ownership.Cli

def modes := ["bridge-reduce", "bridge-export", "all", "oracle", "fixtures", "controls", "reasons", "ci", "summaries",
  "verdict-diff", "falsify", "accepted", "enumerate", "enumerate-targeted", "source-sweep"]

/-- Reject inputs that would otherwise silently select defaults or ignore work. -/
def validate (args : List String) : Except String (String × List String) := do
  let raw := args.head?.getD "all"
  let mode := if raw == "--generator-only" then "oracle" else raw
  unless modes.contains mode do throw s!"unknown command {raw}; commands: {modes}"
  let rest := args.drop 1
  let pos := rest.filter (!·.startsWith "--")
  let maxPos := if ["bridge-reduce", "fixtures", "summaries", "enumerate-targeted"].contains mode then 0 else if mode == "enumerate" then 1 else 2
  if pos.length > maxPos then throw s!"too many arguments for {mode}"
  for p in pos do unless p.toNat?.isSome do throw s!"invalid natural number {p}"
  if (pos[0]?.bind String.toNat?) == some 0 && !["source-sweep", "accepted", "enumerate"].contains mode then
    throw s!"{mode} requires a positive count or bound"
  let general := ["all", "oracle"].contains mode
  let booleans := if general then ["--reinfer", "--cross-check", "--old-rule", "--old-escape-rule"]
    else if ["controls", "verdict-diff"].contains mode then ["--reinfer"]
    else if mode == "enumerate" then ["--reinfer", "--old-rule", "--old-escape-rule", "--count-only"]
    else if mode == "enumerate-targeted" then ["--reinfer", "--old-rule", "--old-escape-rule"]
    else if mode == "ci" then ["--strict"] else []
  let values := (if general || ["controls", "ci", "accepted", "source-sweep", "verdict-diff", "reasons"].contains mode
    then ["generator-version"] else []) ++
    (if general || ["falsify", "enumerate", "enumerate-targeted", "verdict-diff"].contains mode then ["mutant"] else []) ++
    (if ["enumerate", "enumerate-targeted"].contains mode then ["accepted-out", "skip-accepted"] else []) ++
    (if mode == "ci" then ["enumerate-bound"] else []) ++
    (if mode == "bridge-reduce" then ["input", "out"] else []) ++
    (if mode == "bridge-export" then ["enumerate-bound", "out", "suite"] else []) ++
    (if mode == "source-sweep" then ["baseline-accepted"] else []) ++
    (if mode == "summaries" then ["fixture"] else []) ++
    (if mode == "reasons" then ["family"] else [])
  let mut seen : List String := []
  for flag in rest.filter (·.startsWith "--") do
    let key := (flag.splitOn "=").head!
    if seen.contains key then throw s!"duplicate option {key}"
    seen := key :: seen
    if booleans.contains flag then continue
    let some name := values.find? (fun n => flag.startsWith s!"--{n}=") |
      throw s!"unsupported option {flag} for {mode}"
    let value := (flag.drop (name.length + 3)).toString
    if value.isEmpty then throw s!"empty option {flag}"
    if name == "generator-version" && !["1", "3", "4", "5", "6"].contains value then
      throw s!"unsupported generator version {value}"
    if name == "enumerate-bound" && mode == "ci" then
      unless value.toNat?.any (· ≥ 2) do throw "CI enumeration bound must be at least 2"
    if name == "enumerate-bound" && mode == "bridge-export" && value.toNat?.isNone then
      throw "bridge enumeration bound must be a natural number"
    if name == "suite" && !["fixtures", "enumerate", "generator", "generator6"].contains value then
      throw s!"unknown bridge suite {value}"
  if mode == "verdict-diff" && !seen.contains "--mutant" then throw "verdict-diff needs --mutant="
  if mode == "source-sweep" && !seen.contains "--baseline-accepted" then throw "source-sweep needs --baseline-accepted="
  if rest.contains "--count-only" && rest.length != 1 + pos.length then
    throw "--count-only cannot be combined with checker or evidence options"
  return (mode, pos)

end Ownership.Cli
