// Report 40 §2: does `measure.mjs fuzz` catch small mistakes? Ten one-token mutants of
// rewritten.js, each fuzzed on its own; every one must be caught ("killed").
//   node min/tools/mutants.mjs
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const min = fileURLToPath(new URL('../', import.meta.url));
const MUTANTS = [
  ['if (s > 5 && r.length === 1)', 'if (s > 10 && r.length === 1)'], // root collapse
  ['if (i >>> 5 >= 1 << s)', 'if (i >>> 5 > 1 << s)'], // root split
  ['a.n === 0 && !IsA(b) ? b :', '0 ? b :'], // append onto the empty trie keeps b
  ['return r.length === n ? a : r;', 'return r;'], // slice identity
  ['(e < 0 ? Math.max(0, e + n) : e) >= n', '(e < 0 ? e + n : e) >= n'], // slice of the empty trie
  ['if (n <= 1) return Empty;', 'if (n < 1) return Empty;'], // pop to empty
  ['if (n < 64) for', 'if (n < 32) for'], // the copy loop's range
  ['c = s > 5 && PopLeaf', 'c = s > 10 && PopLeaf'], // popLeaf's depth
  ['if (a.t.length === 32) a = Grow(a, []);', 'if (a.t.length === 33) a = Grow(a, []);'], // append's tail
  ['unsafeGet(a, i) === v) return a;', 'false) return a;'], // set's no-op identity
];
const src = fs.readFileSync(min + 'rewritten.js', 'utf8');
let survived = 0;
for (const [a, b] of MUTANTS) {
  if (!src.includes(a)) throw new Error(`not found: ${a}`);
  fs.writeFileSync(min + 'mut.js', src.replace(a, b));
  const r = spawnSync(process.execPath, [min + 'measure.mjs', 'fuzz', 'mut.js'], { encoding: 'utf8' });
  if (r.status === 0) survived++;
  console.log(r.status === 0 ? 'SURVIVED' : 'killed  ', JSON.stringify(a), '->', JSON.stringify(b));
}
fs.rmSync(min + 'mut.js');
console.log(survived ? `${survived} mutants survived` : 'every mutant killed');
process.exitCode = survived ? 1 : 0;
