// The sibling JavaScript of `List.beni` (docs/design/boundary.md §4): the
// runtime of the array-backed `List`, backend.md §4, *Lists are arrays*.
//
// A `List` value is one of three FORMS, and no answer a program can compute
// depends on which:
//
//   plain  a JavaScript array, never written after it is published
//   view   { b, o, length, p, $plain }: the elements b[o] … b[b.length - 1]
//          of a plain array b, o >= 1 — what a pattern's `rest` is
//   trie   { length, h, hc, T, t, p, $plain }: E1tp, a 32-way radix tree
//          with a claimable HEAD and a claimable TAIL (§4, *The claimable
//          head: E1tp*; the prototype is bench/arrays/ports/first-tail-prepend.js)
//
// A trie's elements, in order: the head h[hc - 1], h[hc - 2], … h[0] — the
// first hc elements, stored REVERSED so that a prepend is an append to h —
// then the tree T = { r, s, off, tc }, tc elements at radix positions
// off … off + tc - 1 of the root r (shift s), whole leaves of 32, then the
// tail t[0 … length - hc - tc - 1], 1 to 32 elements. Every reader outside
// this file uses three facts and no field name: `xs.length`,
// `Array.isArray(xs)` for the plain form, and `xs.$plain()` for the others
// (§4, *What a reader of a list may rely on*).
//
// Nothing published is written, but for two claims and a cache (§4,
// invariant 1): `push` onto the version that owns the end of its tail array
// appends to that array in place, a prepend onto the version that owns the
// end of its head array does the same at the front, and `p` caches a trie's
// (or a view's) plain copy once. Each version reads only its own first
// counts of the two arrays, so no other version can see either write.
//
// How this file is written (research/40 §8): the readers — `length`,
// `unsafeGet`, `view`, `base`, `offset`, `slice`, `insertAt`, `removeAt`,
// `eq`, `compare` — never NAME the trie's write code, because a program that
// imports only readers can never hold a trie and `--release` then drops it;
// top-level names are capitalised and locals are not, so a local never keeps
// a top-level unit alive by sharing its name; every top-level initialiser is
// inert; each export is `export const f = (…) =>`. `cons` and `append` are
// writers: a prepend onto 32 elements or more is where a trie is born.
//
// The radix positions are unsigned 32-bit: the descent uses `>>>`, so every
// position must stay below 2^32. Pushes alone reach it only past 2^32
// elements, more than an array holds; left growth centres the old root, so
// one lineage reaches it after about 2^29 prepends — some 4 GB of element
// references, beyond any tab's heap. There is no check.

// ---- The two thresholds (§4: research/38 §15.11 and §17.2) -------------

// `set`, `pop` and `swap` convert a plain list longer than this to a trie.
const Lim = 256;
// `push` and a prepend convert one of Wide elements or more; below it a
// write copies. The same number is a leaf's and a buffer's width.
const Wide = 32;

const IsA = Array.isArray;

// ---- Views -------------------------------------------------------------

// A view's `$plain()`: its elements as a fresh plain array, made once.
const ViewPlain = function () {
  return this.p !== null ? this.p : (this.p = this.b.slice(this.o));
};
// The suffix of plain array `b` from `o`, 1 <= o < b.length.
const View = (b, o) => ({ b, o, length: b.length - o, p: null, $plain: ViewPlain });

// ---- The trie's read half ------------------------------------------------

// A trie's `$plain()`: its elements in order, cached on the header.
const TriePlain = function () {
  return Flat(this);
};
const Mk = (n, h, hc, T, t) => ({ length: n, h, hc, T, t, p: null, $plain: TriePlain });
const Tree = (r, s, off, tc) => ({ r, s, off, tc });
const NoTree = { r: [], s: 5, off: 0, tc: 0 };

