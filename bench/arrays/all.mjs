// Every sequence candidate on every scenario, in one batch (research/46). The one entry point of
// bench/arrays; README.md lists the modes and what each one writes.
//
//   node all.mjs                       the quick default run: one round, a few sizes, ~3 minutes
//   FULL=1 node all.mjs <mode>         the full sweep of report 46 (every size, 300 ms warm-up)
//   node all.mjs build                 compile the three programs with ../../zig-out/bin/beni
//   node all.mjs test                  the differential test: every candidate, every scenario
//   node all.mjs bench [rounds]        Node, one pinned process per (candidate, scenario, style, size)
//   node all.mjs chrome [rounds]       the same bundles in headless Chrome ($CHROME), one page each
//   node all.mjs mem | stack | size    memory, stack safety at 100 000, brotli bytes
//   node all.mjs tables [engine]       the report's tables from results/
//   node all.mjs tables-e1tp           research/46 §11: E1tp against E1t, cons and the best other
//
// Three compiled programs, each byte-identical for every candidate; only the sibling differs:
//
//   arr    §15's six array scenarios (scenarios/src) over scenarios/Array.beni, beni over a
//          first-order `Array` sibling. One style: they are indexed code. `List` stays cons cells.
//   elm    the list scenarios of §16 as an Elm programmer writes them (lists/src) and §3's single
//          operations the same way (ops/elm), over TODAY's core/List. Idiomatic for cons cells.
//   first  the same scenarios array-first (lists/first, ops/first), over §17's array-first core/List
//          (lists/first-core). Idiomatic for every array-like candidate.
//
// elm and first are compiled once and their list syntax rewritten into calls (lib/rewrite.js), so
// `[]`, `::` and `x :: rest` mean whatever the candidate's sibling says. Each candidate is
// seq/<core>.js, turned into every sibling by seq/surface.js.
import * as esbuild from 'esbuild';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { rewriteModule } from './lib/rewrite.js';

const here = path.dirname(fileURLToPath(import.meta.url));
process.chdir(here);
const repo = path.resolve(here, '../..');
const OUT = path.join(here, 'dist/all');
const beniBin = path.join(repo, 'zig-out/bin/beni');
// The three programs below are cons-cell code with their list syntax rewritten into calls
// (lib/rewrite.js), which only a compiler from before the array-backed `List` emits: since the
// flip, `BENI_BEFORE` names such a compiler (and `BENI_BEFORE_CORE` its core, by default the
// `core/` two directories above its `zig-out/bin`), so report 46's figures still reproduce. The
// `beni` candidate is this repository's own compiler and core, unrewritten.
//
// Without `BENI_BEFORE` the two rewritten list programs are not built at all: this repository's
// compiler writes a list as an array, reads a walked list by a scalar view (`List$base`,
// `List$offset`, `List$view`, which `lists/first-core` does not declare) and builds by `push`,
// none of which lib/rewrite.js can turn into a candidate's calls. The run is then §15's array
// scenarios for every candidate (`arr` names `List` only as the shipped one) and the list programs
// for `beni` alone, `beni` the reference. Report 46's list tables come from a checkout of the
// commit it was measured at, whose sources the compiler of that day parses.
const before = Boolean(process.env.BENI_BEFORE);
const beniBefore = process.env.BENI_BEFORE ? path.resolve(process.env.BENI_BEFORE) : beniBin;
const coreBefore = process.env.BENI_BEFORE_CORE ? path.resolve(process.env.BENI_BEFORE_CORE)
  : process.env.BENI_BEFORE ? path.resolve(beniBefore, '../../../core') : path.join(repo, 'core');
const mode = process.argv[2];

// ---------------------------------------------------------------------------------------------
// The candidates. `idiom` is the style written for the representation: Elm-style (cons and reverse)
// for the cons list, array-first (push at the end) for everything else.
export const CANDS = {
  native: { core: 'native', label: 'native mut' },
  nativecow: { core: 'nativecow', label: 'native CoW' },
  cow: { core: 'cow' },
  trie: { core: 'trie' },
  hybrid1024: { core: 'hybrid1024', define: { HYB_T: '1024' } },
  adaptive256: { core: 'adaptive', define: { ADA_T: '256' } },
  E1: { core: 'e1', define: { ADA_T: '256' }, full: true },
  E1t: { core: 'e1t', full: true },
  // E1t plus a claimable head and a radix offset: cheap `x :: xs` (research/46 §11)
  E1tp: { core: 'e1tp', full: true },
  cons: { core: 'cons', idiom: 'elm', full: true },
  immutable: { core: 'immutable', label: 'Immutable.js' },
  funkia: { core: 'funkia' },
  mori: { core: 'mori' },
  mutative: { core: 'mutative', label: 'Mutative' },
  immer: { core: 'immer', label: 'Immer' },
  elm: { core: 'elm', label: 'Elm Array' },
  // research/40's hand-minified sibling is the adaptive array at T = 1 024 (not E1t): it is checked
  // against that array on the array scenarios, the only surface it has
  adaptive1024: { core: 'adaptive', define: { ADA_T: '1024' }, only: 'arr', check: true },
  'adaptive-min': { sibling: 'min/array.min.js', only: 'arr', check: true },
  // the rewrite of the list syntax must change nothing but the representation: the cons list over
  // beni's own output, unrewritten, on the Elm-style programs, against `cons` over the rewrite
  'cons-raw': { core: 'cons', idiom: 'elm', full: true, raw: true, only: 'elm', check: true },
  // the shipped array-backed List: both list programs compiled by this repository's compiler over
  // its own core/List, nothing rewritten (plans/list-arrays.md, the flip)
  beni: { beni: true, full: true, only: 'list' },
};
const MAIN = Object.keys(CANDS).filter((c) => !CANDS[c].check);
const idiom = (c) => CANDS[c].idiom ?? 'first';
const label = (c) => CANDS[c].label ?? c;
const pick = (list) => (process.env.CANDS ? process.env.CANDS.split(',') : list);

// the scenario groups and their sizes
const ARR_SC = ['table', 'decoded', 'grid', 'build', 'history', 'interop'];
// FULL=1 is the whole sweep (report 46's tables); the default is a quick run, a few minutes on 8
// cores: the sizes that separate the candidates, and §15's scenarios up to 100 000 elements
const FULL_RUN = process.env.FULL === '1';
const SIZES = FULL_RUN ? { list: [1000, 10000, 100000], ops: [8, 1000, 100000] } : { list: [10000], ops: [1000] };
const ARR_MAX = FULL_RUN ? Infinity : 10000;
if (!FULL_RUN) { process.env.WARM_MS ??= '100'; process.env.SHORT_MS ??= '3000'; process.env.HARD_MS ??= '10000'; }
const STYLES = ['first', 'elm'];

// ---------------------------------------------------------------------------------------------
// build

