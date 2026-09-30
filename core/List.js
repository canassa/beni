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
// Whether a list is a trie: the one form with a tree.
const IsTrie = (xs) => xs.T !== undefined;

// ---- Views -------------------------------------------------------------

// A view's `$plain()`: its elements as a fresh plain array, made once.
const ViewPlain = function () {
  return this.p !== null ? this.p : (this.p = this.b.slice(this.o));
};
// The suffix of plain array `b` from `o`, 1 <= o < b.length.
const View = (b, o) => ({ b, o, length: b.length - o, p: null, $plain: ViewPlain });

// ---- The trie's read half ------------------------------------------------

// A trie's `$plain()`: its plain copy, made once per header (invariant 1's
// cache) — the head backwards, each leaf, then the tail, into an array made
// its final size. As fast as `concat.apply` over the leaves at 1 000 to
// 100 000 elements (Node 24), and it needs no list of them.
const Flat = function () {
  const a = this;
  if (a.p !== null) return a.p;
  const n = a.length;
  const T = a.T;
  const b = new Array(n);
  let j = 0;
  for (let i = a.hc - 1; i >= 0; i--) b[j++] = a.h[i];
  for (let i = T.off; i < T.off + T.tc; i += 32) {
    const leaf = Leaf(T.r, T.s, i);
    for (let k = 0; k < 32; k++) b[j++] = leaf[k];
  }
  for (let i = 0; j < n; i++) b[j++] = a.t[i];
  return (a.p = b);
};
const Mk = (n, h, hc, T, t) => ({ length: n, h, hc, T, t, p: null, $plain: Flat });
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
// Trie a without its first k elements, 0 < k < a.length: a trie sharing the
// tree, never a flatten (§4, *Removing a prefix*). Inside the head it is a
// header with a smaller head count; past it, whole leaves go by moving the
// offset and the rest of the new first leaf, all 32 when k falls on a leaf's
// start, becomes the head; with only tail elements left, a fresh plain
// array. A tree left with no leaf keeps its root, which no read reaches.
const Drop = (a, k) => {
  const n = a.length - k;
  const hc = a.hc;
  if (k <= hc) return Mk(n, a.h, hc - k, a.T, a.t);
  const T = a.T;
  k -= hc;
  if (k >= T.tc) return a.t.slice(k - T.tc, a.length - hc - T.tc);
  const i = T.off + (k & -32);
  return Mk(n, Leaf(T.r, T.s, i).slice(k & 31).reverse(), 32 - (k & 31), Tree(T.r, T.s, i + 32, T.tc - (k & -32) - 32), a.t);
};

// ---- The trie's write half ---------------------------------------------

// The radix positions a root at shift s covers.
const Span = (s) => 2 ** (s + 5);

