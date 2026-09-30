// research/42 §7.1: what the inserted operations cost on code that never writes, one pattern at a
// time, in the shapes the transformed code has. Node only: `node rc/probe-overhead.mjs [r1|r2]`
// from bench/arrays, pinned with taskset by the caller. Every loop is the same code with and
// without the operation, so the difference is the operation.
const MODE = process.argv[2] ?? 'r1';
const R1 = MODE === 'r1';
const $dupA = R1
  ? (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc++; return x; }
  : (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc = 2; return x; };
const $dropA = (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc--; };
const $dup = R1 ? (x) => { x.rc++; return x; } : (x) => { x.rc = 2; return x; };
const $drop = (x) => { x.rc--; };
const now = () => performance.now();
let sink = 0;
function bench(name, f, per) {
  for (let i = 0; i < 20; i++) f();
  const xs = [];
  for (let s = 0; s < 15; s++) { const t = now(); f(); xs.push(now() - t); }
  xs.sort((a, b) => a - b);
  const ms = xs[7];
  console.log(JSON.stringify({ mode: MODE, op: name, ns: +((ms * 1e6) / per).toFixed(3) }));
}
const N = 100000;
const ints = Array.from({ length: N }, (_, i) => i);
const recs = Array.from({ length: N }, (_, i) => ({ id: i, name: 'x', price: i / 3, category: i % 20 }));
const add = (x, s) => s + x;
const cat = (it, n) => (it.category === 3 ? n + 1 : n);
function foldl(a, z, f) { for (let i = 0; i < a.length; i++) z = f(a[i], z); return z; }
function foldlDup(a, z, f) { for (let i = 0; i < a.length; i++) z = f($dupA(a[i]), z); return z; }
bench('foldl over Ints: plain', () => { sink += foldl(ints, 0, add); }, N);
bench('foldl over Ints: $dupA per element', () => { sink += foldlDup(ints, 0, add); }, N);
bench('foldl over records: plain', () => { sink += foldl(recs, 0, cat); }, N);
bench('foldl over records: $dupA per element', () => { sink += foldlDup(recs, 0, cat); }, N);
// a lambda that owns a parameter of a type variable and does not consume it drops it (r1)
const catDrop = (it, n) => { const r = it.category === 3 ? n + 1 : n; $dropA(it); return r; };
if (R1) bench('foldl over records: $dupA + $dropA per element', () => { sink += foldlDup(recs, 0, catDrop); }, N);
// Array.get's Maybe: one $dupA per read (both the Just and the element stay uncounted)
const get = (a, i) => (0 <= i && i < a.length ? { $: 'Just', a: a[i] } : null);
const getDup = (a, i) => (0 <= i && i < a.length ? { $: 'Just', a: $dupA(a[i]) } : null);
bench('get of a record: plain', () => { let s = 0; for (let i = 0; i < N; i++) s += get(recs, i).a.id; sink += s; }, N);
bench('get of a record: $dupA', () => { let s = 0; for (let i = 0; i < N; i++) s += getDup(recs, i).a.id; sink += s; }, N);
// a record that holds an Array: construction with its count, and the take of a field at the last
// use of an owned record (rule O4), against the plain spread beni emits today
const arr = []; arr.rc = 1;
let m = { nextId: 1, rows: arr, selected: 0 };
bench('record update {...m, selected}: plain', () => { for (let k = 0; k < N; k++) m = { ...m, selected: k }; sink += m.selected; }, N);
let mc = { rc: 1, nextId: 1, rows: arr, selected: 0 };
bench('record update, counted, unique model', () => { for (let k = 0; k < N; k++) { if (mc.rc !== 1) { $dup(mc.rows); if (R1) $drop(mc); } mc = { ...mc, rc: 1, selected: k }; } sink += mc.selected; }, N);
let ms = { rc: 1, nextId: 1, rows: arr, selected: 0 };
bench('record update, counted, shared model', () => { for (let k = 0; k < N; k++) { ms.rc = 2; if (ms.rc !== 1) { $dup(ms.rows); if (R1) $drop(ms); } ms = { ...ms, rc: 1, selected: k }; } sink += ms.selected; }, N);
// an owned array parameter the borrow inference could not make borrowed: dup at the call, drop in
// the callee (r1), or the sticky mark (r2), against nothing
const len = (a) => a.length;
const lenDrop = (a) => { const n = a.length; if (R1) $drop(a); return n; };
const a1 = [1, 2, 3]; a1.rc = 1;
bench('call with a borrowed array', () => { let s = 0; for (let i = 0; i < N; i++) s += len(a1); sink += s; }, N);
bench('call with an owned array, dup + drop', () => { let s = 0; for (let i = 0; i < N; i++) s += lenDrop($dup(a1)); sink += s; }, N);
// every constructor counted (full Perceus, which the report does not propose): a cons cell with a
// count, built and walked
bench('build + walk 100 000 cons cells', () => { let l = null; for (let i = 0; i < N; i++) l = { $: 1, a: i, b: l }; let s = 0; for (; l; l = l.b) s += l.a; sink += s; }, N);
bench('build + walk 100 000 counted cons cells', () => { let l = null; for (let i = 0; i < N; i++) l = { $: 1, a: i, b: l, rc: 1 }; let s = 0; for (; l; l = l.b) { s += l.a; if (R1) l.rc--; } sink += s; }, N);
