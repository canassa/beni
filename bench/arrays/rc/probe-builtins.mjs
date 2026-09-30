// research/42 §7.3: does an `rc` property on a JS array knock V8's array builtins off their fast
// paths? `node rc/probe-builtins.mjs` from bench/arrays.
const now = () => performance.now();
let sink = 0;
function bench(name, f) {
  for (let i = 0; i < 30; i++) f();
  const xs = [];
  for (let s = 0; s < 21; s++) { const t = now(); f(); xs.push(now() - t); }
  xs.sort((a, b) => a - b);
  console.log(name.padEnd(44), (xs[10] * 1000).toFixed(1), 'µs');
}
const N = 10000;
const rows = Array.from({ length: N }, (_, i) => ({ id: i, label: 'row' }));
const more = Array.from({ length: 1000 }, (_, i) => ({ id: N + i, label: 'row' }));
const withRc = rows.slice(); withRc.rc = 2;
const ints = Array.from({ length: N }, (_, i) => i);
const intsRc = ints.slice(); intsRc.rc = 2;
for (const [label, a, b] of [['records', rows, more], ['records, rc', withRc, more], ['ints', ints, ints.slice(0, 1000)], ['ints, rc', intsRc, ints.slice(0, 1000)]]) {
  bench(`concat 10 000 + 1 000 ${label}`, () => { sink += a.concat(b).length; });
  bench(`slice 10 000 ${label}`, () => { sink += a.slice().length; });
  bench(`for-push copy 10 000 ${label}`, () => { const c = []; for (let i = 0; i < a.length; i++) c.push(a[i]); sink += c.length; });
}
