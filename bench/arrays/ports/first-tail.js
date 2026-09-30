// Candidate E1t of research/38 §17: E1 (ports/first.js) with a representation built for `push`.
// It is the same three forms, with two changes to the trie and one to the adaptive threshold:
//
//   plain  a JS array, never mutated after construction
//   view   V {b, o, length}: elements o… of a plain backing array b, to its end (`x :: rest`)
//   trie   {n, s, r, t, p}: the §1 32-way trie, whose TAIL t may be longer than its own count
//
// 1. A CLAIMABLE TAIL. A trie reads only its own n elements, so the tail array may hold elements
//    past this version's end that belong to a newer version. `push` onto a version whose tail array
//    ends exactly at its own end writes the element IN PLACE and returns a new header sharing the
//    array (the element it writes is past every older version's end, so none of them can see it);
//    `push` onto any other version copies at most the 31 tail elements it owns first. `pop` shares
//    the tail too. So building by `push` costs one header per element, like a cons cell, and a
//    version that is pushed onto twice (a stack after an undo, a path with two children) pays at
//    most a 32-element copy, never O(n). A full tail moves into the tree unchanged: a tree leaf has
//    exactly 32 elements and no version's count is below 32 while its tail is a leaf of 32, so no
//    in-place push ever writes into a leaf.
// 2. `push` converts a plain array longer than PT = 32 (not T = 256) to the trie. Below 256 a copy
//    per push is what made E1's builds 4–9× A: 256 pushes onto plain arrays copy 32 896 elements.
//    `set`, `pop` of a plain array keep T = 256 (§15.11), so a read-mostly UI list stays plain.
// 3. A trie caches its plain copy (p) the first time a walk (`x :: rest`), `toJs` or a bulk
//    operation needs one: derived data, invisible, and it makes a repeated `$tl` O(1).
//
// Every operation that builds a fresh sequence (core's builder, `slice`, `append` onto a plain
// array, `$cons`) returns a plain array, as §15's adaptive does. The sibling surface is the same as
// ports/first.js, so the same compiled beni runs over it.
const LIM = typeof ADA_T === 'number' ? ADA_T : 256;
const PT = typeof PUSH_T === 'number' ? PUSH_T : 32;
const isA = Array.isArray;
export class V {
  constructor(b, o, length) { this.b = b; this.o = o; this.length = length; }
}
const isV = (x) => x instanceof V;
export const $nil = [];

