// Report 40 §4.1: appending onto a trie, which none of §15's scenarios times (their `append` cells
// append onto a plain array). original.js copies up to 32 elements per step; the rewrite pushes one
// element at a time through the same `grow` as `push`. Each sibling in its own process:
//   node min/append-bench.mjs [file…]
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const [, , ...args] = process.argv;
if (args[0] === '--child') {
  const m = await import(pathToFileURL(path.resolve(here, args[1])).href);
  const out = [];
  for (const [n, k] of [[10000, 1000], [10000, 10], [100000, 1000], [100000, 100000]]) {
    const base = m.set(Array.from({ length: n }, (_, i) => i), 0, -1); // a trie: the write converts it
    const more = Array.from({ length: k }, (_, i) => i);
    let s;
    const reps = Math.max(20, Math.floor(2e7 / (n / 10 + k * 20)));
    for (let r = 0; r < reps; r++) s = m.append(base, more);
    const xs = [];
    for (let round = 0; round < 7; round++) {
      const t0 = performance.now();
      for (let r = 0; r < reps; r++) s = m.append(base, more);
      xs.push(((performance.now() - t0) / reps) * 1e3);
    }
    xs.sort((a, b) => a - b);
    out.push(`${n}+${k}: ${xs[3].toFixed(2)} µs`);
    if (m.length(s) !== n + k) throw new Error('wrong length');
  }
  console.log(args[1].padEnd(16), out.join('   '));
} else {
  for (const f of args.length ? args : ['original.js', 'rewritten.js', 'array.min.js']) {
    const r = spawnSync('taskset', ['-c', process.env.CORE ?? '10', process.execPath, fileURLToPath(import.meta.url), '--child', f], { encoding: 'utf8' });
    process.stdout.write(r.stdout + r.stderr);
  }
}