// A path copy: node x (null: a new node) with `leaf` at radix position i,
// the one write into the tree. A gap left of a new child is filled with
// null, so every node stays a packed array.
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
// Tree T with `leaf` added at its right end, radix off + tc: a full tail.
// An empty tree starts at 0; a root with no room right grows, the old one
// becoming child 0 of a new one.
const Right = (T, leaf) => {
  let r = T.r;
  let s = T.s;
  let off = T.off;
  if (T.tc === 0) {
    r = [];
    s = 5;
    off = 0;
  }
  while (off + T.tc >= Span(s)) {
    r = [r];
    s += 5;
  }
  return Tree(PutLeaf(r, s, off + T.tc, leaf), s, off, T.tc + 32);
};
// Tree T with `leaf` added at its left end, radix off - 32: a full head,
// the mirror of `Right`. An empty tree starts mid-root, at 512; a root
// with no room left grows, the old one becoming child 16 of a new one, so
// that there is room on both sides.
const Left = (T, leaf) => {
  let r = T.r;
  let s = T.s;
  let off = T.off;
  if (T.tc === 0) {
    r = [];
    s = 5;
    off = 512;
  }
  while (off < 32) {
    r = [...Array(16).fill(null), r];
    off += 16 * Span(s);
    s += 5;
  }
  return Tree(PutLeaf(r, s, off - 32, leaf), s, off - 32, T.tc + 32);
};
// Buffer b of a version that reads its first c elements, with v at index
// c. THE CLAIM: when this version owns b's end (b.length === c), v is
// appended to b in place; when b already holds v there — this version is
// the tail of one that went on with v — b is shared as it is; any other
// version copies its at most 31.
const Claim = (b, c, v) => {
  if (b.length === c) b.push(v);
  else if (b[c] !== v) (b = b.slice(0, c)).push(v);
  return b;
};
// Buffer b's first c elements with index k set to v: a copy.
const Changed = (b, c, k, v) => {
  b = b.slice(0, c);
  b[k] = v;
  return b;
};
// Plain array b from index o, at least Wide elements, as a trie: E1t's
// layout — an empty head, the tree at offset 0, the last 1 to 32 elements
// the tail. Every array is a copy, so no claim can ever write into a plain
// list (invariant 2). Built level by level from slices: placing it a leaf
// at a time is 3–4.5× slower (Node 24, 1 000 to 100 000 elements).
const From = (b, o) => {
  const n = b.length - o;
  const e = ((n - 1) >>> 5) << 5;
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
// Trie a with element i replaced: a copy of the head, the tail or the leaf
// the index falls in, and of the path to that leaf; a itself when the
// element is already v.
const TSet = (a, i, v) => {
  if (Get(a, i) === v) return a;
  const n = a.length;
  const hc = a.hc;
  const T = a.T;
  if (i < hc) return Mk(n, Changed(a.h, hc, hc - 1 - i, v), hc, T, a.t);
  i -= hc;
  if (i >= T.tc) return Mk(n, a.h, hc, T, Changed(a.t, n - hc - T.tc, i - T.tc, v));
  i += T.off;
  return Mk(n, a.h, hc, Tree(PutLeaf(T.r, T.s, i, Changed(Leaf(T.r, T.s, i), 32, i & 31, v)), T.s, T.off, T.tc), a.t);
};
// Trie a with v at the end: the tail claimed; a full tail moves into the
// tree as a leaf and v starts a new one.
const TPush = (a, v) => {
  const c = a.length - a.hc - a.T.tc;
  if (c < 32) return Mk(a.length + 1, a.h, a.hc, a.T, Claim(a.t, c, v));
  return Mk(a.length + 1, a.h, a.hc, Right(a.T, a.t), [v]);
};
// Trie a with the m elements b[o] … b[o + m - 1] at the end, m > 0: what m
// pushes make, with one header and not m. The tail is claimed as `Claim`
// claims it — written in place only by the version that owns its end,
// copied otherwise — and filled; each full tail moves into the tree as a
// leaf, and the next one is a slice of b.
const Pushed = (a, b, o, m) => {
  const c = a.length - a.hc - a.T.tc;
  const end = o + m;
  let T = a.T;
  let t = a.t;
  let i = o;
  if (c < 32) {
    if (t.length !== c) t = t.slice(0, c);
    while (t.length < 32 && i < end) t.push(b[i++]);
  }
  for (; i < end; i += 32) {
    T = Right(T, t);
    t = b.slice(i, i + 32 < end ? i + 32 : end);
  }
  return Mk(a.length + m, a.h, a.hc, T, t);
};
// Trie a with v at the front: the head claimed, the tail claim mirrored; a
// full head moves into the tree as a leaf, reversed back into order, and v
// starts a new one.
const Prepend = (a, v) => {
  const hc = a.hc;
  if (hc < 32) return Mk(a.length + 1, Claim(a.h, hc, v), hc + 1, a.T, a.t);
  return Mk(a.length + 1, [v], 1, Left(a.T, a.h.slice(0, 32).reverse()), a.t);
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

// ---- The surface ---------------------------------------------------------

export const length = (xs) => xs.length;

// Element i, 0 <= i < length, which the caller guarantees.
export const unsafeGet = (xs, i) => (IsA(xs) ? xs[i] : xs.o !== undefined ? xs.b[xs.o + i] : Get(xs, i));

// The plain array a list is a suffix of, and where in it the list starts:
// (xs, 0) plain, (b, o) a view, (its cached copy, 0) a trie.
export const base = (xs) => (IsA(xs) ? xs : xs.o !== undefined ? xs.b : xs.$plain());
export const offset = (xs) => (IsA(xs) || xs.o === undefined ? 0 : xs.o);

// The list without its first k elements, 0 <= k <= length: xs itself at 0,
// `[]` at the end, a view of a plain list or a view, a trie of a trie.
export const view = (xs, k) => {
  if (k === 0) return xs;
  if (k >= xs.length) return [];
  if (IsTrie(xs)) return Drop(xs, k);
  return View(base(xs), offset(xs) + k);
};

// `[ h, ...t ]` (§4, *The claimable head*): onto a trie, the head claim;
// onto a view whose backing array holds h just before it, the wider view or
// the array itself (the runtime re-cons); onto Wide elements or more, the
// list made a trie once and prepended onto; onto fewer, a fresh plain
// array, copied by a loop: below 32 elements it is 1.7× faster than
// `[h].concat(t)` (Node 24).
export const cons = (h, t) => {
  if (IsTrie(t)) return Prepend(t, h);
  const b = base(t);
  const o = offset(t);
  if (o > 0 && b[o - 1] === h) return o === 1 ? b : View(b, o - 1);
  if (t.length >= Wide) return Prepend(From(b, o), h);
  const c = [h];
  for (let i = o; i < b.length; i++) c.push(b[i]);
  return c;
};

// `[ ...xs, ...ys ]`: xs when ys is empty, ys when xs is. A fresh
// concatenation, by the engine's own `concat` (1.2–3× faster than a loop),
// when ys is at least as long as a trie xs — the copy is then within twice
// what any append writes, and the result is plain, which a `For` reads
// without a copy — or when xs is plain and short or ys is Wide long.
// Otherwise ys is pushed onto xs (made a trie first when it is not) a leaf
// at a time, so that `[ ...xs, x ]` costs what `push` does, and appending
// 1 000 costs a header, not 1 000 (the table benchmark's append, measured
// 2026-09-30: 0.32 ms of its first click).
export const append = (xs, ys) => {
  const n = xs.length;
  const m = ys.length;
  if (m === 0) return xs;
  if (n === 0) return ys;
  if (IsTrie(xs) ? m >= n : n < Wide || m >= Wide) return (IsA(xs) ? xs : xs.$plain()).concat(IsA(ys) ? ys : ys.$plain());
  return Pushed(IsTrie(xs) ? xs : From(base(xs), offset(xs)), base(ys), offset(ys), m);
};

// Element i replaced; xs itself out of range or when it is already v. A
// copy up to Lim elements, a trie above.
export const set = (xs, i, v) => {
  const n = xs.length;
  if (i < 0 || i >= n) return xs;
  if (IsTrie(xs)) return TSet(xs, i, v);
  const b = base(xs);
  const o = offset(xs);
  if (b[o + i] === v) return xs;
  if (n > Lim) return TSet(From(b, o), i, v);
  const c = b.slice(o);
  c[i] = v;
  return c;
};

export const push = (xs, v) => {
  if (IsTrie(xs)) return TPush(xs, v);
  const b = base(xs);
  const o = offset(xs);
  if (xs.length >= Wide) return TPush(From(b, o), v);
  const c = b.slice(o);
  c.push(v);
  return c;
};

export const pop = (xs) => {
  const n = xs.length;
  if (n === 0) return xs;
  if (IsTrie(xs)) return TPop(xs);
  const b = base(xs);
  const o = offset(xs);
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
  const o = offset(xs);
  return base(xs).slice(o + from, o + to);
};

// Insert before i, 0 <= i <= length, and remove at i: fresh plain arrays,
// xs itself out of range. `[v]` and not `v` in the concat, which would
// spread v were it an array.
export const insertAt = (xs, i, v) => {
  const n = xs.length;
  if (i < 0 || i > n) return xs;
  const b = base(xs);
  const o = offset(xs);
  return b.slice(o, o + i).concat([v], b.slice(o + i, o + n));
};
export const removeAt = (xs, i) => {
  const n = xs.length;
  if (i < 0 || i >= n) return xs;
  const b = base(xs);
  const o = offset(xs);
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
  const a = base(xs);
  const i = offset(xs);
  const b = base(ys);
  const j = offset(ys);
  for (let k = 0; k < n; k++) if (!m0(a[i + k], b[j + k])) return false;
  return true;
};
export const compare = (m0, xs, ys) => {
  const n = xs.length;
  const m = ys.length;
  const a = base(xs);
  const i = offset(xs);
  const b = base(ys);
  const j = offset(ys);
  for (let k = 0; k < n && k < m; k++) {
    const o = m0(a[i + k], b[j + k]);
    if (o !== "EQ") return o;
  }
  return n === m ? "EQ" : n < m ? "LT" : "GT";
};

// Array b with the elements of list xs written from index j on; the index
// past them. The one copy loop `close` and `concat` share.
const Put = (b, j, xs) => {
  const a = base(xs);
  const o = offset(xs);
  for (let i = 0; i < xs.length; i++) b[j + i] = a[o + i];
  return j + xs.length;
};
// `concat`: the lists' elements in one fresh array made its final size, or
// the one list that is not empty itself, or `[]`. A view is a suffix of its
// base, so every list's elements end at its base's end.
export const concat = (ls) => {
  const a = base(ls);
  let one = [];
  let n = 0;
  for (let i = offset(ls); i < a.length; i++) {
    if (a[i].length > 0) one = n === 0 ? a[i] : null;
    n += a[i].length;
  }
  if (one !== null) return one;
  const b = new Array(n);
  for (let i = offset(ls), j = 0; i < a.length; i++) j = Put(b, j, a[i]);
  return b;
};

// The builder of invariant 5: a fresh array one loop of `List.beni` fills
// and then hands over, once, as a plain list of its first `n` elements.
// `builder(n)` has room for n, filled by index with `put`: at 100 000
// elements an array grown by `push` is copied as it grows and builds in
// about three times the time of one made its size first (Node 24, the
// flip's measurement).
export const builder = (n) => new Array(n > 0 ? n : 0);
export const done = (b, n) => {
  if (b.length !== n) b.length = n;
  return b;
};
// A building loop's exit (backend.md §8, *Tail calls modulo cons, onto an
// array*): the destination b, which its loop owns until now, with v's
// elements pushed after what the steps pushed; v itself when they pushed
// nothing. The result is plain either way, as b is.
export const close = (b, v) => {
  if (b.length === 0) return v;
  Put(b, b.length, v);
  return b;
};

// `at`, `put`, `identical`, `kept` and `half` are what the code generator
// writes in place of a call (backend.md §4, *`List.beni`'s loops read and
// write in place*): `a[i]` of an array `base` returned, a builder's store,
// `===` (what `map` keeps its input's identity by, which beni's `==` cannot
// ask), `map`'s answer, and ⌊n / 2⌋, the merge sort's midpoint, which `//`
// would bring `Basics`' sibling in for. These exports are what a value of
// one would be, which nothing in `List.beni` passes.
export const at = (a, i) => a[i];
export const put = (b, i, x) => {
  b[i] = x;
  return b;
};
export const identical = (x, y) => x === y;
export const kept = (same, xs, ys) => (same ? xs : ys);
export const half = (n) => n >>> 1;
