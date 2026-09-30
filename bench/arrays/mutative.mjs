// Mutative against report 38's candidates, Node only (research/38 §14).
//
//   npm ci
//   node mutative.mjs test              differential test of every candidate against plain arrays
//   node mutative.mjs identity          which no-op writes return the same object
//   node mutative.mjs size              esbuild --minify, tree-shaken, brotli 11
//   node mutative.mjs bench [core]      one `node --expose-gc` process per candidate, pinned with
//                                       `taskset -c <core>`; appends to results/node.jsonl
//   node mutative.mjs tables [file]     renders the report's tables from the JSONL
//
// The timing loop, data and operation shapes are report 38's harness (§13), trimmed to the operations
// §14 benches. Every candidate is bundled into its own IIFE so each process sees one adapter only and
// its call sites stay monomorphic.
import * as esbuild from 'esbuild';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
process.chdir(here);

// ---------------------------------------------------------------------------------------------
// Adapters. Reads of every copy-on-write candidate (cow, Immer, Mutative) are cow's loops over the
// plain array the candidate returns; only the writes differ. `batch100` applies 100 `set`s at the
// indices `ix` with the values `vs`; `each100` is the same 100 writes as 100 separate calls.

const COW_READS = `import * as C from './ports/cow.js';
export const length = C.length, get = C.get, foldl = C.foldl, forEach = C.forEach, eq = C.eq,
  map = C.map, filter = C.filter, toArray = C.toArray, slice = C.slice, concat = C.concat;`;

const each100 = `export function each100(a, ix, vs) { for (let k = 0; k < 100; k++) a = set(a, ix[k], vs[k]); return a; }`;

const mutativeAdapter = (importLine, opts) => `${importLine}
${COW_READS}
import * as Cw from './ports/cow.js';
const O = ${opts};
export const set = (a, i, v) => create(a, (d) => { d[i] = v; }, O);
export const push = (a, v) => create(a, (d) => { d.push(v); }, O);
export const pop = (a) => create(a, (d) => { d.pop(); }, O);
export const swap = (a, i, j) => create(a, (d) => { const t = d[i]; d[i] = d[j]; d[j] = t; }, O);
export const mapDraft = (a, f) => create(a, (d) => { for (let i = 0; i < d.length; i++) d[i] = f(d[i]); }, O);
export const batch100 = (a, ix, vs) => create(a, (d) => { for (let k = 0; k < 100; k++) d[ix[k]] = vs[k]; }, O);
${each100}
// an unchanged draft is still deep-frozen on the way out; returning arr.slice() from the recipe instead
// would send it through handleReturnValue, whose walk has no cycle check and overflows the stack on the
// harness's cyclic records
export const fromArray = O.enableAutoFreeze ? (arr) => create(arr.slice(), () => {}, O) : Cw.fromArray;
export const create_ = create, opts_ = O;`;