// ---- the trie with a claimable tail ------------------------------------------------------------
const tailOff = (n) => (n === 0 ? 0 : ((n - 1) >>> 5) << 5);
const mk = (n, s, r, t) => ({ n, s, r, t, p: null });
function tget(a, i) {
  const o = tailOff(a.n);
  if (i >= o) return a.t[i - o];
  let x = a.r;
  for (let s = a.s; s > 0; s -= 5) x = x[(i >>> s) & 31];
  return x[i & 31];
}
function setIn(x, s, i, v) {
  const c = x.slice();
  if (s === 0) c[i & 31] = v;
  else { const j = (i >>> s) & 31; c[j] = setIn(x[j], s - 5, i, v); }
  return c;
}
function tset(a, i, v) {
  if (i < 0 || i >= a.n || tget(a, i) === v) return a;
  const o = tailOff(a.n);
  if (i >= o) { const t = a.t.slice(0, a.n - o); t[i - o] = v; return mk(a.n, a.s, a.r, t); }
  return mk(a.n, a.s, setIn(a.r, a.s, i, v), a.t);
}
const path = (s, leaf) => (s === 0 ? leaf : [path(s - 5, leaf)]);
function pushLeaf(x, s, i, leaf) {
  const c = x.slice(), j = (i >>> s) & 31;
  c[j] = s === 5 ? leaf : j < x.length ? pushLeaf(x[j], s - 5, i, leaf) : path(s - 5, leaf);
  return c;
}
function addLeaf(r, s, i, leaf) {
  if ((i >>> 5) >= 1 << s) return [[r, path(s, leaf)], s + 5];
  return [pushLeaf(r, s, i, leaf), s];
}
function tpush(a, v) {
  const n = a.n, cnt = n - tailOff(n);
  if (cnt < 32) {
    if (a.t.length === cnt) { a.t.push(v); return mk(n + 1, a.s, a.r, a.t); } // claim the end
    const t = a.t.slice(0, cnt); t.push(v);
    return mk(n + 1, a.s, a.r, t);
  }
  const [r, s] = addLeaf(a.r, a.s, n - 32, a.t); // a.t is exactly 32 long here
  return mk(n + 1, s, r, [v]);
}
function popLeaf(x, s, i) {
  const j = (i >>> s) & 31;
  if (s === 5) return j === 0 ? null : x.slice(0, j);
  const c = popLeaf(x[j], s - 5, i);
  if (c === null) return j === 0 ? null : x.slice(0, j);
  const y = x.slice(); y[j] = c; return y;
}
function tpop(a) {
  const n = a.n;
  if (n <= 1) return $nil;
  if (n - tailOff(n) > 1) return mk(n - 1, a.s, a.r, a.t); // share the tail
  const i = n - 33;
  let x = a.r;
  for (let s = a.s; s > 0; s -= 5) x = x[(i >>> s) & 31];
  let r = popLeaf(a.r, a.s, i) || [], s = a.s;
  if (s > 5 && r.length === 1) { r = r[0]; s -= 5; }
  return mk(n - 1, s, r, x);
}
function tfrom(arr) {
  const n = arr.length, o = tailOff(n);
  if (o === 0) return mk(n, 5, [], arr.slice());
  let xs = [];
  for (let i = 0; i < o; i += 32) xs.push(arr.slice(i, i + 32));
  let s = 5;
  while (xs.length > 32) {
    const up = [];
    for (let i = 0; i < xs.length; i += 32) up.push(xs.slice(i, i + 32));
    xs = up; s += 5;
  }
  return mk(n, s, xs, arr.slice(o));
}
function leaves(x, s, out) {
  if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); }
  else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out);
  return out;
}
// the leaves in order, then the tail cut to this version's count: the runtime's walk, no copy of
// the elements
export function chunksOf(a) {
  const ls = leaves(a.r, a.s, []), cnt = a.n - tailOff(a.n);
  ls.push(a.t.length === cnt ? a.t : a.t.slice(0, cnt));
  return ls;
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
function eachNode(x, s, f) {
  if (s === 0) { for (let i = 0; i < x.length; i++) f(x[i]); }
  else for (let i = 0; i < x.length; i++) eachNode(x[i], s - 5, f);
}
function teach(a, f) {
  eachNode(a.r, a.s, f);
  const t = a.t, cnt = a.n - tailOff(a.n);
  for (let i = 0; i < cnt; i++) f(t[i]);
}

// ---- the list syntax ------------------------------------------------------------------------
export const $isNil = (x) => x.length === 0; // a trie has no `length` and is never empty
export const $isCons = (x) => x.length !== 0;
export const $hd = (x) => (isV(x) ? x.b[x.o] : isA(x) ? x[0] : tget(x, 0));
export function $tl(x) {
  if (isV(x)) return x.length > 1 ? new V(x.b, x.o + 1, x.length - 1) : $nil;
  if (isA(x)) return x.length > 1 ? new V(x, 1, x.length - 1) : $nil;
  return x.n > 1 ? new V(tflat(x), 1, x.n - 1) : $nil;
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
  return [h].concat(tflat(t));
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
export const length = (xs) => (isA(xs) || isV(xs) ? xs.length : xs.n);
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
  let k = 0; teach(xs, (x) => visit(x, k++)); // the runtime walks a trie's leaves, no copy
}
export const stackTopLast = true;
export const kind = (xs) => (isA(xs) ? 'plain' : isV(xs) ? 'view' : 'trie');
