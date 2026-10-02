// node steadyall.mjs <dirA> <dirB> <rounds> <sizes> <workload,…>: alt.mjs × steady.mjs per workload and size.
import { spawnSync } from 'node:child_process';
import { loadavg } from 'node:os';
const [a, b, rounds, sizes, list] = process.argv.slice(2);
console.log(`load ${loadavg()[0].toFixed(1)}; µs per call, median of ${rounds} processes each [range]; b ÷ a`);
console.log('| workload n | a | b | b ÷ a |\n|---|--:|--:|--:|');
for (const w of list.split(','))
  for (const n of sizes.split(',')) {
    const o = spawnSync(process.execPath, ['alt.mjs', 'steady.mjs', rounds, a, b, w, n], { encoding: 'utf8' });
    process.stdout.write(o.stdout || o.stderr);
  }
console.log(`load ${loadavg()[0].toFixed(1)} at the end`);
