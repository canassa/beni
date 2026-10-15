// Which declarations of a release bundle a compiler change touched: two
// mapped builds cut into units (research 102's), matched by owner and beni
// name, and every unit that went, came or changed size listed.
//
//   node bench/runtime-coverage/unitdiff.mjs <before-dir> <after-dir>
//
// Each dir holds `_main.mjs` and `_main.mjs.map` (a `--source-maps` build).

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { units } from "../output-size/units.mjs";
import { br } from "../output-size/lib.mjs";

const load = (dir) => {
  const src = readFileSync(join(dir, "_main.mjs"), "utf8").replace(/\/\/# sourceMappingURL=.*\n?$/, "");
  const { units: us } = units(src, JSON.parse(readFileSync(join(dir, "_main.mjs.map"), "utf8")));
  const by = new Map();
  for (const u of us) {
    const key = `${u.owner} ${u.orig ?? u.js}`;
    const v = by.get(key) ?? { raw: 0, text: "" };
    v.raw += u.end - u.start;
    v.text += src.slice(u.start, u.end).replace(/^[^=]*=/, "");
    by.set(key, v);
  }
  return { by, total: br(src) };
};
const [a, b] = process.argv.slice(2).map(load);
console.log(`brotli ${a.total} -> ${b.total} (${b.total - a.total})`);
for (const key of new Set([...a.by.keys(), ...b.by.keys()])) {
  const x = a.by.get(key), y = b.by.get(key);
  if (x && y && x.raw === y.raw) continue;
  console.log(`${key}: ${x?.raw ?? "-"} -> ${y?.raw ?? "-"}`);
  if (process.env.SHOW && x && y) console.log(`   before: ${x.text.slice(0, 400)}\n   after:  ${y.text.slice(0, 400)}`);
}
