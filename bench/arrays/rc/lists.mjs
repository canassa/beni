// research/42 §8: the list half. Run from bench/arrays after `node lists.mjs build` (research/38
// §16's trees in dist/lists/{A,R,C}).
//
//   node rc/lists.mjs build          dist/rc-lists/{R0,R2}: C and R with rc/lists/decls.js laid over
//   node rc/lists.mjs test           every variant runs rc/lists-harness.js's test; all must agree
//   node rc/lists.mjs bench [core]   one pinned process per (variant, size); results/rc-lists.jsonl
//   node rc/lists.mjs tables [file]
//
// Variants: A (cons cells, today), B (one array type, `::` copies), C (B + §16.3's static rules),
// R0 (C + scalar replacement of a fold's record or tuple state), R2 (B + the sticky shared bit).
import * as esbuild from 'esbuild';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DECLS } from './lists/decls.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
process.chdir(root);
const mode = process.argv[2];
const L = path.join(root, 'dist/lists');
const CAND = {
  A: { tree: `${L}/A`, rt: 'lists/core-cons.js', core: null },
  B: { tree: `${L}/R`, rt: 'lists/core-single.js', core: 'lists/core-single.js' },
  C: { tree: `${L}/C`, rt: 'lists/core-single.js', core: 'lists/core-single.js' },
  R0: { tree: 'dist/rc-lists/R0', rt: 'lists/core-single.js', core: 'lists/core-single.js' },
  R2: { tree: 'dist/rc-lists/R2', rt: 'rc/lists/rt-r2.js', core: 'rc/lists/rt-r2.js' },
};
const NAMES = Object.keys(CAND);

