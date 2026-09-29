// Candidate B of research/38 §16: ONE sequence type for both `List` and `Array`, the adaptive array
// of §15 (plain JS array until the first single-element write to one longer than T, the §1 trie
// after it) plus a third form, the VIEW, which is what `x :: rest` matching makes:
//
//   plain  a JS array, never mutated after construction     (§15's plain form)
//   trie   {n, s, r, t} from ports/trie.js                  (§15's written form)
//   view   V {b, o, length}: elements o, o+1, … of a plain backing array b to its end
//
// How the list syntax lowers (lists.mjs's rewrite of beni's output; a patched `js/Lower.zig` would
// emit the same calls):
//
//   []            $nil                  the one shared empty plain array
//   x :: xs       $cons(x, xs)          a COPY: a fresh plain array of length(xs) + 1   O(n)
//   case: []      $isNil(s)             length === 0                                   O(1)
//   case: x :: r  $hd(s), $tl(s)        the first element, and a view one further on   O(1)
//
// A view is never empty (the tail of a one-element sequence is $nil) and always runs to the end of
// its backing, because the only thing that makes one is taking a tail; the tail of a trie converts
// it to a plain array first (O(n), once per walk), so a view's backing is always plain. A view's
// remaining count is called `length` so that the empty test is one property read for a plain array
// and a view alike; no trie is ever empty here (`pop` returns $nil instead). Every operation that
// is not a read accepts all three forms; the ones that build a fresh sequence return a plain
// array, as §15's adaptive does. T is ADA_T (256, §15.11's setting). The checks test for a view
// first because a walk sees views on every step after the first (this order and the `length` field
// measured 1.6× faster on a 1 000-element walk than a plain-array-first test and a separate count).
import * as A from './adaptive.js';
import * as T from './trie.js';

const isA = Array.isArray;
export class V {
  constructor(b, o, length) { this.b = b; this.o = o; this.length = length; }
}
const isV = (x) => x instanceof V;
export const $nil = [];

// ---- the list syntax ------------------------------------------------------------------------
export const $isNil = (x) => x.length === 0;
export const $isCons = (x) => x.length !== 0;
export const $hd = (x) => (isV(x) ? x.b[x.o] : isA(x) ? x[0] : T.get(x, 0));
export function $tl(x) {
  if (isV(x)) return x.length > 1 ? new V(x.b, x.o + 1, x.length - 1) : $nil;
  if (isA(x)) return x.length > 1 ? new V(x, 1, x.length - 1) : $nil;
  return x.n > 1 ? new V(T.toArray(x), 1, x.n - 1) : $nil;
}
export function $cons(h, t) {
  if (isV(t)) { const c = t.b.slice(t.o - 1); c[0] = h; return c; }
  if (isA(t)) {
    const n = t.length;
    if (n === 0) return [h];
    if (n >= 64) return [h].concat(t);
    const c = new Array(n + 1);
    c[0] = h;
    for (let i = 0; i < n; i++) c[i + 1] = t[i];
    return c;
  }
  return [h].concat(T.toArray(t));
}
// literals longer than the emitter's cons limit: `[e1, …, en]` is already the array
export const $fromArray = (arr) => arr;

// ---- the representation helpers ---------------------------------------------------------------
// a plain array holding exactly the sequence (a copy only for a view or a trie)
export function plain(x) {
  if (isA(x)) return x;
  if (isV(x)) return x.b.slice(x.o);
  return T.toArray(x);
}
// (array, start) covering the sequence to the array's end, without copying a plain backing;
// results in SA / SO so a loop pays no allocation for them
export let SA = $nil, SO = 0;
export function span(x) {
  if (isV(x)) { SA = x.b; SO = x.o; } else if (isA(x)) { SA = x; SO = 0; } else { SA = T.toArray(x); SO = 0; }
}
export const len = (x) => (isA(x) || isV(x) ? x.length : x.n);

// ---- the Array port API of §15 (scenarios.mjs), views accepted ---------------------------------
const flat = (x) => (isV(x) ? plain(x) : x); // a view becomes plain before any adaptive operation
export const empty = $nil;
export const length = len;
export const get = (x, i) => (isA(x) ? x[i] : isV(x) ? x.b[x.o + i] : T.get(x, i));
export const set = (x, i, v) => A.set(flat(x), i, v);
export const push = (x, v) => A.push(flat(x), v);
export const pop = (x) => { const r = A.pop(flat(x)); return r.n === 0 ? $nil : r; }; // never an empty trie
export const swap = (x, i, j) => A.swap(flat(x), i, j);
export const slice = (x, s, e) => A.slice(flat(x), s, e);
export const concat = (x, y) => A.concat(flat(x), flat(y));
export const sort = (x, cmp) => A.sort(flat(x), cmp);
export const toArray = (x) => A.toArray(flat(x));
export const fromCons = A.fromCons; // §15's Array.beni hands over temporary cons lists it builds itself
export const toCons = (x, nil) => A.toCons(flat(x), nil);
export const eq = (x, y, f) => A.eq(flat(x), flat(y), f);
