import Ownership.Fixtures
import Ownership.BridgeWire

/-! File protocol for the external, black-box compiler differential. It exports
    the existing program streams, never a separately generated lookalike. -/
namespace Ownership.Bridge

def quote (s : String) : String := "\"" ++ String.join (s.toList.map fun c =>
  if c == '"' then "\\\"" else if c == '\\' then "\\\\"
  else if c == '\n' then "\\n" else if c == '\r' then "\\r"
  else if c == '\t' then "\\t" else if c.toNat < 32 then "?" else String.singleton c) ++ "\""

def arr (xs : List String) := "[" ++ String.intercalate "," xs ++ "]"
def node (tag : String) (xs : List String := []) := arr (quote tag :: xs)

def ty : Ty → String
  | .int => node "int"
  | .result e a => node "result" [ty e, ty a]
  | .chain t => node "chain" [ty t]
  | .list t => node "list" [ty t]
  | .builder t => node "builder" [ty t]
  | .record ts => node "record" [arr (ts.attach.map fun t => ty t.val)]
  | .fn ps r => node "fn" [arr (ps.attach.map fun t => ty t.val), ty r]
termination_by t => sizeOf t
decreasing_by
  all_goals simp_wf
  all_goals try have h := List.sizeOf_lt_of_mem t.property
  all_goals simp_all +arith
  all_goals omega

def atom : Atom → String
  | .int n => node "int" [quote (toString n)]
  | .var n => node "var" [toString n]
  | .field a n => node "field" [atom a, toString n]

def prim : Prim → String
  | .ok e => node "ok" [ty e]
  | .err a => node "err" [ty a]
  | .endChain t => node "end-chain" [ty t]
  | .link => node "link"
  | .privateRoot => node "private-root"
  | .literal t => node "literal" [ty t]
  | .builder t => node "builder" [ty t]
  | .owned f => node "owned" [toString f]
  | .add => node "add" | .sub => node "sub" | .eq => node "eq" | .lt => node "lt"
  | .record => node "record" | .length => node "length" | .at => node "at"
  | .set => node "set" | .push => node "push" | .copy => node "copy"
  | .prepend => node "prepend" | .events => node "events" | .shared => node "shared"
  | .put => node "put" | .close => node "close"

def expr : Expr → String
  | .atom a => node "atom" [atom a]
  | .letE n a b => node "let" [toString n, expr a, expr b]
  | .prim p xs => node "prim" [prim p, arr (xs.map atom)]
  | .closure n xs => node "closure" [toString n, arr (xs.map atom)]
  | .app f xs => node "app" [atom f, arr (xs.map atom)]
  | .recur xs => node "recur" [arr (xs.map atom)]
  | .entry initial retained model body => node "entry" [expr initial, arr (retained.map atom), toString model, expr body]
  | .resultCase input e a left right => node "result-case" [atom input, toString e, toString a, expr left, expr right]
  | .chainCase input h t left right => node "chain-case" [atom input, toString h, toString t, expr left, expr right]
  | .branch c a b => node "branch" [atom c, expr a, expr b]
  | .focus a i x b => node "focus" [atom a, atom i, toString x, expr b]
  | .traverse k a z i x acc b => node "traverse"
      [quote (match k with | .list => "list" | .range => "range" | .model => "model"),
       atom a, atom z, toString i, toString x, toString acc, expr b]

def intrinsic (d : Decl) : String :=
  match d.parameters, d.result with
  | [.list a, .fn [_] b], .list _ =>
    if d.body == (Library.map a b).body then (if a == b then "identity-map" else "map") else ""
  | [.int, .fn [_] a], .list _ => if d.body == (Library.«initialize» a).body then "initialize" else ""
  | [.list a, b, .fn [_, _] _], _ => if d.body == (Library.foldl a b).body then "foldl" else ""
  | [.list a, .int, .fn [_] _], .list _ => if d.body == (Library.update a).body then "update" else ""
  | _, _ => ""

def decl (d : Decl) := arr [quote d.name, arr (d.parameters.map ty),
  arr (d.captures.map ty), ty d.result, expr d.body, quote (intrinsic d)]

def observation : Observation → String
  | .int n => toString n
  | .record fs => "{" ++ String.intercalate "," (fs.attach.zipIdx.map fun (x, i) =>
      quote s!"f{i}" ++ ":" ++ observation x.val) ++ "}"
  | .list xs => arr (xs.attach.map fun x => observation x.val)
  | .closure _ _ => quote "<function>"
termination_by o => sizeOf o
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals omega

