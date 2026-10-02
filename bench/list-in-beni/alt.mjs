// node alt.mjs <script> <rounds> <dirA> <dirB> [script args…]: run `script dir args…`
// for each dir alternately, each in a process of its own; medians of its first number.
import { spawnSync } from 'node:child_process';
const [script, rounds, a, b, ...rest] = process.argv.slice(2);
const r = { a: [], b: [] };
for (let i = 0; i < +rounds; i++)
  for (const [k, dir] of i % 2 ? [['b', b], ['a', a]] : [['a', a], ['b', b]]) {
    const o = spawnSync(process.execPath, [script, dir, ...rest], { encoding: 'utf8' });
    if (o.status !== 0) throw new Error(o.stderr);
    r[k].push(parseFloat(o.stdout));
  }
const med = (x) => [...x].sort((p, q) => p - q)[x.length >> 1];
const f = (x) => (x >= 100 ? x.toFixed(0) : x >= 10 ? x.toFixed(1) : x.toFixed(3));
console.log(`| ${rest.join(' ')} | ${f(med(r.a))} [${f(Math.min(...r.a))}–${f(Math.max(...r.a))}] | ${f(med(r.b))} [${f(Math.min(...r.b))}–${f(Math.max(...r.b))}] | ${(med(r.b) / med(r.a)).toFixed(3)} |`);