function beni(args, bin = beniBefore) {
  const r = spawnSync(bin, ['build', '--platform=node', '--library', '--no-cache', ...args], { encoding: 'utf8' });
  if (r.status !== 0) { process.stdout.write(r.stdout); process.stderr.write(r.stderr); throw new Error('beni build failed'); }
}
const mjsFiles = (dir) => [...fs.readdirSync(dir).filter((f) => f.endsWith('.mjs')), ...fs.readdirSync(`${dir}/_core`).filter((f) => f.endsWith('.mjs')).map((f) => `_core/${f}`)];
function copySources(dirs, to) {
  fs.rmSync(to, { recursive: true, force: true });
  fs.mkdirSync(to, { recursive: true });
  for (const d of dirs) for (const f of fs.readdirSync(d).filter((f) => f.endsWith('.beni'))) fs.copyFileSync(`${d}/${f}`, `${to}/${f}`);
  return fs.readdirSync(to).map((f) => `${to}/${f}`);
}
function build() {
  if (!fs.existsSync(beniBin)) throw new Error('build beni first: `zig build` at the repository root');
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });
  // arr: core plus the experimental Array of §15
  fs.cpSync(coreBefore, `${OUT}/core-arr`, { recursive: true });
  for (const f of ['Array.beni', 'Array.js']) fs.copyFileSync(`scenarios/${f}`, `${OUT}/core-arr/${f}`);
  const arrSrc = copySources(['scenarios/src'], `${OUT}/src-arr`);
  beni([`--core-root=${OUT}/core-arr`, `--root=${OUT}/src-arr`, `--out=${OUT}/arr`, ...arrSrc]);
  // beni: both list programs as they are, over the shipped core
  const elmSrc = copySources(['lists/src', 'ops/elm'], `${OUT}/src-elm`);
  beni([`--root=${OUT}/src-elm`, `--out=${OUT}/elm-beni`, ...elmSrc], beniBin);
  const firstSrcBeni = copySources(['lists/first', 'ops/first'], `${OUT}/src-first-beni`);
  beni([`--root=${OUT}/src-first-beni`, `--out=${OUT}/first-beni`, ...firstSrcBeni], beniBin);
  if (!before) {
    console.log(`built ${path.relative(here, OUT)}/{arr,elm-beni,first-beni} with ${path.relative(here, beniBin)}; no BENI_BEFORE, so not the rewritten list programs`);
    return;
  }
  // elm: the cons-cell core
  beni([`--core-root=${coreBefore}`, `--root=${OUT}/src-elm`, `--out=${OUT}/elm-raw`, ...elmSrc]);
  // first: core with the array-first List
  fs.cpSync(coreBefore, `${OUT}/core-first`, { recursive: true });
  for (const f of ['List.beni', 'List.js']) fs.copyFileSync(`lists/first-core/${f}`, `${OUT}/core-first/${f}`);
  const firstSrc = copySources(['lists/first', 'ops/first'], `${OUT}/src-first`);
  beni([`--core-root=${OUT}/core-first`, `--root=${OUT}/src-first`, `--out=${OUT}/first-raw`, ...firstSrc]);
  // the list syntax of both list programs, core/List included, as calls
  for (const t of ['elm', 'first']) {
    fs.cpSync(`${OUT}/${t}-raw`, `${OUT}/${t}`, { recursive: true });
    for (const f of mjsFiles(`${OUT}/${t}-raw`)) {
      if (f.endsWith('.foreign.mjs')) continue;
      fs.writeFileSync(`${OUT}/${t}/${f}`, rewriteModule(fs.readFileSync(`${OUT}/${t}-raw/${f}`, 'utf8')));
    }
  }
  console.log(`built ${path.relative(here, OUT)}/{arr,elm,first} with ${path.relative(here, beniBefore)}, {elm,first}-beni with ${path.relative(here, beniBin)}`);
}

// ---------------------------------------------------------------------------------------------
// bundles: one IIFE per (candidate, program), so a process sees one sibling and its call sites stay
// monomorphic (research/38 §1)

