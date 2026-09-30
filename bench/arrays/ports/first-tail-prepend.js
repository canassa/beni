// Candidate E1tp of research/46 §11: E1t (ports/first-tail.js) plus cheap prepend, after Scala
// 2.13's `Vector` (prefix and suffix buffers around a radix-balanced tree), without its per-level
// prefix arrays: one header shape and a radix OFFSET instead. The forms are E1t's:
//
//   plain  a JS array, never mutated after construction
//   view   V {b, o, length}: elements o… of a plain backing array b, to its end
//   trie   {length, h, hc, T: {r, s, off, tc}, t, p}: a HEAD buffer, a 32-way radix tree, E1t's
//          tail. Unlike E1t's trie it has a `length`, so `length` and `[]` read one field
//
// The trie's elements, in order:
//
//   head   h[hc-1], h[hc-2], … h[0]: the first hc elements, stored REVERSED, so that a prepend is
//          an append to h and can be CLAIMED exactly as E1t claims its tail
//   tree   tc elements at radix positions off … off+tc-1 of the root r (shift s): element k of
//          the tree is r[(off+k) >>> s & 31]…[(off+k) & 31]. off and tc are multiples of 32, so
//          the tree is whole leaves, as E1t's is; only where it starts moves
//   tail   t[0 … length-hc-tc-1]: E1t's claimable tail, 1 to 32 elements, never empty
//
// 1. A CLAIMABLE HEAD. `x :: xs` onto a trie whose head array ends exactly at its own head count
//    (h.length === hc < 32) pushes x onto h IN PLACE and returns a new header sharing it; every
//    other version sharing h reads only its own first hc′ ≤ hc slots, so none can see the write.
//    Onto any other version it copies the at most 31 head elements it owns. If the slot past the
//    version's head already holds x (the version is the tail of one that began with x), the
//    header takes it without writing. A full head (32) becomes a leaf, reversed into a fresh
//    array, at radix off-32 … off-1: the offset moves left, so indexing stays O(log₃₂ n). When off
//    is below the leaf, the root grows LEFT: a new root with the old one at child 16 (half the
//    width either side, like Scala's `data` array centred between its prefix and suffix).
// 2. `$tl` of a trie is a trie, O(1): it drops the head's first element (hc - 1) or, with no
//    head, makes the rest of the first leaf the head (a reversed copy of 31, once every 32 steps)
//    and moves the offset one leaf right without touching the tree (Scala's drop by offset). E1t
//    made the tail of a trie a view over the trie's cached plain copy, O(n) once; a view is cheap
//    to walk but costs O(n) to prepend onto, which is what a persistent stack does after `pop`.
// 3. `x :: xs` onto a plain list of 32 or more (or a view that long) converts it to a trie once,
//    O(n), with x in the head; E1t copied it every time. Below 32 it is a copy, as `push` is.
//
// Everything else is E1t's, unchanged in behaviour: `push` claims the tail and converts a plain
// array at 32, `set`/`pop` keep T = 256 on plain arrays, `slice` and every bulk operation return
// plain arrays, a trie caches its plain copy. No leaf and no inner node is ever written after it is
// published; the head and the tail are the two claimable arrays, and neither is ever a leaf or a
// plain list's array.
const LIM = typeof ADA_T === 'number' ? ADA_T : 256;
const PT = typeof PUSH_T === 'number' ? PUSH_T : 32;
const isA = Array.isArray;
export class V {
  constructor(b, o, length) { this.b = b; this.o = o; this.length = length; }
}
const isV = (x) => x instanceof V;
export const $nil = [];