// The leaf holding radix position i of a root r at shift s: the one
// descent, which every read of the tree goes through.
const Leaf = (r, s, i) => {
  for (; s > 0; s -= 5) r = r[(i >>> s) & 31];
  return r;
};
// Element i of trie a. Direct, not through a binding a writer sets: a read
// through an indirection cost 15–18 % on a trie fold (research/40 §5 rule 2).
const Get = (a, i) => {
  const hc = a.hc;
  if (i < hc) return a.h[hc - 1 - i];
  const T = a.T;
  i -= hc;
  if (i >= T.tc) return a.t[i - T.tc];
  i += T.off;
  return Leaf(T.r, T.s, i)[i & 31];
};
// The trie's elements as arrays in order: the head reversed (a copy), each
// leaf, and the tail cut to this version's count.
const Chunks = (a) => {
  const out = [];
  const hc = a.hc;
  const T = a.T;
  const e = T.off + T.tc;
  const n = a.length - hc - T.tc;
  if (hc > 0) out.push(a.h.slice(0, hc).reverse());
  for (let i = T.off; i < e; i += 32) out.push(Leaf(T.r, T.s, i));
  out.push(a.t.length === n ? a.t : a.t.slice(0, n));
  return out;
};
// The trie's plain copy, made once per header (invariant 1's cache).
// `concat.apply` 8 192 chunks at a time keeps the argument count far below
// every engine's limit.
const Flat = (a) => {
  if (a.p !== null) return a.p;
  const c = Chunks(a);
  let out = [];
  for (let i = 0; i < c.length; i += 8192) out = out.concat.apply(out, c.slice(i, i + 8192));
  return (a.p = out);
};
// Trie a without its first k elements, 0 < k < a.length: a trie sharing the
// tree, never a flatten (§4, *Removing a prefix*). Inside the head it is a
// header with a smaller head count; past it, whole leaves go by moving the
// offset and the rest of the new first leaf becomes the head, a reversed
// copy of at most 31; with only tail elements left, a fresh plain array.
const Drop = (a, k) => {
  const n = a.length - k;
  const hc = a.hc;
  if (k <= hc) return Mk(n, a.h, hc - k, a.T, a.t);
  const T = a.T;
  const tc = T.tc;
  k -= hc;
  if (k >= tc) return a.t.slice(k - tc, a.length - hc - tc);
  const off = T.off + (k & -32);
  const left = tc - (k & -32);
  const r = k & 31;
  if (r === 0) return Mk(n, [], 0, Tree(T.r, T.s, off, left), a.t);
  const leaf = Leaf(T.r, T.s, off);
  const h = [];
  for (let j = 31; j >= r; j--) h.push(leaf[j]);
  return Mk(n, h, 32 - r, left === 32 ? NoTree : Tree(T.r, T.s, off + 32, left - 32), a.t);
};

// The plain array a list is a suffix of, and where in it the list starts:
// (xs, 0) plain, (b, o) a view, (its cached copy, 0) a trie.
const Base = (xs) => (IsA(xs) ? xs : xs.o !== undefined ? xs.b : Flat(xs));
const Offset = (xs) => (IsA(xs) || xs.o === undefined ? 0 : xs.o);

// ---- The trie's write half ---------------------------------------------

// The radix positions a root at shift s covers.
const Span = (s) => 2 ** (s + 5);
const NullRow = [null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null];

