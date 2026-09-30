// One sequence type or two? research/38 §16's list scenarios, as beni compiles them. Node only.
//
//   node lists.mjs build            compile lists/src/*.beni with ../../zig-out/bin/beni (build it first:
//                                   `zig build`) into dist/lists/A; rewrite its list syntax into calls
//                                   of the candidate's primitives (dist/lists/R), and apply candidate
//                                   C's hand rewrites on top (dist/lists/C)
//   node lists.mjs test             every candidate runs every cell at 7 sizes; all must agree
//                                   (`ONLY=<op>` limits a bench to one op)
//   node lists.mjs bench [core] [candidate…]
//                                   one `node --expose-gc` process per (candidate, size), pinned with
//                                   `taskset -c <core>`; appends to results/lists.jsonl
//   node lists.mjs mem [core]       one process per (candidate, op, size) for the memory cells;
//                                   appends to results/lists-mem.jsonl
//   node lists.mjs size             esbuild --minify, brotli 11, of each candidate's runtime
//   node lists.mjs tables [file]    the report's tables
//
//   §17 (array-first) adds: `alone [core] [candidate…]` (one process per op and size), `stack`
//   (every op once at 100 000 on Node's default stack), `size-first` (each design's whole sequence
//   surface), `tables-first [file] [cands] [memfile]` (its tables; ALONE=1 for the `alone` rows),
//   and `node lists/claim-test.mjs` (the persistence test of E1t's claimable tail).
//
// Candidates. Every one runs the SAME beni source; what differs is the list syntax's lowering and
// the runtime module it calls:
//
//   A    today: beni's output unchanged, cons cells, the compiled core/List
//   Ac   A through the rewritten output (the `$` primitives over cons cells): checks the rewrite
//   B    the rewritten output over ports/single.js (adaptive array + O(1) views), lists/core-single.js
//   C    B with lists/rewrites-c.js's hand-applied compiler rewrites
//   D    the rewritten output over funkia `list` (RRB), lists/core-funkia.js
//
// Candidate E1 (research/38 §17) runs DIFFERENT source: the same programs written array-first
// (lists/first/*.beni), compiled against an array-first core/List (lists/first-core/List.beni,
// beni over the first-order sibling ports/first.js). Its whole output, core/List included, goes
// through the same rewrite of the list syntax, over ports/first.js. `CANDS=A,E1` limits `test` and
// `mem` to some candidates; `SIZES=1000,10000` and `SKIP=<op>;<op>` limit `bench`.
import * as esbuild from 'esbuild';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { REWRITES } from './lists/rewrites-c.js';

const here = path.dirname(fileURLToPath(import.meta.url));
process.chdir(here);
const repo = path.resolve(here, '../..');
const mode = process.argv[2];
const OUT = path.join(here, 'dist/lists');

const CAND = {
  A: { tree: 'A', rt: 'lists/core-cons.js', core: null },
  Ac: { tree: 'R', rt: 'lists/core-cons.js', core: null },
  B: { tree: 'R', rt: 'lists/core-single.js', core: 'lists/core-single.js' },
  C: { tree: 'C', rt: 'lists/core-single.js', core: 'lists/core-single.js' },
  D: { tree: 'R', rt: 'lists/core-funkia.js', core: 'lists/core-funkia.js' },
  E1: { tree: 'E1', rt: 'ports/first.js', core: null, first: true },
  E1t: { tree: 'E1', rt: 'ports/first-tail.js', core: null, first: true },
  // E1t with §15's push threshold (256) instead of 32: separates the two changes E1t makes
  E1t256: { tree: 'E1', rt: 'ports/first-tail.js', core: null, first: true, define: { PUSH_T: '256' } },
};
const NAMES = process.env.CANDS ? process.env.CANDS.split(',') : Object.keys(CAND);
const RES = process.env.RESULTS ?? 'results/lists.jsonl', MEMRES = process.env.MEMRESULTS ?? 'results/lists-mem.jsonl';
// every op of lists/harness.js's `cells`, for `mem` with MEMOPS=all and for `alone` (§17)
const ALL = ['map, recursive', 'filter, recursive', 'map, accumulator + reverse', 'filter, accumulator + reverse', 'sum', 'sum, List.foldl',
  'takeWhile (90 %)', 'pairwise', 'merge sort', 'merge sort, sorted input', 'foldr building a list', 'foldr sum', 'range + sum', 'map2 (zip)',
  'concatMap', 'append in a loop, acc ++ [x]', 'append two', 'reverse', 'List.map', 'List.filter', 'x :: acc, then reverse', 'into a record field',
  'into a tuple (partition)', 'paths sharing tails, all kept', 'undo stack (3 edits, 1 undo)', 'add to front, first', 'add + remove oldest, steady',
  'toggle one, steady', 'remove one, first', 'render only'];