function plugin(cand, prog) {
  const c = CANDS[cand];
  if (c.beni) {
    // the shipped List: its own sibling, and the hooks read it by the reader protocol
    const tree = path.join(OUT, `${prog}-beni`);
    return {
      name: 'beni-own',
      setup(b) {
        b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
        b.onResolve({ filter: /^(list-rt|list-syntax)$/ }, () => ({ path: path.join(here, 'lists/beni-rt.mjs') }));
      },
    };
  }
  const tree = path.join(OUT, prog === 'elm-raw' ? 'elm-raw' : prog);
  let sibling = c.sibling ? path.join(here, c.sibling) : path.join(here, 'seq/surface.js');
  if (c.sibling && !before) {
    // a hand-written sibling's `fromList`/`toList` speak cons cells; over the shipped List they go
    // through its own `fromJs`/`toJs` instead (seq/surface.js does the same)
    const shim = path.join(OUT, `sibling-${cand}.mjs`);
    fs.writeFileSync(shim, `export * from ${JSON.stringify(sibling)};
import { fromJs, toJs } from ${JSON.stringify(sibling)};
export const fromList = (l) => fromJs((Array.isArray(l) ? l : l.$plain()).slice());
export const toList = (a) => toJs(a).slice();
`);
    sibling = shim;
  }
  const basics = path.join(OUT, `basics-${prog}.mjs`);
  if (prog !== 'arr') fs.writeFileSync(basics, `export * from ${JSON.stringify(path.join(tree, '_core/Basics.foreign.mjs'))};\nexport { basicsAppend as append } from 'list-rt';\n`);
  return {
    name: 'beni-seq',
    setup(b) {
      b.onResolve({ filter: /^seq-core$/ }, () => ({ path: path.join(here, `seq/${c.core}.js`) }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
      b.onResolve({ filter: /^array-sibling$|\/Array\.foreign\.mjs$/ }, () => ({ path: sibling }));
      if (prog === 'arr') return; // §15's `List` stays today's cons cells
      b.onResolve({ filter: /^(list-rt|list-syntax)$|\/List\.foreign\.mjs$/ }, () => ({ path: sibling }));
      b.onResolve({ filter: /^\.\/Basics\.foreign\.mjs$/ }, (a) => (a.importer === basics || !a.importer.endsWith('Basics.mjs') ? undefined : { path: basics }));
    },
  };
}
const ENTRY = {
  arr: `import { run, test, SCENARIOS } from './scenarios/harness.js';
const P = globalThis.__P ?? JSON.parse(process.argv[2]);
if (P.mode === 'test') console.log(test());
else if (P.mode === 'labels') console.log(JSON.stringify(Object.entries(SCENARIOS).flatMap(([sc, f]) => f().map(([op, n]) => [sc, op, n]))));
else run(P.cand, [P.sc], [], [\`\${P.op}@\${P.n}\`]);`,
  list: `import { run, stack, mem, test, cells } from './lists/harness.js';
import { opsCells, opsTest } from './ops/harness.js';
const P = globalThis.__P ?? JSON.parse(process.argv[2]);
const of = P.group === 'ops' ? opsCells : cells;
if (P.mode === 'test') { console.log(test()); console.log(opsTest()); }
else if (P.mode === 'labels') console.log(JSON.stringify({ list: cells(8).map((c) => c[1]), ops: opsCells(8).map((c) => c[1]) }));
else if (P.mode === 'stack') stack(P.cand, P.n, [], of, [P.op]);
else if (P.mode === 'mem') mem(P.cand, P.op, P.n, of);
else run(P.cand, P.n, [], of, [P.op]);`,
};
const defines = (cand, first) => ({ 'process.env.NODE_ENV': '"production"', ADA_T: '256', HYB_T: '1024', STYLE_FIRST: String(first), LIST_CONS: String(before),
  SEQ_FULL: String(!!CANDS[cand]?.full), ...(CANDS[cand]?.define ?? {}) });
async function bundle(cand, prog, extra = {}) {
  const c = CANDS[cand], file = path.join(OUT, 'b', `${cand}-${prog}.js`);
  await esbuild.build({
    stdin: { contents: ENTRY[prog === 'arr' ? 'arr' : 'list'], resolveDir: here, loader: 'js' },
    bundle: true, platform: 'neutral', target: 'es2023', format: 'iife', outfile: file, mainFields: ['module', 'main'], logLevel: 'error',
    define: defines(cand, prog === 'first'),
    plugins: [plugin(cand, c.raw && prog === 'elm' ? 'elm-raw' : prog)], ...extra,
  });
  return file;
}
const bundled = new Map();
const bundleOnce = (cand, prog) => { const k = `${cand}-${prog}`; if (!bundled.has(k)) bundled.set(k, bundle(cand, prog)); return bundled.get(k); };

// ---------------------------------------------------------------------------------------------
// cells and chains. Every cell runs in a process (or a browser context) of its own, so its figure
// does not depend on which other cells ran before it — which differs between candidates, because
// the cells that fail differ. A chain is one cell at its sizes in increasing order: a cell over 1 s
// a call, or one that failed, is not run at the next size (it would be over 10 s).

async function labels() {
  const f = path.join(OUT, 'labels.json');
  if (fs.existsSync(f)) return JSON.parse(fs.readFileSync(f, 'utf8'));
  const run = async (prog, cand = 'cow') => JSON.parse(spawnSync(process.execPath, ['--stack-size=4000', await bundleOnce(cand, prog), JSON.stringify({ mode: 'labels' })], { encoding: 'utf8', maxBuffer: 1 << 26 }).stdout);
  const arr = await run('arr'), l = await run('first', before ? 'cow' : 'beni');
  const res = { arr, list: l.list, ops: l.ops };
  fs.writeFileSync(f, JSON.stringify(res));
  return res;
}
function chains(cands, L) {
  const out = [];
  for (const cand of cands) {
    if (CANDS[cand].only === 'elm') {
      if (!before) continue;
      for (const group of ['list', 'ops']) for (const op of L[group]) out.push({ cand, group, style: 'elm', prog: 'elm', op, sizes: SIZES[group] });
      continue;
    }
    const byOp = new Map();
    for (const [sc, op, n] of L.arr.filter((c) => c[2] <= ARR_MAX)) { const k = `${sc}|${op}`; if (!byOp.has(k)) byOp.set(k, []); byOp.get(k).push(n); }
    if (CANDS[cand].only !== 'list') for (const [k, ns] of byOp) { const [sc, op] = k.split('|'); out.push({ cand, group: 'arr', style: 'index', prog: 'arr', sc, op, sizes: ns.sort((a, b) => a - b) }); }
    if (CANDS[cand].only === 'arr') continue;
    if (!before && !CANDS[cand].beni) continue; // the rewritten list programs need BENI_BEFORE
    for (const group of ['list', 'ops']) for (const style of STYLES) for (const op of L[group]) out.push({ cand, group, style, prog: style, op, sizes: SIZES[group] });
  }
  return out;
}

// cells a candidate that writes in place cannot run honestly: it would read a version it already
// overwrote. For the list programs they are the ones whose differential check failed
// (dist/all/needs-persistence.json, written by `test`); for the single operations, the writes
// repeated on one input (`, first`); for §15's scenarios they are named here.
const NATIVE_ARR = [/\/first$/, /^history\//, /\/edited$/, /^decoded\/sort/];
let persistCache = null;
function needsPersistence(ch) {
  if (ch.cand !== 'native') return false;
  if (ch.group === 'arr') return NATIVE_ARR.some((re) => re.test(ch.op));
  if (ch.group === 'ops') return ch.op.endsWith(', first');
  if (!persistCache) {
    const f = path.join(OUT, 'needs-persistence.json');
    if (!fs.existsSync(f)) throw new Error('run `node all.mjs test` first: it names the cells native cannot run');
    persistCache = JSON.parse(fs.readFileSync(f, 'utf8'));
  }
  return (persistCache[`${ch.style}|list`] ?? []).includes(ch.op);
}

// ---------------------------------------------------------------------------------------------
// cores: pick free physical cores (the machine is shared; other benchmarks may be running), one
// worker per core, each pinned

function cpuTimes() {
  const m = new Map();
  for (const l of fs.readFileSync('/proc/stat', 'utf8').split('\n')) {
    const r = /^cpu(\d+) (.*)/.exec(l);
    if (!r) continue;
    const v = r[2].trim().split(/\s+/).map(Number);
    m.set(+r[1], { idle: v[3] + v[4], total: v.reduce((a, b) => a + b, 0) });
  }
  return m;
}
async function pickCores(k) {
  if (process.env.CORES) return process.env.CORES.split(',');
  const a = cpuTimes();
  await new Promise((r) => setTimeout(r, 2000));
  const b = cpuTimes(), n = b.size, phys = n / 2;
  const idle = (i) => (b.get(i).idle - a.get(i).idle) / Math.max(1, b.get(i).total - a.get(i).total);
  const free = [];
  for (let i = 1; i < phys; i++) free.push({ i, idle: Math.min(idle(i), idle(i + phys)) });
  free.sort((x, y) => y.idle - x.idle);
  const chosen = free.filter((f) => f.idle > 0.9).slice(0, k).map((f) => String(f.i));
  console.log(`cores ${chosen.join(',')} (idle ${free.slice(0, k).map((f) => f.idle.toFixed(2)).join(', ')}); load ${loadavg()}`);
  return chosen;
}
const loadavg = () => fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');

// ---------------------------------------------------------------------------------------------
// one cell under Node, pinned, with a watchdog: a process that runs past HARD_MS is killed

const HARD_MS = +(process.env.HARD_MS ?? 45000);
const WARM_MS = process.env.WARM_MS ?? '300'; // a fresh process per cell starts with cold core functions
function runNode(file, P, core, defaultStack = false, limit = HARD_MS) {
  return new Promise((resolve) => {
    const args = [...(defaultStack ? [] : ['--expose-gc', '--stack-size=4000']), '--max-old-space-size=4096', file, JSON.stringify(P)];
    const child = spawn('taskset', ['-c', core, process.execPath, ...args], { env: { ...process.env, CAP_MS: '3000', WARM_MS } });
    let out = '', err = '', killed = null;
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { err += d; if (err.length > 20000) err = err.slice(-10000); });
    const dog = setTimeout(() => { killed = 'timeout'; child.kill('SIGKILL'); }, limit);
    child.on('close', (code) => {
      clearTimeout(dog);
      const lines = out.split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l)).filter((l) => !l.start);
      resolve({ code, lines, err, killed });
    });
  });
}
const whyDied = (r) => r.killed ?? (r.err.match(/heap out of memory|Ineffective mark-compacts|Maximum call stack|[A-Z][a-z]+Error[^\n]*/) ?? [`exit ${r.code}`])[0];

