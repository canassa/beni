// row-words.mjs: a fuzzer of worded rows' signatures, for panics of the checker v3's reader of rows and
// its safe-build checks (ownership-v3-kernel.md §6 rule 10, §9; research reports 156, 157).
//
//   node bench/ownership-sweeps/row-words.mjs --beni=<beni> --out=<dir> [--rows=27000] [--seed=1] [--batch=60] [--jobs=N]
//
// It writes random signatures of word × type combinations (1 to 3 parameters, function parameters
// included, a third of them a `written returned` parameter beside a `stored` one, the shape of #2559), each
// a `foreign` row of a test platform whose JavaScript answers its first argument, and a program that calls
// every row once. It is no oracle of outputs: most rows are false of that JavaScript. It builds each batch
// of rows under `--ownership=v3 --ownership-everywhere --lists-in-place` and keeps going until `--rows`
// signatures reached the checker: a row the word validator refuses (`misplaced_ownership_word`), or whose
// call does not type, is dropped from its batch, and the batch is built again. A build that ends by a
// signal or an exit other than 0 and 1 is split in halves down to the one row that does it: a CRASH,
// printed with its first `panic` line and its signature. The rows that reached the checker, the dropped
// ones and the crashes go to <dir>/RESULTS (one line each), and a tally to standard output; the exit is
// 1 when any row crashed. Run it on the ReleaseSafe beni (`zig-out/safe/bin/beni`), whose safe-build
// checks are the point. About 4 minutes for 27 000 rows at 24 jobs.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const opt = Object.fromEntries(process.argv.slice(2).map((a) => {
  const [k, v] = a.replace(/^--/, '').split('=');
  return [k, v ?? 'true'];
}));
if (!opt.beni || !opt.out) {
  console.error('usage: node bench/ownership-sweeps/row-words.mjs --beni=<beni> --out=<dir> [--rows=27000] [--seed=1] [--batch=60] [--jobs=N]');
  process.exit(2);
}
const beni = path.resolve(opt.beni);
const out = path.resolve(opt.out);
const want = Number(opt.rows ?? 27000);
const batchSize = Number(opt.batch ?? 60);
const jobs = Number(opt.jobs ?? Math.max(1, os.cpus().length >> 1));
let seed = Number(opt.seed ?? 1);
const rnd = (n) => {
  seed |= 0; seed = seed + 0x6D2B79F5 | 0;
  let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
  t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
  return ((t ^ t >>> 14) >>> 0) % n;
};
const pick = (a) => a[rnd(a.length)];

// [type, an argument of it]
const types = [
  ['a', 'mk 1'], ['List a', '[ mk 1, mk 2 ]'], ['List (List a)', '[ [ mk 1 ], [ mk 2 ] ]'],
  ['Maybe (List a)', 'Just [ mk 1 ]'], ['List a × Int', '( [ mk 1 ], 0 )'], ['{ items : List a }', '{ items = [ mk 1 ] }'],
  ['List PR', '[ mk 1 ]'], ['PR', 'mk 1'], ['Int', '1'], ['b', 'mk 2'], ['List b', '[ mk 3 ]'],
  ['List (Maybe a)', '[ Just (mk 1) ]'], ['a × a', '( mk 1, mk 2 )'], ['List (a × Int)', '[ ( mk 1, 0 ) ]'],
  ['Js.Value', 'Probe.toV (mk 1)'], ['List Js.Value', '[ Probe.toV (mk 1) ]'], ['{ r | items : List a }', '{ items = [ mk 1 ], k = 0 }'],
  ['{ items : List a, more : List a }', '{ items = [ mk 1 ], more = [ mk 2 ] }'], ['List a × List a', '( [ mk 1 ], [ mk 2 ] )'],
  ['Maybe a', 'Just (mk 1)'], ['{ one : a, items : List a }', '{ one = mk 1, items = [ mk 2 ] }'], ['List { v : a }', '[ { v = mk 1 } ]'],
  ['List (List (List a))', '[ [ [ mk 1 ] ] ]'], ['Maybe (Maybe (List a))', 'Just (Just [ mk 1 ])'], ['List a × List b', '( [ mk 1 ], [ mk 2 ] )'],
  ['{ items : List (List a) }', '{ items = [ [ mk 1 ] ] }'], ['String', '"s"'],
];
const rtypes = types.map((t) => t[0]).filter((t) => !t.startsWith('{ r'));
const pwords = ['', 'borrowed', 'stored', 'returned', 'written returned', 'aliased', 'unused', 'consumed', 'escaped', 'written', 'written stored', 'borrowed returned'];
const rwords = ['', 'fresh', 'fresh exclusive', 'exclusive', 'copyof', 'concatenated', 'prepended', 'elementof', 'taken', 'builderdone', 'unknown', 'escaped'];
const fnTypes = [['(⊤ → a)', '(λ⊤ → mk 1)'], ['(a → a)', '(λq → q)'], ['(a → b)', '(λq → q)'], ['(a, b → b)', '(λq w → w)'], ['(a → List a)', '(λq → [ q ])'],
  ['(List a → a)', '(λl → mk 1)'], ['(⊤ → List a)', '(λ⊤ → [ mk 1 ])'], ['(a → Maybe a)', '(λq → Just q)']];
