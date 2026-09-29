// Report 40: how small the adaptive `_core/Array.foreign.mjs` gets under brotli 11, and what
// buys it. Node only. From bench/arrays: `npm ci`, `zig build` at the root, then
// `node scenarios.mjs build && node scenarios.mjs test` (the compiled scenarios, and cow's sibling
// that `test` compares with), then:
//
//   node min/measure.mjs minify          build dist/minify: beni's own release compactor
//                                        (src/js/Minify.zig) as a filter; needs `zig` on PATH
//   node min/measure.mjs size            the stage table, the step ledger, the flagged variants and
//                                        the read-only split (report 40 §3–§5)
//   node min/measure.mjs release         the real `beni build --release` of the scenarios against
//                                        each sibling, and what it keeps of it (§5)
//   node min/measure.mjs test [file…]    each sibling through the scenario harness's 298 checks,
//                                        compared line by line with cow's
//   node min/measure.mjs fuzz [file…]    random operation sequences, each result compared with
//                                        original.js's: contents, representation, identity
//   node min/measure.mjs bench core spec…  §15's scenarios, one pinned process per sibling
//                                        (`file` or `file:sc1,sc2`), appended to min/results.jsonl
//                                        or to $RESULTS
//   node min/measure.mjs tables          min/results.jsonl (or $RESULTS) as a per-cell comparison
//   node min/brotli-probes.mjs           the compressor experiments of §1
//
// With no files, `test` and `fuzz` take every sibling the report measures: original.js, the
// steps, rewritten.js, array.min.js and the flagged variants.
import * as esbuild from 'esbuild';
import { minify as terser } from 'terser';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { rename } from './rename.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const arrays = path.resolve(here, '..');
const repo = path.resolve(arrays, '../..');
const dist = path.join(arrays, 'dist');
fs.mkdirSync(dist, { recursive: true });
const mode = process.argv[2];
const RESULTS = process.env.RESULTS ? path.resolve(process.env.RESULTS) : path.join(here, 'results.jsonl');

const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_LGWIN]: 22 } }).length;
const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
const read = (f) => fs.readFileSync(path.resolve(here, f), 'utf8');

// the whole surface, and what a program that never writes imports
const SURFACE = ['length', 'unsafeGet', 'set', 'push', 'pop', 'slice', 'append', 'fromList', 'toList', 'sortWith', 'fromJs', 'toJs', 'chunks'];
const READS = ['length', 'unsafeGet', 'slice', 'append', 'fromList', 'toList', 'sortWith', 'fromJs', 'toJs', 'chunks'];

const STEPS = fs.readdirSync(path.join(here, 'steps')).filter((f) => f.endsWith('.js')).sort().map((f) => `steps/${f}`);
const FLAGGED = fs.readdirSync(path.join(here, 'flagged')).filter((f) => f.endsWith('.js')).sort().map((f) => `flagged/${f}`);
const ALL = ['original.js', ...STEPS, 'rewritten.js', 'array.min.js', ...FLAGGED];

// ---------------------------------------------------------------------------------------------
// The minifiers

const MINIFY = path.join(dist, 'minify');
function beniMinify(file, keep = SURFACE) {
  if (!fs.existsSync(MINIFY)) throw new Error('run `node min/measure.mjs minify` first');
  const r = spawnSync(MINIFY, [path.resolve(here, file), ...keep], { encoding: 'utf8' });
  if (r.status === 2) return null; // declined: a build copies the file as written
  if (r.status !== 0) throw new Error(r.stderr);
  return r.stdout;
}
async function esb(src, opts) {
  const r = await esbuild.transform(src, { format: 'esm', target: 'es2023', ...opts });
  return r.code;
}
// the strongest terser settings that are sound here (property mangling is not: see the report)
const T_BEST = { compress: { passes: 3, toplevel: true, unsafe_arrows: true, pure_getters: true }, mangle: { toplevel: true } };
async function ters(src, opts) {
  const r = await terser(src, { module: true, ecma: 2020, ...opts });
  return r.code;
}

// ---------------------------------------------------------------------------------------------