// A path copy: node x with the element at radix position i replaced.
const SetIn = (x, s, i, v) => {
  const c = x.slice();
  if (s === 0) c[i & 31] = v;
  else c[(i >>> s) & 31] = SetIn(x[(i >>> s) & 31], s - 5, i, v);
  return c;
};
// A copy of node x (null: a new node) with `leaf` at radix position i. A
// gap left of a new child is filled with null, so every node stays a
// packed array.
const PutLeaf = (x, s, i, leaf) => {
  const c = x === null ? [] : x.slice();
  const j = (i >>> s) & 31;
  while (c.length < j) c.push(null);
  c[j] = s === 5 ? leaf : PutLeaf(j < c.length ? c[j] : null, s - 5, i, leaf);
  return c;
};
// A copy of node x without the leaf at radix position i and everything
// right of it; null when nothing is left.
const PopLeaf = (x, s, i) => {
  const j = (i >>> s) & 31;
  if (s === 5) return j === 0 ? null : x.slice(0, j);
  const c = PopLeaf(x[j], s - 5, i);
  if (c === null) return j === 0 ? null : x.slice(0, j);
  const y = x.slice();
  y[j] = c;
  return y;
};
// Plain array b from index o as a trie: E1t's layout — an empty head, the
// tree at offset 0, the last 1 to 32 elements the tail. Every array is a
// copy, so no claim can ever write into a plain list (invariant 2). The
// slice-based build is the fast one (research/40 §8 rule 11).
const From = (b, o) => {
  const n = b.length - o;
  const e = n === 0 ? 0 : ((n - 1) >>> 5) << 5;
  if (e === 0) return Mk(n, [], 0, NoTree, b.slice(o));
  let x = [];
  let s = 5;
  for (let i = 0; i < e; i += 32) x.push(b.slice(o + i, o + i + 32));
  while (x.length > 32) {
    const up = [];
    for (let i = 0; i < x.length; i += 32) up.push(x.slice(i, i + 32));
    x = up;
    s += 5;
  }
  return Mk(n, [], 0, Tree(x, s, 0, e), b.slice(o + e));
};
// Trie a with element i replaced: a copy of the head, the tail or the path
// the index falls in; a itself when the element is already v.
const TSet = (a, i, v) => {
  if (Get(a, i) === v) return a;
  const hc = a.hc;
  const T = a.T;
  const tc = T.tc;
  if (i < hc) {
    const h = a.h.slice(0, hc);
    h[hc - 1 - i] = v;
    return Mk(a.length, h, hc, T, a.t);
  }
  i -= hc;
  if (i >= tc) {
    const t = a.t.slice(0, a.length - hc - tc);
    t[i - tc] = v;
    return Mk(a.length, a.h, hc, T, t);
  }
  return Mk(a.length, a.h, hc, Tree(SetIn(T.r, T.s, T.off + i, v), T.s, T.off, tc), a.t);
};
// Trie a with v at the end. THE TAIL CLAIM: when this version owns the end
// of its tail array (t.length === its count < 32), v is appended to that
// array in place; any other version copies the at most 31 elements its tail
// owns. A full tail moves into the tree as the leaf at radix off + tc, the
// root growing right.
const TPush = (a, v) => {
  const n = a.length;
  const hc = a.hc;
  const T = a.T;
  const tc = T.tc;
  const c = n - hc - tc;
  const t = a.t;
  if (c < 32) {
    if (t.length === c) {
      t.push(v);
      return Mk(n + 1, a.h, hc, T, t);
    }
    const u = t.slice(0, c);
    u.push(v);
    return Mk(n + 1, a.h, hc, T, u);
  }
  let r = T.r;
  let s = T.s;
  let off = T.off;
  if (tc === 0) {
    r = [];
    s = 5;
    off = 0;
  }
  while (off + tc >= Span(s)) {
    r = [r];
    s += 5;
  }
  return Mk(n + 1, a.h, hc, Tree(PutLeaf(r, s, off + tc, t), s, off, tc + 32), [v]);
};
// Trie a with v at the front. THE HEAD CLAIM, the tail claim mirrored: when
// this version owns the end of its head array, v is appended to it in
// place; when the slot past this version's head already holds v — the
// version is the tail of one that began with v — nothing is written; any
// other version copies its at most 31 head elements. A full head becomes a
// fresh leaf, reversed, at radix off - 32, and the offset moves left; below
// 32 the root first grows LEFT, the old root becoming child 16 of a new one.
// An empty tree starts mid-root, at 512, with room on both sides.
const Prepend = (a, v) => {
  const n = a.length;
  const hc = a.hc;
  const h = a.h;
  if (hc < 32) {
    if (h.length === hc) {
      h.push(v);
      return Mk(n + 1, h, hc + 1, a.T, a.t);
    }
    if (h[hc] === v) return Mk(n + 1, h, hc + 1, a.T, a.t);
    const c = h.slice(0, hc);
    c.push(v);
    return Mk(n + 1, c, hc + 1, a.T, a.t);
  }
  const T = a.T;
  let r = T.r;
  let s = T.s;
  let off = T.off;
  if (T.tc === 0) {
    r = [];
    s = 5;
    off = 512;
  }
  while (off < 32) {
    r = NullRow.concat([r]);
    off += 16 * Span(s);
    s += 5;
  }
  return Mk(n + 1, [v], 1, Tree(PutLeaf(r, s, off - 32, h.slice(0, 32).reverse()), s, off - 32, T.tc + 32), a.t);
};
// Trie a without its last element: a header sharing the tail, or the
// tree's last leaf made the tail (a root left with one live child
// collapses), or, with no tree left, the head reversed as a fresh plain
// array.
const TPop = (a) => {
  const n = a.length;
  if (n <= 1) return [];
  const hc = a.hc;
  const T = a.T;
  const tc = T.tc;
  if (n - hc - tc > 1) return Mk(n - 1, a.h, hc, T, a.t);
  if (tc === 0) return a.h.slice(0, hc).reverse();
  const last = T.off + tc - 32;
  const leaf = Leaf(T.r, T.s, last);
  if (last === T.off) return Mk(n - 1, a.h, hc, NoTree, leaf);
  let r = PopLeaf(T.r, T.s, last) || [];
  let s = T.s;
  let off = T.off;
  const end = last - 1;
  while (s > 5 && off >>> s === end >>> s) {
    const j = off >>> s;
    r = r[j];
    off -= j * 2 ** s;
    s -= 5;
  }
  return Mk(n - 1, a.h, hc, Tree(r, s, off, tc - 32), leaf);
};
// A fresh plain array: v, then b[o …]. Below Wide elements only.
const Onto = (v, b, o) => {
  const c = [v];
  for (let j = o; j < b.length; j++) c.push(b[j]);
  return c;
};