// ---- the trie: a head, a radix tree with an offset, a claimable tail ---------------------------------
// A header is {length, h, hc, T, t, p}; the tree T = {r, s, off, tc} is its own object, shared by every
// header between two changes of the tree (a prepend or a push that stays in its buffer, a `$tl`
// inside the head, a `pop` inside the tail), so the header a list operation allocates is six fields
// where E1t's is five.
const mk = (n, h, hc, T, t) => ({ length: n, h, hc, T, t, p: null });
const tree = (r, s, off, tc) => ({ r, s, off, tc });
const NOTREE = tree([], 5, 0, 0);
const tailOff = (n) => (n === 0 ? 0 : ((n - 1) >>> 5) << 5);
const NULL16 = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null];
const span5 = (s) => 2 ** (s + 5); // the radix positions a root at shift s covers
function tget(a, i) {
  const hc = a.hc;
  if (i < hc) return a.h[hc - 1 - i];
  i -= hc;
  const T = a.T, tc = T.tc;
  if (i >= tc) return a.t[i - tc];
  i += T.off;
  let x = T.r;
  for (let s = T.s; s > 0; s -= 5) x = x[(i >>> s) & 31];
  return x[i & 31];
}
function leafAt(r, s, i) {
  let x = r;
  for (; s > 0; s -= 5) x = x[(i >>> s) & 31];
  return x;
}
function setIn(x, s, i, v) {
  const c = x.slice();
  if (s === 0) c[i & 31] = v;
  else { const j = (i >>> s) & 31; c[j] = setIn(x[j], s - 5, i, v); }
  return c;
}
// a copy of node x (null: a new node) with `leaf` at radix position i; a gap left of a new child
// is filled with null, so every node stays a packed array
function putLeaf(x, s, i, leaf) {
  const c = x == null ? [] : x.slice(), j = (i >>> s) & 31;
  while (c.length < j) c.push(null);
  c[j] = s === 5 ? leaf : putLeaf(j < c.length ? c[j] : null, s - 5, i, leaf);
  return c;
}
function popLeaf(x, s, i) {
  const j = (i >>> s) & 31;
  if (s === 5) return j === 0 ? null : x.slice(0, j);
  const c = popLeaf(x[j], s - 5, i);
  if (c === null) return j === 0 ? null : x.slice(0, j);
  const y = x.slice(); y[j] = c; return y;
}
function tset(a, i, v) {
  if (i < 0 || i >= a.length || tget(a, i) === v) return a;
  const hc = a.hc, T = a.T, tc = T.tc;
  if (i < hc) { const h = a.h.slice(0, hc); h[hc - 1 - i] = v; return mk(a.length, h, hc, T, a.t); }
  const j = i - hc;
  if (j >= tc) { const t = a.t.slice(0, a.length - hc - tc); t[j - tc] = v; return mk(a.length, a.h, hc, T, t); }
  return mk(a.length, a.h, hc, tree(setIn(T.r, T.s, T.off + j, v), T.s, T.off, tc), a.t);
}
// push: E1t's claimable tail; a full tail becomes the leaf at radix off+tc
function tpush(a, v) {
  const n = a.length, hc = a.hc, T = a.T, tc = T.tc, cnt = n - hc - tc;
  if (cnt < 32) {
    if (a.t.length === cnt) { a.t.push(v); return mk(n + 1, a.h, hc, T, a.t); } // claim the end
    const t = a.t.slice(0, cnt); t.push(v);
    return mk(n + 1, a.h, hc, T, t);
  }
  let r = T.r, s = T.s, off = T.off;
  if (tc === 0) { r = []; s = 5; off = 0; }
  const te = off + tc;
  while (te >= span5(s)) { r = [r]; s += 5; }
  return mk(n + 1, a.h, hc, tree(putLeaf(r, s, te, a.t), s, off, tc + 32), [v]); // a.t is exactly 32 long
}
// prepend: the claimable head; a full head becomes the leaf left of off
function tprepend(a, v) {
  const n = a.length, hc = a.hc, h = a.h;
  if (hc < 32) {
    if (h.length === hc) { h.push(v); return mk(n + 1, h, hc + 1, a.T, a.t); } // claim
    if (h[hc] === v) return mk(n + 1, h, hc + 1, a.T, a.t); // already there
    const c = h.slice(0, hc); c.push(v);
    return mk(n + 1, c, hc + 1, a.T, a.t);
  }
  const T = a.T, tc = T.tc;
  let r = T.r, s = T.s, off = T.off;
  if (tc === 0) { r = []; s = 5; off = 512; } // an empty tree starts mid-root: room on both sides
  while (off < 32) { r = NULL16.concat([r]); off += 16 * span5(s); s += 5; } // grow left
  return mk(n + 1, [v], 1, tree(putLeaf(r, s, off - 32, h.slice(0, 32).reverse()), s, off - 32, tc + 32), a.t);
}
// the tail of a trie (`x :: rest`, List.drop 1), O(1): the head loses its first element, or the
// rest of the tree's first leaf becomes the head (a reversed copy of 31 every 32 steps) and the
// offset moves one leaf right, the nodes untouched
function ttl(a) {
  const n = a.length, hc = a.hc;
  if (n <= 1) return $nil;
  if (hc > 0) return mk(n - 1, a.h, hc - 1, a.T, a.t);
  const T = a.T, tc = T.tc;
  if (tc > 0) {
    const leaf = leafAt(T.r, T.s, T.off), h = [];
    for (let k = 31; k > 0; k--) h.push(leaf[k]);
    return mk(n - 1, h, 31, tc === 32 ? NOTREE : tree(T.r, T.s, T.off + 32, tc - 32), a.t);
  }
  return a.t.slice(1, n);
}
function tpop(a) {
  const n = a.length;
  if (n <= 1) return $nil;
  const hc = a.hc, T = a.T, tc = T.tc;
  if (n - hc - tc > 1) return mk(n - 1, a.h, hc, T, a.t); // share the tail
  if (tc === 0) return a.h.slice(0, hc).reverse(); // only the head is left
  // the tree's last leaf becomes the tail
  const base = T.off + tc - 32, leaf = leafAt(T.r, T.s, base);
  if (base === T.off) return mk(n - 1, a.h, hc, NOTREE, leaf);
  let r = popLeaf(T.r, T.s, base) || [], s = T.s, off = T.off;
  const last = base - 1;
  while (s > 5 && (off >>> s) === (last >>> s)) { const j = off >>> s; r = r[j]; off -= j * 2 ** s; s -= 5; } // a root with one live child
  return mk(n - 1, a.h, hc, tree(r, s, off, tc - 32), leaf);
}
// a plain array (from index `from`) as a trie: E1t's layout, an empty head, the tree at offset 0
function tfrom(arr, from = 0) {
  const n = arr.length - from, o = tailOff(n);
  if (o === 0) return mk(n, [], 0, NOTREE, arr.slice(from));
  let xs = [];
  for (let i = 0; i < o; i += 32) xs.push(arr.slice(from + i, from + i + 32));
  let s = 5;
  while (xs.length > 32) {
    const up = [];
    for (let i = 0; i < xs.length; i += 32) up.push(xs.slice(i, i + 32));
    xs = up; s += 5;
  }
  return mk(n, [], 0, tree(xs, s, 0, o), arr.slice(from + o));
}
// the elements in order as arrays: the head reversed, each leaf, the tail cut to this version's
// count. The runtime's walk; no element copied but the head's
export function chunksOf(a) {
  const out = [], hc = a.hc, T = a.T, te = T.off + T.tc;
  if (hc > 0) out.push(a.h.slice(0, hc).reverse());
  for (let i = T.off; i < te; i += 32) out.push(leafAt(T.r, T.s, i));
  const cnt = a.length - hc - T.tc;
  out.push(a.t.length === cnt ? a.t : a.t.slice(0, cnt));
  return out;
}
export function tflatFresh(a) {
  const ls = chunksOf(a);
  let out = [];
  for (let i = 0; i < ls.length; i += 8192) out = out.concat.apply(out, ls.slice(i, i + 8192));
  return out;
}
function tflat(a) {
  if (a.p !== null) return a.p;
  return (a.p = tflatFresh(a));
}
function teach(a, f) {
  const h = a.h, hc = a.hc, T = a.T, te = T.off + T.tc;
  for (let i = hc - 1; i >= 0; i--) f(h[i]);
  for (let i = T.off; i < te; i += 32) {
    const leaf = leafAt(T.r, T.s, i);
    for (let k = 0; k < 32; k++) f(leaf[k]);
  }
  const t = a.t, cnt = a.length - hc - T.tc;
  for (let i = 0; i < cnt; i++) f(t[i]);
}