// a chain under one engine: `once(n)` runs the cell at one size and returns its lines, or a failure
// A cell that could be slow at the next size — over PREDICT_S a call if it grew quadratically from
// this one — runs there with a short watchdog, SHORT_MS, instead of HARD_MS: its first call is the
// probe, and a cell killed by it is recorded as over SHORT_MS. A cell that failed is not run at the
// next size.
const PREDICT_S = +(process.env.PREDICT_S ?? 3), SHORT_MS = +(process.env.SHORT_MS ?? 8000);
async function runChain(ch, emit, once) {
  let blocked = null, limit = HARD_MS;
  for (let i = 0; i < ch.sizes.length; i++) {
    const n = ch.sizes[i], next = ch.sizes[i + 1];
    const base = { impl: ch.cand, sc: ch.sc, op: ch.op, n };
    if (needsPersistence(ch)) { emit({ ...base, skipped: 'needs persistence' }); continue; }
    if (blocked) { emit({ ...base, skipped: blocked }); continue; }
    const r = await once(n, limit);
    for (const l of r.lines) emit(l);
    const cell = r.lines.find((l) => l.op === ch.op && l.n === n);
    if (!cell || cell.nodeFlag) { if (!cell) emit({ ...base, crashed: r.why === 'timeout' ? `timeout ${limit / 1000} s` : r.why }); blocked = 'failed at the size before'; continue; }
    if (cell.overflow) { blocked = 'overflowed the stack at the size before'; continue; }
    limit = next && cell.med * (next / n) ** 2 > PREDICT_S * 1e9 ? SHORT_MS : HARD_MS;
  }
}
const P0 = (ch, n) => (ch.group === 'arr' ? { mode: 'bench', cand: ch.cand, sc: ch.sc, op: ch.op, n } : { mode: 'bench', cand: ch.cand, group: ch.group, op: ch.op, n });
async function chainNode(ch, core, round, sink) {
  const file = await bundleOnce(ch.cand, ch.prog);
  const emit = (l) => sink({ ...l, engine: 'node', group: ch.group, style: ch.style, round, core, load: loadavg() });
  // a cell that failed in an earlier round (killed, heap, stack) keeps that round's flag
  const fails = round > 1 ? nodeFailures() : new Map();
  await runChain(ch, emit, async (n, limit) => {
    const flag = fails.get(`${ch.cand}|${ch.group}|${ch.style}|${ch.op}|${n}`);
    if (flag && flag !== 'n/p' && flag !== 'skip') return { lines: [{ impl: ch.cand, sc: ch.sc, op: ch.op, n, nodeFlag: flag }], why: flag };
    const r = await runNode(file, P0(ch, n), core, false, limit);
    return { lines: r.lines, why: whyDied(r) };
  });
}