function bundleFor(file) {
  const sib = path.resolve(here, file);
  return {
    name: 'min-array',
    setup(b) {
      b.onResolve({ filter: /^array-sibling$|\/Array\.foreign\.mjs$/ }, () => ({ path: sib }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(dist, 'beni', a.path.slice('beni-out/'.length)) }));
    },
  };
}
async function harnessBundle(file, contents, out) {
  await esbuild.build({
    stdin: { contents, resolveDir: arrays, loader: 'js' }, bundle: true, platform: 'neutral', target: 'es2023',
    define: { ADA_T: '1024' }, logLevel: 'error', plugins: [bundleFor(file)], format: 'iife', outfile: out,
  });
}
const slug = (f) => f.replace(/[^\w]+/g, '-');

if (mode === 'minify') {
  const r = spawnSync('zig', ['build-exe', '--dep', 'beni', `-Mroot=${path.join(here, 'minify.zig')}`, `-Mbeni=${path.join(repo, 'src/beni.zig')}`, `-femit-bin=${MINIFY}`], { stdio: 'inherit', cwd: repo });
  process.exit(r.status);
} else if (mode === 'test') {
  const files = process.argv.slice(3).length ? process.argv.slice(3) : ALL;
  const run = async (file) => {
    const out = path.join(dist, `mintest-${slug(file)}.js`);
    await harnessBundle(file, `import { test } from './scenarios/harness.js'; console.log(test());`, out);
    const r = spawnSync(process.execPath, ['--stack-size=4000', out], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) throw new Error(`${file}: ${r.stderr.slice(-1500)}`);
    return r.stdout.trim().split('\n');
  };
  // `node scenarios.mjs test` writes cow's sibling there
  const ref = await run(path.relative(here, path.join(dist, 'sib-cow.js')));
  if (ref.some((l) => /INPUT CHANGED|identity.*false/.test(l))) throw new Error('cow itself fails');
  for (const f of files) {
    const got = await run(f);
    const diff = got.map((l, i) => [l, ref[i]]).filter(([a, b]) => a !== b);
    const ok = got.length === ref.length && diff.length === 0;
    console.log(`${f.padEnd(34)} ${got.length} checks ${ok ? 'agree with cow' : 'DIFFER: ' + JSON.stringify(diff.slice(0, 3))}`);
    if (!ok) process.exitCode = 1;
  }
} else if (mode === 'fuzz') {
  const files = process.argv.slice(3).length ? process.argv.slice(3) : ALL.slice(1);
  await fuzz(files);
} else if (mode === 'size') {
  await size();
} else if (mode === 'bench') {
  const core = process.argv[3];
  // `file:sc1,sc2` runs only those scenarios
  for (const spec of process.argv.slice(4)) {
    const [file, scs] = spec.split(':');
    const out = path.join(dist, `minbench-${slug(spec)}.js`);
    const sc = scs ? scs.split(',') : ['table', 'decoded', 'grid', 'build', 'history', 'interop'];
    await harnessBundle(file, `import { run } from './scenarios/harness.js'; run(${JSON.stringify(file)}, ${JSON.stringify(sc)});`, out);
    const t0 = Date.now();
    const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', out], { encoding: 'utf8', maxBuffer: 1 << 26 });
    if (r.status !== 0) console.error(file, 'FAILED', r.stderr.slice(-800));
    const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
    fs.appendFileSync(RESULTS, lines.join('\n') + '\n');
    console.log(file, lines.length, 'cells', ((Date.now() - t0) / 1000).toFixed(1), 's');
  }
} else if (mode === 'release') {
  // the real compiler: `beni build --release` (zig-out/bin/beni, `zig build` first) of the scenario
  // modules against a copy of core/ whose Array is min/Array.beni with each sibling as Array.js;
  // what is measured is the `_core/Array.foreign.mjs` the build writes
  const beniBin = path.join(repo, 'zig-out/bin/beni');
  console.log('| sibling | program | foreign exports kept | raw | gzip-9 | brotli-11 |\n|---|---|---|--:|--:|--:|');
  for (const f of ['original.js', 'rewritten.js', 'array.min.js']) {
    const core = path.join(dist, 'relcore');
    fs.rmSync(core, { recursive: true, force: true });
    fs.cpSync(path.join(repo, 'core'), core, { recursive: true });
    fs.copyFileSync(path.join(here, 'Array.beni'), path.join(core, 'Array.beni'));
    fs.copyFileSync(path.join(here, f), path.join(core, 'Array.js'));
    for (const [label, mods] of [['Decoded (reads only)', ['Decoded']], ['all seven scenarios', ['Build', 'Decoded', 'Grid', 'History', 'Interop', 'Life', 'Table']]]) {
      const out = path.join(dist, `rel-${slug(f)}-${mods.length}`);
      fs.rmSync(out, { recursive: true, force: true });
      const r = spawnSync(beniBin, ['build', '--release', '--platform=node', '--library', '--no-cache', `--core-root=${core}`, `--root=${path.join(arrays, 'scenarios/src')}`, `--out=${out}`, ...mods.map((m) => path.join(arrays, `scenarios/src/${m}.beni`))], { encoding: 'utf8' });
      // original.js is refused by check 3 (report 40 §4: a `function f(a, extra)` parameter)
      if (r.status !== 0) { console.log(`| ${f} | ${label} | refused: ${(r.stdout + r.stderr).split('\n').slice(0, 3).join(' ').replace(/\S*\/relcore\//g, '').replace(/\s+/g, ' ').slice(0, 140)} | | | |`); continue; }
      const t = fs.readFileSync(path.join(out, '_core/Array.foreign.mjs'), 'utf8');
      const kept = [...t.matchAll(/export (?:let|const|function) (\w+)/g)].map((m) => m[1]);
      console.log(`| ${f} | ${label} | ${kept.join(', ')} | ${t.length} | ${gz(t)} | **${br(t)}** |`);
    }
  }
} else if (mode === 'tables') {
  tables();
} else {
  console.log('usage: node min/measure.mjs minify | size | test [file…] | fuzz [file…] | bench core file… | tables');
}