// ---- the list syntax ------------------------------------------------------------------------
export const $isNil = (x) => x.length === 0; // every form has a `length`; a trie is never empty
export const $isCons = (x) => x.length !== 0;
export const $hd = (x) => (isV(x) ? x.b[x.o] : isA(x) ? x[0] : x.hc > 0 ? x.h[x.hc - 1] : tget(x, 0));
export function $tl(x) {
  if (isV(x)) return x.length > 1 ? new V(x.b, x.o + 1, x.length - 1) : $nil;
  if (isA(x)) return x.length > 1 ? new V(x, 1, x.length - 1) : $nil;
  return ttl(x);
}
export function $cons(h, t) {
  if (isV(t)) {
    const b = t.b, o = t.o;
    if (b[o - 1] === h) return o === 1 ? b : new V(b, o - 1, t.length + 1); // re-consing what a pattern matched
    if (t.length + 1 >= PT) return tprepend(tfrom(b, o), h);
    t = b.slice(o);
  }
  if (isA(t)) {
    const n = t.length;
    if (n === 0) return [h];
    if (n >= PT) return tprepend(tfrom(t), h);
    const c = new Array(n + 1);
    c[0] = h;
    for (let i = 0; i < n; i++) c[i + 1] = t[i];
    return c;
  }
  return tprepend(t, h);
}
export const $fromArray = (arr) => arr;

