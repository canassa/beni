// Single edits to the runtime's SOURCE (src/runtime.js), each applied ALONE,
// the page rebuilt through `Minify.zig` against a copy of the platform, and
// the shipped file priced against the page built from the unedited copy.
// This prices a source rule as the compactor will actually ship it (its
// renaming and A3 included), which a text edit of the output cannot.
//   node tools/source-trials.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { build, sizes } from "../measure.mjs";

import { SOURCE } from "./edits.mjs";
const here = new URL("..", import.meta.url).pathname;
const src = fs.readFileSync(path.join(here, "src/runtime.js"), "utf8");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "source-trials-"));


if (import.meta.url === `file://${process.argv[1]}`) {
  const basePath = path.join(tmp, "base.mjs");
  build(basePath, path.join(here, "src/runtime.js"));
  const b = sizes(fs.readFileSync(basePath));
  const d = (x) => (x > 0 ? "+" : "") + x;
  console.log(`base (src/runtime.js through Minify.zig): raw ${b.raw}, gz ${b.gz}, br ${b.br}\n\n| source edit, alone | Δ raw | Δ gz | Δ br |\n|---|--:|--:|--:|`);
  const only = process.argv.slice(2);
  for (const [key, [label, f]] of Object.entries(SOURCE)) {
    if (only.length && !only.includes(key)) continue;
    const rt = path.join(tmp, `${key}.js`);
    const out = path.join(tmp, `${key}.mjs`);
    try {
      fs.writeFileSync(rt, f(src));
      build(out, rt);
    } catch (e) {
      console.log(`| ${label} | n/a (${only.length ? e.message : e.message.split("\n")[0].slice(0, 60)}) | | |`);
      continue;
    }
    const s = sizes(fs.readFileSync(out));
    console.log(`| ${label} | ${d(s.raw - b.raw)} | ${d(s.gz - b.gz)} | ${d(s.br - b.br)} |`);
  }
  fs.rmSync(tmp, { recursive: true, force: true });
}
