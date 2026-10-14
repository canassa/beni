import Ownership.Checker

/-! Printing published summaries in a notation close to the thesis's bracket
    rows (§3.7): `use` per parameter path (R read, A in the result, E escaped,
    W written or consumed through a supply), `res` and `xres` per result path,
    `xreq`, and per function-typed input its `calls` and supplies. The guards
    a summary was computed under are listed as the class facts they asked. -/

namespace Ownership.Report

def stepS : Step → String
  | .field i => s!".{i}" | .element => "[*]" | .capture i => s!".env{i}" | .env => ".env"

def pathS (p : Path) : String := String.join (p.map stepS)

partial def originS : Origin → String
  | .parameter i p => s!"π{i}{pathS p}"
  | .capture i p => s!"◇{i}{pathS p}"
  | .site s i => s!"site{s}#{i}"
  | .fresh i => s!"fresh{i}"
  | .position _ cur o => s!"{if cur then "cur" else "prev"}({originS o})"
  | .shared => "shared"
  | .unknown => "⊤"

def originsS (cs : List Origin) : String :=
  "{" ++ ", ".intercalate (cs.map originS) ++ "}"

def resultRows (a : Abstract) : List String :=
  a.paths.map fun (p, cs) =>
    let ex := match a.atPath p with
      | .list _ _ ex => if ex.deep then " excl" else if ex.spine then " spine" else ""
      | _ => ""
    s!"res {if p.isEmpty then "ε" else pathS p} = {originsS cs}{ex}"

def factS : Fact → String
  | .spine q => s!"spine({pathS q})"
  | .requiresSpine k p => s!"spine(π{k}{pathS p})"
  | .writes k p => s!"W∈use(π{k}{pathS p})"
  | .escapes k p => s!"E∈use(π{k}{pathS p})"
  | .requires k p => s!"xreq(π{k}{pathS p})"
  | .aliases k p q => s!"π{k}{pathS p}∈res({pathS q})"
  | .env q => s!"env∈res({pathS q})"
  | .fresh q => s!"fresh∈res({pathS q})"
  | .shared q => s!"shared∈res({pathS q})"
  | .top q => s!"⊤∈res({pathS q})"
  | .xres q => s!"xres({pathS q})"
  | .escapesEnv => "E∈use(env)"
  | .once => "once"

/-- The use bits of every parameter or capture path the summary mentions. -/
def useRows (s : Summary) : List String :=
  let mentioned := (s.reads ++ s.writes ++ s.consumes ++ s.escapes ++ s.result.cells).filter fun c =>
    match c with | .parameter .. | .capture .. => true | _ => false
  let paths := mentioned.foldl (fun xs x => union xs [x]) []
  paths.map fun c =>
    let bit := fun (b : Bool) (n : String) => if b then n else ""
    let bits := bit (s.reads.contains c) "R" ++ bit (s.result.cells.contains c) "A" ++
      bit (s.escapes.contains c) "E" ++ bit ((s.writes ++ s.consumes).contains c) "W"
    s!"use {originS c} = {if bits.isEmpty then "unused" else bits}"

def callsS (n : Nat) : String := match n with | 0 => "0" | 1 => "≤1" | _ => "many"

def supplyS (sp : Supply) : String :=
  let args := sp.args.zipIdx.map fun (a, k) =>
    let owned := sp.owned.filter (·.1 == k) |>.map (fun (_, p) => if p.isEmpty then "ε" else pathS p)
    let excl := sp.exclusive.filter (·.1 == k) |>.map (fun (_, p) => if p.isEmpty then "ε" else pathS p)
    let spine := sp.spine.filter (·.1 == k) |>.map (fun (_, p) => if p.isEmpty then "ε" else pathS p)
    s!"arg{k} = {originsS a.cells} owned at {owned} excl at {excl} spine at {spine}"
  s!"supply to slot {sp.slot}: " ++ "; ".intercalate args

def summaryLines (s : Summary) : List String :=
  useRows s ++ resultRows s.result ++
  (if s.requiresExclusive.isEmpty then [] else [s!"xreq {originsS s.requiresExclusive}"]) ++
  (if s.requiresSpine.isEmpty then [] else [s!"spine-req {originsS s.requiresSpine}"]) ++
  s.calls.map (fun (j, n) => s!"calls slot {j} = {callsS n}") ++
  s.supplies.map supplyS ++
  [s!"guards ({s.guards.length}): " ++ ", ".intercalate (s.guards.map fun g =>
      s!"slot{g.query.slot}:{factS g.query.fact}={g.answer}")]

def entryS (decls : List Decl) (e : CacheEntry) : String :=
  let name := (decls[e.decl]?.map (·.name)).getD "?"
  s!"summary of {name}\n" ++ "\n".intercalate ((summaryLines e.summary).map ("  " ++ ·))

end Ownership.Report