// ---- The surface ---------------------------------------------------------

export const length = (xs) => xs.length;

// Element i, 0 <= i < length, which the caller guarantees.
export const unsafeGet = (xs, i) => (IsA(xs) ? xs[i] : xs.o !== undefined ? xs.b[xs.o + i] : Get(xs, i));

// The list without its first k elements, 0 <= k <= length: xs itself at 0,
// `[]` at the end, a view of a plain list or a view, a trie of a trie.
export const view = (xs, k) => {
  if (k === 0) return xs;
  if (k >= xs.length) return [];
  if (IsA(xs)) return View(xs, k);
  if (xs.o !== undefined) return View(xs.b, xs.o + k);
  return Drop(xs, k);
};

export const base = (xs) => Base(xs);
export const offset = (xs) => Offset(xs);

// `[ h, ...t ]` (§4, *The claimable head*): a fresh plain array onto fewer
// than Wide elements; onto a view whose backing array holds h just before
// it, the wider view or the array itself (the runtime re-cons, tested
// first); onto Wide or more, the list made a trie once and prepended onto;
// onto a trie, the head claim.
export const cons = (h, t) => {
  if (IsA(t)) return t.length < Wide ? Onto(h, t, 0) : Prepend(From(t, 0), h);
  if (t.o !== undefined) {
    const b = t.b;
    const o = t.o;
    if (b[o - 1] === h) return o === 1 ? b : View(b, o - 1);
    return t.length < Wide ? Onto(h, b, o) : Prepend(From(b, o), h);
  }
  return Prepend(t, h);
};

// `[ ...xs, ...ys ]`: xs when ys is empty, ys when xs is; each element of ys
// pushed onto xs when xs is a trie, or is Wide long while ys is not, so that
// `[ ...xs, x ]` costs what `push` does; otherwise a fresh concatenation.
export const append = (xs, ys) => {
  const m = ys.length;
  if (m === 0) return xs;
  if (xs.length === 0) return ys;
  if (IsA(xs) || xs.o !== undefined) {
    if (xs.length < Wide || m >= Wide) return (IsA(xs) ? xs : xs.$plain()).concat(IsA(ys) ? ys : ys.$plain());
    xs = From(Base(xs), Offset(xs));
  }
  const b = Base(ys);
  const o = Offset(ys);
  for (let i = 0; i < m; i++) xs = TPush(xs, b[o + i]);
  return xs;
};

// Element i replaced; xs itself out of range or when it is already v. A
// copy up to Lim elements, a trie above.
export const set = (xs, i, v) => {
  const n = xs.length;
  if (i < 0 || i >= n) return xs;
  if (!IsA(xs) && xs.o === undefined) return TSet(xs, i, v);
  const b = Base(xs);
  const o = Offset(xs);
  if (b[o + i] === v) return xs;
  if (n > Lim) return TSet(From(b, o), i, v);
  const c = b.slice(o);
  c[i] = v;
  return c;
};

export const push = (xs, v) => {
  if (!IsA(xs) && xs.o === undefined) return TPush(xs, v);
  const b = Base(xs);
  const o = Offset(xs);
  if (xs.length >= Wide) return TPush(From(b, o), v);
  const c = b.slice(o);
  c.push(v);
  return c;
};

