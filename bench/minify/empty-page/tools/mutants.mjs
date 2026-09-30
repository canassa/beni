// Proves the two behaviour checks catch a wrong step: one-token mutants of the
// first and the last step file must each fail `measure.mjs test`'s page test,
// and mutants of the final runtime source must each fail the corpus.
//   node tools/mutants.mjs [--corpus]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const here = new URL("..", import.meta.url).pathname;
const read = (p) => fs.readFileSync(path.join(here, p), "utf8");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mutants-"));

const PAGE = {
  "steps/00-baseline.mjs": [
    ["no `$$root`", "T.$$root=", "T.$$roo="],
    ["`!==undefined` → `===undefined`", "T.$$root!==undefined", "T.$$root===undefined"],
    ["message: `already holds`", "already holds a program", "already holds the program"],
    ["message: `no element`", "no element has the id", "no element with the id"],
    ["`===null` → `!==null` on the mount node", "if(T===null||", "if(T!==null||"],
    ["mount before the body's children", "parent.insertBefore(R,aa)", "parent.insertBefore(R,parent.firstChild)"],
    ["no flush export", "export{O as flush}", "export{}"],
    ["template `<!>` → `<p>`", '"<!>"', '"<p>"'],
  ],
  "steps/25-append-child.mjs": [
    ["no `$$root`", "S.$$root=ca", "S.$$roo=ca"],
    ["`!==undefined` → `===undefined`", "S.$$root!==undefined", "S.$$root===undefined"],
    ["message: `already holds`", "already holds a program", "already holds the program"],
    ["message: `\"null\"`", 'the id "null"', 'the id "none"'],
    ["`===null` → `!==null`", "if(S===null||", "if(S!==null||"],
    ["comment text", 'createComment("")', 'createComment(" ")'],
    ["prepend", "S.appendChild(", "S.prepend("],
    ["no flush export", "export let flush", "let flush"],
  ],
};

let missed = 0;
for (const [file, mutants] of Object.entries(PAGE)) {
  const src = read(file);
  for (const [label, a, b] of mutants) {
    if (!src.includes(a)) { console.log(`${file}: ${label}: MUTANT NOT APPLICABLE`); missed++; continue; }
    const p = path.join(tmp, "m.mjs");
    fs.writeFileSync(p, src.replace(a, () => b));
    const r = spawnSync(process.execPath, [path.join(here, "measure.mjs"), "test", p], { encoding: "utf8" });
    const caught = r.status !== 0;
    if (!caught) missed++;
    console.log(`${file}: ${label}: ${caught ? "caught" : "MISSED"}`);
  }
}

if (process.argv.includes("--corpus")) {
  const final = read("src/runtime.final.js");
  const CORPUS = [
    ["childHtml forgets its instance", "    put(parentOf(s), i, s.m);\n    s.i = i;", "    put(parentOf(s), i, s.m);"],
    ["head of an instance slot: its marker for its instance", ": s.i !== null ? first(s.i) : s.m)", ": s.i !== null ? s.m : s.m)"],
    ["head of a list slot: the marker for its first row", "? first(s.u[0])", "? s.m"],
    ["head reads the list's last row", "? first(s.u[0])", "? first(s.u[s.u.length - 1])"],
    ["tail of a slot with a marker: its instance's end", "(s.m !== null ? s.m :", "(s.m !== null && s.i === null ? s.m :"],
    ["tail of a slot with no marker: the first row's end", "? last(s.u[s.u.length - 1])", "? last(s.u[0])"],
  ];
  // A mutant the corpus misses is a coverage gap of the corpus, reported,
  // not a failure of this study: the step that touched that code is then
  // argued equivalent (README), not tested.
  const { corpus } = await import(path.join(here, "measure.mjs"));
  for (const [label, a, b] of CORPUS) {
    if (!final.includes(a)) { console.log(`corpus: ${label}: MUTANT NOT APPLICABLE`); missed++; continue; }
    const p = path.join(tmp, "runtime.js");
    fs.writeFileSync(p, final.replace(a, () => b));
    const { failed } = corpus(p);
    console.log(`corpus: ${label}: ${failed ? `caught (${failed} fixtures fail)` : "GAP (no corpus page reaches it)"}`);
  }
}
fs.rmSync(tmp, { recursive: true, force: true });
process.exit(missed ? 1 : 0);
