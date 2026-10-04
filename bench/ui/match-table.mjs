// Research 56: the prototypes of match-variants.mjs applied to the table
// benchmark's and the static page's beni builds (out/beni-dev, out/micro-*-dev,
// made by build.mjs), registered as extra subjects for bench.mjs
// (out/extra-subjects.json) and micro.mjs (out/extra-micro.json). PROTOTYPES:
// hand edits of a development build, never committed output.
//
//   node match-table.mjs [--variants=A-evflush,...]

import { cpSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { root } from "./lib/serve.mjs";
import { variants } from "./match-variants.mjs";

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const wanted = arg("variants", "A-evflush").split(",");

const apply = (name, from, edits) => {
  const rel = `match/${name}`;
  const dir = join(root, "out", rel);
  rmSync(dir, { recursive: true, force: true });
  cpSync(join(root, "out", from), dir, { recursive: true });
  for (const [file, find, replace] of edits) {
    const f = join(dir, file);
    let s = readFileSync(f, "utf8");
    const re = find instanceof RegExp ? find : null;
    if (re ? !re.test(s) : !s.includes(find)) throw new Error(`${name}: ${file} has no ${String(find).slice(0, 100)}`);
    s = re ? s.replace(re, replace) : s.replace(find, () => replace);
    writeFileSync(f, s);
  }
  return rel;
};

const table = [];
const micro = [];
for (const name of wanted) {
  const v = variants.find((x) => x.name === name && x.sweeps.includes("table")) ?? variants.find((x) => x.name === name);
  const edits = v.edits({ sweep: "table" });
  table.push({ name: `beni-${name}`, kind: "beni", dir: apply(`table-${name}`, "beni-dev", edits) });
  const s = variants.find((x) => x.name === name && x.sweeps.includes("static")) ?? v;
  const sEdits = s.edits({ sweep: "static" });
  const dir = apply(`static-${name}`, "micro-inline-dev", sEdits);
  micro.push({ name: `beni-inline-${name}`, kind: "beni-micro", dir });
}
writeFileSync(join(root, "out/extra-subjects.json"), JSON.stringify(table, null, 1));
writeFileSync(join(root, "out/extra-micro.json"), JSON.stringify(micro, null, 1));
console.log(JSON.stringify({ table, micro }, null, 1));
