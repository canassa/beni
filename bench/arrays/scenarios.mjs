// Realistic Array scenarios as beni compiles them (research/38 §15), Node only.
//
//   node scenarios.mjs build            compile scenarios/src/*.beni with ../../zig-out/bin/beni (build it
//                                       first: `zig build`) against a copy of core/ plus
//                                       scenarios/Array.{beni,js}, into dist/beni; then write the
//                                       proven-plain rewrite of it into dist/beniP
//   node scenarios.mjs test             every candidate runs every scenario once; all must agree
//   node scenarios.mjs bench [core] [candidate…]
//                                       one `node --expose-gc` process per candidate, pinned with
//                                       `taskset -c <core>`; appends to results/scenarios.jsonl
//   node scenarios.mjs size             esbuild --minify, tree-shaken, brotli 11, of each sibling
//   node scenarios.mjs tables [file]    the report's tables from the JSONL
//
// The beni code is compiled once and is byte-identical for every candidate: only the sibling
// `_core/Array.foreign.mjs` changes, swapped in at bundle time by an esbuild plugin. Each candidate
// is bundled into its own IIFE, so every process sees one sibling and its call sites stay
// monomorphic, as in the rest of report 38.
import * as esbuild from 'esbuild';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
process.chdir(here);
const repo = path.resolve(here, '../..');
const mode = process.argv[2];

// ---------------------------------------------------------------------------------------------
// The candidates' siblings. Each exports scenarios/Array.beni's foreign surface under the declared
// names and parameter lists, plus the two host-side entry points the scenarios need: `fromJs`, the
// decoder's hand-over of a fresh JS array it owns (adopted, not copied, wherever the representation
// allows), and `toJs`, what the DOM runtime and a JS API read.

const common = (port) => `
export { length, get as unsafeGet, set, push, pop, slice, concat as append, fromCons as fromList } from '../ports/${port}.js';
import { toCons, sort, toArray } from '../ports/${port}.js';
const NIL = { $: 0, a: null, b: null };
export const toList = (a) => toCons(a, NIL);
export const sortWith = (a, f) => sort(a, (x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; });
export const toJs = (a) => toArray(a);
// the runtime's way through an array without copying it: the plain array itself, or the trie's
// leaves in order and then its tail (report 38 §12.2: "walks the trie's leaves otherwise")
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
export const chunks = (a) => { if (Array.isArray(a)) return [a]; const out = leaves(a.r, a.s, []); out.push(a.t); return out; };`;

const SIB = {
  cow: { port: 'cow', fromJs: `export const fromJs = (arr) => arr;` },
  trie: { port: 'trie', fromJs: `import { fromArray } from '../ports/trie.js';\nexport const fromJs = (arr) => fromArray(arr);` },
  hybrid1024: { port: 'hybrid', T: 1024, fromJs: `import { fromArray as trieFrom } from '../ports/trie.js';\nexport const fromJs = (arr) => (arr.length <= 1024 ? arr : trieFrom(arr));` },
  adaptive32: { port: 'adaptive', T: 32, fromJs: `export const fromJs = (arr) => arr;` },
  adaptive256: { port: 'adaptive', T: 256, fromJs: `export const fromJs = (arr) => arr;` },
  adaptive1024: { port: 'adaptive', T: 1024, fromJs: `export const fromJs = (arr) => arr;` },
  // adaptive 1024 again, with the modules whose arrays are provably plain compiled to bare `a[i]`
  adaptive1024P: { port: 'adaptive', T: 1024, fromJs: `export const fromJs = (arr) => arr;`, P: true },
};
const CANDIDATES = Object.keys(SIB);
// the proven-plain build only differs in scenarios 2 and 3's life step; the rest would repeat adaptive1024
const P_ONLY = ['decoded', 'grid'];
const ALL_SC = ['table', 'decoded', 'grid', 'build', 'history', 'interop'];

function writeSibling(name) {
  const s = SIB[name];
  const file = path.join(here, 'dist', `sib-${name}.js`);
  fs.writeFileSync(file, common(s.port) + '\n' + s.fromJs + '\n');
  return file;
}

