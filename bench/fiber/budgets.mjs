// Copies of a `beni build --library` of Bench.beni whose runtime escapes to
// a macrotask after a different number of resumptions: `node budgets.mjs
// <build dir> <out dir> 16 64 512 2048` writes `<out dir>/b<n>/`, each the
// build with core/Task.js's `const budget = 64;` rewritten. The constant is
// the one §7.5 of the effects proposal calls a platform's to choose; this
// is how the sweep varies it without a flag in the language.

import { cpSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [from, to, ...values] = process.argv.slice(2);
for (const v of values) {
  const dir = join(to, `b${v}`);
  cpSync(from, dir, { recursive: true });
  const file = join(dir, "_core/Task.foreign.mjs");
  const text = readFileSync(file, "utf8");
  if (!text.includes("const budget = 64;")) throw new Error(`${file}: no budget to patch`);
  writeFileSync(file, text.replace("const budget = 64;", `const budget = ${v};`));
  console.log(dir);
}
