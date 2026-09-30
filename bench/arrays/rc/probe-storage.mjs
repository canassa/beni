// Where does a count or a shared bit live on a plain JS array, and what does each choice cost?
// research/42 §7.2. Node only: `node rc/probe-storage.mjs` from bench/arrays.
const now = () => performance.now();
function bench(name, f) {
  for (let i = 0; i < 5; i++) f();
  const xs = [];
  for (let s = 0; s < 9; s++) { const t = now(); f(); xs.push(now() - t); }
  xs.sort((a, b) => a - b);
  console.log(name.padEnd(46), xs[4].toFixed(3), 'ms');
}
const N = 100000;
let sink = 0;
bench('create [i, i+1], plain, x1e6', () => { for (let i = 0; i < 1e6; i++) { const a = [i, i + 1]; sink += a.length; } });
bench('create [i, i+1] then a.rc = 1, x1e6', () => { for (let i = 0; i < 1e6; i++) { const a = [i, i + 1]; a.rc = 1; sink += a.length; } });
bench('create wrapper {rc, a: [i, i+1]}, x1e6', () => { for (let i = 0; i < 1e6; i++) { const a = { rc: 1, a: [i, i + 1] }; sink += a.a.length; } });
bench('create record {x, y}, x1e6', () => { for (let i = 0; i < 1e6; i++) { const a = { x: i, y: i }; sink += a.x; } });
bench('create record {rc, x, y}, x1e6', () => { for (let i = 0; i < 1e6; i++) { const a = { rc: 1, x: i, y: i }; sink += a.x; } });

const P = []; for (let i = 0; i < N; i++) P.push(i);
const R = []; for (let i = 0; i < N; i++) R.push(i); R.rc = 1;
const W = { rc: 1, a: P.slice() };
const F = Object.freeze(P.slice());
const rd = (a) => { let s = 0; for (let k = 0; k < 20; k++) for (let i = 0; i < a.length; i++) s += a[i]; return s; };
bench('read 2e6: plain', () => { sink += rd(P); });
bench('read 2e6: array with an rc property', () => { sink += rd(R); });
bench('read 2e6: frozen array', () => { sink += rd(F); });
bench('read 2e6: through a wrapper', () => { let s = 0; for (let k = 0; k < 20; k++) for (let i = 0; i < W.a.length; i++) s += W.a[i]; sink += s; });
const P2 = P.slice();
bench('write 2e6: plain', () => { const a = P2; for (let k = 0; k < 20; k++) for (let i = 0; i < a.length; i++) a[i] = i + k; });
bench('write 2e6: if (a.rc === 1)', () => { const a = R; for (let k = 0; k < 20; k++) for (let i = 0; i < a.length; i++) { if (a.rc === 1) a[i] = i + k; } });
const R2 = P.slice();
bench('write 2e6: if (!Object.isFrozen(a))', () => { const a = R2; for (let k = 0; k < 20; k++) for (let i = 0; i < a.length; i++) { if (!Object.isFrozen(a)) a[i] = i + k; } });
const objs = []; for (let i = 0; i < 1000; i++) { const a = [i]; a.rc = 1; objs.push(a); }
bench('rc++ then rc-- on 1e6 arrays', () => { for (let k = 0; k < 1000; k++) for (let i = 0; i < 1000; i++) { const o = objs[i]; o.rc++; o.rc--; } });
bench('Object.freeze of a fresh 1e5 copy, x10', () => { for (let k = 0; k < 10; k++) Object.freeze(P.slice()); });
bench('a fresh 1e5 copy, x10', () => { for (let k = 0; k < 10; k++) sink += P.slice().length; });
