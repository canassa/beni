// Report 40 §6.3: copying a plain array of n elements and writing one, by a loop, slice() and
// concat(). Pinned: taskset -c 10 node min/tools/copy-bench.mjs
const loop = (a, k) => { const n = a.length, c = new Array(n + k); for (let j = 0; j < n; j++) c[j] = a[j]; return c; };
const variants = {
  loopSet: (a) => { const c = loop(a, 0); c[1] = 7; return c; },
  sliceSet: (a) => { const c = a.slice(); c[1] = 7; return c; },
  concatSet: (a) => { const c = a.concat(); c[1] = 7; return c; },
  loopPush: (a) => { const c = loop(a, 1); c[a.length] = 7; return c; },
  concatPush: (a) => a.concat([7]),
  slicePush: (a) => { const c = a.slice(); c.push(7); return c; },
};
for (const n of [2, 8, 32, 63]) {
  for (const kind of ['objects', 'smis']) {
    const a = Array.from({ length: n }, (_, i) => (kind === 'smis' ? i : { i }));
    const out = [];
    for (const [k, f] of Object.entries(variants)) {
      let s; const reps = 2e6;
      for (let i = 0; i < reps; i++) s = f(a);
      const t0 = performance.now(); for (let i = 0; i < reps; i++) s = f(a); const dt = (performance.now() - t0) / reps * 1e6;
      out.push(`${k} ${dt.toFixed(1)}`);
    }
    console.log(n, kind.padEnd(8), out.join('  '));
  }
}
