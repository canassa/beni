// Source-level checker mutants for the ownership oracle.
//
// Each entry deletes or weakens one rule of Ownership/Checker.lean by a textual
// edit. The first nineteen are the read-only review's mutants (2026-10-11),
// re-anchored to the current source; the `summary-*` entries weaken a row of
// the summary layer. A mutant is caught when the unmodified generator finds an
// accepted disagreement in a normal run (see run-mutants.sh). Usage:
//   node scripts/mutate.mjs <mutant> <project-dir>
//   node scripts/mutate.mjs --list
import fs from "node:fs";

export const mutants = {
  // The seven negative controls also exposed as `--mutant=` flags.
  disjoint: ["Checker.lean", '  if !cfg.has .disjoint && cellOverlap cs others then throw "Disjoint: another operand path holds the written cell"\n', ""],
  borrowedsupply: ["Checker.lean", "union roots (if consumes || ctx.config.has .borrowedSupply then later\n            else union later rawElement.cells)", "union roots later"],
  travexcl: ["Checker.lean", "              if !ctx.config.has .traversalExclusive then\n                requireExclusive input later (capValues.flatMap Abstract.cells)\n", ""],
  manycap: ["Checker.lean", 'throw "many calls: traversal step consumes a capture or once closure"', "pure ()"],
  copyexcl: ["Checker.lean", "pure (.list [fresh] elem (ctx.config.has .copyExclusive))", "pure (.list [fresh] elem true)"],
  closesrc: ["Checker.lean", "else pure (.list (union cs ds) (elem.join old) ex)", "else pure (.list cs elem ex)"],
  keepsshape: ["Checker.lean", "(ex && (ctx.config.has .keepsShape || keepsShape s.result))", "ex"],
  // The review's other mutants.
  xres: ["Checker.lean", "  let recursivePremise := values.all Abstract.deepExclusive ||", "  let recursivePremise := true ||"],
  separated: ["Checker.lean", "  recursivePremise && separatedValues values && values.all", "  recursivePremise && values.all"],
  dead: ["Checker.lean", '  if cellOverlap cs later then throw "Dead: an old holder is live after the demand"\n', ""],
  escape: ["Checker.lean", '  if cellOverlap (cs.map Origin.base) ((← get).escapes.map Origin.base) then throw "Unescaped: program-lifetime holder"\n', ""],
  focusexcl: ["Checker.lean", "      if consumes then requireExclusive input later (caps.flatMap (fun (_, a) => a.cells))\n", ""],
  once: ["Checker.lean", "      demand ctx.config once later (actuals.flatMap Abstract.cells)\n", ""],
  nestedsep: ["Checker.lean", "  if !ex || !elem.deepExclusive || !separatedPaths elem.paths then", "  if !ex || !elem.deepExclusive then"],
  reqexcloutside: ["Checker.lean", '  if cellOverlap elem.cells (union later other) then\n    throw "exclusive contents: outside live holder"\n', ""],
  recvalidate: ["Checker.lean", '    if candidate.join (normalized { facts with result }) != candidate then throw "summary validation failed"\n', ""],
  writeout: ["Checker.lean", "    let exclusive := ex && storeExclusive ctx [v] later elem.cells (op == .put)", "    let exclusive := ex"],
  tsupplyexcl: ["Checker.lean", "          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))\n        else rawElement", "          (rawElement.grantExclusive).mapOrigins (fun _ cs => cs.map (.position site true))\n        else rawElement.grantExclusive"],
  escapeowned: ["Checker.lean", "  !cellOverlap (cs.map Origin.base) (ctx.escaped.map Origin.base) &&\n", ""],
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
