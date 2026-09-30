// Report 38 §3's single operations (report 46), as compiled beni: `beni-out/Ops.mjs` is ops/elm or
// ops/first compiled into the same tree as the list scenarios, and `list-rt` is the candidate's
// surface (seq/surface.js). Elements are §3's `{k, o}` records; the timing loop and the driver are
// lists/harness.js's `run`, `stack` and `mem`, given `opsCells`.
//
// A candidate whose writes land in place (native, `MUTABLE`) cannot repeat a write on one input: its
// `push` truncates every 4 096 calls, its `pop` is a pop and a push, its `insert`/`remove` alternate so
// the length stays n and its `concat` appends and truncates, as §3's native adapter did.
import * as RT from 'list-rt';
import * as Ops from 'beni-out/Ops.mjs';
const { fromJs, toJs, walk } = RT;

let seed = 12345;
const rnd = (n) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n; };
function dataFor(n) {
  // `o` is the record's partner, which points back, so `map (\x -> x.o)` allocates nothing per element
  const mk = (i) => { const q = { k: i, o: null }, p = { k: -i, o: q }; q.o = p; return q; };
  seed = 12345;
  const data = Array.from({ length: n }, (_, i) => mk(i));
  const data2 = Array.from({ length: n }, (_, i) => mk(i + n));
  const shuffled = data.slice();
  for (let i = n - 1; i > 0; i--) { const j = rnd(i + 1); const t = shuffled[i]; shuffled[i] = shuffled[j]; shuffled[j] = t; }
  const idx = Array.from({ length: 256 }, () => (n ? rnd(n) : 0));
  const vals = Array.from({ length: 256 }, (_, i) => mk(-1 - i));
  return { data, data2, shuffled, idx, vals };
}
const eqf = (x, y) => x === y;
const cmp = (x, y) => (x.k < y.k ? 'LT' : x.k > y.k ? 'GT' : 'EQ');
const toO = (x) => x.o;
const even = (x) => (x.k & 1) === 0;
const addK = (x, z) => z + x.k;

// Every write is measured twice. `first`: on the same input every call, which is what §3 measured
// (for the adaptive arrays it is the first write, which converts a large plain array to the trie).
// `threaded`: each call writes the previous call's result, the steady state of a loop or a model;
// the sequence is reset to the input every min(n, 4 096) calls where it grows or shrinks.
export const OPS = ['get', 'set, first', 'set, threaded', 'push, first', 'push, threaded', 'pop, first', 'pop, threaded', 'slice', 'concat',
  'insert, first', 'insert, threaded', 'remove, first', 'remove, threaded', 'swap, first', 'swap, threaded', 'map', 'filter', 'foldl', 'iterate',
  'fromArray', 'toArray', 'eq', 'sort'];
// what native cannot run: a write repeated on one input it has overwritten
export const FIRST_WRITES = OPS.filter((o) => o.endsWith(', first'));