// a pool of workers over the chains, one per core
async function pool(jobs, cores, work) {
  let next = 0, done = 0;
  const t0 = Date.now();
  await Promise.all(cores.map(async (core) => {
    while (next < jobs.length) {
      const j = jobs[next++];
      await work(j, core);
      done++;
      if (done % 200 === 0 || done === jobs.length) console.log(`  ${done}/${jobs.length}, ${((Date.now() - t0) / 60000).toFixed(1)} min, load ${loadavg()}`);
    }
  }));
}
function shuffled(xs, seed) {
  const a = xs.slice();
  for (let i = a.length - 1; i > 0; i--) { seed = (seed * 1103515245 + 12345) & 0x7fffffff; const j = seed % (i + 1); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

// ---------------------------------------------------------------------------------------------
// Chrome: one browser per worker, pinned to its core; one fresh browser context (a fresh renderer
// process) per cell, fed the same bundle. A cell Node could not time (overflow, heap, timeout,
// skipped) is not run here; it keeps Node's flag.

async function chainChrome(ref, ch, core, round, sink) {
  const src = fs.readFileSync(await bundleOnce(ch.cand, ch.prog), 'utf8');
  const fails = nodeFailures();
  const emit = (l) => sink({ ...l, engine: 'chrome', group: ch.group, style: ch.style, round, core });
  await runChain(ch, emit, async (n, limit) => {
    const flag = fails.get(`${ch.cand}|${ch.group}|${ch.style}|${ch.op}|${n}`);
    if (flag) return { lines: [{ impl: ch.cand, sc: ch.sc, op: ch.op, n, nodeFlag: flag }], why: flag };
    return chromeRun(ref, core, src, P0(ch, n), limit);
  });
}
// the cells Node could not time, with their flag (SO, OOM, timeout, skip, n/p)
let nodeFailCache = null;
function nodeFailures() {
  if (nodeFailCache) return nodeFailCache;
  const s = new Map();
  for (const r of load('results/all-node.jsonl')) if (r.med === undefined && r.bytes === undefined && r.op !== undefined) s.set(`${r.impl}|${r.group}|${r.style}|${r.op}|${r.n}`, flagOf(r));
  return (nodeFailCache = s);
}
const flagOf = (r) => r.nodeFlag ?? (r.overflow ? 'SO' : r.skipped === 'needs persistence' ? 'n/p' : r.skipped ? 'skip' : /^timeout/.test(r.crashed ?? '') ? '> ' + (r.crashed.split(' ')[1] ?? HARD_MS / 1000) + ' s'
  : r.crashed ? (/memory|mark-compacts|crashed/.test(r.crashed) ? 'OOM' : /stack/.test(r.crashed) ? 'SO' : 'failed') : '?');
async function chromeRun(ref, core, src, P, limit = HARD_MS) {
  const { launch } = await import('../ui/lib/cdp.mjs');
  if (!ref.browser) ref.browser = await launch({ taskset: core, chrome: process.env.CHROME });
  const br = ref.browser;
  const { browserContextId } = await br.send('Target.createBrowserContext');
  const { targetId } = await br.send('Target.createTarget', { url: 'about:blank', browserContextId });
  const { sessionId } = await br.send('Target.attachToTarget', { targetId, flatten: true });
  await br.send('Runtime.enable', {}, sessionId);
  await br.send('Inspector.enable', {}, sessionId).catch(() => {});
  const lines = [];
  let crashed = null;
  const off = br.on((msg) => {
    if (msg.sessionId !== sessionId) return;
    if (msg.method === 'Runtime.consoleAPICalled') {
      for (const t of msg.params.args.map((a) => a.value).join(' ').split('\n')) if (t.startsWith('{')) { const l = JSON.parse(t); if (!l.start) lines.push(l); }
    } else if (msg.method === 'Inspector.targetCrashed') crashed = 'renderer crashed (out of memory)';
  });
  const expression = `globalThis.process = { env: { CAP_MS: '3000', WARM_MS: '${WARM_MS}' } }; globalThis.__P = ${JSON.stringify(P)};\n${src}\n;1`;
  const evalP = br.send('Runtime.evaluate', { expression, returnByValue: true }, sessionId)
    .then((r) => (r.exceptionDetails ? `exception: ${(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text).split('\n')[0]}` : null), (e) => `cdp: ${e.message}`);
  const t0 = Date.now();
  let result, stuck = false;
  for (;;) {
    const t = await Promise.race([evalP.then((x) => ({ x })), new Promise((r) => setTimeout(() => r(null), 250))]);
    if (t) { result = t.x; break; }
    if (crashed) { result = crashed; break; }
    if (Date.now() - t0 > limit) { stuck = true; result = 'timeout'; break; }
  }
  off();
  if (stuck || crashed) {
    // a renderer that does not answer cannot be closed politely: restart the browser
    try { await br.close(); } catch {}
    ref.browser = null;
  } else {
    try { await br.send('Target.disposeBrowserContext', { browserContextId }); } catch {}
  }
  return { lines, why: result ?? 'no result' };
}

// ---------------------------------------------------------------------------------------------

async function modeTest() {
  fs.mkdirSync('results', { recursive: true });
  const run = async (cand, prog) => {
    const file = await bundleOnce(cand, prog);
    const r = spawnSync(process.execPath, ['--stack-size=4000', '--max-old-space-size=4096', file, JSON.stringify({ mode: 'test' })], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) return { fail: whyDied({ err: r.stderr, code: r.status }) + ' ' + r.stderr.split('\n').filter((l) => /Error/.test(l)).slice(0, 2).join(' | ') };
    return { lines: r.stdout.trim().split('\n') };
  };
  const cands = pick(Object.keys(CANDS));
  const report = [], identity = [];
  let bad = 0;
  const needs = {};
  for (const prog of ['arr', 'elm', 'first']) {
    // one reference for both list programs: cons cells, or without BENI_BEFORE the shipped List
    const ref = await run(prog === 'arr' ? 'cow' : before ? 'cons' : 'beni', prog === 'arr' ? 'arr' : 'elm');
    if (ref.fail) throw new Error(`the reference failed: ${ref.fail}`);
    for (const cand of cands) {
      const only = CANDS[cand].only;
      if (only && only !== prog && !(only === 'list' && prog !== 'arr')) continue;
      if (!before && prog !== 'arr' && !CANDS[cand].beni) continue; // not built without BENI_BEFORE
      const o = await run(cand, prog);
      if (o.fail) { report.push(`${prog} ${cand}: FAILED ${o.fail}`); bad++; continue; }
      // identity lines (§7: does a no-op return its input?) are a property, reported, not a result
      const isIdentity = (l) => / identity /.test(l) || l.includes('| set, same value |');
      identity.push(`${prog} ${cand}: ${o.lines.filter(isIdentity).map((l) => l.replace(/ \| input unchanged$/, '').split(/ \| | identity /).slice(-1)[0]).join(' ')}`);
      const diff = o.lines.map((l, i) => [l, ref.lines[i]]).filter(([a, b]) => a !== b && !isIdentity(a));
      if (o.lines.length !== ref.lines.length) diff.push(['length', `${o.lines.length} vs ${ref.lines.length}`]);
      if (cand === 'native') {
        // the list cells whose results differ need persistence and are skipped; the single operations
        // measure native's in-place writes on purpose (ops/harness.js keeps each on its own array)
        const ops = [...new Set(diff.map(([l]) => l.split(' | ')).filter((p) => p.length > 3 && !p[0].startsWith('0 ')).map((p) => p[1]))];
        if (prog !== 'arr') needs[`${prog}|list`] = ops;
        report.push(`${prog} ${cand}: ${o.lines.length} checks, ${diff.length} differ (it writes in place)${prog !== 'arr' ? `; ${ops.length} list cells need persistence and are skipped: ${ops.join('; ')}` : '; the cells that need persistence are named in all.mjs'}`);
        continue;
      }
      if (diff.length) { report.push(`${prog} ${cand}: ${diff.length} of ${o.lines.length} checks DIFFER, e.g. ${diff.slice(0, 3).map(([a, b]) => `${a}  ≠  ${b}`).join(' ;; ')}`); bad++; continue; }
      report.push(`${prog} ${cand}: ${o.lines.length} checks, all agree`);
    }
  }
  fs.writeFileSync(path.join(OUT, 'needs-persistence.json'), JSON.stringify(needs, null, 1));
  report.push('', 'identity of no-op writes (§7), per check in order; not compared:', ...identity);
  fs.writeFileSync('results/all-test.txt', report.join('\n') + '\n');
  console.log(report.join('\n'));
  console.log(bad ? `${bad} FAILED` : 'every persistent candidate agrees with the reference on every check');
  process.exitCode = bad ? 1 : 0;
}

async function modeBench(engine) {
  const rounds = +(process.argv[3] ?? 1);
  const cands = pick(Object.keys(CANDS));
  const L = await labels();
  const cores = await pickCores(+(process.env.WORKERS ?? 6));
  const file = process.env.RESULTS ?? `results/all-${FULL_RUN ? '' : 'quick-'}${engine}.jsonl`;
  fs.mkdirSync('results', { recursive: true });
  const sink = (l) => fs.appendFileSync(file, JSON.stringify(l) + '\n');
  for (const ch of chains(cands, L)) await bundleOnce(ch.cand, ch.prog); // bundle before any timing
  const only = process.env.GROUP ? process.env.GROUP.split(',') : null; // not GROUPS: bash owns that name
  const r0 = +(process.env.ROUND0 ?? 1);
  for (let r = r0; r < r0 + rounds; r++) {
    const jobs = shuffled(chains(cands, L).filter((c) => !only || only.includes(c.group)), 7919 * r);
    console.log(`${engine} round ${r}: ${jobs.length} chains on cores ${cores.join(',')}, load ${loadavg()}`);
    if (engine === 'node') await pool(jobs, cores, (ch, core) => chainNode(ch, core, r, sink));
    else {
      const refs = new Map(cores.map((c) => [c, {}]));
      await pool(jobs, cores, (ch, core) => chainChrome(refs.get(core), ch, core, r, sink));
      for (const ref of refs.values()) if (ref.browser) await ref.browser.close();
    }
  }
}

// memory: one process per (candidate, cell) at n = 100 000, each candidate on its own style; a cell
// that Node could not time there, or that took over 3 s a call, is left out
async function modeMem() {
  const cands = pick(MAIN);
  const L = await labels();
  const cores = await pickCores(+(process.env.WORKERS ?? 6));
  const out = 'results/all-mem.jsonl';
  const timed = timedCells(), n = 100000;
  const ok = (cand, group, style, op) => timed.some((r) => r.impl === cand && r.group === group && r.style === style && r.op === op && r.n === n && r.med < 3e9);
  const jobs = [];
  for (const cand of cands) {
    const style = idiom(cand);
    for (const op of L.list) jobs.push({ cand, style, group: 'list', op });
    for (const op of ['fromArray', 'map', 'filter', 'set, threaded', 'push, threaded', 'concat']) jobs.push({ cand, style, group: 'ops', op });
  }
  for (const j of jobs) await bundleOnce(j.cand, j.style);
  await pool(jobs, cores, async (j, core) => {
    if (!ok(j.cand, j.group, j.style, j.op)) { fs.appendFileSync(out, JSON.stringify({ impl: j.cand, op: j.op, n, group: j.group, style: j.style, err: 'not timed at 100 000' }) + '\n'); return; }
    const file = await bundleOnce(j.cand, j.style);
    const r = await runNode(file, { mode: 'mem', cand: j.cand, group: j.group, op: j.op, n }, core);
    const rec = r.lines[0] ?? { impl: j.cand, op: j.op, n, err: whyDied(r) };
    fs.appendFileSync(out, JSON.stringify({ ...rec, group: j.group, style: j.style }) + '\n');
  });
}

// stack safety: every cell of the list and single-operation programs once at 100 000, in both
// styles, on Node's DEFAULT stack (no --stack-size); a cell whose timed call took over 3 s at
// 100 000, or was not timed there for another reason than the stack, is left out
async function modeStack() {
  const cands = pick(MAIN);
  const L = await labels();
  const out = 'results/all-stack.jsonl';
  const fails = nodeFailures(), timed = timedCells(), n = 100000;
  const jobs = [];
  for (const cand of cands) for (const style of STYLES) for (const group of ['list', 'ops']) for (const op of L[group]) jobs.push({ cand, style, group, op });
  const cores = await pickCores(+(process.env.WORKERS ?? 6));
  for (const j of jobs) await bundleOnce(j.cand, j.style);
  await pool(jobs, cores, async (j, core) => {
    const key = `${j.cand}|${j.group}|${j.style}|${j.op}|${n}`, flag = fails.get(key);
    const t = timed.find((r) => `${r.impl}|${r.group}|${r.style}|${r.op}|${r.n}` === key);
    const rec = { impl: j.cand, op: j.op, n, group: j.group, style: j.style };
    if ((flag && flag !== 'SO') || (t && t.med > 3e9)) { fs.appendFileSync(out, JSON.stringify({ ...rec, stack: `not run (${flag ?? 'over 3 s'})` }) + '\n'); return; }
    if (j.cand === 'native' && needsPersistence({ cand: j.cand, group: j.group, style: j.style, op: j.op })) { fs.appendFileSync(out, JSON.stringify({ ...rec, stack: 'not run (n/p)' }) + '\n'); return; }
    const r = await runNode(await bundleOnce(j.cand, j.style), { mode: 'stack', cand: j.cand, group: j.group, op: j.op, n }, core, true);
    const l = r.lines.find((x) => x.op === j.op);
    fs.appendFileSync(out, JSON.stringify({ ...rec, stack: l ? l.stack : whyDied(r) }) + '\n');
  });
}
let timedCache = null;
function timedCells() {
  if (!timedCache) timedCache = load('results/all-node.jsonl').filter((r) => r.med !== undefined);
  return timedCache;
}

// ---------------------------------------------------------------------------------------------
// bytes: esbuild --minify, tree-shaken, brotli 11

async function modeSize() {
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
  // the whole-surface programs: every public function of each design, from lists/surface
  const surf = `${OUT}/surface`;
  fs.rmSync(surf, { recursive: true, force: true });
  beni([`--core-root=${OUT}/core-first`, '--root=lists/surface/E1', `--out=${surf}/first-raw`, 'lists/surface/E1/Surface.beni']);
  beni([`--core-root=${OUT}/core-arr`, '--root=lists/surface/A', `--out=${surf}/A`, 'lists/surface/A/Surface.beni']);
  fs.cpSync(`${surf}/first-raw`, `${surf}/first`, { recursive: true });
  for (const f of mjsFiles(`${surf}/first-raw`)) if (!f.endsWith('.foreign.mjs')) fs.writeFileSync(`${surf}/first/${f}`, rewriteModule(fs.readFileSync(`${surf}/first-raw/${f}`, 'utf8')));
  const SIB = 'cons, eq, compare, length, unsafeGet, set, push, pop, slice, append, insertAt, removeAt, swap, builder, add, done, basicsAppend, $nil, $isNil, $isCons, $hd, $tl, $cons';
  const measure = async (cand, contents, prog) => {
    const r = await esbuild.build({
      stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser',
      define: defines(cand, true), mainFields: ['module', 'main'], logLevel: 'error',
      plugins: prog ? [plugin(cand, prog)] : [{ name: 'core', setup(b) { b.onResolve({ filter: /^seq-core$/ }, () => ({ path: path.join(here, `seq/${CANDS[cand].core}.js`) })); } }],
    });
    const t = r.outputFiles[0].text;
    return { min: t.length, gzip: gz(t), brotli: br(t) };
  };
  const rows = [];
  // the surface plugin maps list-rt to the candidate's sibling for the `first` program; the whole
  // surface is lists/surface/E1 over it
  const firstPlugin = (cand) => ({ name: 'surf', setup(b) {
    const p = plugin(cand, 'first');
    p.setup({ onResolve: (o, f) => b.onResolve(o, f) });
    b.onResolve({ filter: /^surf-out\// }, (a) => ({ path: path.join(surf, 'first', a.path.slice('surf-out/'.length)) }));
  } });
  for (const cand of MAIN) {
    if (CANDS[cand].beni) continue; // bench/size.mjs measures the shipped List through the real build
    const sib = await measure(cand, `export { ${SIB} } from './seq/surface.js';`);
    const whole = await (async () => {
      const r = await esbuild.build({
        stdin: { contents: `export * from 'surf-out/Surface.mjs';`, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser',
        define: defines(cand, true), mainFields: ['module', 'main'], logLevel: 'error', plugins: [firstPlugin(cand)],
      });
      const t = r.outputFiles[0].text;
      return { min: t.length, gzip: gz(t), brotli: br(t) };
    })();
    rows.push({ cand, sibling: sib, whole });
  }
  // today's two types: core/List (cons cells, core/List.js) + §15's Array over the adaptive port as
  // §15 and §17.8 shipped it (no view layer: its `List` is the cons list), whole surface
  const arrSib = path.join(OUT, 'sib-adaptive-arr.js');
  fs.writeFileSync(arrSib, `import { toCons, sort, toArray } from '../../ports/adaptive.js';
export { length, get as unsafeGet, set, push, pop, slice, concat as append, fromCons as fromList } from '../../ports/adaptive.js';
export const toList = (a) => toCons(a, { $: 0, a: null, b: null });
export const sortWith = (a, f) => sort(a, (x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; });`);
  const two = await (async () => {
    const r = await esbuild.build({
      stdin: { contents: `export * from ${JSON.stringify(path.join(surf, 'A/Surface.mjs'))};`, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser',
      define: defines('adaptive256', false), mainFields: ['module', 'main'], logLevel: 'error',
      plugins: [{ name: 'two', setup(b) { b.onResolve({ filter: /\/Array\.foreign\.mjs$/ }, () => ({ path: arrSib })); } }],
    });
    const t = r.outputFiles[0].text;
    return { min: t.length, gzip: gz(t), brotli: br(t) };
  })();
  // §15's Array sibling alone: research/40's hand-minified file against the adaptive array it minified
  const ARRSIB = 'length, unsafeGet, set, push, pop, slice, append, fromList, toList, sortWith, fromJs, toJs, chunks';
  const minRow = await measure('adaptive1024', `export { ${ARRSIB} } from './min/array.min.js';`);
  // the same surface from ports/adaptive.js as research/38 §15.10 and research/40 measured it (scenarios.mjs's sibling)
  const adaRow = await measure('adaptive1024', `import { toCons, sort, toArray } from './ports/adaptive.js';
export { length, get as unsafeGet, set, push, pop, slice, concat as append, fromCons as fromList } from './ports/adaptive.js';
export const toList = (a) => toCons(a, { $: 0, a: null, b: null });
export const sortWith = (a, f) => sort(a, (x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; });
export const toJs = (a) => toArray(a);
export const fromJs = (arr) => arr;
export { chunks } from './seq/adaptive.js';`);
  const res = { rows, two, arraySibling: { 'adaptive-min': minRow, adaptive1024: adaRow } };
  fs.mkdirSync('results', { recursive: true });
  fs.writeFileSync('results/all-size.json', JSON.stringify(res, null, 1));
  console.log('| candidate | sibling min | gzip | brotli | whole array-first surface brotli |\n|---|--:|--:|--:|--:|');
  for (const r of rows) console.log(`| ${label(r.cand)} | ${r.sibling.min} | ${r.sibling.gzip} | ${r.sibling.brotli} | ${r.whole.brotli} |`);
  console.log(`| today's two types (cons List + adaptive256 Array), whole surface | | | | ${two.brotli} |`);
  console.log(`array sibling: adaptive-min ${minRow.brotli}, adaptive1024 (ports/adaptive.js) ${adaRow.brotli}`);
}

// ---------------------------------------------------------------------------------------------
// tables

function load(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)) : [];
}
const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
const ratio = (x) => (x < 1.95 ? x.toFixed(2) : x < 9.95 ? x.toFixed(1) : Math.round(x).toLocaleString('en')) + '×';

// a cell: the median of its rounds' medians, and the within-run IQR of that round as a fraction
function cells(rows) {
  const g = new Map(), flags = new Map();
  for (const r of rows) {
    if (r.op === undefined) continue;
    const k = `${r.impl}|${r.group}|${r.style}|${r.group === 'arr' ? r.op : r.op}|${r.n}`;
    if (r.med === undefined) {
      if (r.bytes !== undefined) { g.set(k, [...(g.get(k) ?? []), { med: r.bytes, q1: r.bytes, q3: r.bytes }]); continue; }
      const f = flagOf(r);
      if (!flags.has(k) || f === 'n/p') flags.set(k, f);
      continue;
    }
    if (!g.has(k)) g.set(k, []);
    g.get(k).push(r);
  }
  const out = new Map();
  for (const [k, rs] of g) {
    rs.sort((a, b) => a.med - b.med);
    const m = rs[rs.length >> 1];
    out.set(k, { med: m.med, iqr: (m.q3 - m.q1) / m.med, rounds: rs.length, spread: rs.length > 1 ? (rs[rs.length - 1].med - rs[0].med) / m.med : 0, S: m.S, load: m.load ? +m.load.split(' ')[0] : 0 });
  }
  for (const [k, f] of flags) if (!out.has(k)) out.set(k, f);
  return out;
}

const kb = (b) => (Math.abs(b) >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : (b / 1024).toFixed(b < 10240 ? 1 : 0) + ' KB');
function tableFor(C, group, styleOf, cands, title, rowsOrder) {
  const lines = [];
  lines.push(`**${title}**`, '');
  lines.push(`| ${group === 'arr' ? 'scenario / op' : 'op'} | n | ${cands.map(label).join(' | ')} |`);
  lines.push(`|---|--:|${cands.map(() => '--:').join('|')}|`);
  lines.push(`| *style* | | ${cands.map((c) => `*${styleOf(c)}*`).join(' | ')} |`);
  for (const [op, n] of rowsOrder) {
    const v = cands.map((c) => C.get(`${c}|${group}|${styleOf(c)}|${op}|${n}`));
    if (v.every((x) => x === undefined)) continue;
    const nums = v.map((x, i) => (typeof x === 'object' && x && cands[i] !== 'native' ? x.med : Infinity));
    const best = Math.min(...nums), bytes = op.startsWith('retained');
    const cellsTxt = v.map((x, i) => {
      if (x === undefined) return '—';
      if (typeof x === 'string') return x;
      const t = (bytes ? kb(x.med) : fmt(x.med)) + (x.S === 0 ? '¹' : x.iqr > 0.2 ? '²' : '') + (x.rounds === 1 && !bytes ? '³' : '') + (x.load > 16 ? '⁴' : '');
      return nums[i] === best ? `**${t}**` : `${t} (${ratio(x.med / best)})`;
    });
    lines.push(`| ${op} | ${(+n).toLocaleString('en')} | ${cellsTxt.join(' | ')} |`);
  }
  return lines.join('\n');
}

function modeTables() {
  const engine = process.argv[3] ?? 'chrome';
  const rows = load(process.env.RESULTS ?? `results/all-${engine === 'quick' ? 'quick-node' : engine}.jsonl`);
  const C = cells(rows);
  const cands = pick(MAIN);
  const L = JSON.parse(fs.readFileSync(path.join(OUT, 'labels.json'), 'utf8'));
  const out = [];
  // rows in the harnesses' order, each op at its sizes
  const order = (group) => {
    const sizes = { list: [1000, 10000, 100000], ops: [8, 1000, 100000] };
    if (group !== 'arr') return L[group].flatMap((op) => sizes[group].map((n) => [op, n]));
    const byOp = new Map();
    for (const [, op, n] of L.arr) { if (!byOp.has(op)) byOp.set(op, []); byOp.get(op).push(n); }
    const res = [...byOp].flatMap(([op, ns]) => ns.sort((a, b) => a - b).map((n) => [op, n]));
    for (const op of ['retained/one version', 'retained/101 versions']) res.push([op, 10000]);
    return res;
  };
  out.push(`# All candidates, ${engine}\n`);
  out.push(`Median of the rounds' medians per call; **bold** is the fastest persistent candidate in the row and every other cell's ratio is to it (native mut writes in place and is never bold). ¹ one cold call (over the 3 s cap). ² within-run IQR over 20 % of the median. ³ one round only. ⁴ the median round ran at a load average over 16 (32 threads). SO stack overflow; OOM heap exhausted (Node) or renderer crashed (Chrome); > 8 s / > ${HARD_MS / 1000} s killed after that long on one call; skip not run because it failed at the size before; n/p needs persistence (native only); — not applicable.\n`);
  out.push(tableFor(C, 'arr', () => 'index', cands, `§15's array scenarios (one style: indexed code over the Array API)`, order('arr')));
  for (const group of ['list', 'ops']) {
    const title = group === 'list' ? "§16/§17's list scenarios" : "§3's single operations";
    out.push('', tableFor(C, group, (c) => idiom(c), cands, `${title}, each candidate on the code written for it (cons: Elm-style; every other: array-first)`, order(group)));
    out.push('', tableFor(C, group, (c) => (idiom(c) === 'first' ? 'elm' : 'first'), cands, `${title}, each candidate on the OTHER style (cons: array-first; every other: Elm-style)`, order(group)));
  }
  // the check of research 40's minified sibling
  const chk = ['adaptive1024', 'adaptive-min'];
  out.push('', tableFor(C, 'arr', () => 'index', chk, `research 40's hand-minified sibling against the adaptive array it minified (T = 1 024)`, order('arr')));
  // the check of the list-syntax rewrite: cons cells over the rewritten output against beni's own
  for (const group of ['list', 'ops']) out.push('', tableFor(C, group, () => 'elm', ['cons', 'cons-raw'], `the rewrite of the list syntax, ${group}: cons over the rewritten output against cons over beni's own output`, order(group)));
  // spread
  const timed = [...C.values()].filter((x) => typeof x === 'object');
  const iq = timed.map((x) => x.iqr).sort((a, b) => a - b), sp = timed.filter((x) => x.rounds > 1).map((x) => x.spread).sort((a, b) => a - b);
  const q = (a, p) => (a.length ? (100 * a[Math.min(a.length - 1, Math.floor(p * (a.length - 1)))]).toFixed(1) + ' %' : '—');
  out.push('', `Spread: ${timed.length} cells; within a run, IQR / median: median ${q(iq, 0.5)}, 90th percentile ${q(iq, 0.9)}; between rounds, (max − min) / median of a cell's round medians: median ${q(sp, 0.5)}, 90th percentile ${q(sp, 0.9)}. Loads seen: ${[...new Set(rows.filter((r) => r.load).map((r) => r.load.split(' ')[0]))].map(Number).sort((a, b) => a - b).filter((_, i, a) => i === 0 || i === a.length - 1).join(' – ')}.`);
  // memory
  const mem = load('results/all-mem.jsonl');
  if (mem.length) {
    const mb = (b) => (b === null || b === undefined ? '—' : Math.abs(b) >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : (b / 1024).toFixed(0) + ' KB');
    out.push('', `**Memory, the list scenarios and single operations at n = 100 000, each candidate on its own style: peak resident growth during one call / heap retained by the result**`, '');
    out.push(`| op | ${cands.map(label).join(' | ')} |`, `|---|${cands.map(() => '--:').join('|')}|`);
    const mc = new Map(mem.map((r) => [`${r.impl}|${r.group}|${r.op}|${r.n}`, r]));
    for (const key of [...new Set(mem.map((r) => `${r.group}|${r.op}|${r.n}`))]) {
      const [g, op, n] = key.split('|');
      out.push(`| ${g === 'ops' ? 'single: ' : ''}${op} | ${cands.map((c) => { const r = mc.get(`${c}|${g}|${op}|${n}`); if (!r) return '—'; if (r.err) return r.err.includes('overflow') ? 'SO' : /memory|mark/.test(r.err) ? 'OOM' : r.err; return `${mb(r.peakKB * 1024)} / ${mb(r.retained)}`; }).join(' | ')} |`);
    }
  }
  const st = load('results/all-stack.jsonl');
  if (st.length) {
    out.push('', `**Stack safety at n = 100 000 on Node's default stack: the cells that overflow**`, '');
    out.push(`| style | ${cands.map(label).join(' | ')} |`, `|---|${cands.map(() => '---').join('|')}|`);
    for (const style of STYLES) {
      out.push(`| ${style} | ${cands.map((c) => {
        const bad = st.filter((r) => r.impl === c && r.style === style && /overflow|Maximum call stack/.test(r.stack));
        const ok = st.filter((r) => r.impl === c && r.style === style && r.stack === 'ok').length;
        return bad.length ? `${bad.length} SO (${bad.map((r) => r.op).join(', ')})` : ok ? `none of ${ok}` : '—';
      }).join(' | ')} |`);
    }
  }
  const txt = out.join('\n') + '\n';
  fs.writeFileSync(`results/all-tables-${engine}.md`, txt);
  console.log(txt);
}

// research/46 §11: E1tp against E1t, the cons list and the best of every other candidate in the
// results file, one table per kind of code. Each cell is the median of its rounds' medians; bold is
// the fastest of the four columns, every other cell its ratio to that one
function modeTablesE1tp() {
  const file = process.env.RESULTS ?? 'results/e1tp-node.jsonl';
  const C = cells(load(file));
  const L = JSON.parse(fs.readFileSync(path.join(OUT, 'labels.json'), 'utf8'));
  const others = [...new Set([...C.keys()].map((k) => k.split('|')[0]))].filter((c) => !['E1tp', 'E1t', 'cons', 'native'].includes(c));
  const num = (x) => (typeof x === 'object' && x ? x.med : Infinity);
  const show = (x) => (x === undefined ? '—' : typeof x === 'string' ? x : fmt(x.med) + (x.S === 0 ? '¹' : x.iqr > 0.2 ? '²' : '') + (x.rounds === 1 ? '³' : '') + (x.load > 16 ? '⁴' : ''));
  const sizes = { list: [1000, 10000, 100000], ops: [8, 1000, 100000] }; // a size not in the file is left out
  const out = [];
  const counts = [];
  const table = (title, group, styles, rows) => {
    out.push(`**${title}**`, '', `| op | n | E1tp (${styles.E1tp}) | E1t (${styles.E1t}) | cons (${styles.cons}) | best other (${styles.rest}) |`, '|---|--:|--:|--:|--:|--:|');
    const tally = { E1tp: [0, 0, 0], E1t: [0, 0, 0], cons: [0, 0, 0], rows: 0 };
    for (const [op, n] of rows) {
      const get = (c, st) => C.get(`${c}|${group}|${st}|${op}|${n}`);
      const v = [get('E1tp', styles.E1tp), get('E1t', styles.E1t), get('cons', styles.cons)];
      let bo = null, bv;
      for (const c of others) { const x = get(c, styles.rest); if (typeof x === 'object' && (!bo || x.med < bv.med)) { bo = c; bv = x; } }
      v.push(bv);
      if (v.every((x) => x === undefined)) continue;
      const best = Math.min(...v.map(num));
      tally.rows++;
      ['E1tp', 'E1t', 'cons'].forEach((c, i) => { const r = num(v[i]) / best; if (r <= 1.5) tally[c][0]++; if (r > 3) tally[c][1]++; if (r > 10) tally[c][2]++; });
      const txt = v.map((x, i) => (x === undefined || typeof x === 'string' ? show(x) : num(x) === best ? `**${show(x)}**` : `${show(x)} (${ratio(x.med / best)})`));
      if (bo) txt[3] = `${txt[3]} ${label(bo)}`;
      out.push(`| ${op} | ${(+n).toLocaleString('en')} | ${txt.join(' | ')} |`);
    }
    counts.push(`| ${title.replace(/:.*/, '')} | ${tally.rows} | ${['E1tp', 'E1t', 'cons'].map((c) => tally[c].join(' / ')).join(' | ')} |`);
    out.push('');
  };
  const byOp = (group) => L[group].flatMap((op) => sizes[group].map((n) => [op, n]));
  const arrRows = (() => { const m = new Map(); for (const [, op, n] of L.arr) { if (!m.has(op)) m.set(op, []); m.get(op).push(n); } return [...m].flatMap(([op, ns]) => ns.sort((a, b) => a - b).map((n) => [op, n])); })();
  out.push(`# E1tp, ${file}`, '', `Median of the rounds' medians per call; **bold** is the fastest of the four columns, every other cell its ratio to it. "best other": the fastest persistent candidate in the file other than these three, named. ¹ one cold call. ² IQR over 20 % of the median. ³ one round. ⁴ load over 16. > 8 s / > 45 s killed; skip: failed at the size before; SO stack overflow.`, '');
  table('A. The list scenarios, Elm-style code', 'list', { E1tp: 'elm', E1t: 'elm', cons: 'elm', rest: 'elm' }, byOp('list'));
  table('B. The list scenarios, array-first code (cons on its own Elm-style code)', 'list', { E1tp: 'first', E1t: 'first', cons: 'elm', rest: 'first' }, byOp('list'));
  table('C. The single operations, array-first (cons on its own Elm-style code)', 'ops', { E1tp: 'first', E1t: 'first', cons: 'elm', rest: 'first' }, byOp('ops'));
  table("D. §15's array scenarios (indexed code)", 'arr', { E1tp: 'index', E1t: 'index', cons: 'index', rest: 'index' }, arrRows);
  out.push('**Rows within 1.5× of the row\'s best / over 3× / over 10×**', '', '| table | rows | E1tp | E1t | cons |', '|---|--:|--:|--:|--:|', ...counts, '');
  const txt = out.join('\n');
  fs.writeFileSync(file.replace(/\.jsonl$/, '-tables.md'), txt);
  console.log(txt);
}

// ---------------------------------------------------------------------------------------------

if (mode === undefined) {
  // the default run: build if needed, then one quick round in Node (README.md)
  const t0 = Date.now();
  if (!fs.existsSync(path.join(OUT, before ? 'first' : 'first-beni'))) build();
  if (!fs.existsSync(path.join(OUT, 'needs-persistence.json'))) await modeTest();
  fs.rmSync(process.env.RESULTS ?? 'results/all-quick-node.jsonl', { force: true });
  process.env.WORKERS ??= '8';
  // the candidates, not the three checks (adaptive1024, adaptive-min, cons-raw): `node all.mjs
  // bench` runs those, and the quick run stays under 5 minutes with E1tp in it
  process.env.CANDS ??= MAIN.join(',');
  await modeBench('node');
  console.log(`quick run: ${((Date.now() - t0) / 1000).toFixed(0)} s; ${process.env.RESULTS ?? "results/all-quick-node.jsonl (node all.mjs tables quick)"}`);
} else if (mode === 'build') build();
else if (mode === 'test') await modeTest();
else if (mode === 'bench') await modeBench('node');
else if (mode === 'chrome') await modeBench('chrome');
else if (mode === 'mem') await modeMem();
else if (mode === 'stack') await modeStack();
else if (mode === 'size') await modeSize();
else if (mode === 'tables') modeTables();
else if (mode === 'tables-e1tp') modeTablesE1tp();
else console.log('usage: node all.mjs build | test | bench [rounds] | chrome [rounds] | mem | stack | size | tables [node|chrome] | tables-e1tp   (README.md)');