def maxAtom : Atom → Nat
  | .int _ => 0 | .var n => n | .field a _ => maxAtom a

def maxVar : Expr → Nat
  | .atom a => maxAtom a
  | .letE n a b => max n (max (maxVar a) (maxVar b))
  | .prim _ xs | .closure _ xs | .recur xs => (xs.map maxAtom).foldl max 0
  | .app f xs => max (maxAtom f) ((xs.map maxAtom).foldl max 0)
  | .entry initial retained model body => max model (max (maxVar initial) (max (maxVar body) ((retained.map maxAtom).foldl max 0)))
  | .resultCase input e a left right | .chainCase input e a left right =>
    [maxAtom input, e, a, maxVar left, maxVar right].foldl max 0
  | .branch c a b => max (maxAtom c) (max (maxVar a) (maxVar b))
  | .focus a i x b => max x (max (maxAtom a) (max (maxAtom i) (maxVar b)))
  | .traverse _ a z i x acc b =>
    [maxAtom a, maxAtom z, i, x, acc, maxVar b].foldl max 0

/-- Add a value-interpreter read after arithmetic, including discarded results.
    These fresh binders never enter either ownership checker or emitted source. -/
def auditArithmetic (fresh : Nat) : Expr → Expr
  | .prim op xs =>
    if op == .add || op == .sub then
      .letE fresh (.prim op xs) <|
        .letE (fresh+1) (.prim (.literal .int) [.var fresh]) <|
          .prim .at [.var (fresh+1), .int 0, .int 0]
    else .prim op xs
  | .letE n a b => .letE n (auditArithmetic fresh a) (auditArithmetic fresh b)
  | .entry initial retained model body => .entry (auditArithmetic fresh initial) retained model (auditArithmetic fresh body)
  | .resultCase input e a left right => .resultCase input e a (auditArithmetic fresh left) (auditArithmetic fresh right)
  | .chainCase input h t left right => .chainCase input h t (auditArithmetic fresh left) (auditArithmetic fresh right)
  | .branch c a b => .branch c (auditArithmetic fresh a) (auditArithmetic fresh b)
  | .focus a i x b => .focus a i x (auditArithmetic fresh b)
  | .traverse k a z i x acc b => .traverse k a z i x acc (auditArithmetic fresh b)
  | e => e

def exactObservation : Observation → Bool
  | .int n => n.natAbs ≤ 9007199254740991
  | .record xs | .list xs | .closure _ xs => xs.attach.all fun x => exactObservation x.val
termination_by o => sizeOf o
decreasing_by
  all_goals simp_wf
  all_goals have := List.sizeOf_lt_of_mem x.property
  all_goals omega

def numericAudit (p : Program) (fuel := 100000) : String := Id.run do
  let fresh := 1 + (p.declarations.map fun d =>
    max (d.parameters.length + d.captures.length) (maxVar d.body)).foldl max (maxVar p.main)
  let q := { p with
    main := auditArithmetic fresh p.main
    declarations := p.declarations.map fun d => { d with body := auditArithmetic fresh d.body } }
  match ValueSemantics.run q fuel with
  | .error _ => return "numeric-audit-execution-limit"
  | .ok t => return if (t.finalValue :: t.reads).all exactObservation then "" else "integer-out-of-range"

#guard numericAudit { main := .prim .add [.int 9007199254740991, .int 1] } == "integer-out-of-range"
#guard numericAudit { main := .letE 0 (.prim .add [.int 9007199254740991, .int 1]) (.atom (.int 0)) } == "integer-out-of-range"
#guard numericAudit { main := .prim .sub [.int 4, .int 1] } == ""
#guard match BridgeWire.program (arr [arr (Generator.decls.map decl), expr (Fixtures.retained false).main]) with
  | .ok q => q == { (Fixtures.retained false) with declarations := Generator.decls }
  | .error _ => false

/-- The reported trace may annotate an error, but cannot change its verdict or
    underlying message. Every exported program checks this invariant. -/
def verdict (p : Program) : Except String (Bool × List String × String × String) := do
  let plain := check p
  match check p { bridgeTrace := true }, plain with
  | .ok a, .ok _ => pure (true, a.bridgeSites, "", "")
  | .error trace, .error error =>
    let pieces := trace.splitOn "\n"
    if pieces.head? == some "BRIDGE" then
      let original := String.intercalate "\n" (pieces.drop 3)
      if original != error then throw "bridge instrumentation changed rejection"
      pure (false, (pieces[2]?.getD "").splitOn "," |>.filter (!·.isEmpty), pieces[1]?.getD "", error)
    else if trace == error then pure (false, [], "", error)
    else throw "bridge instrumentation changed rejection"
  | _, _ => throw "bridge instrumentation changed verdict"