// ---------------------------------------------------------------------------------------------
// Random differential test. Each sibling is loaded twice: as written (T = 1 024) and with its
// threshold constant rewritten to 4, so small arrays reach the trie, its tail, a root split and a
// root collapse. Every operation's result is compared with original.js's by JSON (which spells out
// the representation: a plain array, or the trie's {n, s, r, t} node for node), by identity with
// its input, and by its `toJs`/`chunks`/`toList` readings.

async function load(file, T) {
  let src = read(file);
  if (T !== 1024) {
    // every `1024` in the code is the threshold (the files spell it nowhere else)
    if (!/\b1024\b/.test(src)) throw new Error(`${file}: no 1024 threshold`);
    src = src.replace(/\b1024\b/g, String(T));
  }
  const out = path.join(dist, `fuzz-${slug(file)}-${T}.mjs`);
  fs.writeFileSync(out, src);
  return import(out + `?${Date.now()}`);
}
async function fuzz(files) {
  const nil = { $: 0, a: null, b: null };
  const cons = (xs) => { let l = nil; for (let i = xs.length - 1; i >= 0; i--) l = { $: 1, a: xs[i], b: l }; return l; };
  const unlist = (l) => { const xs = []; for (; l.$ === 1; l = l.b) xs.push(l.a); return xs; };
  for (const T of [4, 1024]) {
    const ref = await load('original.js', T);
    const subs = await Promise.all(files.map((f) => load(f, T)));
    let seed = 7, checks = 0;
    // mulberry32: an LCG's low bits cycle too fast for `% n`
    const rnd = (n) => {
      seed = (seed + 0x6d2b79f5) | 0;
      let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) % n;
    };
    const sizes = T === 4
      ? [0, 1, 2, 3, 4, 5, 6, 31, 32, 33, 34, 63, 64, 65, 100, 1023, 1024, 1025, 1055, 1056, 1057, 1088, 1089, 1100, 33000, 33823, 33824, 33825, 33856, 40000]
      : [0, 1, 5, 31, 32, 33, 40, 63, 64, 65, 1000, 1023, 1024, 1025, 1100, 2048, 5000, 40000];
    for (let round = 0; round < (T === 4 ? 400 : 60); round++) {
      const n0 = sizes[rnd(sizes.length)];
      const init = Array.from({ length: n0 }, (_, i) => i * 3);
      // every version of the value so far, one per sibling
      let hist = [[ref.fromList(cons(init)), ...subs.map((m) => m.fromList(cons(init)))]];
      for (let step = 0; step < 40; step++) {
        const cur = hist[rnd(hist.length)];
        const n = ref.length(cur[0]);
        const i = rnd(n + 4) - 2, j = rnd(n + 6) - 3, e = n + rnd(3);
        const k = rnd(12);
        const other = hist[rnd(hist.length)];
        const v = rnd(3) === 0 ? ref.unsafeGet(cur[0], Math.max(0, Math.min(n - 1, i))) : rnd(1000);
        const ops = [
          (m, a, b) => m.set(a, i, v),
          (m, a, b) => m.push(a, v),
          (m, a, b) => m.pop(a),
          (m, a, b) => m.slice(a, i, j),
          (m, a, b) => m.slice(a, 0, e),
          (m, a, b) => m.append(a, b),
          (m, a, b) => m.append(b, a),
          (m, a, b) => m.sortWith(a, (x, y) => (x < y ? 'LT' : x > y ? 'GT' : 'EQ')),
          (m, a, b) => m.fromList(m.toList(a)),
          (m, a, b) => m.fromJs(m.toJs(a).slice()),
          (m, a, b) => { let x = a; for (let q = 0; q < 40; q++) x = m.push(x, q); return x; },
          (m, a, b) => { let x = a; for (let q = 0; q < 40; q++) x = m.pop(x); return x; },
        ];
        const res = [ref, ...subs].map((m, s) => ops[k](m, cur[s], other[s]));
        const want = JSON.stringify(res[0]), same = res[0] === cur[0];
        const reading = (m, a) => JSON.stringify([m.length(a), m.toJs(a), m.chunks(a), unlist(m.toList(a)), n > 0 ? [m.unsafeGet(a, 0), m.unsafeGet(a, m.length(a) - 1)] : 0]);
        const wantRead = reading(ref, res[0]);
        subs.forEach((m, s) => {
          checks++;
          const r = res[s + 1];
          const bad = JSON.stringify(r) !== want ? 'representation' : (r === cur[s + 1]) !== same ? 'identity' : reading(m, r) !== wantRead ? 'reading' : '';
          if (bad) { console.log(`${files[s]} T=${T}: ${bad} differs, op ${k} n ${n} i ${i} j ${j}`); process.exit(1); }
        });
        hist.push(res);
        if (hist.length > 8) hist.shift();
      }
    }
    console.log(`T = ${T}: ${files.length} siblings agree with original.js on ${checks} results`);
  }
}

