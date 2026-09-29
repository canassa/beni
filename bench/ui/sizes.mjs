// Output size of the benchmark app (research 29 §12.1's method): every
// JavaScript file the page loads, concatenated, then raw, gzip -9 and
// brotli 11. `as served` is what the build wrote; `minified` is each file
// through terser (`--compress --mangle --module`) first, which the Solid 2
// build already did and beni does not yet do.
//
//   node sizes.mjs     (after build.mjs; terser comes from apps/solid2)

import { readdirSync, readFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { root } from "./lib/serve.mjs";

const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");

const walk = (dir) =>
  readdirSync(dir)
    .sort()
    .flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.(m?js)$/.test(f) ? [p] : [];
    });

const subjects = [
  ["beni, development", walk(join(root, "out/beni-dev"))],
  ["beni, --release", walk(join(root, "out/beni-rel"))],
  ["Solid 2.0.0-rc.9", [join(root, "out/solid2/bench.js")]],
  ["Solid 1.9.15", [join(root, "out/solid1/main.js")]],
  ["P2 (hand-written)", [join(root, "apps/p2/bench.js")]],
  ["vanillajs", [join(root, "out/jfb/Main.js")]],
];

const measure = (texts) => {
  const all = Buffer.from(texts.join("\n"));
  return {
    raw: all.length,
    gzip: gzipSync(all, { level: 9 }).length,
    brotli: brotliCompressSync(all, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: all.length } }).length,
  };
};

console.log("| subject | files | as served raw | gzip -9 | brotli 11 | minified raw | minified brotli |");
console.log("|---|--:|--:|--:|--:|--:|--:|");
for (const [name, files] of subjects) {
  const texts = files.map((f) => readFileSync(f, "utf8"));
  const served = measure(texts);
  const minified = [];
  for (const t of texts) minified.push((await minify(t, { compress: true, mangle: true, module: true })).code);
  const min = measure(minified);
  console.log(`| ${name} | ${files.length} | ${served.raw} | ${served.gzip} | ${served.brotli} | ${min.raw} | ${min.brotli} |`);
}

// Where beni's release bytes are, file by file.
console.log("\n| beni --release file | raw | brotli 11 alone |");
console.log("|---|--:|--:|");
for (const f of walk(join(root, "out/beni-rel"))) {
  const b = readFileSync(f);
  console.log(`| ${f.slice(join(root, "out/beni-rel").length + 1)} | ${b.length} | ${brotliCompressSync(b, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length} |`);
}
