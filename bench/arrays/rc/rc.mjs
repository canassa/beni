// research/42: can beni write arrays in place by keeping its own reference information in the
// JavaScript it emits? Node only. Run from bench/arrays, after `node scenarios.mjs build` (which
// compiles research/38 §15's scenarios into dist/beni with ../../zig-out/bin/beni).
//
//   node rc/rc.mjs build            dist/rc/<variant>/: dist/beni with the variant's hand
//                                   transformation laid over it (rc/src/r0, rc/src/r1), r2
//                                   derived from r1 by deleting every line marked `// R1`, and
//                                   r2plain derived from r2 by turning every read into `a[i]`
//   node rc/rc.mjs test             every variant runs the differential test; all must agree
//   node rc/rc.mjs bench [core] [variant[:sc,sc]…]
//                                   one pinned `node --expose-gc` process per variant; appends
//                                   to results/rc.jsonl (or $RESULTS)
//   node rc/rc.mjs size             emitted-code growth: the scenario modules plus core's
//                                   Array and List, esbuild --minify, brotli 11; and the siblings
//   node rc/rc.mjs tables [file]    the report's tables
//
// Variants (research/42 §1):
//   adaptive  §15's adaptive array, T = 256, no uniqueness: the baseline
//   cow       plain copy-on-write
//   R0        static: in place where last use and interface summaries prove a value unique,
//             a copy where a caller cannot prove what a callee consumes
//   R1        full counts, Perceus-style dup/drop with borrowing, over adaptive
//   R2        a sticky shared bit (R1 minus every drop), over adaptive
//   R2plain   R2 over plain JS arrays only: in place when unique, a whole copy when shared
import * as esbuild from 'esbuild';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
process.chdir(root);
const mode = process.argv[2];

const V = {
  adaptive: { tree: 'beni', port: '../ports/adaptive.js', hooks: 'baseline' },
  cow: { tree: 'beni', port: '../ports/cow.js', hooks: 'baseline' },
  R0: { tree: 'r0', port: '../rc/ports/r0.js', hooks: 'r0' },
  R1: { tree: 'r1', port: '../rc/ports/rc-adaptive.js', hooks: 'rc', rc: 'r1' },
  R2: { tree: 'r2', port: '../rc/ports/rc-adaptive.js', hooks: 'rc', rc: 'r2' },
  R2plain: { tree: 'r2plain', port: '../rc/ports/rc-plain.js', hooks: 'rc', rc: 'r2' },
};
const NAMES = Object.keys(V);
const ALL_SC = ['table', 'decoded', 'grid', 'build', 'history', 'interop', 'memory'];

// ---- the variant trees --------------------------------------------------------------------------
const walk = (d, pre = '') => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(path.join(d, e.name), pre + e.name + '/') : [pre + e.name]));
const r2of = (s) => s.split('\n').filter((l) => !l.includes('// R1')).join('\n');
const bare = (s) => s
  .replace(/Array\$unsafeGet\(([\w$.]+), ([\w$.]+)\)/g, '$1[$2]')
  .replace(/Array\$length\(([\w$.]+)\)/g, '$1.length');