// ---- representation helpers ---------------------------------------------------------------------
export function plain(x) { return isA(x) ? x : isV(x) ? x.b.slice(x.o) : tflat(x); }
export let SA = $nil, SO = 0;
export function span(x) {
  if (isV(x)) { SA = x.b; SO = x.o; } else if (isA(x)) { SA = x; SO = 0; } else { SA = tflat(x); SO = 0; }
}

// ---- the sibling surface of lists/first-core/List.beni -------------------------------------------
function copy(a, extra) {
  const n = a.length;
  if (n >= 64) return a.concat();
  const c = new Array(n + extra);
  for (let j = 0; j < n; j++) c[j] = a[j];
  return c;
}
export const cons = (head, tail) => $cons(head, tail);
export const length = (xs) => xs.length;
export const unsafeGet = (xs, i) => (isA(xs) ? xs[i] : isV(xs) ? xs.b[xs.o + i] : tget(xs, i));
export function set(xs, i, v) {
  if (isV(xs)) xs = plain(xs);
  if (!isA(xs)) return tset(xs, i, v);
  if (i < 0 || i >= xs.length || xs[i] === v) return xs;
  if (xs.length <= LIM) { const c = copy(xs, 0); c[i] = v; return c; }
  return tset(tfrom(xs), i, v);
}
export function push(xs, v) {
  if (isV(xs)) xs = plain(xs);
  if (!isA(xs)) return tpush(xs, v);
  const n = xs.length;
  if (n < PT) { const c = copy(xs, 1); c[n] = v; return c; }
  return tpush(tfrom(xs), v);
}
export function pop(xs) {
  if (isV(xs)) xs = plain(xs);
  if (!isA(xs)) return tpop(xs);
  if (xs.length === 0) return xs;
  return xs.length <= LIM ? xs.slice(0, -1) : tpop(tfrom(xs));
}
export function slice(xs, from, to) {
  const n = length(xs);
  if (from < 0) from = Math.max(0, n + from);
  if (to < 0) to = Math.max(0, n + to);
  if (to > n) to = n;
  if (from === 0 && to === n) return xs;
  if (from >= to) return $nil;
  if (isV(xs)) return xs.b.slice(xs.o + from, xs.o + to);
  return (isA(xs) ? xs : tflat(xs)).slice(from, to);
}
export function append(xs, ys) {
  const m = length(ys);
  if (m === 0) return xs;
  if (length(xs) === 0) return ys;
  if (isA(xs) || isV(xs)) return plain(xs).concat(plain(ys));
  // a trie keeps its tree and takes ys onto its tail, in place where it can claim it
  span(ys); const b = SA, o = SO;
  let a = xs;
  for (let i = 0; i < m; i++) a = tpush(a, b[o + i]);
  return a;
}
export const builder = (n) => [];
export const add = (b, x) => { b.push(x); return b; };
export const done = (b) => b;
export function eq(m0, xs, ys) {
  if (xs === ys) return true;
  const n = length(xs);
  if (n !== length(ys)) return false;
  for (let i = 0; i < n; i++) if (!m0(unsafeGet(xs, i), unsafeGet(ys, i))) return false;
  return true;
}
export function compare(m0, xs, ys) {
  const n = length(xs), m = length(ys), k = Math.min(n, m);
  for (let i = 0; i < k; i++) { const o = m0(unsafeGet(xs, i), unsafeGet(ys, i)); if (o !== 'EQ') return o; }
  return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
}
export const basicsAppend = (a, b) => (typeof a === 'string' ? a + b : append(a, b));

// ---- harness hooks ----------------------------------------------------------------------------------
export const fromJs = (arr) => arr.slice();
export const toJs = (xs) => plain(xs).slice();
export function walk(xs, visit) {
  if (isA(xs) || isV(xs)) { span(xs); const a = SA, n = a.length, o = SO; for (let i = o; i < n; i++) visit(a[i], i - o); return; }
  let k = 0; teach(xs, (x) => visit(x, k++)); // the runtime walks a trie's buffers and leaves, no copy
}
export const stackTopLast = true;
export const kind = (xs) => (isA(xs) ? 'plain' : isV(xs) ? 'view' : 'trie');