function overlay(from, to, table, extraImport) {
  fs.rmSync(to, { recursive: true, force: true });
  fs.cpSync(from, to, { recursive: true });
  for (const [file, decls] of Object.entries(table)) {
    const parts = fs.readFileSync(`${from}/${file}`, 'utf8').split(/\n(?=const |export |import )/), seen = new Set();
    const out = parts.map((d) => { const m = /^const ([\w$]+) = /.exec(d); if (m && decls[m[1]]) { seen.add(m[1]); return decls[m[1]]; } return d; });
    for (const k of Object.keys(decls)) if (!seen.has(k)) throw new Error(`${file} has no ${k}`);
    fs.writeFileSync(`${to}/${file}`, extraImport + out.join('\n'));
  }
}
function plugin(name) {
  const c = CAND[name], tree = path.resolve(root, c.tree), rt = path.join(root, c.rt);
  const basics = path.join(root, 'dist', `rc-lists-basics-${name}.mjs`);
  if (c.core) fs.writeFileSync(basics, `export * from ${JSON.stringify(path.join(tree, '_core/Basics.foreign.mjs'))};\nexport { append } from ${JSON.stringify(rt)};\n`);
  return {
    name: 'rc-lists',
    setup(b) {
      b.onResolve({ filter: /^(list-rt|list-syntax)$/ }, () => ({ path: rt }));
      b.onResolve({ filter: /^beni-out\// }, (a) => ({ path: path.join(tree, a.path.slice('beni-out/'.length)) }));
      if (c.core) {
        b.onResolve({ filter: /(^|\/)_core\/List\.mjs$/ }, () => ({ path: path.join(root, c.core) }));
        b.onResolve({ filter: /^\.\/Basics\.foreign\.mjs$/ }, (a) => (a.importer.endsWith('Basics.mjs') ? { path: basics } : undefined));
      }
    },
  };
}
const bundle = (name, contents, extra) => esbuild.build({
  stdin: { contents, resolveDir: here, loader: 'js' }, bundle: true, platform: 'neutral', target: 'es2023',
  define: { ADA_T: '256' }, mainFields: ['module', 'main'], logLevel: 'error', plugins: [plugin(name)], ...extra,
});

if (mode === 'build') {
  if (!fs.existsSync(`${L}/C/Lib.mjs`)) throw new Error('run `node lists.mjs build` first');
  overlay(`${L}/C`, 'dist/rc-lists/R0', DECLS.R0, '');
  overlay(`${L}/R`, 'dist/rc-lists/R2', DECLS.R2, 'import { $share } from "list-syntax";\n');
  console.log('built dist/rc-lists/{R0,R2}');
} else if (mode === 'test') {
  const outs = {};
  for (const name of NAMES) {
    const file = path.join(root, 'dist', `rc-lists-test-${name}.js`);
    await bundle(name, `import { test } from './lists-harness.js'; console.log(test());`, { format: 'iife', outfile: file });
    const r = spawnSync(process.execPath, ['--stack-size=4000', file], { encoding: 'utf8', maxBuffer: 1 << 28 });
    if (r.status !== 0) { console.log(name, 'FAILED', r.stderr.slice(-2000)); process.exitCode = 1; continue; }
    outs[name] = r.stdout.trim().split('\n');
    console.log(name.padEnd(4), outs[name].length, 'checks');
  }
  const ref = outs.A;
  for (const name of Object.keys(outs)) {
    const diff = outs[name].map((l, i) => [l, ref[i]]).filter(([a, b]) => a !== b);
    if (outs[name].length !== ref.length || diff.length) { console.log(name, 'DIFFERS from A:', diff.slice(0, 6)); process.exitCode = 1; }
  }
  if (ref.some((l) => /unchanged false|CHANGED/.test(l))) { console.log('A itself changed something'); process.exitCode = 1; }
  if (!process.exitCode) console.log(`all ${Object.keys(outs).length} variants agree on ${ref.length} checks`);
} else if (mode === 'bench') {
  const core = process.argv[3] ?? '13';
  const only = process.argv.slice(4).length ? process.argv.slice(4) : NAMES;
  for (const name of only) {
    const file = path.join(root, 'dist', `rc-lists-bench-${core}-${name}.js`);
    await bundle(name, `import { run } from './lists-harness.js'; run(${JSON.stringify(name)}, +process.argv[2]);`, { format: 'iife', outfile: file });
    for (const n of [1000, 10000, 100000]) {
      const r = spawnSync('taskset', ['-c', core, process.execPath, '--expose-gc', '--stack-size=4000', '--max-old-space-size=4096', file, String(n)], { encoding: 'utf8', maxBuffer: 1 << 26 });
      const lines = r.stdout.split('\n').filter((l) => l.startsWith('{'));
      if (r.status !== 0) console.error(name, n, 'FAILED', r.stderr.slice(-500));
      fs.appendFileSync(process.env.RESULTS ?? 'results/rc-lists.jsonl', lines.join('\n') + '\n');
      console.log(name, n, lines.length, 'cells');
    }
  }
} else if (mode === 'tables') {
  const rows = fs.readFileSync(process.argv[3] ?? 'results/rc-lists.jsonl', 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const groups = new Map();
  for (const r of rows) { if (r.med === undefined) continue; const k = `${r.impl}|${r.op}|${r.n}`; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r.med); }
  const cell = new Map([...groups].map(([k, ms]) => { ms.sort((a, b) => a - b); return [k, ms[ms.length >> 1]]; }));
  const fmt = (ns) => ns < 1e3 ? ns.toFixed(0) + ' ns' : ns < 1e6 ? (ns / 1e3).toPrecision(3) + ' µs' : ns < 1e9 ? (ns / 1e6).toPrecision(3) + ' ms' : (ns / 1e9).toPrecision(3) + ' s';
  const ops = [...new Set(rows.map((r) => r.op))];
  console.log(`| op | n | ${NAMES.join(' | ')} |\n|---|--:|${NAMES.map(() => '--:').join('|')}|`);
  for (const op of ops) for (const n of [1000, 10000, 100000]) {
    const base = cell.get(`A|${op}|${n}`);
    if (!NAMES.some((c) => cell.has(`${c}|${op}|${n}`))) continue;
    console.log(`| ${op} | ${n.toLocaleString('en')} | ` + NAMES.map((c) => { const v = cell.get(`${c}|${op}|${n}`); return v === undefined ? '—' : fmt(v) + (c !== 'A' && base ? ` (${(v / base).toFixed(v / base < 10 ? 2 : 0)}×)` : ''); }).join(' | ') + ' |');
  }
  console.log(`\nrounds: ${[...new Set([...groups.values()].map((m) => m.length))].join(', ')}`);
} else {
  console.log('usage: node rc/lists.mjs build | test | bench [core] [variant…] | tables [file]');
}
