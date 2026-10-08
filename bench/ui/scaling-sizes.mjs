// Output size of every scaling page (sizes.mjs's method, applied to each
// program of each sweep): every JavaScript file the page loads, concatenated,
// through terser (`--compress --mangle --module`), then gzip -9 and brotli 11.
// beni is its `--release` build — the one a user ships, not the development
// build the sweeps time; Solid 1 is its production bundle; vanilla is the one
// script.
//
//   node scaling-sizes.mjs [--out=results/<date>-scaling-sizes.json]
//
// After `node scaling.mjs --build-only --full --subjects=beni,beni-release,solid1,vanillajs`;
// terser comes from apps/solid2.

import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import { root } from "./lib/serve.mjs";

const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;

const walk = (dir) =>
  readdirSync(dir)
    .sort()
    .flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.(m?js)$/.test(f) ? [p] : [];
    });

const measure = async (files) => {
  const texts = [];
  for (const f of files) texts.push((await minify(readFileSync(f, "utf8"), { compress: true, mangle: true, module: true })).code);
  const all = Buffer.from(texts.join("\n"));
  return {
    files: files.length,
    raw: all.length,
    gzip: gzipSync(all, { level: 9 }).length,
    brotli: brotliCompressSync(all, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: all.length } }).length,
  };
};

const scaling = join(root, "out/scaling");
const result = {};
for (const sweep of readdirSync(scaling).filter((d) => statSync(join(scaling, d)).isDirectory()).sort()) {
  result[sweep] = {};
  const points = readdirSync(join(scaling, sweep)).sort((a, b) => Number(a) - Number(b));
  for (const p of points) {
    const dir = join(scaling, sweep, p);
    const subjects = {
      beni: existsSync(join(dir, "beni-rel")) ? walk(join(dir, "beni-rel")) : null,
      solid1: existsSync(join(dir, "solid1.js")) ? [join(dir, "solid1.js")] : null,
      vanillajs: existsSync(join(dir, "vanilla.js")) ? [join(dir, "vanilla.js")] : null,
    };
    result[sweep][p] = {};
    for (const [name, files] of Object.entries(subjects)) if (files !== null) result[sweep][p][name] = await measure(files);
  }
}

const out = arg("out", null);
if (out !== null) writeFileSync(join(root, out), JSON.stringify(result, null, 1) + "\n");
for (const [sweep, points] of Object.entries(result)) {
  console.log(`\n### ${sweep}: minified, then brotli 11 / gzip -9, bytes\n`);
  console.log("| point | beni `--release` | Solid 1 | vanilla |");
  console.log("|--:|--:|--:|--:|");
  const cell = (m) => (m === undefined ? "—" : `${m.brotli} / ${m.gzip}`);
  for (const [p, s] of Object.entries(points)) console.log(`| ${p} | ${cell(s.beni)} | ${cell(s.solid1)} | ${cell(s.vanillajs)} |`);
}