// ---------------------------------------------------------------------------------------------

function row(label, text, base) {
  const b = br(text);
  return `| ${label} | ${text.length} | ${gz(text)} | **${b}** | ${base === undefined ? '' : (b - base > 0 ? '+' : '') + (b - base)} |`;
}
async function size() {
  const orig = read('original.js');
  const beni = beniMinify('original.js');
  console.log('**Stages** (the whole surface: 13 exports)\n\n| stage | raw | gzip-9 | brotli-11 | Δ brotli |\n|---|--:|--:|--:|--:|');
  // the lexical passes a tokenizer can do soundly (§7 (a)): A2 renaming, A3 three token rewrites
  const lexical = (s) => s.replace(/;}/g, '}').replace(/\((\w+)\)=>/g, '$1=>').replace(/\bconst /g, 'let ');
  const stagesFor = async (f, n) => {
    const src = read(f), b = beniMinify(f);
    return [
      [`${n} ${f}, as written`, src],
      [`${n}a beni \`--release\` today (Minify.zig)`, b],
      [`${n}b + A2 renaming by tokens (rename.mjs)`, rename(b, SURFACE)],
      [`${n}c + A3 const→let, (x)=>→x=>, ;}→}`, lexical(rename(b, SURFACE))],
      [`${n}d beni today + terser mangle, locals only (scope analysis)`, await ters(b, { module: false, compress: false, mangle: { toplevel: false } })],
      [`${n}e beni today + terser mangle, all names`, await ters(b, { compress: false, mangle: { toplevel: true } })],
      [`${n}f esbuild --minify (report 38 §15.10's method)`, await esb(src, { minify: true })],
      [`${n}g terser defaults`, await ters(src, {})],
      [`${n}h terser passes 3, toplevel, unsafe_arrows, pure_getters`, await ters(src, T_BEST)],
    ];
  };
  const stages = [
    ...(await stagesFor('original.js', 0)),
    ...(await stagesFor('rewritten.js', 1)),
    ['2 array.min.js, by hand', read('array.min.js')],
    ['2a array.min.js, beni `--release` today', beniMinify('array.min.js')],
    ['2h array.min.js through terser best', await ters(read('array.min.js'), T_BEST)],
  ];
  let prev;
  for (const [l, t] of stages) { if (t === null) { console.log(`| ${l} | declined | | | |`); continue; } console.log(row(l, t, prev)); prev = br(t); }

  console.log('\n**Steps** (each file is the one before it with one technique applied; readable steps measured after beni `--release` and after terser best, hand steps as they are)\n');
  console.log('| step | beni raw | beni brotli | Δ | terser raw | terser brotli | Δ |\n|---|--:|--:|--:|--:|--:|--:|');
  let pb, pt;
  for (const f of STEPS) {
    const src = read(f);
    const hand = /^steps\/1\d/.test(f);
    const b = hand ? src : beniMinify(f), t = hand ? src : await ters(src, T_BEST);
    const bb = br(b), tb = br(t);
    const d = (x, p) => (p === undefined ? '' : (x - p > 0 ? '+' : '') + (x - p));
    console.log(`| ${f} | ${b.length} | ${bb} | ${d(bb, pb)} | ${t.length} | ${tb} | ${d(tb, pt)} |`);
    pb = bb; pt = tb;
  }

  console.log('\n**Flagged** (smaller, but each changes speed: §6)\n\n| file | raw | gzip-9 | brotli-11 | Δ vs array.min.js |\n|---|--:|--:|--:|--:|');
  const base = br(read('array.min.js'));
  for (const f of FLAGGED) console.log(row(f, read(f), base));

  console.log('\n**Read-only programs** (`set`, `push`, `pop` not imported), beni `--release` elimination\n\n| sibling | kept | raw | gzip-9 | brotli-11 | Δ vs whole |\n|---|---|--:|--:|--:|--:|');
  for (const f of ['original.js', 'rewritten.js', 'array.min.js']) {
    const whole = br(beniMinify(f, SURFACE));
    for (const [k, keep] of [['all 13', SURFACE], ['reads', READS], ['length, unsafeGet, fromList', ['length', 'unsafeGet', 'fromList']]]) {
      const t = beniMinify(f, keep);
      if (t === null) { console.log(`| ${f} | ${k} | declined | | | |`); continue; }
      console.log(`| ${f} | ${k} | ${t.length} | ${gz(t)} | **${br(t)}** | ${br(t) - whole} |`);
    }
  }
}

