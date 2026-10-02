// node steady.mjs <release-library-dir> <workload> <n>: one p.mjs workload of LB2,
// warmed for 300 ms, then timed for 600 ms; prints µs per call. Run by alt.mjs.
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const [dir, name, ns] = process.argv.slice(2);
const n = +ns;
const src = fs.readFileSync(new URL('./LB2.beni', import.meta.url), 'utf8');
const names = [...src.matchAll(/^pub (\w+) :/gm)].map((m) => m[1]);
const file = `${dir}/LB2.mjs`;
const spelled = [...fs.readFileSync(file, 'utf8').matchAll(/export\s*\{([^}]*)\}/g)].at(-1)[1].split(',').map((s) => s.trim());
const ns_ = await import(pathToFileURL(file).href);
const m = {};
names.forEach((k, i) => (m[`LB2$${k}`] = ns_[spelled[i]]));
const wl = (await import('./p.mjs')).default.concat((await import('./t1.mjs')).default);
const [, make, call] = wl.find((w) => w[0] === name);
const xs = make(m, n);
let sink = 0;
const run = (ms) => {
  const end = process.hrtime.bigint() + BigInt(ms * 1e6);
  let c = 0;
  const t0 = process.hrtime.bigint();
  while (process.hrtime.bigint() < end) {
    for (let k = 0; k < 16; k++) sink ^= call(m, xs, n) === null ? 0 : 1;
    c += 16;
  }
  return Number(process.hrtime.bigint() - t0) / c / 1000;
};
run(300);
const ts = [run(100), run(100), run(100), run(100), run(100), run(100)].sort((a, b) => a - b);
console.log(ts[3], sink);
