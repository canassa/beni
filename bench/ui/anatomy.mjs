// Where the benchmark app's release bytes go, beni against Solid 1.9.15
// (research 40). Every figure is brotli 11 of the files the page loads,
// concatenated in sorted path order (sizes.mjs's method), unless it says
// otherwise.
//
//   node anatomy.mjs     (after build.mjs)
//
// Three instruments:
//
// - **Leave-one-out.** A file's or a part's cost is the whole's brotli minus
//   the whole's brotli without it, which charges each part only the bytes
//   the rest of the bundle does not already explain. The parts do not add up
//   to the whole; the "alone" column is the other bound.
// - **Hand-applied candidates.** Each candidate fix is a text rewrite of the
//   built tree that prices it before anything is built (backend.md §9's
//   discipline). They are measurements, not programs: none is run.
// - **Solid 1 by source.** Its bundle is rebuilt through its own Rollup
//   config with a source map, and every minified byte is charged to the
//   module the map says it came from.

import { readdirSync, readFileSync, statSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { createRequire, SourceMap } from "node:module";
import { join, relative } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";
import { root } from "./lib/serve.mjs";

const solid1 = join(root, "apps/solid1");
const require = createRequire(join(solid1, "package.json"));
const { rollup } = require("rollup");
const { minify } = require("terser");

const br = (s) =>
  brotliCompressSync(Buffer.from(s), {
    params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: Buffer.byteLength(s) },
  }).length;
const raw = (s) => Buffer.byteLength(s);

const walk = (dir) =>
  readdirSync(dir)
    .sort()
    .flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.(m?js)$/.test(f) ? [p] : [];
    });

const rel = join(root, "out/beni-rel");
const files = walk(rel).map((p) => ({ name: relative(rel, p), text: readFileSync(p, "utf8") }));
const bundle = (fs) => fs.map((f) => f.text).join("\n");
const whole = bundle(files);
const base = br(whole);
const row = (...cells) => console.log(`| ${cells.join(" | ")} |`);

console.log(`## beni --release, ${files.length} files: ${raw(whole)} raw, ${base} brotli\n`);
row("file", "raw", "brotli alone", "leave-one-out");
row("---", "--:", "--:", "--:");
for (const f of files) row(f.name, raw(f.text), br(f.text), base - br(bundle(files.filter((g) => g !== f))));

// Parts of the text, priced by deleting every match from the bundle.
const parts = [
  ["`import`/`export` statements", /^(import\{[^}]*\}from"[^"]*";|export\{[^}]*\};)$/gm],
  ["template HTML strings", /[A-Za-z$_]+\("<[^"]*(?:\\"[^"]*)*",\d\)/g],
  ["the three word lists (list literals)", /\{\$:1,a:"[a-z]+",b:[^\n]*?\{\$:0,a:null,b:null\}\}+/g],
  ["constructor tag strings `$:\"Tag\"`", /\$:"[A-Za-z]+",?/g],
];
console.log("\n| part of the bundle | matches | raw | leave-one-out |\n|---|--:|--:|--:|");
for (const [name, re] of parts) {
  const m = whole.match(re) ?? [];
  row(name, m.length, m.reduce((n, s) => n + raw(s), 0), base - br(whole.replace(re, "")));
}

// Candidate fixes, hand-applied.
const tmp = join(root, "out/anatomy");
rmSync(tmp, { recursive: true, force: true });
mkdirSync(tmp, { recursive: true });

const hoist = async (dir, entry, { minified = false } = {}) => {
  const b = await rollup({ input: join(dir, entry), logLevel: "silent" });
  const { output } = await b.generate({ format: "es" });
  const code = output[0].code;
  return minified ? (await minify(code, { module: true, compress: { passes: 3 }, mangle: true })).code : code;
};
const terserEach = async (fs, opts) => Promise.all(fs.map(async (f) => ({ ...f, text: (await minify(f.text, opts)).code })));

const tagged = new Map();
const intTags = (text) =>
  text
    .replace(/\$:"([A-Za-z]+)"/g, (_, t) => `$:${tagged.get(t) ?? (tagged.set(t, tagged.size), tagged.size - 1)}`)
    .replace(/(\.\$(?:===|!==))"([A-Za-z]+)"/g, (_, op, t) => `${op}${tagged.get(t) ?? (tagged.set(t, tagged.size), tagged.size - 1)}`)
    .replace(/case"([A-Za-z]+)"/g, (_, t) => `case ${tagged.get(t) ?? (tagged.set(t, tagged.size), tagged.size - 1)}`);