export const pop = (xs) => {
  const n = xs.length;
  if (n === 0) return xs;
  if (!IsA(xs) && xs.o === undefined) return TPop(xs);
  const b = Base(xs);
  const o = Offset(xs);
  return n > Lim ? TPop(From(b, o)) : b.slice(o, b.length - 1);
};

// Elm's `Array.slice`: a negative index counts from the end, both clamp;
// xs itself for all of it, `[]` when from >= to, a fresh plain array
// otherwise.
export const slice = (xs, from, to) => {
  const n = xs.length;
  from = from < 0 ? Math.max(0, n + from) : Math.min(from, n);
  to = to < 0 ? Math.max(0, n + to) : Math.min(to, n);
  if (from === 0 && to === n) return xs;
  if (from >= to) return [];
  const o = Offset(xs);
  return Base(xs).slice(o + from, o + to);
};

// Insert before i, 0 <= i <= length, and remove at i: fresh plain arrays,
// xs itself out of range. `[v]` and not `v` in the concat, which would
// spread v were it an array.
export const insertAt = (xs, i, v) => {
  const n = xs.length;
  if (i < 0 || i > n) return xs;
  const b = Base(xs);
  const o = Offset(xs);
  return b.slice(o, o + i).concat([v], b.slice(o + i, o + n));
};
export const removeAt = (xs, i) => {
  const n = xs.length;
  if (i < 0 || i >= n) return xs;
  const b = Base(xs);
  const o = Offset(xs);
  return b.slice(o, o + i).concat(b.slice(o + i + 1, o + n));
};

export const swap = (xs, i, j) => {
  const n = xs.length;
  if (i < 0 || j < 0 || i >= n || j >= n || i === j) return xs;
  const x = unsafeGet(xs, i);
  const y = unsafeGet(xs, j);
  return set(set(xs, i, y), j, x);
};

// `==` and `compare` on a list, the `where` evidence first (boundary.md §4
// check 4): element by element over the two base arrays; a shorter list is
// LT against a longer one that starts the same. `Order` is a bare tag
// string. No shortcut for a list against itself: a list holding a NaN is
// not equal to itself, as a record holding one is not, and as it was not
// before lists were arrays.
export const eq = (m0, xs, ys) => {
  const n = xs.length;
  if (n !== ys.length) return false;
  const a = Base(xs);
  const i = Offset(xs);
  const b = Base(ys);
  const j = Offset(ys);
  for (let k = 0; k < n; k++) if (!m0(a[i + k], b[j + k])) return false;
  return true;
};
export const compare = (m0, xs, ys) => {
  const n = xs.length;
  const m = ys.length;
  const a = Base(xs);
  const i = Offset(xs);
  const b = Base(ys);
  const j = Offset(ys);
  for (let k = 0; k < n && k < m; k++) {
    const o = m0(a[i + k], b[j + k]);
    if (o !== "EQ") return o;
  }
  return n === m ? "EQ" : n < m ? "LT" : "GT";
};

// The builder of invariant 5: a fresh array one loop of `List.beni` pushes
// onto and then hands over, once, as a plain list. `n` is a size hint.
export const builder = (n) => [];
export const add = (b, x) => {
  b.push(x);
  return b;
};
export const done = (b) => b;
// A building loop's exit (backend.md §8, *Tail calls modulo cons, onto an
// array*): the destination b, which its loop owns until now, with v's
// elements pushed after what the steps pushed; v itself when they pushed
// nothing. The result is plain either way, as b is.
export const close = (b, v) => {
  if (b.length === 0) return v;
  const a = Base(v);
  const o = Offset(v);
  for (let i = 0; i < v.length; i++) b.push(a[o + i]);
  return b;
};

// Whether two values are the same reference: what `map` asks to keep its
// input's identity (§4, *Identity*), which beni's `==` cannot say.
export const identical = (x, y) => x === y;
// `map`'s answer: its input when every result was the element itself.
export const kept = (same, xs, ys) => (same ? xs : ys);
// ⌊n / 2⌋ for a non-negative n: the merge sort's midpoint, which `//`
// would bring `Basics`' sibling into every program that sorts.
export const half = (n) => n >>> 1;