const fwords = ['', 'once', 'many', 'owned', 'once returned', 'many returned', 'once taken stored', 'once stored', 'many aliased', 'once aliased', 'once escaped', 'many stored', 'borrowed', 'once taken', 'many taken'];

const seen = new Set();
function nextRow() {
  for (;;) {
    let ps;
    if (rnd(3) === 0) {
      // #2559's family: a `written returned` parameter of any type beside a `stored` one or a stored callback.
      ps = [['written returned', pick(types)], rnd(4) === 0 ? [pick(['once taken stored', 'once stored', 'many stored']), pick(fnTypes)] : [pick(['stored', 'written stored']), pick(types)]];
      if (rnd(2)) ps.splice(rnd(3), 0, rnd(3) === 0 ? [pick(fwords), pick(fnTypes)] : [pick(pwords), pick(types)]);
      if (rnd(2)) ps.reverse();
    } else {
      const k = 1 + rnd(3);
      ps = Array.from({ length: k }, () => rnd(3) === 0 ? [pick(fwords), pick(fnTypes)] : [pick(pwords), pick(types)]);
    }
    const r = [pick(rwords), pick(rtypes)];
    const sig = `${ps.map(([w, [t]]) => `${w} ${t}`.trim()).join(', ')} → ${`${r[0]} ${r[1]}`.trim()}`;
    if (seen.has(sig)) continue;
    seen.add(sig);
    return { sig, args: ps.map(([, [, v]]) => `(${v})`).join(' '), arity: ps.length };
  }
}

const probeHead = `--! A probe platform: one row for each signature.

import Js


pub type alias PR =
    x : Int
    xs : List Int


--| to a host value
pub toV : a → Js.Value
toV v =
    Js.from v
`;
const mainHead = `import Node exposing (Program)
import Probe exposing (PR)


mk : Int → PR
mk n = { x = n, xs = [ n ] }
`;

// Writes one batch; answers the line of each row in Probe.beni and in Main.beni.
function write(dir, rows) {
  fs.mkdirSync(path.join(dir, '_p'), { recursive: true });
  fs.writeFileSync(path.join(dir, '_p', 'beni.json'), '{ "platform": true, "name": "rowwords", "platforms": ["node"], "reexports": ["Node", "Probe"] }\n');
  let probe = probeHead;
  let js = '';
  let main = mainHead;
  const at = [];
  rows.forEach((row, i) => {
    probe += `\n\n--| row ${i}\npub foreign pure row${i} : ${row.sig}\n`;
    const pl = probe.split('\n').length - 1;
    js += `export const row${i} = (${Array.from({ length: row.arity }, (_, j) => `p${j}`).join(', ')}) => p0;\n`;
    main += `\n\nt${i} : Int → String\nt${i} n =\n    Debug.toString (Probe.row${i} ${row.args})\n`;
    const ml = main.split('\n').length - 1;
    at.push({ probe: pl, main: [ml - 2, ml] });
  });
  main += `\n\nmain : Program\nmain = Node.print (String.join [ ${rows.map((_, i) => `t${i} 1`).join(', ')} ] ",")\n`;
  fs.writeFileSync(path.join(dir, '_p', 'Probe.beni'), probe);
  fs.writeFileSync(path.join(dir, '_p', 'Probe.js'), js);
  fs.writeFileSync(path.join(dir, 'Main.beni'), main);
  return at;
}

