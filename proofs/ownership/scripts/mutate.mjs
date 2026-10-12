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
  requiresedge: ["Checker.lean", "          if k < sp.args.length && !sp.exclusive.contains (k, p) then", "          if false then"],
  callbackwrites: ["Checker.lean", "          modifyFacts fun s => { s with consumes := union s.consumes (cs.filter external) }", "          pure ()"],
  callbackescapes: ["Checker.lean", "          modifyFacts fun s => { s with escapes := union s.escapes cs }", "          pure ()"],
  callbackaliases: ["Checker.lean", "            cs := union cs ((args[k]?.getD .bottom).cellsAt p)", "            cs := cs"],
  callbackenv: ["Checker.lean", "      if !(← ask f ctx (query (.env q))).isEmpty then cs := union cs envCells\n", ""],
  callbackrequires: ["Checker.lean", "          modifyFacts fun s => { s with requiresExclusive := union s.requiresExclusive ((a.atPath p).roots.filter external) }", "          pure ()"],
  forwardguards: ["Checker.lean", "        let _ ← ask f ctx { g.query with slot := j }", "        pure ()"],
  transfersupplies: ["Checker.lean", "        modifyFacts fun facts => { facts with supplies := union facts.supplies [{ sp with slot := j }] }", "        pure ()"],
};

const [name, dir] = process.argv.slice(2);
if (name === "--list") {
  console.log(Object.keys(mutants).join(" "));
} else if (name) {
  const entry = mutants[name];
  if (!entry) { console.error(`unknown mutant ${name}`); process.exit(2); }
  const [file, from, to] = entry;
  const path = `${dir}/Ownership/${file}`;
  const source = fs.readFileSync(path, "utf8");
  const count = source.split(from).length - 1;
  if (count !== 1) { console.error(`${name}: pattern found ${count} times in ${file}`); process.exit(1); }
  fs.writeFileSync(path, source.replace(from, () => to));
}