function buildTrees() {
  if (!fs.existsSync('dist/beni/Table.mjs')) throw new Error('run `node scenarios.mjs build` first');
  fs.rmSync('dist/rc', { recursive: true, force: true });
  for (const t of ['r0', 'r1', 'r2', 'r2plain']) fs.cpSync('dist/beni', `dist/rc/${t}`, { recursive: true });
  for (const f of walk('rc/src/r0')) fs.copyFileSync(`rc/src/r0/${f}`, `dist/rc/r0/${f}`);
  for (const f of walk('rc/src/r1')) {
    const s = fs.readFileSync(`rc/src/r1/${f}`, 'utf8');
    fs.writeFileSync(`dist/rc/r1/${f}`, s);
    const r2 = r2of(s);
    if (/\$drop(A)?\(|\$drop\(|--\w+\$\d*\.rc/.test(r2.replace(/import[^\n]*/g, ''))) throw new Error(`r2: a drop survived in ${f}`);
    fs.writeFileSync(`dist/rc/r2/${f}`, r2);
  }
  // r2plain: every array is a plain JS array, so every read is `a[i]`/`a.length`, in every module
  for (const f of walk('dist/rc/r2')) {
    if (!f.endsWith('.mjs') || f.includes('foreign')) continue;
    const s = bare(fs.readFileSync(`dist/rc/r2/${f}`, 'utf8'));
    if (f !== '_core/Array.mjs' && /Array\$(unsafeGet|length)\(/.test(s)) throw new Error(`r2plain: a read survived in ${f}`);
    fs.writeFileSync(`dist/rc/r2plain/${f}`, s);
  }
  console.log('built dist/rc/{r0,r1,r2,r2plain}');
}

// ---- siblings and hooks ------------------------------------------------------------------------
const TRIE_CHUNKS = `import * as T from '../ports/trie.js';
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
export const chunks = (a) => { if (Array.isArray(a)) return [a]; const out = leaves(a.r, a.s, []); out.push(a.t); return out; };`;
function sibling(name) {
  const v = V[name];
  const rc = v.hooks === 'rc';
  const extra = name === 'R0' ? `export { setU, pushU, popU, concatU, copy } from '${v.port}';` : '';
  const src = `export { length, get as unsafeGet, set, push, pop, slice, concat as append, fromCons as fromList } from '${v.port}';
import { toCons, sort, toArray${rc ? ', adopt, pin' : ''} } from '${v.port}';
${extra}
const NIL = { $: 0, a: null, b: null };
export const toList = (a) => toCons(a, NIL);
export const sortWith = (a, f) => sort(a, (x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; });
${rc ? `export const fromJs = adopt;
// what JavaScript is handed it may keep: a plain array goes out as itself and is pinned (O7)
export const toJs = (a) => { const r = toArray(a); return r === a ? pin(a) : r; };
export { pin };
export const copy = (a) => a;` : `export const fromJs = (arr) => arr;
export const toJs = (a) => toArray(a);
export const pin = (a) => a;
${name === 'R0' ? '' : 'export const copy = (a) => a;'}`}
${name === 'R2plain' ? 'export const chunks = (a) => [a];' : TRIE_CHUNKS}
`;
  const file = path.join(root, 'dist', `rc-sib-${name}.js`);
  if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== src) fs.writeFileSync(file, src);
  return file;
}
function hooks(name) {
  const h = V[name].hooks;
  const body = {
    baseline: `const id = (x) => x;
export const keep = id, giveModel = id, giveGrid = id, giveArray = id, giveRetained = id, retain = () => {};`,
    r0: `import { copy } from 'array-sibling';
const id = (x) => x;
export const keep = id, giveArray = copy, retain = () => {};
export const giveModel = (m) => ({ ...m, rows: copy(m.rows) });
export const giveRetained = giveModel;
export const giveGrid = (g) => ({ ...g, cells: copy(g.cells) });`,
    rc: `import { $pin } from 'rc-rt';
const id = (x) => x;
export const keep = $pin, retain = $pin;
export const giveModel = id, giveGrid = id, giveArray = id, giveRetained = id;`,
  }[h];
  const file = path.join(root, 'dist', `rc-hooks-${name}.js`);
  const src = `export const NAME = ${JSON.stringify(h === 'baseline' ? 'baseline' : name)};\n${body}\n`;
  // rounds run side by side on two cores: rewrite a shared file only when it changes
  if (!fs.existsSync(file) || fs.readFileSync(file, 'utf8') !== src) fs.writeFileSync(file, src);
  return file;
}
function plugin(name) {
  const sib = sibling(name), hk = hooks(name), tree = path.join(root, 'dist', V[name].tree === 'beni' ? 'beni' : `rc/${V[name].tree}`);
  return {
    name: 'rc',
    setup(b) {
      b.onResolve({ filter: /^array-sibling$|\/Array\.foreign\.mjs$/ }, () => ({ path: sib }));
      b.onResolve({ filter: /^rc-variant$/ }, () => ({ path: hk }));
      b.onResolve({ filter: /^rc-rt$/ }, () => ({ path: path.join(here, 'rt.js') }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
    },
  };
}
const define = (name) => ({ ADA_T: '256', RC_MODE: JSON.stringify(V[name].rc ?? 'none') });
async function bundle(name, contents, extra) {
  return esbuild.build({
    stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, platform: 'neutral', target: 'es2023',
    define: define(name), mainFields: ['module', 'main'], logLevel: 'error', plugins: [plugin(name)], ...extra,
  });
}

// ---- modes -------------------------------------------------------------------------------------
const node = process.execPath;
if (mode === 'build') {
  buildTrees();
} else if (mode === 'test') {
  const outs = {};
  for (const name of NAMES) {
    const file = path.join(root, 'dist', `rc-test-${name}.js`);
    await bundle(name, `import { test } from './harness.js'; const r = test(); console.log(r.out); console.error(r.mech);`, { format: 'iife', outfile: file });
    const r = spawnSync(node, ['--stack-size=4000', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) { console.log(name, 'FAILED', r.stderr.slice(-2000)); process.exitCode = 1; continue; }
    outs[name] = r.stdout.trim().split('\n');
    console.log(`${name.padEnd(9)} ${outs[name].length} checks; ${r.stderr.trim().split('\n').join('; ')}`);
  }
  for (const m of ['r1', 'r2']) {
    const file = path.join(root, 'dist', `rc-unit-${m}.js`);
    await esbuild.build({ entryPoints: [path.join(here, 'unit.js')], bundle: true, format: 'iife', platform: 'node', outfile: file, define: { RC_MODE: JSON.stringify(m), ADA_T: '256' }, logLevel: 'error' });
    const r = spawnSync(node, [file], { encoding: 'utf8' });
    console.log(`unit ${m}: ${r.stdout.trim()}`);
    if (r.stdout.trim() !== 'ok') process.exitCode = 1;
  }
  const ref = outs.adaptive;
  for (const name of Object.keys(outs)) {
    const diff = outs[name].map((l, i) => [l, ref[i]]).filter(([a, b]) => a !== b);
    if (outs[name].length !== ref.length || diff.length) { console.log(name, 'DIFFERS from adaptive:', diff.slice(0, 6)); process.exitCode = 1; }
  }
  const bad = ref.filter((l) => /CHANGED|escape \d+ false/.test(l));
  if (bad.length) { console.log('adaptive itself:', bad); process.exitCode = 1; }
  if (!process.exitCode) console.log(`all ${Object.keys(outs).length} variants agree on ${ref.length} checks`);
} else if (mode === 'bench') {
  const core = process.argv[3] ?? '13';
  const specs = process.argv.slice(4).length ? process.argv.slice(4) : NAMES;
  fs.mkdirSync('results', { recursive: true });
  for (const spec of specs) {
    const [name, scs] = spec.split(':');
    const sc = scs ? scs.split(',') : ALL_SC;
    const file = path.join(root, 'dist', `rc-bench-${core}-${spec.replace(/[:,]/g, '-')}.js`);
    await bundle(name, `import { run } from './harness.js'; run(${JSON.stringify(name)}, ${JSON.stringify(sc)});`, { format: 'iife', outfile: file });
    const t0 = Date.now();
    const load = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).join(' ');
    const r = spawnSync('taskset', ['-c', core, node, '--expose-gc', '--stack-size=4000', '--max-old-space-size=4096', file], { encoding: 'utf8', maxBuffer: 1 << 26, env: process.env });
    const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
    if (r.status !== 0) console.error(name, 'FAILED', r.stderr.slice(-800));
    fs.appendFileSync(process.env.RESULTS ?? 'results/rc.jsonl', lines.join('\n') + '\n');
    console.log(name, lines.length, 'cells', ((Date.now() - t0) / 1000).toFixed(1) + ' s', `load ${load}`);
  }
} else if (mode === 'size') {
  const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
  const gz = (s) => zlib.gzipSync(Buffer.from(s), { level: 9 }).length;
  // the emitted beni: every scenario module and core's Array and List, bundled without the
  // siblings (marked external) and minified; rt.js is counted with the sibling
  const mods = ['Table', 'Decoded', 'Grid', 'Life', 'Build', 'History', 'Interop'];
  const entry = mods.map((m) => `export * as ${m} from 'beni-out/${m}.mjs';`).join('\n');
  console.log('| emitted beni (7 modules + core Array, List) | raw | min | gzip | brotli |\n|---|--:|--:|--:|--:|');
  const base = {};
  for (const name of ['adaptive', 'R0', 'R1', 'R2', 'R2plain']) {
    let tree = path.join(root, 'dist', V[name].tree === 'beni' ? 'beni' : `rc/${V[name].tree}`);
    if (name === 'R0') {
      // R0's Build.mjs carries an extra, measurement-only function (histogram without inlining)
      fs.rmSync('dist/rc/size-r0', { recursive: true, force: true });
      fs.cpSync(tree, 'dist/rc/size-r0', { recursive: true });
      tree = path.join(root, 'dist/rc/size-r0');
      const b = fs.readFileSync(`${tree}/Build.mjs`, 'utf8').split('\n').filter((l) => !l.startsWith('const Build$histogramNoInline')).join('\n').replace('Build$histogramNoInline, ', '');
      fs.writeFileSync(`${tree}/Build.mjs`, b);
    }
    const raw = mods.map((m) => fs.readFileSync(`${tree}/${m}.mjs`, 'utf8')).join('') + fs.readFileSync(`${tree}/_core/Array.mjs`, 'utf8') + fs.readFileSync(`${tree}/_core/List.mjs`, 'utf8');
    const r = await esbuild.build({
      stdin: { contents: entry, resolveDir: here, loader: 'js' }, bundle: true, format: 'esm', minify: true, write: false, platform: 'neutral',
      logLevel: 'error', plugins: [{ name: 'x', setup(b) {
        b.onResolve({ filter: /\.foreign\.mjs$|^rc-rt$/ }, (a) => ({ path: a.path, external: true }));
        b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
      } }],
    });
    const t = r.outputFiles[0].text;
    const row = { raw: raw.length, min: t.length, gz: gz(t), br: br(t) };
    if (name === 'adaptive') Object.assign(base, row);
    const d = (k) => (name === 'adaptive' ? '' : ` (${row[k] >= base[k] ? '+' : ''}${row[k] - base[k]})`);
    console.log(`| ${name} | ${row.raw}${d('raw')} | ${row.min}${d('min')} | ${row.gz}${d('gz')} | **${row.br}**${d('br')} |`);
  }
  console.log('\n| sibling + rt.js | min | gzip | brotli |\n|---|--:|--:|--:|');
  for (const name of ['adaptive', 'R0', 'R1', 'R2', 'R2plain']) {
    const r = await bundle(name, `export * from 'array-sibling';${V[name].rc ? ` export * from 'rc-rt';` : ''}`, { format: 'esm', minify: true, treeShaking: true, write: false, platform: 'browser' });
    const t = r.outputFiles[0].text;
    console.log(`| ${name} | ${t.length} | ${gz(t)} | **${br(t)}** |`);
  }
} else if (mode === 'tables') {
  const file = process.argv[3] ?? 'results/rc.jsonl';
  const rows = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const groups = new Map();
  for (const r of rows) {
    const k = `${r.impl}|${r.op}|${r.n}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r.med ?? r.bytes);
  }
  const cell = new Map();
  for (const [k, ms] of groups) { ms.sort((a, b) => a - b); cell.set(k, ms[ms.length >> 1]); }
  const fmt = (ns) => ns < 10 ? ns.toFixed(1) + ' ns' : ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e4 ? (ns / 1e3).toFixed(2) + ' µs' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const kb = (b) => (b / 1024).toFixed(b < 10240 ? 1 : 0) + ' KB';
  const ops = [...new Set(rows.map((r) => `${r.sc}|${r.op}|${r.n}`))];
  let lastSc = '';
  for (const o of ops) {
    const [sc, op, n] = o.split('|');
    if (sc !== lastSc) { console.log(`\n**${sc}**\n\n| op | n | ${NAMES.join(' | ')} |\n|---|--:|${NAMES.map(() => '--:').join('|')}|`); lastSc = sc; }
    const base = cell.get(`adaptive|${op}|${n}`);
    console.log(`| ${op} | ${(+n).toLocaleString('en')} | ` + NAMES.map((c) => {
      const v = cell.get(`${c}|${op}|${n}`);
      if (v === undefined) return '—';
      if (sc === 'memory') return kb(v);
      const x = base ? v / base : 0;
      return fmt(v) + (c !== 'adaptive' && base ? ` (${x < 10 ? x.toFixed(2) : Math.round(x).toLocaleString('en')}×)` : '');
    }).join(' | ') + ' |');
  }
  const counts = new Map();
  for (const [k, ms] of groups) counts.set(ms.length, (counts.get(ms.length) ?? 0) + 1);
  console.log(`\nrounds per cell: ${[...counts].map(([a, b]) => `${a}: ${b}`).join(', ')}`);
} else {
  console.log('usage: node rc/rc.mjs build | test | bench [core] [variant[:sc,…]…] | size | tables [file]');
}