// [scenario, op, n, fn, per]: `get` is 256 reads a call, reported per read
export function opsCells(n) {
  const d = dataFor(n), ix = d.idx, vs = d.vals, M = RT.MUTABLE;
  const seq = (arr) => fromJs(arr.slice());
  const a = seq(d.data), b = seq(d.data2), a2 = seq(d.data), sh = seq(d.shuffled);
  const own = () => seq(d.data); // a cell that writes in place gets its own copy
  const sc = '0 single operations', mid = n >> 1, period = Math.min(n, 4096);
  let k = 0;
  const threaded = (step, every = Infinity) => { let x = a, c = 0; return () => { x = step(x); if (++c === every) { x = a; c = 0; } return x; }; };
  // native writes in place, so it cannot go back to the input: its growing and shrinking writes are
  // undone by the opposite write, as §3's native adapter did
  const inPlace = (step) => { const x = own(); return () => step(x); };
  const cells = [
    [sc, 'get', n, () => { let s = 0; for (let j = 0; j < 256; j++) s += Ops.Ops$get(a, ix[j]).a.k; return s; }, 256],
    [sc, 'set, first', n, () => { k = (k + 1) & 255; return Ops.Ops$set(a, ix[k], vs[k]); }],
    [sc, 'set, threaded', n, M ? inPlace((x) => { k = (k + 1) & 255; return Ops.Ops$set(x, ix[k], vs[k]); }) : threaded((x) => { k = (k + 1) & 255; return Ops.Ops$set(x, ix[k], vs[k]); })],
    [sc, 'push, first', n, () => Ops.Ops$push(a, vs[(k++) & 255])],
    [sc, 'push, threaded', n, M ? inPlace((x) => { Ops.Ops$push(x, vs[(k++) & 255]); if (x.length >= n + 4096) x.length = n; return x; }) : threaded((x) => Ops.Ops$push(x, vs[(k++) & 255]), period)],
    [sc, 'pop, first', n, () => Ops.Ops$pop(a)],
    [sc, 'pop, threaded', n, M ? inPlace((x) => { const last = x[n - 1]; return Ops.Ops$push(Ops.Ops$pop(x), last); }) : threaded((x) => Ops.Ops$pop(x), period)],
    [sc, 'slice', n, () => Ops.Ops$slice(a, n >> 2, (3 * n) >> 2)],
    [sc, 'concat', n, M ? inPlace((x) => { Ops.Ops$concat(x, b); x.length = n; return x; }) : () => Ops.Ops$concat(a, b)],
    [sc, 'insert, first', n, () => Ops.Ops$insert(a, mid, vs[0])],
    [sc, 'insert, threaded', n, M ? (() => { const x = own(); let t = 0; return () => ((t ^= 1) ? Ops.Ops$insert(x, mid, vs[0]) : Ops.Ops$remove(x, mid)); })() : threaded((x) => Ops.Ops$insert(x, mid, vs[0]), period)],
    [sc, 'remove, first', n, () => Ops.Ops$remove(a, mid)],
    [sc, 'remove, threaded', n, M ? (() => { const x = own(); let t = 0; return () => ((t ^= 1) ? Ops.Ops$remove(x, mid) : Ops.Ops$insert(x, mid, vs[0])); })() : threaded((x) => Ops.Ops$remove(x, (RT.length(x) >> 1)), period)],
    [sc, 'swap, first', n, () => Ops.Ops$swap(a, 1, n - 2)],
    [sc, 'swap, threaded', n, M ? inPlace((x) => Ops.Ops$swap(x, 1, n - 2)) : threaded((x) => Ops.Ops$swap(x, 1, n - 2))],
    [sc, 'map', n, () => Ops.Ops$map(a, toO)],
    [sc, 'filter', n, () => Ops.Ops$filter(a, even)],
    [sc, 'foldl', n, () => Ops.Ops$foldl(a, 0, addK)],
    [sc, 'iterate', n, () => { let s = 0; walk(a, (x) => { s += x.k; }); return s; }],
    [sc, 'fromArray', n, () => seq(d.data)],
    [sc, 'toArray', n, () => toJs(a)],
    [sc, 'eq', n, () => Ops.Ops$eq(eqf, a, a2)],
    [sc, 'sort', n, () => Ops.Ops$sort(sh, cmp)],
  ];
  return cells;
}

// The differential test: every op on small and boundary sizes, results reduced to their keys, the
// input checked unchanged afterwards (a candidate that writes in place fails it, as it should).
const keys = (x) => toJs(x).map((e) => e.k).join(',');
export function opsTest() {
  const out = [];
  for (const n of [1, 2, 3, 8, 33, 257, 1000, 1025]) {
    const d = dataFor(n), seq = (arr) => fromJs(arr.slice());
    const one = (op, f) => { const a = seq(d.data), before = keys(a); let r; try { r = f(a); } catch (e) { r = 'threw ' + String(e).slice(0, 40); } out.push(`0 single operations | ${op} | ${n} | ${r} | ${keys(a) === before ? 'input unchanged' : 'INPUT CHANGED'}`); };
    one('get', (a) => [0, n >> 1, n - 1].map((i) => Ops.Ops$get(a, i).a.k).join(','));
    one('set', (a) => keys(Ops.Ops$set(a, n >> 1, d.vals[0])));
    one('set, same value', (a) => Ops.Ops$set(a, n >> 1, d.data[n >> 1]) === a);
    one('push', (a) => keys(Ops.Ops$push(a, d.vals[1])));
    one('pop', (a) => keys(Ops.Ops$pop(a)));
    one('slice', (a) => keys(Ops.Ops$slice(a, n >> 2, (3 * n) >> 2)));
    one('concat', (a) => keys(Ops.Ops$concat(a, seq(d.data2))));
    one('insert', (a) => keys(Ops.Ops$insert(a, n >> 1, d.vals[2])));
    one('remove', (a) => keys(Ops.Ops$remove(a, n >> 1)));
    one('swap', (a) => keys(Ops.Ops$swap(a, 0, n - 1)));
    one('map', (a) => toJs(Ops.Ops$map(a, toO)).map((e) => e.k).join(','));
    one('filter', (a) => keys(Ops.Ops$filter(a, even)));
    one('foldl', (a) => Ops.Ops$foldl(a, 0, addK));
    one('iterate', (a) => { const ks = []; walk(a, (x, i) => ks.push(`${i}:${x.k}`)); return ks.join(','); });
    one('eq', (a) => `${Ops.Ops$eq(eqf, a, seq(d.data))} ${Ops.Ops$eq(eqf, a, seq(d.data2))}`);
    one('sort', (a) => keys(Ops.Ops$sort(seq(d.shuffled), cmp)));
    // a write that goes through several versions: each old version must still read as it did
    one('versions', (a) => { const b1 = Ops.Ops$push(a, d.vals[3]), b2 = Ops.Ops$set(a, 0, d.vals[4]), b3 = Ops.Ops$pop(b1); return [keys(b1), keys(b2), keys(b3)].join(' / '); });
  }
  return out.join('\n');
}
