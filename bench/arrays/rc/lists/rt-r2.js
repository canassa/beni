// research/42 §8: R2 (the sticky shared bit) on research/38 §16's single sequence type B, where
// `List` is an array and `x :: xs` copies. The question is whether a run-time bit gives B the
// O(1) prepend that C's static rewrites could not reach (an accumulator inside a record or a
// tuple). It replaces `core/List` and the lowering's `$` primitives, as lists/core-single.js does.
//
// A sequence is a plain JS array, or a view V {b, o, length}: the elements b[o], …, b[end] of a
// backing array b, which always runs to b's end (ports/single.js's invariant). Both carry `rc`
// (1 unique, 2 shared, sticky); a view's backing carries its own `rc`, because the tail a match
// takes (`$tl`) is a second view on the same backing.
//
//   x :: t   t is consumed. When t is a unique view on a unique backing, the element goes into
//            the free slot before o, in place: amortised O(1), because a full backing is regrown
//            with as much room in front as it holds. Otherwise it is a copy with 8 free slots.
//   $tl x    a new view one further on; x's storage now has two readers, so it is marked shared.
//   $hd x    the element leaves the sequence: marked shared if it is a counted value.
//
// No element here is itself counted except in `chainPaths` (a list of lists), whose parent path
// is read out of `paths` and so is shared: its `i :: parent` copies, as it must.
const PIN = 2;
export class V {
  constructor(b, o, length) { this.b = b; this.o = o; this.length = length; this.rc = 1; }
}
const isV = (x) => x instanceof V;
const isA = Array.isArray;
const share = (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc = 2; return x; };
const fresh = (a) => { a.rc = 1; return a; };
export const $nil = []; $nil.rc = PIN;

export const $isNil = (x) => x.length === 0;
export const $isCons = (x) => x.length !== 0;
export const $hd = (x) => share(isV(x) ? x.b[x.o] : x[0]);
export function $tl(x) {
  if (x.length <= 1) return $nil;
  if (isV(x)) { x.b.rc = 2; return new V(x.b, x.o + 1, x.length - 1); }
  x.rc = 2;
  return new V(x, 1, x.length - 1);
}
// a fresh backing of `n` elements copied from a[o…], with `room` free slots in front
function backing(a, o, n, room) {
  const b = new Array(room + n);
  for (let i = 0; i < n; i++) b[room + i] = a[o + i];
  b.rc = 1;
  return b;
}
export function $cons(h, t) {
  if (isV(t)) {
    if (t.rc === 1 && t.b.rc === 1) {
      if (t.o === 0) { const n = t.length, room = Math.max(8, n); t.b = backing(t.b, 0, n, room); t.o = room; }
      t.b[--t.o] = h; t.length++;
      return t;
    }
    const n = t.length, v = new V(backing(t.b, t.o, n, 8), 8, n);
    v.b[--v.o] = h; v.length++;
    return v;
  }
  const n = t.length;
  // a unique plain array is regrown with room in front (once); a shared one is copied
  const room = t.rc === 1 ? Math.max(8, n) : 8;
  const v = new V(backing(t, 0, n, room), room, n);
  v.b[--v.o] = h; v.length++;
  return v;
}
export const $fromArray = (arr) => fresh(arr);

// ---- core/List, the functions the scenarios reach, as lists/core-single.js writes them --------
let SA = $nil, SO = 0;
function span(x) { if (isV(x)) { SA = x.b; SO = x.o; } else { SA = x; SO = 0; } }
const plain = (x) => (isV(x) ? x.b.slice(x.o) : x);
export const List$cons = $cons;
// `xs` borrowed, `acc` owned and threaded; every element read out is shared (rule O5)
export function List$foldl(xs, acc, f) {
  span(xs); const a = SA, n = a.length;
  for (let i = SO; i < n; i++) acc = f(share(a[i]), acc);
  return acc;
}
export function List$foldr(xs, acc, f) {
  span(xs); const a = SA, o = SO;
  for (let i = a.length - 1; i >= o; i--) acc = f(share(a[i]), acc);
  return acc;
}
export function List$map(xs, f) {
  span(xs); const a = SA, n = a.length, out = [];
  for (let i = SO; i < n; i++) out.push(f(share(a[i])));
  return fresh(out);
}
export function List$filter(xs, keep) {
  span(xs); const a = SA, n = a.length, o = SO, out = [];
  for (let i = o; i < n; i++) { const x = share(a[i]); if (keep(x)) out.push(x); }
  return out.length === n - o ? share(xs) : fresh(out);
}
export function List$reverse(xs) {
  span(xs); const a = SA, o = SO, out = [];
  for (let i = a.length - 1; i >= o; i--) out.push(share(a[i]));
  return fresh(out);
}
export function List$range(lo, hi) { const out = []; for (let i = lo; i <= hi; i++) out.push(i); return fresh(out); }
export const List$sum = (xs) => List$foldl(xs, 0, (x, s) => s + x);
export function List$append(xs, ys) {
  if (ys.length === 0) return share(xs);
  if (xs.length === 0) return share(ys);
  return fresh(plain(xs).concat(plain(ys)));
}
export function List$concatMap(xs, f) {
  span(xs); const a = SA, n = a.length, out = [];
  for (let i = SO; i < n; i++) { const ys = f(share(a[i])); span(ys); const b = SA, m = b.length; for (let j = SO; j < m; j++) out.push(b[j]); span(xs); }
  return fresh(out);
}
export function List$map2(xs, ys, f) {
  span(xs); const a = SA, i0 = SO; span(ys); const b = SA, j0 = SO;
  const m = Math.min(a.length - i0, b.length - j0), out = [];
  for (let k = 0; k < m; k++) out.push(f(share(a[i0 + k]), share(b[j0 + k])));
  return fresh(out);
}
export const append = (a, b) => (typeof a === 'string' ? a + b : List$append(a, b));

// ---- harness hooks ---------------------------------------------------------------------------------
export const fromJs = (arr) => fresh(arr.slice());
export const toJs = (xs) => plain(xs).slice();
export function walk(xs, visit) {
  span(xs); const a = SA, n = a.length, o = SO;
  for (let i = o; i < n; i++) visit(a[i], i - o);
}
// what the DOM runtime keeps (`s.b`) is shared from then on
export const $share = share;
export const retain = share;
export const keep = share;