const candidates = [
  ["as served", async () => whole],
  ["one scope-hoisted file (Rollup, no minifier)", async () => hoist(rel, "_main.mjs")],
  ["one scope-hoisted file, then terser", async () => hoist(rel, "_main.mjs", { minified: true })],
  ["each file through terser, still 12 files", async () => bundle(await terserEach(files, { module: true, compress: true, mangle: true }))],
  ["runtime locals renamed (terser mangle only, runtime file)", async () =>
    bundle(await Promise.all(files.map(async (f) => (f.name.endsWith("runtime.foreign.mjs") ? { ...f, text: (await minify(f.text, { module: true, compress: false, mangle: true })).code } : f))))],
  ["integer constructor tags", async () => intTags(whole)],
  // The runtime's `map` export survives the cut only because `reconcile`
  // declares a local named `map`, and a lexical pass must count that as a
  // mention (backend.md §9, *Hand-written JavaScript under `--release`*).
  ["runtime `map` export and `mapKind` gone", async () =>
    whole.replace(/const [\w$]+=\{m:\(v,cx\)=>\{const c=\{f:v\[1\],up:cx\}.*?\},\};export const map=\([\w$]+,f\)=>\(\{t:[\w$]+,v:\[[\w$]+,f\]\}\);/s, "")],
  ["the word lists written as an array and one helper", async () =>
    whole.replace(/\{\$:1,a:("[a-z]+"),b:([^\n]*?)\{\$:0,a:null,b:null\}\}+/g, (m) => "Z([" + [...m.matchAll(/a:("[a-z]+")/g)].map((x) => x[1]).join(",") + "])") +
      "\nconst Z=(a)=>{let l={$:0,a:null,b:null};for(let i=a.length;i-->0;)l={$:1,a:a[i],b:l};return l};"],
];
console.log("\n| candidate (hand-applied) | raw | brotli | Δ brotli |\n|---|--:|--:|--:|");
for (const [name, make] of candidates) {
  const t = await make();
  row(name, raw(t), br(t), br(t) - base);
}

// What is left once both sides are minified alike: the hand-written
// runtime against the generated rest, each through terser on its own.
const isRuntime = (f) => f.name.endsWith("runtime.foreign.mjs");
const minifiedAll = await terserEach(files, { module: true, compress: { passes: 3 }, mangle: true });
const runtimeMin = bundle(minifiedAll.filter(isRuntime));
const restMin = bundle(minifiedAll.filter((f) => !isRuntime(f)));
console.log("\n| beni, each file through terser | raw | brotli alone |\n|---|--:|--:|");
row("the program runtime", raw(runtimeMin), br(runtimeMin));
row("everything else (generated, core, siblings)", raw(restMin), br(restMin));

// Solid 1 by source module.
// The config reads `production` when it is imported, and Babel finds its
// preset from the working directory.
process.env.production = "true";
process.chdir(solid1);
const b = await rollup({
  input: join(solid1, "src/main.jsx"),
  logLevel: "silent",
  plugins: (await import(join(solid1, "rollup.config.js"))).default.plugins,
});
const { output } = await b.generate({ format: "iife", sourcemap: true });
const sol = output[0];
const map = new SourceMap(sol.map);
const lines = sol.code.split("\n");
const byModule = new Map();
const charge = (src, s) => byModule.set(src, (byModule.get(src) ?? "") + s);
lines.forEach((line, l) => {
  for (let c = 0; c < line.length; c++) {
    const e = map.findEntry(l, c);
    const src = e?.originalSource ? e.originalSource.replace(/.*node_modules\//, "").replace(/.*\/src\//, "app: ") : "(unmapped)";
    charge(src, line[c]);
  }
});
const solidWhole = sol.code;
console.log(`\n## Solid 1.9.15, rebuilt with a map: ${raw(solidWhole)} raw, ${br(solidWhole)} brotli\n`);
row("source", "minified raw", "brotli alone");
row("---", "--:", "--:");
for (const [src, s] of [...byModule].sort((x, y) => raw(y[1]) - raw(x[1]))) row(src, raw(s), br(s));
const library = [...byModule].filter(([src]) => src.startsWith("solid-js/")).map(([, s]) => s).join("");
row("**the library, both files**", raw(library), br(library));
writeFileSync(join(tmp, "solid1.js"), solidWhole);