const SRC = {
  native: `import * as C from './ports/cow.js';
export const length = C.length, get = C.get, foldl = C.foldl, forEach = C.forEach, eq = C.eq, filter = C.filter, toArray = C.toArray;
export const fromArray = (arr) => arr.slice();
export const inPlace = true;
export const set = (a, i, v) => { a[i] = v; return a; };
export const map = (a, f) => { for (let i = 0; i < a.length; i++) a[i] = f(a[i]); return a; };
export const swap = (a, i, j) => { const t = a[i]; a[i] = a[j]; a[j] = t; return a; };
export const batch100 = (a, ix, vs) => { for (let k = 0; k < 100; k++) a[ix[k]] = vs[k]; return a; };`,
  cow: `export * from './ports/cow.js';
import { set } from './ports/cow.js';
${each100}
// what a batch reduces to when the compiler can prove the intermediate arrays local: one copy, 100 writes
export function batch100(a, ix, vs) { const c = a.slice(); for (let k = 0; k < 100; k++) c[ix[k]] = vs[k]; return c; }`,
  trie: `export * from './ports/trie.js';
import { set } from './ports/trie.js';
${each100}`,
  hybrid1024: `export * from './ports/hybrid.js';
import { set } from './ports/hybrid.js';
${each100}`,
  immer: `import { produce } from 'immer';
${COW_READS}
import * as Cw from './ports/cow.js';
export const set = (a, i, v) => produce(a, (d) => { d[i] = v; });
export const push = (a, v) => produce(a, (d) => { d.push(v); });
export const pop = (a) => produce(a, (d) => { d.pop(); });
export const swap = (a, i, j) => produce(a, (d) => { const t = d[i]; d[i] = d[j]; d[j] = t; });
export const mapDraft = (a, f) => produce(a, (d) => { for (let i = 0; i < d.length; i++) d[i] = f(d[i]); });
export const batch100 = (a, ix, vs) => produce(a, (d) => { for (let k = 0; k < 100; k++) d[ix[k]] = vs[k]; });
${each100}
export const fromArray = (arr) => produce([], () => arr.slice());`,
  // default options, the build a bundler resolves for \`import { create } from 'mutative'\`:
  // package.json's "import" condition is dist/mutative.esm.mjs, which is the DEVELOPMENT build
  mutative: mutativeAdapter(`import { create } from 'mutative';`, '{}'),
  // default options, production build: separates what the build costs from what `mark` buys
  'mutative-prod': mutativeAdapter(`import { create } from 'mutative/dist/mutative.cjs.production.min.js';`, '{}'),
  // the fastest honest configuration: the production build (only reachable by path or through the
  // CommonJS entry under NODE_ENV=production), no freeze (the default), and \`mark\` telling Mutative the
  // elements are opaque values, so reading d[i] returns the element instead of drafting it
  'mutative-fast': mutativeAdapter(
    `import { create } from 'mutative/dist/mutative.cjs.production.min.js';`,
    `{ mark: (v, t) => (Array.isArray(v) ? undefined : t.mutable) }`,
  ),
  // Immer-parity: enableAutoFreeze on, production build (the development build's deepFreeze refuses the
  // harness's cyclic records with "Forbids circular reference")
  'mutative-freeze': mutativeAdapter(
    `import { create } from 'mutative/dist/mutative.cjs.production.min.js';`,
    `{ enableAutoFreeze: true }`,
  ),
};
const CANDIDATES = ['native', 'cow', 'trie', 'hybrid1024', 'immer', 'mutative', 'mutative-prod', 'mutative-fast', 'mutative-freeze'];

async function bundle(name, contents, extra = {}) {
  return esbuild.build({
    stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, platform: 'neutral',
    mainFields: ['module', 'main'], define: { 'process.env.NODE_ENV': '"production"', HYB_T: '1024' },
    logLevel: 'error', target: 'es2023', ...extra,
  });
}
// the adapter as an ES module in dist/, for the test and identity modes (run in this process)
async function adapterModule(name) {
  const file = path.join(here, 'dist', `adapter-${name}.mjs`);
  await bundle(name, SRC[name], { format: 'esm', outfile: file });
  return import(file);
}

// ---------------------------------------------------------------------------------------------
// The timing harness (report 38 §13's harness.js, unchanged in method): warm up >= 25 ms and >= 3
// calls, then 7 samples (3 when a call exceeds 400 ms) of >= 10 ms each, median; a full GC first.

