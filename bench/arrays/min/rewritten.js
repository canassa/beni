// Report 40 §5: the adaptive sibling rewritten by the writing rules of §8 (b), as core/Array.js
// would be written — readable, commented, and shaped so that beni's release compactor and brotli
// both do well with it. Same behaviour as original.js, result for result: the same values, the
// same representation (plain array, or the trie node for node) and the same identities.
//
// An `Array a` is a plain JS array, never mutated after construction, until the first
// single-element write (`set`, `push`, `pop`) lands on one longer than `Lim` elements; that write
// converts it to a 32-way trie with a tail once, and writes to the result stay in the trie.
// Everything that builds a fresh array returns a plain one. A trie is {n, s, r, t}: length, shift
// of the root (>= 5), root node, tail (a plain array of 1..32, the last elements).
//
// Two rules shape the file (§8 (b)):
//  * the readers (`length`, `unsafeGet`, `slice`, `append`, `fromList`, `toList`, `sortWith`,
//    `fromJs`, `toJs`, `chunks`) never NAME the trie's write code: a program that never writes
//    never has a trie, and the compactor drops every unit nothing live names. The one thing a
//    reader needs of the write half, appending onto a trie, it calls through `Grower`, which the
//    only place a trie is born, `Build`, fills in. Reading a trie stays the readers' own code: a
//    call through a mutable binding in `unsafeGet` cost 15-18 % on a trie fold (§6);
//  * top-level names are capitalised and locals are not, so a local never keeps a top-level unit
//    alive by sharing its name.

const Lim = 1024;
const IsA = Array.isArray;
const Nil = { $: 0, a: null, b: null };

// The trie's leaves in order, then its tail: the renderer's walk, and what toArray flattens.
const Leaves = (x, s, out) => {
  for (const y of x) s > 5 ? Leaves(y, s - 5, out) : out.push(y);
  return out;
};
const Chunks = (a) => {
  if (IsA(a)) return [a];
  const out = Leaves(a.r, a.s, []);
  out.push(a.t);
  return out;
};
// A fresh plain copy of a trie's elements; concat.apply 8192 leaves at a time keeps the
// argument count far below every engine's limit.
const ToArray = (a) => {
  const cs = Chunks(a);
  let out = [];
  for (let i = 0; i < cs.length; i += 8192) out = out.concat.apply(out, cs.slice(i, i + 8192));
  return out;
};
const Plain = (a) => (IsA(a) ? a : ToArray(a));
// the leaf holding index i
const Leaf = (a, i) => {
  let x = a.r;
  for (let s = a.s; s; s -= 5) x = x[(i >>> s) & 31];
  return x;
};
const Get = (a, i) => {
  if (i < 0 || i >= a.n) return;
  const o = a.n - a.t.length;
  return i >= o ? a.t[i - o] : Leaf(a, i)[i & 31];
};
// The write half, as a reader reaches it: appending to a trie, once one exists.
let Grower;

export const length = (a) => (IsA(a) ? a.length : a.n);
export const unsafeGet = (a, i) => (IsA(a) ? a[i] : Get(a, i));
export const slice = (a, s, e) => {
  const n = length(a);
  if (IsA(a)) {
    const r = a.slice(s, e);
    return r.length === n ? a : r;
  }
  // the whole trie is itself, without flattening it; anything less is a plain array
  return (s < 0 ? s + n : s) <= 0 && (e < 0 ? Math.max(0, e + n) : e) >= n ? a : ToArray(a).slice(s, e);
};
export const append = (a, b) => {
  if (IsA(a)) {
    b = Plain(b);
    return b.length === 0 ? a : a.length === 0 ? b : a.concat(b);
  }
  // a trie keeps its tree and takes b onto its tail
  return length(b) === 0 ? a : a.n === 0 && !IsA(b) ? b : Grower(a, Plain(b));
};
export const fromList = (l) => {
  const out = [];
  for (; l.$; l = l.b) out.push(l.a);
  return out;
};
export const toList = (a) => {
  let l = Nil;
  for (const c of Chunks(a).reverse()) for (let i = c.length; i--; ) l = { $: 1, a: c[i], b: l };
  return l;
};
export const sortWith = (a, f) => (IsA(a) ? a.slice() : ToArray(a)).sort((x, y) => {
  const o = f(x, y);
  return o === "LT" ? -1 : o === "GT" ? 1 : 0;
});
export const fromJs = (a) => a;
export const toJs = (a) => Plain(a);
export const chunks = (a) => Chunks(a);