// ---------------------------------------------------------------------------------------------

function tables() {
  const rows = fs.readFileSync(RESULTS, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const impls = [...new Set(rows.map((r) => r.impl))];
  const cell = new Map();
  for (const r of rows) {
    const k = `${r.impl}|${r.sc}|${r.op}|${r.n}`;
    if (!cell.has(k)) cell.set(k, []);
    cell.get(k).push(r.med ?? r.bytes);
  }
  const med = (xs) => { const s = [...xs].sort((a, b) => a - b); return s[s.length >> 1]; };
  const keys = [...new Set(rows.map((r) => `${r.sc}|${r.op}|${r.n}`))];
  const [base, ...others] = impls;
  // the spread of the first sibling's round medians, (max - min) / median, is the cell's noise; a ratio
  // outside 1 ± max(5 %, that spread) is marked *
  console.log(`| scenario | op | n | rounds | spread | ${impls.join(' | ')} |\n|---|---|--:|--:|--:|${impls.map(() => '--:').join('|')}|`);
  const ratios = [];
  for (const k of keys) {
    const bs = cell.get(`${base}|${k}`) ?? [NaN], b = med(bs), spread = (Math.max(...bs) - Math.min(...bs)) / b, tol = Math.max(0.05, spread);
    const cs = impls.map((i) => med(cell.get(`${i}|${k}`) ?? [NaN]));
    const [sc, op, n] = k.split('|');
    for (let x = 1; x < cs.length; x++) ratios.push({ k, r: cs[x] / b });
    console.log(`| ${sc} | ${op} | ${n} | ${bs.length} | ${(100 * spread).toFixed(0)} % | ${cs.map((c, x) => (x === 0 ? fmt(c, op) : `${fmt(c, op)} (${(c / b).toFixed(2)}×${Math.abs(c / b - 1) > tol ? ' *' : ''})`)).join(' | ')} |`);
  }
  ratios.sort((a, b) => a.r - b.r);
  console.log(`\nratio to ${base}: min ${ratios[0].r.toFixed(2)} (${ratios[0].k}), median ${ratios[ratios.length >> 1].r.toFixed(2)}, max ${ratios.at(-1).r.toFixed(2)} (${ratios.at(-1).k})`);
}
function fmt(v, op) {
  if (op.startsWith('retained')) return (v / 1024).toFixed(0) + ' KB';
  return v < 1e3 ? v.toFixed(0) + ' ns' : v < 1e6 ? (v / 1e3).toPrecision(3) + ' µs' : (v / 1e6).toPrecision(3) + ' ms';
}