def writeRecord (out : IO.FS.Handle) (family id : String) (table : Nat) (p : Program)
    (fuel := 100000) : IO Unit := do
  let (ok, sites, failed, reason) ← match verdict p with
    | .ok v => pure v
    | .error e => throw (IO.userError s!"{id}: {e}")
  out.putStrLn (arr [quote "program", quote family, quote id, toString table,
    expr p.main, toString ok, arr (sites.map quote), quote failed, quote reason,
    quote "runtime checked externally", quote (reprStr p.main),
    (match ValueSemantics.run p fuel with | .ok t => observation t.finalValue | .error _ => "null"),
    (match typecheck p with | .ok t => ty t | .error _ => node "invalid"), quote (numericAudit p fuel)])

/-- `suite` selects an existing stream. The enumerator uses exactly CI's walk
    and prelude, including all final observations, in deterministic order. -/
def writeExport (path suite : String) (count seed bound : Nat) : IO Unit := do
  let out ← IO.FS.Handle.mk path .write
  let tables ← IO.mkRef ({} : Std.HashMap String Nat)
  let total ← IO.mkRef 0
  let emit := fun (family id : String) (p : Program) => do
    let ds := arr (p.declarations.map decl)
    let table ← match (← tables.get)[ds]? with
      | some n => pure n
      | none => do
        let n := (← tables.get).size
        tables.modify (·.insert ds n)
        out.putStrLn (arr [quote "table", toString n, ds])
        pure n
    writeRecord out family id table p
    total.modify (· + 1)
  if suite == "fixtures" then
    for (f, i) in Fixtures.all.zipIdx do emit "fixture" s!"fixture-{i}" f.program
    for ((_, p, _), i) in Sync.fixtures.zipIdx do emit "sync" s!"sync-{i}" p
    for (p, i) in Targeted.programs.zipIdx do emit "targeted" s!"targeted-{i}" p
  else if suite == "generator" then
    let mut state := seed
    for i in List.range count do
      let ((family, p), next) := (Oracle.generateVersion 5).run state
      state := next
      emit family s!"seed-{seed}-{i}" p
  else if suite == "enumerate" then
    let index ← IO.mkRef 0
    let _ ← Enumerate.walk bound Enumerate.preludeEnv [] Enumerate.preludeSize Enumerate.prelude fun main => do
      let i ← index.modifyGet fun n => (n, n+1)
      emit "enumerate" s!"enum-{bound}-{i}" { declarations := Generator.decls, main }
      pure true
  else throw (IO.userError s!"unknown bridge suite {suite}")
  out.flush
  IO.println s!"bridge-export suite={suite} count={← total.get} file={path}"

/-- One-step, type-preserving reductions. The external runner chooses only
    reductions preserving the verdict difference and concrete outcome. -/
def references : Expr → List Nat
  | .closure d _ => [d]
  | .letE _ a b | .branch _ a b => references a ++ references b
  | .focus _ _ _ b | .traverse _ _ _ _ _ _ b => references b
  | _ => []

def reachable (p : Program) : List Nat := Id.run do
  let mut ids := references p.main
  for _ in List.range p.declarations.length do
    ids := (ids ++ ids.flatMap fun i => (p.declarations[i]?.map fun d => references d.body).getD []).eraseDups
  return ids

def reduceFile (input output : String) : IO Unit := do
  let p ← match BridgeWire.program (← IO.FS.readFile input) with
    | .ok p => pure p | .error e => throw (IO.userError e)
  let out ← IO.FS.Handle.mk output .write
  let mains := (Oracle.reductions p.main).map fun main => { p with main }
  let ids := reachable p
  let bodies := p.declarations.zipIdx.flatMap fun (d, i) =>
    (if ids.contains i then Oracle.reductions d.body else []).map fun body =>
      { p with declarations := p.declarations.set i { d with body } }
  for (candidate, i) in (mains ++ bodies).zipIdx do
    if (typecheck candidate).isOk then
      out.putStrLn (arr [quote "table", toString i, arr (candidate.declarations.map decl)])
      -- Removing a base case may diverge; use the oracle shrinker's smaller
      -- execution budget rather than overflowing the native stack at 100k.
      writeRecord out "reduction" s!"candidate-{i}" i candidate 5000
  out.flush

end Ownership.Bridge