// ---------------------------------------------------------------------------------------------
// The write half.

const Node = (n, s, r, t) => ({ n, s, r, t });
const Empty = { n: 0, s: 5, r: [], t: [] };

// a plain array cut into nodes of 32
const Group = (x, end) => {
  const out = [];
  for (let i = 0; i < end; i += 32) out.push(x.slice(i, i + 32));
  return out;
};
// a plain array of more than Lim elements as a trie: the one place a trie is born
const Build = (a) => {
  Grower = AppendTrie;
  const n = a.length, end = (n - 1) & -32;
  let r = Group(a, end), s = 5;
  while (r.length > 32) r = Group(r, r.length), s += 5;
  return Node(n, s, r, a.slice(end));
};
const Trie = (a) => (IsA(a) ? Build(a) : a);

// one path copy for every write into a node: copy each node from x down to shift d and put v at
// i's slot there; a missing child starts as an empty node, which is how a new leaf's path is made
const SetIn = (x, s, i, v, d) => {
  const c = x.slice(), j = (i >>> s) & 31;
  c[j] = s > d ? SetIn(x[j] || [], s - 5, i, v, d) : v;
  return c;
};
// a's full tail moved into the tree, and t the new tail
const Grow = (a, t) => {
  const i = a.n - 32;
  let r = a.r, s = a.s;
  if (i >>> 5 >= 1 << s) r = [r], s += 5;
  return Node(a.n + t.length, s, SetIn(r, s, i, a.t, 5), t);
};
const PopLeaf = (x, s, i) => {
  const j = (i >>> s) & 31, c = s > 5 && PopLeaf(x[j], s - 5, i);
  if (!c) return j && x.slice(0, j);
  x = x.slice();
  x[j] = c;
  return x;
};
// the elements of a non-empty plain array appended to a trie
const AppendTrie = (a, b) => {
  a = Node(a.n, a.s, a.r, a.t.slice());
  for (const x of b) {
    if (a.t.length === 32) a = Grow(a, []);
    a.t.push(x);
    a.n++;
  }
  return a;
};

// A write that changes nothing returns its input and never converts (report 38 §7).
export const set = (a, i, v) => {
  if (i < 0 || i >= length(a) || unsafeGet(a, i) === v) return a;
  if (IsA(a) && a.length <= Lim) {
    // copy: a loop below 64 elements (V8's slice/concat have a high fixed cost), concat above
    const n = a.length, c = n < 64 ? new Array(n) : a.concat();
    if (n < 64) for (let j = 0; j < n; j++) c[j] = a[j];
    c[i] = v;
    return c;
  }
  a = Trie(a);
  const o = a.n - a.t.length;
  return i < o ? Node(a.n, a.s, SetIn(a.r, a.s, i, v, 0), a.t) : Node(a.n, a.s, a.r, SetIn(a.t, 0, i - o, v, 0));
};
export const push = (a, v) => {
  const n = length(a);
  if (IsA(a) && n < Lim) {
    // never a.concat(v): v may be an array
    if (n >= 64) return a.concat([v]);
    const c = new Array(n + 1);
    for (let j = 0; j < n; j++) c[j] = a[j];
    c[n] = v;
    return c;
  }
  a = Trie(a);
  if (a.t.length < 32) {
    const t = a.t.slice();
    t.push(v);
    return Node(n + 1, a.s, a.r, t);
  }
  return Grow(a, [v]);
};
export const pop = (a) => {
  const n = length(a);
  if (IsA(a) && n <= Lim) return a.slice(0, -1);
  a = Trie(a);
  if (n <= 1) return Empty;
  if (a.t.length > 1) return Node(n - 1, a.s, a.r, a.t.slice(0, -1));
  // the tail is empty after this: the last leaf of the tree becomes it
  let r = PopLeaf(a.r, a.s, n - 33) || [], s = a.s;
  if (s > 5 && r.length === 1) r = r[0], s -= 5;
  return Node(n - 1, s, r, Leaf(a, n - 33));
};