const HARNESS = String.raw`
import { measure } from '../lib/measure.js'; // the timing loop, shared by every harness here
function prewarm() {
  const xs = [1, 2, 3, 4, 5, 6, 7, 8];
  for (let r = 0; r < 3; r++) for (const f of [() => xs.slice(), () => xs.length, () => xs.map((x) => x), () => ({ a: xs }), () => xs[3]]) measure(f, 1);
}
let seed = 12345;
const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
function dataFor(n) {
  const mk = (i) => { const q = { k: i, o: null }, p = { k: -i, o: q }; q.o = p; return q; };
  const data = Array.from({ length: n }, (_, i) => mk(i));
  const idx = Array.from({ length: 256 }, () => rnd(n));
  const vals = Array.from({ length: 256 }, (_, i) => mk(-1 - i));
  return { data, idx, vals };
}
const OPS = {
  get: (I, n, d) => { const a = I.fromArray(d.data), ix = d.idx; return [() => { let s = 0; for (let k = 0; k < 256; k++) s += I.get(a, ix[k]).k; return s; }, 256]; },
  set: (I, n, d) => { const a = I.fromArray(d.data), ix = d.idx; let k = 0; return [() => { k = (k + 1) & 255; return I.set(a, ix[k], d.vals[k]); }, 1]; },
  push: (I, n, d) => { if (I.inPlace) { const a = d.data.slice(), lim = n + 4096; let k = 0; return [() => { a.push(d.vals[(k++) & 255]); if (a.length >= lim) a.length = n; return a; }, 1]; }
    const a = I.fromArray(d.data); let k = 0; return [() => I.push(a, d.vals[(k++) & 255]), 1]; },
  pop: (I, n, d) => { if (I.inPlace) { const a = d.data.slice(); return [() => { const x = a.pop(); a.push(x); return a; }, 1]; }
    const a = I.fromArray(d.data); return [() => I.pop(a), 1]; },
  swap: (I, n, d) => { const a = I.inPlace ? d.data.slice() : I.fromArray(d.data), i = 1, j = n - 2;
    if (I.swap) return [() => I.swap(a, i, j), 1];
    return [() => { const x = I.get(a, i), y = I.get(a, j); return I.set(I.set(a, i, y), j, x); }, 1]; },
  map: (I, n, d) => { const a = I.inPlace ? d.data.slice() : I.fromArray(d.data), f = (x) => x.o; return [() => I.map(a, f), 1]; },
  mapDraft: (I, n, d) => { if (!I.mapDraft) return null; const a = I.fromArray(d.data), f = (x) => x.o; return [() => I.mapDraft(a, f), 1]; },
  filter: (I, n, d) => { const a = I.fromArray(d.data), f = (x) => (x.k & 1) === 0; return [() => I.filter(a, f), 1]; },
  foldl: (I, n, d) => { const a = I.fromArray(d.data), f = (x, z) => z + x.k; return [() => I.foldl(a, f, 0), 1]; },
  // 100 writes at 100 distinct random indices (n >= 100) or cycling indices (n = 8); per call = all 100
  batch100: (I, n, d) => { if (!I.batch100) return null; const a = I.inPlace ? d.data.slice() : I.fromArray(d.data); return [() => I.batch100(a, d.idx, d.vals), 1]; },
  each100: (I, n, d) => { if (!I.each100) return null; const a = I.fromArray(d.data); return [() => I.each100(a, d.idx, d.vals), 1]; },
};
export function run(I, name) {
  prewarm();
  for (const n of [8, 1000, 100000]) {
    const d = dataFor(n);
    for (const op in OPS) {
      const mk = OPS[op](I, n, d);
      if (!mk) continue;
      if (typeof gc === 'function') gc();
      const r = measure(mk[0], mk[1]);
      const p = (x) => +x.toPrecision(4);
      console.log(JSON.stringify({ engine: 'node', impl: name, op, n, med: p(r.med), q1: p(r.q1), q3: p(r.q3), lo: p(r.lo), hi: p(r.hi), S: r.S }));
    }
  }
}`;

// ---------------------------------------------------------------------------------------------

const mode = process.argv[2];

