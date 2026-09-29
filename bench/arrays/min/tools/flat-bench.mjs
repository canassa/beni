// Report 40 §6.2: flattening a trie to a plain array (toArray) and listing its leaves (chunks), by
// the port's concat.apply and by the shorter alternatives. Pinned: taskset -c 10 node min/tools/flat-bench.mjs
const T = await import(new URL('../../ports/trie.js', import.meta.url));
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
const variants = {
  concatApply: (a) => T.toArray(a),
  flat: (a) => a.r.flat(a.s / 5).concat(a.t),
  flatChunks: (a) => [...a.r.flat(a.s / 5 - 1), a.t].flat(),
  leavesFlat: (a) => { const l = leaves(a.r, a.s, []); l.push(a.t); return l.flat(); },
  pushLoop: (a) => { const l = leaves(a.r, a.s, []); l.push(a.t); const o = []; for (const c of l) for (let i = 0; i < c.length; i++) o.push(c[i]); return o; },
  prealloc: (a) => { const l = leaves(a.r, a.s, []); l.push(a.t); const o = new Array(a.n); let k = 0; for (const c of l) for (let i = 0; i < c.length; i++) o[k++] = c[i]; return o; },
  concatSpread: (a) => { const l = leaves(a.r, a.s, []); l.push(a.t); return [].concat(...l); },
};
const chunkV = {
  leaves: (a) => { const l = leaves(a.r, a.s, []); l.push(a.t); return l; },
  flat: (a) => { const l = a.r.flat(a.s / 5 - 1); l.push(a.t); return l; },
};
for (const n of [2000, 10000, 100000, 1000000]) {
  const a = T.fromArray(Array.from({ length: n }, (_, i) => ({ id: i })));
  const ref = JSON.stringify(T.toArray(a));
  for (const [k, f] of Object.entries(variants)) {
    if (JSON.stringify(f(a)) !== ref) throw k;
    let s; const reps = Math.max(3, 2e6 / n | 0);
    for (let i = 0; i < reps; i++) s = f(a);
    const t0 = performance.now(); for (let i = 0; i < reps; i++) s = f(a); const dt = (performance.now() - t0) / reps * 1e3;
    console.log(n, 'toArray', k.padEnd(14), dt.toFixed(1), 'µs');
  }
  for (const [k, f] of Object.entries(chunkV)) {
    let s; const reps = Math.max(3, 2e7 / n | 0);
    for (let i = 0; i < reps; i++) s = f(a);
    const t0 = performance.now(); for (let i = 0; i < reps; i++) s = f(a); const dt = (performance.now() - t0) / reps * 1e3;
    console.log(n, 'chunks ', k.padEnd(14), dt.toFixed(2), 'µs');
  }
}
