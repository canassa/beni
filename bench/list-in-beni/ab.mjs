// A/B microbenchmark of two (compiler, core) pairs on one beni program, each
// side timed in processes of its own, alternating round by round (as
// bench/primitives/run.mjs does: two builds imported into one process
// measure differently by load order).
//
//   node ab.mjs --src=LB2.beni --wl=t1.mjs --a-beni=… --a-core=… --b-beni=… --b-core=…
//        [--sizes=100,1000,10000] [--rounds=8] [--samples=7] [--sample-ms=10] [--dev] [--only=a,b]
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync } from 'node:fs';
import { loadavg } from 'node:os';
import { join, resolve, basename } from 'node:path';
import { pathToFileURL } from 'node:url';

const o = { sizes: [100, 1000, 10000], rounds: 8, samples: 7, sampleMs: 10, release: true, only: null };
for (const arg of process.argv.slice(2)) {
  const [k, v] = arg.replace(/^--/, '').split('=');
  if (k === 'sizes') o.sizes = v.split(',').map(Number);
  else if (k === 'rounds') o.rounds = +v;
  else if (k === 'samples') o.samples = +v;
  else if (k === 'sample-ms') o.sampleMs = +v;
  else if (k === 'dev') o.release = false;
  else if (k === 'only') o.only = new Set(v.split(','));
  else o[k] = v;
}
const mod = basename(o.src, '.beni');
const names = [...readFileSync(o.src, 'utf8').matchAll(/^pub (\w+) :/gm)].map((m) => m[1]);

if (o.child) {
  const file = join(o.child, `${mod}.mjs`);
  const spelled = [...readFileSync(file, 'utf8').matchAll(/export\s*\{([^}]*)\}/g)].at(-1)[1].split(',').map((s) => s.trim());
  const ns = await import(pathToFileURL(file).href);
  const m = {};
  if (o.release) names.forEach((n, i) => (m[`${mod}$${n}`] = ns[spelled[i]]));
  else Object.assign(m, ns);
  const workloads = (await import(pathToFileURL(resolve(o.wl)).href)).default;
  let sink = 0;
  const sample = (call, xs, n) => {
    const budget = o.sampleMs * 1e6;
    let calls = 0;
    const start = process.hrtime.bigint();
    let el = 0n;
    do {
      const r = call(m, xs, n);
      sink ^= r === null ? 0 : 1;
      calls++;
      el = process.hrtime.bigint() - start;
    } while (el < budget);
    return Number(el) / calls / 1000;
  };
  if (o.count) {
    // Instructions mode: warm up as the timing does, then `iters` calls.
    const [cname, cn, iters] = o.count.split(':');
    const [, make, call] = workloads.find((w) => w[0] === cname);
    const n = +cn;
    const xs = make(m, n);
    for (let k = 0; k < 2000; k++) sink ^= call(m, xs, n) === null ? 0 : 1;
    for (let k = 0; k < +iters; k++) sink ^= call(m, xs, n) === null ? 0 : 1;
    if (sink === 42) console.error('');
    process.exit(0);
  }
  const out = {};
  for (const [name, make, call] of workloads) {
    if (o.only && !o.only.has(name)) continue;
    for (const n of o.sizes) {
      const xs = make(m, n);
      sample(call, xs, n);
      sample(call, xs, n);
      const got = [];
      for (let s = 0; s < o.samples; s++) got.push(sample(call, xs, n));
      got.sort((a, b) => a - b);
      out[`${name}|${n}`] = got[got.length >> 1];
    }
  }
  console.log(JSON.stringify(out));
  if (sink === 42) console.error('');
  process.exit(0);
}