if (mode === 'bench') {
  const core = process.argv[3] ?? '13';
  const only = process.argv.slice(4);
  fs.mkdirSync('dist', { recursive: true });
  fs.mkdirSync('results', { recursive: true });
  fs.writeFileSync('dist/harness.js', HARNESS);
  for (const name of only.length ? only : CANDIDATES) {
    fs.writeFileSync(`dist/src-${name}.js`, SRC[name].replaceAll('./ports/', '../ports/'));
    await bundle(name, `import * as I from './dist/src-${name}.js'; import { run } from './dist/harness.js'; run(I, ${JSON.stringify(name)});`,
      { format: 'iife', outfile: `dist/bench-${name}.js` });
    const t0 = Date.now();
    const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', `dist/bench-${name}.js`], { encoding: 'utf8', maxBuffer: 1 << 26 });
    const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
    if (r.status !== 0) console.error(name, 'FAILED', r.stderr.slice(-600));
    fs.appendFileSync('results/node.jsonl', lines.join('\n') + '\n');
    console.log(name, lines.length, 'cells', ((Date.now() - t0) / 1000).toFixed(1) + ' s');
  }
} else if (mode === 'test') {
  // Every benched write, random sequences at sizes across the hybrid's and the trie's boundaries,
  // against a plain-array reference; after every call the input must be untouched.
  const eqf = (x, y) => x === y;
  let failures = 0;
  for (const name of CANDIDATES.filter((c) => c !== 'native')) {
    const I = await adapterModule(name);
    let seed = 7, fails = 0, calls = 0;
    const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
    const bad = (...m) => { if (fails++ < 5) console.log(name, 'FAIL', ...m); };
    const same = (arr, ref) => I.length(arr) === ref.length && I.toArray(arr).every((x, i) => x === ref[i]);
    for (const n0 of [0, 1, 8, 31, 32, 33, 100, 1000, 1024, 1025, 2000, 33000]) {
      const recs = (m, base) => Array.from({ length: m }, (_, i) => ({ k: base + i }));
      let ref = recs(n0, 0), a = I.fromArray(ref.slice());
      for (let step = 0; step < 50; step++) {
        const n = ref.length, i = n ? rnd(n) : 0, j = n ? rnd(n) : 0, v = { k: -1 - step };
        const before = ref.slice(), beforeKeys = ref.map((x) => x.k);
        let r = a, nref = ref;
        switch (rnd(8)) {
          case 0: if (n) { r = I.set(a, i, v); nref = ref.with(i, v); } break;
          case 1: r = I.push(a, v); nref = [...ref, v]; break;
          case 2: if (n) { r = I.pop(a); nref = ref.slice(0, -1); } break;
          case 3: if (n) { r = I.swap(a, i, j); nref = ref.with(i, ref[j]).with(j, ref[i]); } break;
          case 4: { const f = (x) => (x.k % 3 === 0 ? { k: x.k * 2 } : x); r = (I.mapDraft ?? I.map)(a, f); nref = ref.map(f); break; }
          case 5: { const f = (x) => (x.k & 1) === 0; r = I.filter(a, f); nref = ref.filter(f); break; }
          case 6: if (n) { const ix = Array.from({ length: 100 }, () => rnd(n)), vs = recs(100, 1e6 + step * 100);
            let e = ref.slice(); for (let k = 0; k < 100; k++) e[ix[k]] = vs[k];
            if (I.batch100 && !same(I.batch100(a, ix, vs), e)) bad('batch100', n0, step);
            if (I.each100) { r = I.each100(a, ix, vs); nref = e; } } break;
          case 7: if (n) { const c = (I.mapDraft && name.startsWith('mutative')) ? I.mapDraft(a, (x) => x) : a; if (!same(c, ref)) bad('mapDraft identity fn'); } break;
        }
        calls++;
        // the input is untouched: same length, same element objects, same element contents
        if (!same(a, before) || before.some((x, k) => x.k !== beforeKeys[k])) bad('input changed', n0, step);
        if (!same(r, nref)) bad('result', n0, step, I.length(r), nref.length);
        if (nref.length && I.get(r, i % nref.length) !== nref[i % nref.length]) bad('get', n0, step);
        if (I.foldl(r, (x, z) => z + x.k, 0) !== nref.reduce((z, x) => z + x.k, 0)) bad('foldl', n0, step);
        if (!I.eq(r, I.fromArray(nref.slice()), eqf)) bad('eq', n0, step);
        a = r; ref = nref;
      }
    }
    if (name === 'mutative-freeze' && !Object.isFrozen(I.set(I.fromArray([{ k: 1 }]), 0, { k: 2 }))) bad('not frozen');
    if (name === 'mutative' && Object.isFrozen(I.set([{ k: 1 }], 0, { k: 2 }))) bad('frozen by default');
    console.log(name.padEnd(16), fails ? `FAILED ${fails}` : `ok (${calls} calls)`);
    failures += fails;
  }
  process.exitCode = failures ? 1 : 0;
} else if (mode === 'identity') {
  const rows = [];
  for (const name of ['cow', 'immer', 'mutative', 'mutative-prod', 'mutative-fast', 'mutative-freeze']) {
    const I = await adapterModule(name);
    const data = Array.from({ length: 100 }, (_, i) => ({ id: i }));
    const a = I.fromArray(data);
    const t = (f) => { try { return f() === a ? 'same' : 'new'; } catch (e) { return 'throws'; } };
    const r = { impl: name };
    r['set identical value'] = t(() => I.set(a, 3, I.get(a, 3)));
    r['swap i i'] = t(() => I.swap(a, 2, 2));
    r['map identity (draft)'] = I.mapDraft ? t(() => I.mapDraft(a, (x) => x)) : 'n/a';
    if (I.create_) {
      const c = I.create_, O = I.opts_;
      r['create, empty recipe'] = t(() => c(a, () => {}, O));
      r['create, read only'] = t(() => c(a, (d) => { let s = 0; for (let i = 0; i < d.length; i++) s += d[i].id; }, O));
      r['create, d[i] = d[i]'] = t(() => c(a, (d) => { d[3] = d[3]; }, O));
      r['create, push then pop'] = t(() => c(a, (d) => { d.push({ id: -1 }); d.pop(); }, O));
      const ints = I.fromArray([1, 2, 3]);
      r['ints, d[i] = same int'] = c(ints, (d) => { d[1] = 2; }, O) === ints ? 'same' : 'new';
    }
    const b = I.set(a, 1, { id: -1 });
    r['untouched elements'] = I.get(b, 99) === data[99] ? 'same' : 'new';
    rows.push(r);
  }
  const cols = Object.keys(rows.at(-1));
  console.log('| ' + cols.join(' | ') + ' |\n|' + cols.map(() => '---').join('|') + '|');
  for (const r of rows) console.log('| ' + cols.map((k) => r[k] ?? '—').join(' | ') + ' |');
} else if (mode === 'size') {
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
  const size = async (contents, define = { 'process.env.NODE_ENV': '"production"' }) => {
    const r = await esbuild.build({ stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', platform: 'browser',
      minify: true, treeShaking: true, write: false, define, logLevel: 'error' });
    const t = r.outputFiles[0].text;
    return `${t.length} | ${gz(t)} | **${br(t)}**`;
  };
  const typical = ['fromArray', 'toArray', 'get', 'set', 'push', 'slice', 'concat', 'map', 'filter', 'foldl', 'length', 'forEach', 'eq'];
  fs.mkdirSync('dist', { recursive: true });
  const typ = (name) => { fs.writeFileSync(`dist/src-${name}.js`, SRC[name].replaceAll('./ports/', '../ports/')); return `import { ${typical.join(', ')} } from './dist/src-${name}.js'; export default [${typical.join(', ')}];`; };
  console.log('| bundle | min | gzip | brotli |\n|---|--:|--:|--:|');
  console.log(`| \`create\` from 'mutative' (resolves to the ESM development build) | ${await size(`export { create } from 'mutative';`)} |`);
  console.log(`| \`create\` from the production build | ${await size(`export { create } from 'mutative/dist/mutative.cjs.production.min.js';`)} |`);
  console.log(`| \`produce\` from 'immer' (production) | ${await size(`export { produce } from 'immer';`)} |`);
  console.log(`| typical set: Mutative (ESM) + cow reads | ${await size(typ('mutative'))} |`);
  console.log(`| typical set: Mutative (production) + cow reads | ${await size(typ('mutative-fast'))} |`);
  console.log(`| typical set: Immer + cow reads | ${await size(typ('immer'))} |`);
  console.log(`| typical set: cow (port) | ${await size(typ('cow'))} |`);
} else if (mode === 'tables') {
  const file = process.argv[3] ?? 'results/node.jsonl';
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  // several rounds of `bench` append to one file: a cell is the median of its rounds' medians
  const groups = new Map();
  for (const r of rows) { const k = `${r.impl}/${r.op}/${r.n}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r.med); }
  const cell = new Map();
  const spread = [];
  for (const [k, ms] of groups) {
    ms.sort((a, b) => a - b);
    cell.set(k, { med: ms[ms.length >> 1] });
    // spread between rounds: the interquartile range of the round medians (rounds 2 and 4 of 5), so
    // one round disturbed by another process on the machine does not decide it
    const q = (p) => ms[Math.min(ms.length - 1, Math.floor(p * (ms.length - 1) + 0.5))];
    if (ms.length > 2) spread.push({ k, s: (q(0.75) - q(0.25)) / ms[ms.length >> 1] });
  }
  const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : (ns / 1e6).toPrecision(3) + ' ms';
  const ops = ['get', 'set', 'push', 'pop', 'swap', 'map', 'mapDraft', 'filter', 'foldl', 'batch100', 'each100'];
  for (const n of [8, 1000, 100000]) {
    console.log(`\n**n = ${n.toLocaleString('en')}**\n\n| op | ${CANDIDATES.join(' | ')} |\n|---|${CANDIDATES.map(() => '--:').join('|')}|`);
    for (const op of ops) {
      const base = cell.get(`native/${op === 'each100' ? 'batch100' : op === 'mapDraft' ? 'map' : op}/${n}`)?.med;
      console.log(`| ${op} | ` + CANDIDATES.map((c) => { const r = cell.get(`${c}/${op}/${n}`); if (!r) return '—';
        const x = base ? r.med / base : 0; return fmt(r.med) + (c !== 'native' && base ? ` (${x < 10 ? x.toFixed(1) : Math.round(x).toLocaleString('en')}×)` : ''); }).join(' | ') + ' |');
    }
  }
  const rel = rows.map((r) => (r.q3 - r.q1) / r.med).sort((a, b) => a - b);
  const wide = rows.filter((r) => (r.hi - r.lo) / r.med > 0.25).length;
  console.log(`\nsamples: ${rows.length} cell medians; within a run, median IQR/median ${(100 * rel[rel.length >> 1]).toFixed(1)} %, 90th percentile ${(100 * rel[Math.floor(rel.length * 0.9)]).toFixed(1)} %; min–max > 25 % of median: ${wide}`);
  if (spread.length) {
    spread.sort((a, b) => a.s - b.s);
    const pct = (p) => (100 * spread[Math.floor(p * (spread.length - 1))].s).toFixed(0) + ' %';
    console.log(`between rounds (IQR of the round medians / median): median ${pct(0.5)}, 90th percentile ${pct(0.9)}; worst: ${spread.slice(-6).map((x) => `${x.k} ${(100 * x.s).toFixed(0)} %`).join(', ')}`);
    for (const who of CANDIDATES) {
      const s = spread.filter((x) => x.k.startsWith(who + '/')).map((x) => x.s).sort((a, b) => a - b);
      if (s.length) console.log(`  ${who}: median ${(100 * s[s.length >> 1]).toFixed(0)} %, max ${(100 * s.at(-1)).toFixed(0)} %`);
    }
  }
} else {
  console.log('usage: node mutative.mjs test | identity | size | bench [core] [candidate…] | tables [file]');
}
