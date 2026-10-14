// Source-level checker mutants for the ownership oracle.
//
// Each entry deletes or weakens one rule of Ownership/Checker.lean by a textual
// edit. The first nineteen are the read-only review's mutants (2026-10-11),
// re-anchored to the summary-layer checker; the rest weaken a row of the
// summary layer. A mutant is caught when the unmodified generator finds an
// accepted disagreement in a normal run (see run-mutants.sh). Usage:
//   node scripts/mutate.mjs <mutant> <project-dir>
//   node scripts/mutate.mjs --list
import fs from "node:fs";

export const mutants = {
  // The review's seven missed mutants, also `--mutant=` flags.
  disjoint: ["Checker.lean", '  else if !cfg.has .disjoint && cellOverlap cs others then some "Disjoint: another operand path holds the written cell"\n', ""],
  borrowedsupply: ["Checker.lean", "union roots (if consumes || ctx.config.has .borrowedSupply then later\n            else union later rawElement.cells)", "union roots later"],
  travexcl: ["Checker.lean", "              if !ctx.config.has .traversalExclusive then\n                requireExclusive input later (capValues.flatMap Abstract.cells)\n", ""],
  manycap: ["Checker.lean", 'throw "many calls: traversal step consumes a capture or once closure"', "pure ()"],
  copyexcl: ["Checker.lean", "pure (.list [fresh] elem (ctx.config.has .copyExclusive))", "pure (.list [fresh] elem true)"],
  closesrc: ["Checker.lean", "else pure (.list (union cs ds) (elem.join old) ex)", "else pure (.list cs elem ex)"],
  keepsshape: ["Checker.lean", "(ex && (ctx.config.has .keepsShape || keepsShape s.result))", "ex"],
  // The review's other twelve.
  xres: ["Checker.lean", "  let recursivePremise := values.all Abstract.deepExclusive ||", "  let recursivePremise := true ||"],
  separated: ["Checker.lean", "  recursivePremise && separatedValues values && values.all", "  recursivePremise && values.all"],
  dead: ["Checker.lean", '  else if cellOverlap cs later then some "Dead: an old holder is live after the demand"\n', ""],
  escape: ["Checker.lean", '  else if cellOverlap (cs.map Origin.base) (escapes.map Origin.base) then some "Unescaped: program-lifetime holder"\n', ""],
  focusexcl: ["Checker.lean", "      if consumes then requireExclusive input later (capValues.flatMap Abstract.cells)\n", ""],
  once: ["Checker.lean", "        demand ctx.config once later (actuals.flatMap Abstract.cells)\n", ""],
  nestedsep: ["Checker.lean", "    if !ex || !elem.deepExclusive || !separatedPaths elem.paths then", "    if !ex || !elem.deepExclusive then"],
  reqexcloutside: ["Checker.lean", '    else if cellOverlap elem.cells (union later other) then\n      some "exclusive contents: outside live holder"\n', ""],
  recvalidate: ["Checker.lean", '    if candidate.join (normalized { facts with result }) != candidate then throw "summary validation failed"\n', ""],
  writeout: ["Checker.lean", "    let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)", "    let exclusive := ex"],
  tsupplyexcl: ["Checker.lean", "          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))\n        else rawElement", "          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))\n        else rawElement.grantExclusive"],
  escapeowned: ["Checker.lean", "  !cellOverlap (cs.map Origin.base) (ctx.escaped.map Origin.base) &&\n", ""],
  // Rows of the summary layer; the first five are also `--mutant=` flags.
  guardreuse: ["Checker.lean", "        if !parent.config.has .guardReuse then", "        if false then"],
  callbackxres: ["Checker.lean", "      if ctx.config.has .callbackXres || !(← ask f ctx (query (.xres q))).isEmpty then", "      if true then"],
  supplyedge: ["Checker.lean", "          if k < sp.args.length && !sp.owned.contains (k, p) && !ctx.config.has .supplyEdge then", "          if false then"],
  supplyrecheck: ["Checker.lean", "    if ctx.config.has .supplyRecheck then { sp with args := inst, env }", "    if true then { sp with args := inst, env }"],
  callsedge: ["Checker.lean", "        if count ≥ 2 && !roots.isEmpty && !ctx.config.has .callsEdge then", "        if false then"],
  requiresedge: ["Checker.lean", "          if k < sp.args.length && !sp.exclusive.contains (k, p) && !ctx.config.has .requiresEdge then", "          if false then"],
  callbackwrites: ["Checker.lean", "          modifyFacts fun s => { s with consumes := union s.consumes (cs.filter external) }", "          pure ()"],
  callbackescapes: ["Checker.lean", "          modifyFacts fun s => { s with escapes := union s.escapes cs }", "          pure ()"],
  callbackaliases: ["Checker.lean", "            cs := union cs ((args[k]?.getD .bottom).cellsAt p)", "            cs := cs"],
  callbackenv: ["Checker.lean", "      if !(← ask f ctx (query (.env q))).isEmpty && !ctx.config.has .callbackEnv then cs := union cs envCells\n", ""],
  callbackrequires: ["Checker.lean", "          modifyFacts fun s => { s with requiresExclusive := union s.requiresExclusive ((a.atPath p).roots.filter external) }", "          pure ()"],
  forwardguards: ["Checker.lean", "          let _ ← ask f ctx { g.query with slot := j }", "          pure ()"],
  transfersupplies: ["Checker.lean", "          modifyFacts fun facts => { facts with supplies := union facts.supplies [{ sp with slot := j }] }", "          pure ()"],
  // A once callback called by a callee is consumed at the call (also `--mutant=once-through-call`).
  oncethroughcall: ["Checker.lean", "        if count ≥ 1 && !roots.isEmpty && !ctx.config.has .onceThroughCall then", "        if false then"],
  // The second review's nine planted holes (2026-10-12).
  // A closure's captured cells are not live through the closure binding.
  capturelive: ["Domain.lean", "if isPrefix p q || isPrefix q p then union cs ds else cs",
    "if (isPrefix p q || isPrefix q p) && !(match q with | .capture _ :: _ => true | _ => false) then union cs ds else cs"],
  // copy's elements are treated as fresh cells aliasing nothing.
  copyelems: ["Checker.lean", "pure (.list [fresh] elem (ctx.config.has .copyExclusive))",
    "pure (.list [fresh] (elem.mapOrigins fun _ cs => if cs.isEmpty then [] else [Origin.site site 1]) (ctx.config.has .copyExclusive))"],
  // Builder put always stores exclusively (T59's per-element certificate dropped for put only).
  putexcl: ["Checker.lean", "let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)",
    "let exclusive := ex && (op == .put || storeExclusive ctx [v] later elem.cells (op == .put))"],
  // A recursive call's writes are ignored at the call.
  recwrites: ["Checker.lean", "applyCall ctx ctx.recursiveSummary site actuals ctx.recursiveCaptures later",
    "applyCall ctx { ctx.recursiveSummary with writes := [], consumes := [] } site actuals ctx.recursiveCaptures later"],
  // recwrites is masked by the entry-ownership rule of a recursive call (a
  // recursive write to an entry-owned path needs that path owned again, i.e.
  // the same Known/Unescaped/Dead/Disjoint test; COVERAGE.md). With both
  // removed, a recursive call's writes go unchecked: shows the generator
  // reaches the shape.
  recwritesown: [
    ["Checker.lean", "applyCall ctx ctx.recursiveSummary site actuals ctx.recursiveCaptures later",
      "applyCall ctx { ctx.recursiveSummary with writes := [], consumes := [] } site actuals ctx.recursiveCaptures later"],
    ["Checker.lean", 'throw "recursive call does not preserve entry ownership assumptions"', "pure ()"]],
  // keeps-shape accepts any parameter path.
  keepsany: ["Checker.lean", "      | .parameter i q => i == parameter && p == q", "      | .parameter _ _ => true"],
  // A callback's own environment is not another operand of its arguments.
  symenv: ["Checker.lean", "let others := fun (k : Nat) => union envCells (args.zipIdx.flatMap",
    "let others := fun (k : Nat) => union [] (args.zipIdx.flatMap"],
  // Liveness ignores a conditional's nonzero arm (also `--mutant=branch-live`).
  branchlive: ["Domain.lean", "    let ub := if nonzero then usesArms nonzero armClosures b else []",
    "    let ub : Live := []"],
  // Liveness ignores the captures of closures a conditional arm creates (also `--mutant=branch-closure`).
  branchclosure: ["Checker.lean", "usesArms (!cfg.has .branchLive) (!cfg.has .branchClosure) e", "usesArms (!cfg.has .branchLive) false e"],
  // `shared` escapes only its operand's spine (also `--mutant=shared-roots`).
  sharedroots: ["Checker.lean", "let escaped := if ctx.config.has .sharedRoots then a.roots", "let escaped := if true then a.roots"],
  // The fourth review's holes. `shared` forgets cells under a closure held in
  // a record field (also `--mutant=shared-fn`).
  sharedfn: ["Checker.lean", "      else if ctx.config.has .sharedFn then", "      else if true then"],
  // A traversal step's single call of a callback counts as one (also `--mutant=many-off`).
  manyoff: ["Checker.lean", "(j, if many && n > (if ctx.config.has .manyOff then 1 else 0) then 2 else n)",
    "(j, if many && n > 1 then 2 else n)"],
  // An unbound live variable is read as dead (also `--mutant=no-scope`).
  noscope: ["Checker.lean", "    if !ctx.config.has .noScope then liveScope env after", "    pure ()"],
  // Joining an exclusive list with a non-exclusive one stays exclusive.
  joinexcl: ["Domain.lean", "| .list cs x ex, .list ds y ey => .list (union cs ds) (x.join y) (ex && ey)",
    "| .list cs x ex, .list ds y ey => .list (union cs ds) (x.join y) (ex || ey)"],
  // The third review's other holes, re-anchored to the current sources.
  // A call's result forgets the provenance of its second parameter.
  resprov: ["Checker.lean", "  pure (instantiateValue site args caps true s.result)\ntermination_by (0, 1)",
    "  pure (instantiateValue site args caps true (s.result.mapOrigins fun _ cs => cs.filter fun c => match c with | .parameter 1 _ => false | _ => true))\ntermination_by (0, 1)"],
  // A call does not demand the writes its summary makes to its second parameter.
  argrecheck2: ["Checker.lean", "    (later : List Origin) : CheckM Abstract := do\n  for w in s.writes ++ s.consumes do\n    demand ctx.config",
    "    (later : List Origin) : CheckM Abstract := do\n  for w in s.writes ++ s.consumes do\n    if (match w with | .parameter 1 _ => true | _ => false) then continue\n    demand ctx.config"],
  // A push keeps its list exclusive whatever it stores.
  pushexcl: ["Checker.lean", "    let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)",
    "    let exclusive := if op == .push then ex else ex && storeExclusive ctx [v] later elem.cells (op == .put)"],
  // Undo the once-through-call fixes: both demands (nofix1, as oncethroughcall),
  // or only the written-captures demand (nofix2).
  nofix2: ["Checker.lean", "      if let .capture .. := w then\n        demand ctx.config (instantiateOrigin site [] caps w)",
    "      if let .capture .. := w then\n        if false then demand ctx.config (instantiateOrigin site [] caps w)"],
  // An interpreter hole: the in-place interpreter copies where it should
  // write (it allocates a new array for every set, push and focus write-back).
  hiddencopy: ["Semantics.lean", "  if !(old == xs) then countWrite\n  write c xs", "  if !(old == xs) then countWrite\n  alloc xs"],
  // focus drops the demand on its container.
  focuscontainer: ["Checker.lean", "      demand ctx.config cs later (capValues.flatMap Abstract.cells)\n      let out",
    "      let out"],
  // An indexed read's result forgets the element cells.
  atelem: ["Checker.lean", "pure (elem.join fallback)", "pure (fallback.join (elem.mapOrigins fun _ _ => []))"],
  // The third review's shadowing hole disables both layers together.
  shadowing: [
    ["Checker.lean", "  let _ ← (if config.has .shadowing then typesOf p else typecheck p)",
      "  let _ ← typesOf p"],
    ["Checker.lean", "      if ctx.config.has .shadowing || outer.isEmpty then",
      "      if true then"]],
  // The fifth review's holes. A `set` keeps its list exclusive whatever it
  // stores (also `--mutant=set-exclusive`).
  setexcl: ["Checker.lean", "    let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)",
    "    let exclusive := if op == .set then ex else ex && storeExclusive ctx [v] later elem.cells (op == .put)"],
  // Liveness drops the capture paths of once closures (also `--mutant=once-live`).
  oncelive: ["Domain.lean", "    | some a => a.paths.foldl (fun cs (q, ds) =>",
    "    | some a => (a.paths.filter fun (q, _) => a.roots.isEmpty || !(match q with | .capture _ :: _ => true | _ => false)).foldl (fun cs (q, ds) =>"],
  // A function input's environment instantiates to nothing at a call.
  envinst: ["Checker.lean", "  | .parameter i (.env :: _) => (args[i]?.getD .bottom).envCells", "  | .parameter i (.env :: _) => []"],
  // keeps-shape forgets that the result's paths must stay separated.
  keepsep: ["Checker.lean", "  a.deepExclusive && separatedPaths a.paths && a.paths.all fun (p, cs) =>", "  a.deepExclusive && a.paths.all fun (p, cs) =>"],
  // An owned input path ignores the other input paths that hold its cells.
  ownedothers: ["Checker.lean", "      if individuallyOwned ctx cs && !cellOverlap cs (union later others) then",
    "      if individuallyOwned ctx cs && !cellOverlap cs later then"],
  // The join of two shapes forgets both sides' cells (the defect the fifth
  // review's P6 exposed, fixed in Domain.lean).
  joindrops: [
    ["Domain.lean", "else .list (union [.unknown] (union a.cells b.cells)) .bottom false", "else .list [.unknown] .bottom false"],
    ["Domain.lean", "  | _, _ => .list (union [.unknown] (union a.cells b.cells)) .bottom false", "  | _, _ => .list [.unknown] .bottom false"]],
  capturerecurse: ["Checker.lean", "        for (child, nested) in alts do\n          demandCallbackCaptures f ctx child nested site later", "        pure ()"],
  joinright: [
    ["Domain.lean", "else .list (union [.unknown] (union a.cells b.cells)) .bottom false", "else .list (union [.unknown] a.cells) .bottom false"],
    ["Domain.lean", "  | _, _ => .list (union [.unknown] (union a.cells b.cells)) .bottom false", "  | _, _ => .list (union [.unknown] a.cells) .bottom false"]],
  capturecount: ["Checker.lean", "if !ctx.config.has .callsEdge && count ≥ 2 then", "if !ctx.config.has .callsEdge && count ≥ 3 then"],
  captureconsume: ["Checker.lean", "    for w in cs.writes ++ cs.consumes do", "    for w in cs.writes do"],
};

export const aliases = { nofix1: "oncethroughcall" };

const [name, dir] = process.argv.slice(2);
if (name === "--list") {
  console.log(Object.keys(mutants).join(" "));
} else if (name === "--canonical") {
  const names = process.argv.slice(3).map(n => aliases[n] || n);
  for (const n of names) if (!mutants[n]) { console.error(`unknown mutant ${n}`); process.exit(2); }
  console.log([...new Set(names)].join(" "));
} else if (name) {
  const entry = mutants[aliases[name] || name];
  if (!entry) { console.error(`unknown mutant ${name}`); process.exit(2); }
  // An entry is one edit [file, from, to] or a list of edits.
  for (const [file, from, to] of Array.isArray(entry[0]) ? entry : [entry]) {
    const path = `${dir}/Ownership/${file}`;
    const source = fs.readFileSync(path, "utf8");
    const count = source.split(from).length - 1;
    if (count !== 1) { console.error(`${name}: pattern found ${count} times in ${file}`); process.exit(1); }
    fs.writeFileSync(path, source.replace(from, () => to));
  }
}