// ---------------------------------------------------------------------------------------------
// The rewrite of beni's list syntax. beni emits `::` as a call of `List$cons` already; what it
// writes inline is the empty list `{ $: 0, a: null, b: null }`, a literal's cells
// `{ $: 1, a: h, b: t }`, the case tests `s.$ === 0` / `s.$ === 1`, and the cell reads `s.a` /
// `s.b` of a subject it has tested. The rewrite turns exactly those into `$nil`, `$cons(h, t)`,
// `$isNil(s)` / `$isCons(s)`, `$hd(s)` and `$tl(s)` — what a patched `js/Lower.zig` (`nilNode`,
// `consNode`, `fanDiscriminant`/`edgeKey` for `.list`, `bindings` for `.pat_cons`/`.pat_list`) would
// emit. A subject is recognised by its test; a read of `.a`/`.b` is rewritten only on a subject or
// on the tail of one, so a tuple's `.a` and a constructor's `.a` are left alone.

const NIL = '{ $: 0, a: null, b: null }';
const CONS = '{ $: 1, a: ';
function scanExpr(s, i, stops) { // from i to the first depth-0 occurrence of one of `stops`
  let d = 0;
  for (; i < s.length; i++) {
    const c = s[i];
    if (c === '"' || c === "'" || c === '`') { const q = c; for (i++; i < s.length && s[i] !== q; i++) if (s[i] === '\\') i++; continue; }
    if (d === 0) for (const st of stops) if (s.startsWith(st, i)) return i;
    if (c === '(' || c === '[' || c === '{') d++;
    else if (c === ')' || c === ']' || c === '}') d--;
  }
  throw new Error('unbalanced');
}
function rewriteDecl(src) {
  let s = src.split(NIL).join('$nil');
  for (let k = s.lastIndexOf(CONS); k >= 0; k = s.lastIndexOf(CONS)) {
    const h0 = k + CONS.length, h1 = scanExpr(s, h0, [', b: ']);
    const t0 = h1 + ', b: '.length, t1 = scanExpr(s, t0, [' }']);
    s = s.slice(0, k) + `$cons(${s.slice(h0, h1)}, ${s.slice(t0, t1)})` + s.slice(t1 + 2);
  }
  if (s.includes('reduceRight')) throw new Error('a list literal longer than the cons limit: not handled');
  const subjects = new Set();
  for (const m of s.matchAll(/(?<![\w$.])([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.\$ === [01]\b/g)) subjects.add(m[1]);
  s = s.replace(/(?<![\w$.])([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)( === [01]\b)?/g, (all, ch, test) => {
    const t = ch.split('.');
    let cur = t[0], raw = t[0], isList = subjects.has(raw);
    for (let i = 1; i < t.length; i++) {
      const f = t[i];
      if (isList && f === '$') {
        if (i !== t.length - 1 || !test) throw new Error(`a list tag read that is not a test: ${all}`);
        return `${test.endsWith('0') ? '$isNil' : '$isCons'}(${cur})`;
      }
      if (isList && (f === 'a' || f === 'b')) { cur = f === 'a' ? `$hd(${cur})` : `$tl(${cur})`; raw += '.' + f; isList = f === 'b' || subjects.has(raw); }
      else { cur += '.' + f; raw += '.' + f; isList = subjects.has(raw); }
    }
    return cur + (test ?? '');
  });
  if (/\.\$ === [01]\b/.test(s) || s.includes('{ $: 1') || s.includes('{ $: 0')) throw new Error('list syntax survived the rewrite:\n' + s);
  return s;
}
const splitDecls = (text) => text.split(/\n(?=const |export |import )/);
function rewriteModule(text, extraImport = '') {
  const out = splitDecls(text).map((d) => (d.startsWith('const ') ? rewriteDecl(d) : d)).join('\n');
  return `import { $nil, $cons, $isNil, $isCons, $hd, $tl, $fromArray } from "list-syntax";\n${extraImport}${out}`;
}
function applyC(file, text) {
  const table = REWRITES[file];
  if (!table) return text;
  const decls = splitDecls(text), seen = new Set();
  const out = decls.map((d) => {
    const m = /^const ([\w$]+) = /.exec(d);
    if (m && table[m[1]]) { seen.add(m[1]); return table[m[1]]; }
    return d;
  });
  for (const k of Object.keys(table)) if (!seen.has(k)) throw new Error(`C: ${file} has no ${k}`);
  return out.join('\n');
}

function build() {
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });
  const srcs = fs.readdirSync('lists/src').filter((f) => f.endsWith('.beni')).map((f) => `lists/src/${f}`);
  const r = spawnSync(path.join(repo, 'zig-out/bin/beni'),
    ['build', '--platform=node', '--library', '--no-cache', '--root=lists/src', `--out=${OUT}/A`, ...srcs], { encoding: 'utf8' });
  process.stdout.write(r.stdout); process.stderr.write(r.stderr);
  if (r.status !== 0) process.exit(1);
  for (const tree of ['R', 'C']) {
    fs.cpSync(`${OUT}/A`, `${OUT}/${tree}`, { recursive: true });
    const files = [...fs.readdirSync(`${OUT}/A`).filter((f) => f.endsWith('.mjs')), ...fs.readdirSync(`${OUT}/A/_core`).filter((f) => f.endsWith('.mjs')).map((f) => `_core/${f}`)];
    for (const f of files) {
      if (f.endsWith('.foreign.mjs') || f === '_core/List.mjs') continue; // the list core is the candidate's
      let t = fs.readFileSync(`${OUT}/A/${f}`, 'utf8');
      const extra = tree === 'C' && REWRITES[f] ? 'import { span as $span, SA as $SA, SO as $SO, $fromBuilder, $fromBuilderRev } from "list-syntax";\n' : '';
      t = rewriteModule(t, extra);
      if (tree === 'C') t = applyC(f, t);
      fs.writeFileSync(`${OUT}/${tree}/${f}`, t);
    }
  }
  console.log('built dist/lists/{A,R,C}');
  buildFirst();
}

// E1 (§17): the array-first sources against the array-first core/List, in a copy of core/
function buildFirst() {
  const core = `${OUT}/first-core`, raw = `${OUT}/E1raw`, out = `${OUT}/E1`;
  fs.cpSync(path.join(repo, 'core'), core, { recursive: true });
  for (const f of ['List.beni', 'List.js']) fs.copyFileSync(`lists/first-core/${f}`, `${core}/${f}`);
  const srcs = fs.readdirSync('lists/first').filter((f) => f.endsWith('.beni')).map((f) => `lists/first/${f}`);
  const r = spawnSync(path.join(repo, 'zig-out/bin/beni'),
    ['build', '--platform=node', '--library', '--no-cache', `--core-root=${core}`, '--root=lists/first', `--out=${raw}`, ...srcs], { encoding: 'utf8' });
  process.stdout.write(r.stdout); process.stderr.write(r.stderr);
  if (r.status !== 0) process.exit(1);
  fs.cpSync(raw, out, { recursive: true });
  const files = [...fs.readdirSync(raw).filter((f) => f.endsWith('.mjs')), ...fs.readdirSync(`${raw}/_core`).filter((f) => f.endsWith('.mjs')).map((f) => `_core/${f}`)];
  for (const f of files) {
    if (f.endsWith('.foreign.mjs')) continue;
    fs.writeFileSync(`${out}/${f}`, rewriteModule(fs.readFileSync(`${raw}/${f}`, 'utf8')));
  }
  console.log('built dist/lists/E1');
}

// ---------------------------------------------------------------------------------------------
function plugin(name) {
  const c = CAND[name], tree = path.join(OUT, c.tree), rt = path.join(here, c.rt);
  const basics = path.join(OUT, `basics-${name}.mjs`);
  if (c.core) fs.writeFileSync(basics, `export * from ${JSON.stringify(path.join(tree, '_core/Basics.foreign.mjs'))};\nexport { append } from ${JSON.stringify(rt)};\n`);
  if (c.first) fs.writeFileSync(basics, `export * from ${JSON.stringify(path.join(tree, '_core/Basics.foreign.mjs'))};\nexport { basicsAppend as append } from ${JSON.stringify(rt)};\n`);
  return {
    name: 'beni-lists',
    setup(b) {
      b.onResolve({ filter: /^(list-rt|list-syntax)$/ }, () => ({ path: rt }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
      if (c.core) {
        b.onResolve({ filter: /(^|\/)_core\/List\.mjs$/ }, () => ({ path: path.join(here, c.core) }));
        b.onResolve({ filter: /^\.\/Basics\.foreign\.mjs$/ }, (a) => (a.importer.endsWith('Basics.mjs') ? { path: basics } : undefined));
      }
      if (c.first) {
        b.onResolve({ filter: /^\.\/List\.foreign\.mjs$/ }, () => ({ path: rt }));
        b.onResolve({ filter: /^\.\/Basics\.foreign\.mjs$/ }, (a) => (a.importer.endsWith('Basics.mjs') ? { path: basics } : undefined));
      }
    },
  };
}
const bundle = (name, contents, extra) => esbuild.build({
  stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, platform: 'neutral', target: 'es2023',
  define: { ADA_T: '256', ...CAND[name].define }, mainFields: ['module', 'main'], logLevel: 'error', plugins: [plugin(name)], ...extra,
});

if (mode === 'build') build();
else if (mode === 'test') {
  const outs = {};
  for (const name of NAMES) {
    const file = path.join(OUT, `test-${name}.js`);
    await bundle(name, `import { test } from './lists/harness.js'; console.log(test());`, { format: 'iife', outfile: file });
    const r = spawnSync(process.execPath, ['--stack-size=4000', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) { console.log(name, 'FAILED', r.stderr.slice(-2500)); process.exitCode = 1; continue; }
    outs[name] = r.stdout.trim().split('\n');
    console.log(name.padEnd(4), outs[name].length, 'checks');
  }
  const ref = outs.A;
  for (const name of Object.keys(outs)) {
    const diff = outs[name].map((l, i) => [l, ref[i]]).filter(([a, b]) => a !== b);
    if (outs[name].length !== ref.length || diff.length) { console.log(name, 'DIFFERS from A:', diff.slice(0, 6)); process.exitCode = 1; }
  }
  if (ref.some((l) => l.includes('unchanged false'))) { console.log('A changed its input'); process.exitCode = 1; }
  if (!process.exitCode) console.log(`all ${Object.keys(outs).length} candidates agree on ${ref.length} checks`);
} else if (mode === 'bench') {
  const core = process.argv[3] ?? '13';
  const only = process.argv.slice(4).length ? process.argv.slice(4) : NAMES;
  fs.mkdirSync('results', { recursive: true });
  // one process per (candidate, size); an op over 3 s per call is not run at the next size, and a
  // process that dies (heap exhausted at --max-old-space-size=4096) is restarted without the op
  // that killed it, which is recorded as `crashed`
  for (const name of only) {
    const file = path.join(OUT, `bench-${name}.js`);
    await bundle(name, `import { run } from './lists/harness.js'; run(${JSON.stringify(name)}, +process.argv[2], JSON.parse(process.argv[3]));`, { format: 'iife', outfile: file });
    const t0 = Date.now(), load = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
    let slow = process.env.SKIP ? process.env.SKIP.split(';') : [], count = 0;
    for (const n of process.env.SIZES ? process.env.SIZES.split(',').map(Number) : [10, 100, 1000, 10000, 100000]) {
      // SKIP_AT='<op>@<n>;…' leaves one op out at one size (§17: A's 107-second `acc ++ [x]`)
      const at = (process.env.SKIP_AT ?? '').split(';').filter((s) => s.endsWith('@' + n)).map((s) => s.slice(0, s.lastIndexOf('@')));
      const skip = [...slow, ...at.filter((o) => (process.env.SKIP_AT_IMPL ?? name) === name)], next = [];
      for (;;) {
        const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', '--max-old-space-size=4096', file, String(n), JSON.stringify(skip)], { encoding: 'utf8', maxBuffer: 1 << 26 });
        const lines = r.stdout.split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l));
        const done = lines.filter((l) => !l.start);
        for (const l of done) if (l.med > 3e9) next.push(l.op);
        fs.appendFileSync(RES, done.map((l) => JSON.stringify(l)).join('\n') + (done.length ? '\n' : ''));
        count += done.length;
        if (r.status === 0) break;
        const starts = lines.filter((l) => l.start), killer = starts.length ? starts[starts.length - 1].start : null;
        if (!killer || skip.includes(killer)) { console.error(name, n, 'FAILED', r.stderr.slice(-800)); break; }
        const why = (r.stderr.match(/heap out of memory|Ineffective mark-compacts|Maximum call stack|[A-Z][a-z]+Error[^\n]*/) ?? [`exit ${r.status}`])[0];
        console.log(`${name} n=${n}: ${killer} crashed (${why}); restarting without it`);
        fs.appendFileSync(RES, JSON.stringify({ engine: 'node', impl: name, op: killer, n, crashed: why }) + '\n');
        skip.push(killer);
        next.push(killer);
      }
      slow = [...slow, ...next];
      if (n < 100000) for (const op of next) fs.appendFileSync(RES, JSON.stringify({ engine: 'node', impl: name, op, n: n * 10, skipped: 'over 3 s per call, or crashed, at the size before' }) + '\n');
    }
    const load2 = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
    console.log(name, count, 'cells', ((Date.now() - t0) / 1000).toFixed(1) + ' s', `load ${load} -> ${load2}`);
  }
} else if (mode === 'alone') {
  // §17: every (candidate, op, size) in a process of its own, so no op runs on a heap or JIT state
  // that another op left behind; lines are tagged `alone` (A's 107-second `acc ++ [x]` at 100 000 is
  // left out). `node lists.mjs alone [core] [candidate…]`, SIZES as for bench.
  const core = process.argv[3] ?? '13';
  const only = process.argv.slice(4).length ? process.argv.slice(4) : ['A', 'E1', 'E1t'];
  const sizes = process.env.SIZES ? process.env.SIZES.split(',').map(Number) : [1000, 10000, 100000];
  for (const name of only) {
    const file = path.join(OUT, `bench-${name}.js`);
    await bundle(name, `import { run } from './lists/harness.js'; run(${JSON.stringify(name)}, +process.argv[2], JSON.parse(process.argv[3]));`, { format: 'iife', outfile: file });
    const t0 = Date.now();
    let count = 0;
    for (const n of sizes) for (const op of ALL) {
      if (name === 'A' && n === 100000 && op.startsWith('append in a loop')) continue;
      const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', '--max-old-space-size=4096', file, String(n), '[]'], { encoding: 'utf8', maxBuffer: 1 << 26, env: { ...process.env, ONLY: op } });
      const done = r.stdout.split('\n').filter((l) => l.startsWith('{')).map((l) => JSON.parse(l)).filter((l) => !l.start).map((l) => ({ ...l, alone: true }));
      if (!done.length) done.push({ engine: 'node', impl: name, op, n, alone: true, crashed: (r.stderr.match(/heap out of memory|Maximum call stack/) ?? [`exit ${r.status}`])[0] });
      fs.appendFileSync(RES, done.map((l) => JSON.stringify(l)).join('\n') + '\n');
      count += done.length;
    }
    console.log(name, count, 'cells alone', ((Date.now() - t0) / 1000).toFixed(1) + ' s', `load ${fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ')}`);
  }
} else if (mode === 'mem') {
  const core = process.argv[3] ?? '13';
  const OPS = ['map, recursive', 'map, accumulator + reverse', 'merge sort', 'pairwise', 'x :: acc, then reverse', 'paths sharing tails, all kept',
    'into a record field', 'into a tuple (partition)', 'foldr building a list', 'List.map', 'add + remove oldest, steady'];
  // §17: MEMOPS=all measures every op, at MEMSIZES (default 1000,10000,100000); A's `acc ++ [x]`
  // takes 107 s a call at 100 000 and is left out there
  const all = process.env.MEMOPS === 'all';
  const sizes = all ? (process.env.MEMSIZES ?? '1000,10000,100000').split(',').map(Number) : [10000, 100000];
  for (const name of process.env.CANDS ? NAMES : ['A', 'B', 'C', 'D']) {
    const file = path.join(OUT, `mem-${name}.js`);
    await bundle(name, `import { mem } from './lists/harness.js'; mem(${JSON.stringify(name)}, process.argv[2], +process.argv[3]);`, { format: 'iife', outfile: file });
    for (const n of sizes) for (const op of all ? ALL : OPS) {
      if (all && n === 100000 && op.startsWith('append in a loop') && name === 'A') continue;
      const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', '--max-old-space-size=4096', file, op, String(n)], { encoding: 'utf8', timeout: 120000 });
      const line = r.stdout.split('\n').find((l) => l.startsWith('{')) ?? JSON.stringify({ engine: 'node', impl: name, op, n, err: r.signal ? `killed ${r.signal}` : `exit ${r.status}: ${r.stderr.split('\n').filter(Boolean).slice(-1)[0]}` });
      fs.appendFileSync(MEMRES, line + '\n');
      console.log(line);
    }
  }
} else if (mode === 'size') {
  // What each design ships for sequences: the list runtime the scenarios reach plus the Array
  // sibling of §15 (two-type baseline), or the one runtime that serves both (single type).
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const LIST = 'List$cons, List$foldl, List$foldr, List$map, List$filter, List$reverse, List$range, List$sum, List$append, List$concat, List$concatMap, List$map2';
  const SYN = '$nil, $cons, $isNil, $isCons, $hd, $tl';
  const ARR = 'length, get, set, push, pop, slice, concat, fromCons, toCons, sort, toArray';
  const entries = {
    'A: cons list (compiled core/List + List.js)': `export { ${LIST} } from ${JSON.stringify(path.join(OUT, 'A/_core/List.mjs'))}; export { eq, compare } from ${JSON.stringify(path.join(OUT, 'A/_core/List.foreign.mjs'))};`,
    'A: Array sibling (adaptive, §15)': `export { ${ARR} } from './ports/adaptive.js';`,
    'A: both': `export { ${LIST} } from ${JSON.stringify(path.join(OUT, 'A/_core/List.mjs'))}; export { eq, compare } from ${JSON.stringify(path.join(OUT, 'A/_core/List.foreign.mjs'))}; export { ${ARR} } from './ports/adaptive.js';`,
    'B: one runtime (single.js + list core)': `export { ${LIST}, ${SYN} } from './lists/core-single.js'; export { ${ARR}, eq } from './ports/single.js';`,
    'C: B + builder helpers': `export { ${LIST}, ${SYN}, span, SA, SO, $fromBuilder, $fromBuilderRev } from './lists/core-single.js'; export { ${ARR}, eq } from './ports/single.js';`,
    'D: one runtime (funkia + adapters)': `export { ${LIST}, ${SYN} } from './lists/core-funkia.js'; export { ${ARR} } from './ports/funkia.js';`,
  };
  console.log('| runtime | min | gzip | brotli |\n|---|--:|--:|--:|');
  for (const [label, contents] of Object.entries(entries)) {
    const r = await esbuild.build({ stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser', define: { ADA_T: '256' }, mainFields: ['module', 'main'], logLevel: 'error' });
    const t = r.outputFiles[0].text;
    console.log(`| ${label} | ${t.length} | ${zlib.gzipSync(Buffer.from(t), { level: 9 }).length} | **${br(t)}** |`);
  }
} else if (mode === 'tables') {
  const file = process.argv[3] ?? 'results/lists.jsonl';
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const groups = new Map(), flags = new Map();
  for (const r of rows) {
    const k = `${r.impl}|${r.op}|${r.n}`;
    if (r.med === undefined) { flags.set(k, r.overflow ? 'stack overflow' : r.crashed ? 'heap exhausted' : 'not run'); continue; }
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r.med);
  }
  const cell = new Map(), spread = [];
  for (const [k, ms] of groups) {
    ms.sort((a, b) => a - b); cell.set(k, ms[ms.length >> 1]);
    if (ms.length > 2) spread.push((ms[Math.min(ms.length - 1, Math.round(0.75 * (ms.length - 1)))] - ms[Math.round(0.25 * (ms.length - 1))]) / ms[ms.length >> 1]);
  }
  const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const ratio = (x) => (x < 0.095 ? x.toFixed(2) : x < 10 ? x.toFixed(1) : Math.round(x).toLocaleString('en')) + '×';
  const ops = [...new Set(rows.filter((r) => r.sc).map((r) => `${r.sc}|${r.op}`))];
  const sizes = [...new Set(rows.map((r) => r.n))].sort((a, b) => a - b);
  const get = (c, op, n) => cell.get(`${c}|${op}|${n}`) ?? flags.get(`${c}|${op}|${n}`);
  let last = '';
  for (const o of ops) {
    const [sc, op] = o.split('|');
    if (sc !== last) { console.log(`\n**${sc}**\n\n| op | n | A (cons) | Ac | B | C | D |\n|---|--:|--:|--:|--:|--:|--:|`); last = sc; }
    for (const n of sizes) {
      const a = get('A', op, n);
      if (a === undefined) continue;
      const cols = ['A', 'Ac', 'B', 'C', 'D'].map((c) => {
        const v = get(c, op, n);
        if (v === undefined) return '—';
        if (typeof v === 'string') return v;
        return c === 'A' || typeof a !== 'number' ? fmt(v) : `${fmt(v)} (${ratio(v / a)})`;
      });
      console.log(`| ${op} | ${n.toLocaleString('en')} | ${cols.join(' | ')} |`);
    }
  }
  const timed = rows.filter((r) => r.med !== undefined), rel = timed.map((r) => (r.q3 - r.q1) / r.med).sort((a, b) => a - b);
  console.log(`\nwithin a run: ${timed.length} cells, median IQR/median ${(100 * rel[rel.length >> 1]).toFixed(1)} %, 90th percentile ${(100 * rel[Math.floor(rel.length * 0.9)]).toFixed(1)} %`);
  if (spread.length) { spread.sort((a, b) => a - b); console.log(`between rounds: IQR of round medians / median: median ${(100 * spread[spread.length >> 1]).toFixed(0)} %, 90th percentile ${(100 * spread[Math.floor(spread.length * 0.9)]).toFixed(0)} %`); }
  const memFile = 'results/lists-mem.jsonl';
  if (fs.existsSync(memFile)) {
    const mrows = fs.readFileSync(memFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const mc = new Map();
    for (const r of mrows) mc.set(`${r.impl}|${r.op}|${r.n}`, r);
    const kb = (b) => (b / 1024 >= 1024 ? (b / 1048576).toFixed(1) + ' MB' : (b / 1024).toFixed(0) + ' KB');
    console.log('\n| op | n | ' + ['A', 'B', 'C', 'D'].map((c) => `${c} peak / retained`).join(' | ') + ' |\n|---|--:|--:|--:|--:|--:|');
    for (const op of [...new Set(mrows.map((r) => r.op))]) for (const n of [10000, 100000]) {
      console.log(`| ${op} | ${n.toLocaleString('en')} | ` + ['A', 'B', 'C', 'D'].map((c) => {
        const r = mc.get(`${c}|${op}|${n}`);
        if (!r) return '—';
        if (r.err) return r.err;
        return `${kb(r.peakKB * 1024)} / ${kb(r.retained)}`;
      }).join(' | ') + ' |');
    }
  }
} else if (mode === 'tables-arrays') {
  // §15's array scenarios under the single types: adaptive256 (A's Array), single256 (B and C),
  // funkia (D), from `RESULTS=results/single-scenarios.jsonl node scenarios.mjs bench …`
  const file = process.argv[3] ?? 'results/single-scenarios.jsonl';
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((r) => r.med !== undefined);
  const g = new Map();
  for (const r of rows) { const k = `${r.impl}|${r.sc}|${r.op}|${r.n}`; if (!g.has(k)) g.set(k, []); g.get(k).push(r.med); }
  const med = (k) => { const v = g.get(k); if (!v) return undefined; v.sort((a, b) => a - b); return v[v.length >> 1]; };
  const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const ratio = (x) => (x < 10 ? x.toFixed(2) : x < 100 ? x.toFixed(1) : Math.round(x).toLocaleString('en')) + '×';
  const others = (process.argv[4] ?? 'single256,funkia').split(','); // §17: `tables-arrays results/first-scenarios.jsonl single256,firsttail`
  console.log(`| scenario | op | n | adaptive256 (A) | ${others.join(' | ')} |\n|---|---|--:|--:|${others.map(() => '--:').join('|')}|`);
  for (const key of [...new Set(rows.map((r) => `${r.sc}|${r.op}|${r.n}`))]) {
    const [sc, op, n] = key.split('|');
    const a = med(`adaptive256|${key}`);
    if (a === undefined) continue;
    const c = (impl) => { const v = med(`${impl}|${key}`); return v === undefined ? '—' : `${fmt(v)} (${ratio(v / a)})`; };
    console.log(`| ${sc} | ${op} | ${(+n).toLocaleString('en')} | ${fmt(a)} | ${others.map(c).join(' | ')} |`);
  }
} else if (mode === 'stack') {
  // §17: every cell once at n = 100 000 on Node's DEFAULT stack (no --stack-size), one process per
  // candidate; a RangeError is a stack overflow. A's `acc ++ [x]` (107 s a call) is not run.
  fs.mkdirSync('results', { recursive: true });
  for (const name of NAMES) {
    const file = path.join(OUT, `stack-${name}.js`);
    await bundle(name, `import { stack } from './lists/harness.js'; stack(${JSON.stringify(name)}, 100000, JSON.parse(process.argv[2]));`, { format: 'iife', outfile: file });
    const skip = name === 'A' ? ['append in a loop, acc ++ [x]'] : [];
    const r = spawnSync(process.execPath, ['--max-old-space-size=4096', file, JSON.stringify(skip)], { encoding: 'utf8', maxBuffer: 1 << 26 });
    const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
    fs.appendFileSync('results/first-stack.jsonl', lines.join('\n') + '\n');
    const rows = lines.map((l) => JSON.parse(l));
    console.log(name, `exit ${r.status}`, rows.filter((x) => x.stack !== 'ok').map((x) => `${x.op}: ${x.stack}`).join('; ') || 'every cell ok');
  }
} else if (mode === 'size-first') {
  // §17: the WHOLE sequence surface each design ships, esbuild --minify, tree-shaken, brotli 11.
  // Every public function is reached from lists/surface/*/Surface.beni. A is today's `List` (core)
  // plus §15's `Array` (scenarios/Array.beni over the adaptive sibling); E1 and E1t are the one
  // array-first `List` over their siblings. "runtime" is the JavaScript sibling alone.
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
  const beni = (args) => { const r = spawnSync(path.join(repo, 'zig-out/bin/beni'), ['build', '--platform=node', '--library', '--no-cache', ...args], { encoding: 'utf8' }); if (r.status !== 0) { console.log(r.stdout, r.stderr); process.exit(1); } };
  if (!fs.existsSync('dist/core/Array.beni') || !fs.existsSync('dist/sib-adaptive256.js')) { console.log('run `node scenarios.mjs build` and `node scenarios.mjs test` first (they write dist/core and dist/sib-adaptive256.js)'); process.exit(1); }
  if (!fs.existsSync(`${OUT}/first-core/List.beni`)) { console.log('run `node lists.mjs build` first'); process.exit(1); }
  beni(['--core-root=dist/core', '--root=lists/surface/A', `--out=${OUT}/surfA`, 'lists/surface/A/Surface.beni']);
  beni([`--core-root=${OUT}/first-core`, '--root=lists/surface/E1', `--out=${OUT}/surfE1raw`, 'lists/surface/E1/Surface.beni']);
  fs.rmSync(`${OUT}/surfE1`, { recursive: true, force: true });
  fs.cpSync(`${OUT}/surfE1raw`, `${OUT}/surfE1`, { recursive: true });
  for (const f of ['Surface.mjs', ...fs.readdirSync(`${OUT}/surfE1raw/_core`).filter((x) => x.endsWith('.mjs') && !x.endsWith('.foreign.mjs')).map((x) => `_core/${x}`)])
    fs.writeFileSync(`${OUT}/surfE1/${f}`, rewriteModule(fs.readFileSync(`${OUT}/surfE1raw/${f}`, 'utf8')));
  const FOREIGN = 'cons, eq, compare, length, unsafeGet, set, push, pop, slice, append, builder, add, done, basicsAppend, $nil, $isNil, $isCons, $hd, $tl, $cons, $fromArray';
  const one = async (label, contents, port) => {
    const plug = port ? [{ name: 'first', setup(b) {
      b.onResolve({ filter: /^list-syntax$|^\.\/List\.foreign\.mjs$/ }, () => ({ path: path.join(here, port) }));
      b.onResolve({ filter: /^\.\/Basics\.foreign\.mjs$/ }, (a) => {
        if (!a.importer.endsWith('Basics.mjs')) return undefined;
        const f = path.join(OUT, `size-basics-${path.basename(port)}`);
        fs.writeFileSync(f, `export * from ${JSON.stringify(path.join(OUT, 'surfE1/_core/Basics.foreign.mjs'))};\nexport { basicsAppend as append } from ${JSON.stringify(path.join(here, port))};\n`);
        return { path: f };
      });
    } }] : [{ name: 'arr', setup(b) { b.onResolve({ filter: /\/?Array\.foreign\.mjs$/ }, () => ({ path: path.join(here, 'dist/sib-adaptive256.js') })); } }];
    const r = await esbuild.build({ stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser', define: { ADA_T: '256' }, mainFields: ['module', 'main'], logLevel: 'error', plugins: plug });
    const t = r.outputFiles[0].text;
    console.log(`| ${label} | ${t.length} | ${gz(t)} | **${br(t)}** |`);
  };
  console.log('| surface | min | gzip | brotli |\n|---|--:|--:|--:|');
  const surfA = JSON.stringify(path.join(OUT, 'surfA/Surface.mjs')), surfE = JSON.stringify(path.join(OUT, 'surfE1/Surface.mjs'));
  await one('A: `List` + `Array`, whole surface', `export * from ${surfA};`);
  await one('A: runtime (`List.js`, `++`, adaptive sibling)', `export { cons, eq, compare } from ${JSON.stringify(path.join(repo, 'core/List.js'))}; export { append as basicsAppend } from ${JSON.stringify(path.join(repo, 'core/Basics.js'))}; export { length, unsafeGet, set, push, pop, slice, append, fromList, toList, sortWith } from ${JSON.stringify(path.join(here, "dist/sib-adaptive256.js"))};`);
  await one('E1: one `List`, whole surface', `export * from ${surfE};`, 'ports/first.js');
  await one('E1: runtime (ports/first.js)', `export { ${FOREIGN} } from './ports/first.js';`, 'ports/first.js');
  await one('E1t: one `List`, whole surface', `export * from ${surfE};`, 'ports/first-tail.js');
  await one('E1t: runtime (ports/first-tail.js)', `export { ${FOREIGN} } from './ports/first-tail.js';`, 'ports/first-tail.js');
} else if (mode === 'tables-first') {
  // §17's tables: A against the array-first candidates, per op and size, medians of the round medians
  const file = process.argv[3] ?? 'results/first.jsonl';
  const cands = (process.argv[4] ?? 'A,E1,E1t').split(',');
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)).filter((r) => !!r.alone === !!process.env.ALONE); // ALONE=1: the `alone` rows
  const g = new Map(), flag = new Map(), spread = [];
  for (const r of rows) {
    const k = `${r.impl}|${r.op}|${r.n}`;
    if (r.med === undefined) { flag.set(k, r.overflow ? 'SO' : r.crashed ? 'OOM' : 'not run'); continue; }
    if (!g.has(k)) g.set(k, []);
    g.get(k).push(r.med);
  }
  const med = (k) => { const v = g.get(k); if (!v) return flag.get(k); const s = v.slice().sort((a, b) => a - b); if (s.length > 2) spread.push((s[s.length - 1] - s[0]) / s[s.length >> 1]); return s[s.length >> 1]; };
  const fmt = (ns) => typeof ns !== 'number' ? (ns ?? '—') : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const ratio = (x) => (x < 0.095 ? x.toFixed(2) : x < 10 ? x.toFixed(1) : Math.round(x).toLocaleString('en')) + '×';
  const ops = [...new Set(rows.filter((r) => r.op && r.sc).map((r) => `${r.sc}|${r.op}`))];
  console.log(`| scenario | op | A: 1 000 / 10 000 / 100 000 | ${cands.slice(1).map((c) => `${c} ÷ A`).join(' | ')} |\n|---|---|--:|${cands.slice(1).map(() => '--:').join('|')}|`);
  for (const o of ops) {
    const [sc, op] = o.split('|');
    const a = [1000, 10000, 100000].map((n) => med(`A|${op}|${n}`));
    const cols = cands.slice(1).map((c) => [1000, 10000, 100000].map((n, i) => {
      const v = med(`${c}|${op}|${n}`);
      if (typeof v !== 'number') return v ?? '—';
      return typeof a[i] === 'number' ? ratio(v / a[i]) : fmt(v);
    }).join(' / '));
    console.log(`| ${sc} | ${op} | ${a.map(fmt).join(' / ')} | ${cols.join(' | ')} |`);
  }
  const timed = rows.filter((r) => r.med !== undefined), rel = timed.map((r) => (r.q3 - r.q1) / r.med).sort((x, y) => x - y);
  spread.sort((x, y) => x - y);
  console.log(`\nwithin a run: ${timed.length} cells, median IQR/median ${(100 * rel[rel.length >> 1]).toFixed(1)} %; between rounds: range of a cell's round medians / median: median ${(100 * spread[spread.length >> 1]).toFixed(0)} %, 90th percentile ${(100 * spread[Math.floor(spread.length * 0.9)]).toFixed(0)} %`);
  const memFile = process.argv[5] ?? 'results/first-mem.jsonl';
  if (fs.existsSync(memFile)) {
    const mrows = fs.readFileSync(memFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
    const mc = new Map();
    for (const r of mrows) mc.set(`${r.impl}|${r.op}|${r.n}`, r);
    const mb = (b) => (b >= 1048576 ? (b / 1048576).toFixed(1) + ' MB' : (b / 1024).toFixed(0) + ' KB');
    console.log(`\n| op | n | ${cands.map((c) => `${c} peak / retained`).join(' | ')} |\n|---|--:|${cands.map(() => '--:').join('|')}|`);
    for (const op of [...new Set(mrows.map((r) => r.op))]) for (const n of [1000, 10000, 100000]) {
      console.log(`| ${op} | ${n.toLocaleString('en')} | ` + cands.map((c) => {
        const r = mc.get(`${c}|${op}|${n}`);
        if (!r) return '—';
        if (r.err) return r.err;
        return `${mb(r.peakKB * 1024)} / ${mb(r.retained)}`;
      }).join(' | ') + ' |');
    }
  }
} else {
  console.log('usage: node lists.mjs build | test | bench [core] [candidate…] | mem [core] | stack | size | size-first | tables [file] | tables-arrays [file] | tables-first [file] [cands] [memfile]');
}