function build(dir) {
  return new Promise((resolve) => {
    const p = spawn(beni, ['build', '--no-cache', '--jobs=1', `--platform=${path.join(dir, '_p')}`, '--ownership=v3', '--ownership-everywhere', '--lists-in-place', `--out=${path.join(dir, 'o')}`, 'Main.beni'], { cwd: dir, stdio: ['ignore', 'pipe', 'pipe'] });
    let log = '';
    p.stdout.on('data', (d) => { log += d; });
    p.stderr.on('data', (d) => { log += d; });
    const t = setTimeout(() => p.kill('SIGKILL'), 120000);
    p.on('close', (code, signal) => { clearTimeout(t); resolve({ code: signal ? -1 : code, log }); });
  });
}

// What a checker of ownership reports; any other diagnostic drops its row.
const checkerTitle = /STILL IN USE|CHANGED WHILE|TOO LARGE|OWNERSHIP LIMIT/;
const results = [];
const tally = { checked: 0, dropped: 0, crashes: 0, builds: 0 };
let serial = 0;

async function judge(rows) {
  if (rows.length === 0) return;
  const dir = path.join(out, `b${serial++}`);
  const at = write(dir, rows);
  const r = await build(dir);
  tally.builds++;
  if (process.env.ROWWORDS_KEEP) fs.writeFileSync(path.join(dir, 'LOG'), r.log); else fs.rmSync(dir, { recursive: true, force: true });
  if (r.code !== 0 && r.code !== 1) {
    if (rows.length === 1) {
      const line = (r.log.match(/panic: .*/) || [`exit ${r.code}`])[0];
      results.push(`CRASH | ${rows[0].sig} | ${line}`);
      tally.crashes++;
      return;
    }
    const h = rows.length >> 1;
    await judge(rows.slice(0, h));
    await judge(rows.slice(h));
    return;
  }
  const drop = new Set();
  let unplaced = false;
  for (const m of r.log.matchAll(/^-- ([A-Z][A-Z ]*[A-Z]) -+ (\S+):(\d+):\d+/gm)) {
    if (checkerTitle.test(m[1])) continue;
    const file = path.basename(m[2]);
    const line = Number(m[3]);
    const i = at.findIndex((a) => file === 'Probe.beni' ? a.probe === line : line >= a.main[0] && line <= a.main[1]);
    if (i < 0) unplaced = true; else drop.add(i);
  }
  if (r.code === 1 && /^-- /m.test(r.log) === false) unplaced = true;
  if (unplaced) {
    if (rows.length === 1) {
      results.push(`DROPPED | ${rows[0].sig} | ${(r.log.match(/^-- [A-Z ]+/m) || ['?'])[0]}`);
      tally.dropped++;
      return;
    }
    const h = rows.length >> 1;
    await judge(rows.slice(0, h));
    await judge(rows.slice(h));
    return;
  }
  if (drop.size === 0) {
    for (const row of rows) results.push(`CHECKED | ${row.sig}`);
    tally.checked += rows.length;
    return;
  }
  for (const i of drop) { results.push(`DROPPED | ${rows[i].sig}`); tally.dropped++; }
  await judge(rows.filter((_, i) => !drop.has(i)));
}

fs.mkdirSync(out, { recursive: true });
const t0 = Date.now();
while (tally.checked < want) {
  const need = want - tally.checked;
  // About half the rows the generator writes reach the checker; ask for twice what is missing.
  const n = Math.max(Math.min(need * 2, batchSize * jobs * 4), batchSize);
  const batches = [];
  for (let i = 0; i < n; i += batchSize) batches.push(Array.from({ length: Math.min(batchSize, n - i) }, nextRow));
  let next = 0;
  await Promise.all(Array.from({ length: jobs }, async () => { while (next < batches.length) await judge(batches[next++]); }));
  console.error(`${tally.checked} checked, ${tally.dropped} dropped, ${tally.crashes} crashes, ${tally.builds} builds, ${Math.round((Date.now() - t0) / 1000)} s`);
}
fs.writeFileSync(path.join(out, 'RESULTS'), results.join('\n') + '\n');
for (const l of results.filter((l) => l.startsWith('CRASH'))) console.log(l);
console.log(`rows ${tally.checked + tally.dropped + tally.crashes}: ${tally.checked} reached the checker, ${tally.dropped} dropped (refused words or calls), ${tally.crashes} CRASH; ${tally.builds} builds, ${Math.round((Date.now() - t0) / 1000)} s`);
process.exit(tally.crashes ? 1 : 0);
