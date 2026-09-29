// Report 40 §4.3 and §1.5: searches over a minified file's layout, keeping any change that shrinks
// its brotli-11 output. Deterministic (fixed seeds), so the output is reproducible for one brotli.
//
//   node min/tools/order.mjs order <in> <out> [iterations]   the order of the top-level statements
//                                                            (steps/10-hand.js -> steps/11-order.js)
//   node min/tools/order.mjs names <in> [iterations]          the letters of the single-capital
//                                                            top-level names, a bijection onto A-Z
//
// Reordering is correct only for a file whose top-level initialisers read no other top-level
// binding at load time — here every one is a literal or a function, and `Array.isArray`.
import fs from 'node:fs';
import zlib from 'node:zlib';

const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const [mode, inp, a3, a4] = process.argv.slice(2);
const src = fs.readFileSync(inp, 'utf8').trim();

if (mode === 'order') {
  const iters = +(a4 ?? 3000);
  // the top-level statements: split at `;` at bracket depth 0 (no strings or regexps contain one)
  const parts = [];
  let depth = 0, start = 0;
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if ('([{'.includes(c)) depth++;
    else if (')]}'.includes(c)) depth--;
    else if (c === ';' && depth === 0) { parts.push(src.slice(start, i + 1)); start = i + 1; }
  }
  if (start < src.length) parts.push(src.slice(start));
  let best = parts.slice(), bestSize = br(best.join(''));
  console.log('statements', parts.length, 'start', bestSize);
  let seed = 1;
  const rnd = (n) => { seed = (seed * 48271) % 2147483647; return seed % n; };
  for (let k = 0; k < iters; k++) {
    const cand = best.slice();
    const i = rnd(cand.length), j = rnd(cand.length);
    if (rnd(2)) [cand[i], cand[j]] = [cand[j], cand[i]];
    else { const [x] = cand.splice(i, 1); cand.splice(j, 0, x); }
    const s = br(cand.join(''));
    if (s < bestSize) { best = cand; bestSize = s; }
  }
  console.log('best', bestSize);
  fs.writeFileSync(a3, best.join(''));
} else if (mode === 'names') {
  const iters = +(a3 ?? 2000);
  const used = [...new Set(src.match(/\b[A-Z]\b/g))];
  const pool = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('');
  const render = (map) => src.replace(/\b[A-Z]\b/g, (c) => map[c]);
  let best = Object.fromEntries(used.map((c) => [c, c])), bestSize = br(render(best));
  console.log('names', used.join(''), 'start', bestSize);
  let seed = 3;
  const rnd = (n) => { seed = (seed * 48271) % 2147483647; return seed % n; };
  for (let k = 0; k < iters; k++) {
    const cand = { ...best };
    const a = used[rnd(used.length)];
    const target = pool[rnd(pool.length)];
    const holder = used.find((u) => cand[u] === target);
    if (holder) cand[holder] = cand[a];
    cand[a] = target;
    const s = br(render(cand));
    if (s < bestSize) { best = cand; bestSize = s; }
  }
  console.log('best', bestSize, JSON.stringify(best));
} else {
  console.log('usage: node min/tools/order.mjs order <in> <out> [iterations] | names <in> [iterations]');
}
