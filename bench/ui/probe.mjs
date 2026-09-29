// A copy of a beni build whose runtime stamps `performance.now()` at the
// seams of a render — the flush, `view`, the keyed list's in-place pass,
// its main pass, its key-map sweep and the reconcile — into
// `window.__probe`, so `halves.mjs --probe` can say which part of the
// render the time is in. An instrument: the stamps cost a few
// microseconds, so compare probe builds with each other, never with the
// table.
//
//   node probe.mjs [--from=beni-dev] [--name=beni-probe]   (after build.mjs)
//
// Registers the copy in out/extra-subjects.json (never committed).

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const from = arg("from", "beni-dev");
const name = arg("name", "beni-probe");
const dir = new URL(`./out/${name}/`, import.meta.url);
rmSync(dir, { recursive: true, force: true });
cpSync(new URL(`./out/${from}/`, import.meta.url), dir, { recursive: true });

const f = new URL("_platform/_browser/runtime.foreign.mjs", dir);
let s = readFileSync(f, "utf8");
const edit = (a, b) => {
  if (!s.includes(a)) throw new Error(`probe: the runtime has no ${JSON.stringify(a)}`);
  s = s.replace(a, () => b);
};
const now = "globalThis.performance.now()";
edit("export const flush = () => {\n", `const P = (globalThis.__probe = {});\nexport const flush = () => {\n  P.flush = ${now};\n`);
edit("  for (const render of renders) render();\n", `  for (const render of renders) render();\n  P.end = ${now};\n`);
edit("    childHtml(s, program.view(model));\n  };", `    const v = program.view(model);\n    P.view = ${now};\n    childHtml(s, v);\n  };`);
// The keyed list's fast path: `inPlace` before 2026-09-30, `trimmed` after.
if (s.includes("    if (s.d && inPlace(s, items, keyOf, row, same)) {")) {
  edit("    if (s.d && inPlace(s, items, keyOf, row, same)) {", `    P.list = ${now};\n    const ip = s.d && inPlace(s, items, keyOf, row, same);\n    P.fast = ${now};\n    if (ip) {`);
} else {
  edit("    if (s.d && trimmed(s, items, keyOf, row, same)) {", `    P.list = ${now};\n    const ip = s.d && trimmed(s, items, keyOf, row, same);\n    P.fast = ${now};\n    if (ip) {`);
  edit("  if (p === m && at.$ !== 1) return true;\n", `  P.prefix = ${now};\n  if (p === m && at.$ !== 1) return true;\n`);
  edit("  // What is left: its keys looked up,", `  P.ends = ${now};\n  // What is left: its keys looked up,`);
  edit("  for (let b = p; b < n; b++) {\n    const item = xs[b - p];", `  P.middle = ${now};\n  for (let b = p; b < n; b++) {\n    const item = xs[b - p];`);
  edit("  for (let a = aStart; a < aEnd; a++) if (old[a].kv !== stamp)", `  P.rows = ${now};\n  for (let a = aStart; a < aEnd; a++) if (old[a].kv !== stamp)`);
  edit("  if (crossed || aStart < aEnd || bStart < bEnd) {", `  P.tsweep = ${now};\n  if (crossed || aStart < aEnd || bStart < bEnd) {`);
}
edit("    if (next.length !== old.length) moved = true;\n", `    P.pass = ${now};\n    if (next.length !== old.length) moved = true;\n`);
edit("    if (moved) {\n      const parent = parentOf(s);", `    P.sweep = ${now};\n    if (moved) {\n      const parent = parentOf(s);`);
edit("    s.u = next;\n    s.d = distinct;", `    P.moved = ${now};\n    s.u = next;\n    s.d = distinct;`);
writeFileSync(f, s);

const extra = new URL("./out/extra-subjects.json", import.meta.url);
const list = existsSync(extra) ? JSON.parse(readFileSync(extra, "utf8")).filter((x) => x.name !== name) : [];
list.push({ name, kind: "beni", dir: name });
writeFileSync(extra, JSON.stringify(list));
console.log(`out/${name}: ${from} with a probed runtime`);
