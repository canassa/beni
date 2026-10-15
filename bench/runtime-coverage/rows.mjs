// Research 103 §4: list rows, beni against Solid 2 — each side's keyed-row
// code minified and compressed on its own (brotli 11 with the size hint).
//
//   node bench/runtime-coverage/rows.mjs
//
// Solid: `mapArray`'s keyed half (`references/solid/packages/signals/src/
// map.ts`, `repeat` left out) and dom-expressions' `reconcileArrays`,
// through esbuild (types) and Terser (compress, mangle, passes 2). beni:
// the release units of browser-tea's Rt that keyed rows reach, cut from
// run.mjs's TodoMVC build (`Rt.forKeyed` and what it calls), already
// minified by `--release`.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { br } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const require = createRequire(join(repo, "bench/output-size/package.json"));
const esbuild = require("esbuild");
const terser = require("terser");
const refs = process.env.REFERENCES ?? join(repo, "references");
const min = async (code) => (await terser.minify(code, { module: true, compress: { passes: 2 }, mangle: true })).code;

const ts = readFileSync(join(refs, "solid/packages/signals/src/map.ts"), "utf8");
const keyed = ts.slice(0, ts.indexOf("export function repeat(")) + ts.slice(ts.indexOf("function compare<Item>"));
const js = esbuild.transformSync(keyed, { loader: "ts", format: "esm" }).code.replace(/^import[\s\S]*?from\s*["'][^"']+["'];?/gm, "");
const map = await min(`${js}\nexport { mapArray };`);
const rec = await min(readFileSync(join(refs, "dom-expressions/packages/runtime/src/reconcile.js"), "utf8").replace(/^import .*$/m, "const $$SLOT = Symbol();") );
console.log(`Solid mapArray (keyed):          raw ${map.length}, brotli ${br(map)}`);
console.log(`dom-expressions reconcileArrays: raw ${rec.length}, brotli ${br(rec)}`);
console.log(`Solid's keyed rows together:     brotli ${br(map + rec)}`);

const analysis = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/analysis.json"), "utf8"));
for (const key of ["TodoMVC-tea", "Table-tea"]) {
  const a = analysis[key];
  const src = readFileSync(a.bundle, "utf8");
  const names = ["forKeyed", "trimmed", "reconcile", "patchRow", "mountRow", "sameInputs", "sameFrom", "sameInputsBut", "sameFromBut", "reselect", "reselectFrom", "park", "keyedPass", "keyedRows", "startRows", "endRows", "crossRows", "lookUpRows", "patchRows", "forgetRows", "sameEnds", "putRange", "putBefore", "dropRange", "indexRange", "sameRun", "copyRows"];
  const units = a.rows.filter((r) => r.owner === "platforms/browser/Rt" && names.includes(r.orig));
  // The units' text: `name=…` without the leading declarator keyword.
  const text = units.map((r) => src.slice(src.indexOf(`${r.js}=`), src.indexOf(`${r.js}=`) + r.raw)).join(",");
  console.log(`beni ${key} keyed rows (${units.map((u) => u.orig).join(" ")}): raw ${text.length}, brotli ${br(text)}`);
}