const work = mkdtempSync('/tmp/claude-1000/-home-canassa-src-github-com-canassa-beni/34a0b1f8-8c70-4b52-95dc-f0884dce8bed/scratchpad/list/out/ab-');
process.on('exit', () => rmSync(work, { recursive: true, force: true }));
const dirs = {};
for (const side of ['a', 'b']) {
  const out = join(work, side);
  mkdirSync(out, { recursive: true });
  const r = spawnSync(o[`${side}-beni`], ['build', '--no-cache', '--library', '--platform=node', ...(o.release ? ['--release'] : []), `--core-root=${resolve(o[`${side}-core`])}`, `--out=${out}`, o.src], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`${side}: ${r.stdout}${r.stderr}`);
  dirs[side] = out;
}
const pass = process.argv.slice(2).filter((a) => !/^--(a|b)-/.test(a));
if (o.icount) {
  // Instructions per call: (I(iters) − I(0)) / iters, each side, `rounds` processes each, median.
  const workloads = (await import(pathToFileURL(resolve(o.wl)).href)).default;
  const itersFor = (n) => (o.iters ? +o.iters : Math.max(2000, Math.round(1e7 / n)));
  const count = (side, name, n, k) => {
    const c = spawnSync(o.icount, [process.execPath, '--single-threaded', process.argv[1], `--child=${dirs[side]}`, `--count=${name}:${n}:${k}`, ...pass.filter((a) => !a.startsWith('--icount'))], { encoding: 'utf8' });
    const mm = /instructions (\d+)/.exec(c.stderr);
    if (!mm) throw new Error(c.stderr);
    return +mm[1];
  };
  console.log(`instructions per call, (I(k) − I(0)) / k, k = 1e7 / n, median of ${o.rounds} processes; b ÷ a\n`);
  console.log('| workload | n | a | b | b ÷ a |');
  console.log('|---|--:|--:|--:|--:|');
  const med = (xs) => [...xs].sort((a, b) => a - b)[xs.length >> 1];
  for (const [name] of workloads) {
    if (o.only && !o.only.has(name)) continue;
    for (const n of o.sizes) {
      const per = { a: [], b: [] };
      for (let r = 0; r < o.rounds; r++)
        for (const side of ["a", "b"]) per[side].push((count(side, name, n, itersFor(n)) - count(side, name, n, 0)) / itersFor(n));
      const a = med(per.a), b = med(per.b);
      console.log(`| ${name} | ${n} | ${a.toFixed(0)} | ${b.toFixed(0)} | ${(b / a).toFixed(3)}× |`);
    }
  }
  process.exit(0);
}
const res = { a: [], b: [] };
const load0 = loadavg()[0];
for (let r = 0; r < o.rounds; r++) {
  for (const side of r % 2 ? ['b', 'a'] : ['a', 'b']) {
    const c = spawnSync(process.execPath, [process.argv[1], `--child=${dirs[side]}`, ...pass], { encoding: 'utf8' });
    if (c.status !== 0) throw new Error(`${side} round ${r}: ${c.stderr}`);
    res[side].push(JSON.parse(c.stdout.trim().split('\n').at(-1)));
  }
}
const med = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const k = s.length >> 1;
  return s.length % 2 ? s[k] : (s[k - 1] + s[k]) / 2;
};
const f = (x) => (x >= 100 ? x.toFixed(0) : x >= 10 ? x.toFixed(1) : x.toFixed(2));
console.log(`node ${process.version}, ${o.release ? '--release' : 'development'}, ${o.rounds} rounds × ${o.samples} samples of ${o.sampleMs} ms, load ${load0.toFixed(1)} → ${loadavg()[0].toFixed(1)}; µs per call, median over rounds [range], b ÷ a\n`);
console.log('| workload | n | a | b | b ÷ a |');
console.log('|---|--:|--:|--:|--:|');
for (const key of Object.keys(res.a[0])) {
  const a = res.a.map((x) => x[key]);
  const b = res.b.map((x) => x[key]);
  const [name, n] = key.split('|');
  console.log(`| ${name} | ${n} | ${f(med(a))} [${f(Math.min(...a))}–${f(Math.max(...a))}] | ${f(med(b))} [${f(Math.min(...b))}–${f(Math.max(...b))}] | ${(med(b) / med(a)).toFixed(2)}× |`);
}