function plugin(name) {
  const sib = writeSibling(name), tree = path.join(here, 'dist', SIB[name].P ? 'beniP' : 'beni');
  return {
    name: 'beni-array',
    setup(b) {
      b.onResolve({ filter: /^array-sibling$|\/Array\.foreign\.mjs$/ }, () => ({ path: sib }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
    },
  };
}
async function bundle(name, contents, extra) {
  const s = SIB[name];
  return esbuild.build({
    stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, platform: 'neutral', target: 'es2023',
    define: { ADA_T: String(s.T ?? 1024), HYB_T: String(s.T ?? 1024) }, logLevel: 'error', plugins: [plugin(name)], ...extra,
  });
}

// ---------------------------------------------------------------------------------------------
// The proven-plain rewrite: what a compiler that tracks "this value is a plain JS array" would emit
// for the modules where every Array provably is one (it came from the decoder, fromList,
// initialize, map, filter, sortWith or slice and was never written). Mechanical, on the compiled
// text: `_core/Array.mjs` gains a `$P` twin of each beni-written reader with `unsafeGet(a, i)` as
// `a[i]` and `length(a)` as `a.length`, and the proven modules call the twins.

const READERS = ['get', 'update', 'foldlHelp', 'foldl', 'foldrHelp', 'foldr', 'map', 'indexedMapHelp', 'indexedMap', 'filter'];
const PROVEN = ['Decoded.mjs', 'Life.mjs'];
const readerRe = new RegExp(`\\bArray\\$(${READERS.join('|')})\\b(?!\\$)`, 'g');
const bare = (s) => s
  .replace(/Array\$unsafeGet\(([\w$.]+), ([\w$.]+)\)/g, '$1[$2]')
  .replace(/Array\$length\(([\w$.]+)\)/g, '$1.length');
function provenPlain() {
  fs.rmSync('dist/beniP', { recursive: true, force: true });
  fs.cpSync('dist/beni', 'dist/beniP', { recursive: true });
  const core = fs.readFileSync('dist/beni/_core/Array.mjs', 'utf8');
  const stmts = core.split(/\n(?=const |export )/);
  const twins = [], names = [];
  for (const st of stmts) {
    const m = /^const Array\$(\w+) = /.exec(st);
    if (m && READERS.includes(m[1])) { twins.push(bare(st.replace(readerRe, 'Array$$$1$$P'))); names.push(`Array$${m[1]}$P`); }
  }
  const out = stmts.map((st) => (st.startsWith('export {') ? twins.join('\n') + '\n' + st.replace('};', `, ${names.join(', ')} };`) : st)).join('\n');
  if (/unsafeGet\(|\bArray\$length\(/.test(twins.join('\n'))) throw new Error('proven-plain: a read survived in the twins');
  fs.writeFileSync('dist/beniP/_core/Array.mjs', out);
  for (const f of PROVEN) {
    let s = fs.readFileSync(`dist/beni/${f}`, 'utf8');
    s = bare(s.replace(readerRe, 'Array$$$1$$P'));
    if (/\bArray\$length\(/.test(s)) throw new Error(`proven-plain: ${f} still calls length`);
    fs.writeFileSync(`dist/beniP/${f}`, s);
  }
}

// ---------------------------------------------------------------------------------------------

if (mode === 'build') {
  fs.rmSync('dist/core', { recursive: true, force: true });
  fs.rmSync('dist/beni', { recursive: true, force: true });
  fs.mkdirSync('dist', { recursive: true });
  fs.cpSync(path.join(repo, 'core'), 'dist/core', { recursive: true });
  fs.copyFileSync('scenarios/Array.beni', 'dist/core/Array.beni');
  fs.copyFileSync('scenarios/Array.js', 'dist/core/Array.js');
  const srcs = fs.readdirSync('scenarios/src').filter((f) => f.endsWith('.beni')).map((f) => `scenarios/src/${f}`);
  const r = spawnSync(path.join(repo, 'zig-out/bin/beni'),
    ['build', '--platform=node', '--library', '--no-cache', '--core-root=dist/core', '--root=scenarios/src', '--out=dist/beni', ...srcs],
    { encoding: 'utf8' });
  process.stdout.write(r.stdout); process.stderr.write(r.stderr);
  if (r.status !== 0) process.exit(1);
  provenPlain();
  console.log('built dist/beni and dist/beniP');
} else if (mode === 'test') {
  fs.mkdirSync('dist', { recursive: true });
  const outs = {};
  for (const name of CANDIDATES) {
    const file = path.join(here, 'dist', `test-${name}.js`);
    await bundle(name, `import { test } from './scenarios/harness.js'; console.log(test());`, { format: 'iife', outfile: file });
    const r = spawnSync(process.execPath, ['--stack-size=4000', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) { console.log(name, 'FAILED', r.stderr.slice(-1500)); process.exitCode = 1; continue; }
    outs[name] = r.stdout.trim().split('\n');
    console.log(name.padEnd(14), outs[name].length, 'checks');
  }
  const ref = outs.cow;
  for (const name of Object.keys(outs)) {
    const diff = outs[name].map((l, i) => [l, ref[i]]).filter(([a, b]) => a !== b);
    if (outs[name].length !== ref.length || diff.length) { console.log(name, 'DIFFERS from cow:', diff.slice(0, 5)); process.exitCode = 1; }
  }
  const bad = ref.filter((l) => /INPUT CHANGED|identity.*false/.test(l));
  if (bad.length) { console.log('cow itself:', bad); process.exitCode = 1; }
  if (!process.exitCode) console.log(`all ${Object.keys(outs).length} candidates agree on ${ref.length} checks`);
} else if (mode === 'bench') {
  const core = process.argv[3] ?? '13';
  const only = process.argv.slice(4).length ? process.argv.slice(4) : CANDIDATES;
  fs.mkdirSync('results', { recursive: true });
  // `name:sc1,sc2` runs only those scenarios, in a process of their own, labelled so in the results
  for (const spec of only) {
    const [name, scs] = spec.split(":");
    const sc = scs ? scs.split(",") : SIB[name].P ? P_ONLY : ALL_SC;
    const file = path.join(here, "dist", `bench-${spec.replace(/[:,]/g, "-")}.js`);
    await bundle(name, `import { run } from "./scenarios/harness.js"; run(${JSON.stringify(spec)}, ${JSON.stringify(sc)});`, { format: 'iife', outfile: file });
    const t0 = Date.now();
    const load = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
    const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', file], { encoding: 'utf8', maxBuffer: 1 << 26 });
    const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
    if (r.status !== 0) console.error(name, 'FAILED', r.stderr.slice(-800));
    fs.appendFileSync('results/scenarios.jsonl', lines.join('\n') + '\n');
    const load2 = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
    console.log(name, lines.length, 'cells', ((Date.now() - t0) / 1000).toFixed(1) + ' s', `load ${load} -> ${load2}`);
  }
} else if (mode === 'size') {
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
  console.log('| sibling | min | gzip | brotli |\n|---|--:|--:|--:|');
  for (const name of ['cow', 'trie', 'hybrid1024', 'adaptive1024']) {
    // the foreign surface of scenarios/Array.beni, as core's `_core/Array.foreign.mjs` would ship it
    // (`fromJs`/`toJs` are the decoder's and the runtime's, and included)
    const r = await bundle(name, `export * from 'array-sibling';`, { format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser' });
    const t = r.outputFiles[0].text;
    console.log(`| ${name} | ${t.length} | ${gz(t)} | **${br(t)}** |`);
  }
} else if (mode === 'tables') {
  const file = process.argv[3] ?? 'results/scenarios.jsonl';
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const groups = new Map();
  for (const r of rows) {
    const k = `${r.impl}|${r.op}|${r.n}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r.med ?? r.bytes);
  }
  const cell = new Map(), spread = [];
  for (const [k, ms] of groups) {
    ms.sort((a, b) => a - b);
    cell.set(k, ms[ms.length >> 1]);
    const q = (p) => ms[Math.min(ms.length - 1, Math.floor(p * (ms.length - 1) + 0.5))];
    if (ms.length > 2) spread.push({ k, s: (q(0.75) - q(0.25)) / ms[ms.length >> 1] });
  }
  const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const kb = (b) => (b / 1024).toFixed(b < 10240 ? 1 : 0) + ' KB';
  const cols = [...CANDIDATES, ...new Set(rows.map((r) => r.impl).filter((i) => !CANDIDATES.includes(i)))];
  const ops = [...new Set(rows.map((r) => `${r.sc}|${r.op}|${r.n}`))];
  let lastSc = '';
  for (const o of ops) {
    const [sc, op, n] = o.split('|');
    if (sc !== lastSc) { console.log(`\n**${sc}**\n\n| op | n | ${cols.join(' | ')} |\n|---|--:|${cols.map(() => '--:').join('|')}|`); lastSc = sc; }
    const base = cell.get(`adaptive1024|${op}|${n}`);
    console.log(`| ${op} | ${(+n).toLocaleString('en')} | ` + cols.map((c) => {
      const v = cell.get(`${c}|${op}|${n}`);
      if (v === undefined) return '—';
      if (op.startsWith('retained')) return kb(v);
      const x = base ? v / base : 0;
      return fmt(v) + (c !== 'adaptive1024' && base ? ` (${x < 10 ? x.toFixed(1) : Math.round(x).toLocaleString('en')}×)` : '');
    }).join(' | ') + ' |');
  }
  const timed = rows.filter((r) => r.med !== undefined);
  const rel = timed.map((r) => (r.q3 - r.q1) / r.med).sort((a, b) => a - b);
  const wide = timed.filter((r) => (r.hi - r.lo) / r.med > 0.25).length;
  console.log(`\nwithin a run: ${timed.length} cells, median IQR/median ${(100 * rel[rel.length >> 1]).toFixed(1)} %, 90th percentile ${(100 * rel[Math.floor(rel.length * 0.9)]).toFixed(1)} %; min–max > 25 % of median: ${wide}`);
  if (spread.length) {
    spread.sort((a, b) => a.s - b.s);
    const pct = (p) => (100 * spread[Math.floor(p * (spread.length - 1))].s).toFixed(0) + ' %';
    console.log(`between rounds (IQR of round medians / median): median ${pct(0.5)}, 90th percentile ${pct(0.9)}; worst: ${spread.slice(-6).map((x) => `${x.k} ${(100 * x.s).toFixed(0)} %`).join(', ')}`);
  }
} else {
  console.log('usage: node scenarios.mjs build | test | bench [core] [candidate…] | size | tables [file]');
}
