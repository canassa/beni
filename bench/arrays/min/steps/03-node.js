// Stage 0 of report 40: the adaptive sibling as `_core/Array.foreign.mjs` would be written by hand
// today — `ports/adaptive.js` with the parts of `ports/cow.js` and `ports/trie.js` it reaches, and
// `scenarios.mjs`'s `common()` surface (the ten foreign exports, `fromJs`, `toJs` and the leaf walk
// `chunks`), merged into one file. The code is the ports' code, statement for statement; only the
// names the merge would clash on are prefixed (`cow…`, `trie…`), and the two exports the ports wrote as
// a bare name are written with their parameter list, which boundary.md §4 check 4 requires. T is
// 1 024, as adaptive1024.
//
// Adaptive: every array starts, and stays, a plain JS array — whatever its size — until the first
// single-element write (`set`, `push`, `pop`) lands on a plain array longer than T. That write
// converts it to the trie once (O(n)) and applies itself there; later writes to the result stay in
// the trie. Everything that builds a fresh array anyway returns a plain array, so a value that is
// only ever read never leaves the plain representation. The old version stays valid (neither
// representation is mutated), and the no-ops of report 38 §7 return their input.

// ---------------------------------------------------------------------------------------------
// Copy-on-write: the value IS a plain JS array, never mutated after construction.

// copy with room for `extra` more: a loop below 64 elements (V8's slice/concat have a high fixed
// cost), concat above (one exact-size memcpy)
function copy(a, extra) {
  const n = a.length;
  if (n >= 64) return a.concat();
  const c = new Array(n + extra);
  for (let j = 0; j < n; j++) c[j] = a[j];
  return c;
}
function cowSlice(a, s, e) {
  const r = a.slice(s, e);
  return r.length === a.length ? a : r;
}
const cowConcat = (a, b) => (b.length === 0 ? a : a.length === 0 ? b : a.concat(b));
function cowFromCons(l) { const c = []; for (; l.$ === 1; l = l.b) c.push(l.a); return c; }

// ---------------------------------------------------------------------------------------------
// A 32-way persistent vector with a tail (Clojure/Elm shape), uncurried, variable-length nodes,
// leaves are plain JS arrays.
// Representation: {n, s, r, t}: length, shift of root (>=5), root node, tail (plain array).
// Invariant: tail holds elements [n - t.length, n); t.length is 1..32 unless n===0.
const E = { n: 0, s: 5, r: [], t: [] };
// every trie is made here: one allocation site, one shape
const node = (n, s, r, t) => ({ n, s, r, t });
const tailOff = (n) => (n === 0 ? 0 : ((n - 1) >>> 5) << 5);

function trieGet(a, i) {
  if (i < 0 || i >= a.n) return undefined;
  const o = a.n - a.t.length;
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

const path = (s, leaf) => (s === 0 ? leaf : [path(s - 5, leaf)]);
function pushLeaf(x, s, i, leaf) {
  const c = x.slice(), j = (i >>> s) & 31;
  c[j] = s === 5 ? leaf : j < x.length ? pushLeaf(x[j], s - 5, i, leaf) : path(s - 5, leaf);
  return c;
}
// push a full leaf whose first index is i (= current tail offset) into the tree
function addLeaf(r, s, i, leaf) {
  if ((i >>> 5) >= 1 << s) return [[r, path(s, leaf)], s + 5];
  return [pushLeaf(r, s, i, leaf), s];
}

function popLeaf(x, s, i) {
  const j = (i >>> s) & 31;
  if (s === 5) return j === 0 ? null : x.slice(0, j);
  const c = popLeaf(x[j], s - 5, i);
  if (c === null) return j === 0 ? null : x.slice(0, j);
  const y = x.slice(); y[j] = c; return y;
}

function triePop(a) {
  if (a.n <= 1) return E;
  if (a.t.length > 1) return node(a.n - 1, a.s, a.r, a.t.slice(0, -1));
  const i = a.n - 33; // first index of the last leaf in the tree
  let x = a.r;
  for (let s = a.s; s > 0; s -= 5) x = x[(i >>> s) & 31];
  let r = popLeaf(a.r, a.s, i) || [], s = a.s;
  if (s > 5 && r.length === 1) { r = r[0]; s -= 5; }
  return node(a.n - 1, s, r, x);
}

// build from a plain array
function trieFromArray(arr) {
  const n = arr.length;
  if (n === 0) return E;
  const o = tailOff(n);
  if (o === 0) return node(n, 5, [], arr.slice());
  let xs = [];
  for (let i = 0; i < o; i += 32) xs.push(arr.slice(i, i + 32));
  let s = 5;
  while (xs.length > 32) {
    const up = [];
    for (let i = 0; i < xs.length; i += 32) up.push(xs.slice(i, i + 32));
    xs = up; s += 5;
  }
  return node(n, s, xs, arr.slice(o));
}

function leaves(x, s, out) {
  if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); }
  else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out);
  return out;
}
// the leaf walk: the plain array itself, or the trie's leaves in order and then its tail
function chunksOf(a) {
  if (Array.isArray(a)) return [a];
  const out = leaves(a.r, a.s, []);
  out.push(a.t);
  return out;
}
function trieToArray(a) {
  const ls = chunksOf(a);
  let out = [];
  for (let i = 0; i < ls.length; i += 8192) out = out.concat.apply(out, ls.slice(i, i + 8192));
  return out;
}

// append the elements of a plain array, sharing a's tree
function appendArray(a, arr) {
  if (arr.length === 0) return a;
  let { n, s, r } = a, t = a.t.slice(), k = 0;
  while (k < arr.length) {
    if (t.length === 32) { [r, s] = addLeaf(r, s, n - 32, t); t = []; }
    const m = Math.min(32 - t.length, arr.length - k);
    for (let j = 0; j < m; j++) t.push(arr[k + j]);
    k += m; n += m;
  }
  return node(n, s, r, t);
}
function trieConcat(a, b) {
  if (b.n === 0) return a;
  if (a.n === 0) return b;
  return appendArray(a, trieToArray(b));
}

// ---------------------------------------------------------------------------------------------
// The adaptive dispatch: one `Array.isArray` per export.

const LIM = 1024;
const isA = Array.isArray;
const plain = (a) => (isA(a) ? a : trieToArray(a));
export const length = (a) => (isA(a) ? a.length : a.n);
export const unsafeGet = (a, i) => (isA(a) ? a[i] : trieGet(a, i));
// A plain array longer than LIM becomes a trie at its first write; a trie stays one.
const trie = (a) => (isA(a) ? trieFromArray(a) : a);
// A write that changes nothing returns its input and never converts (report 38 §7): one check,
// before the dispatch, for both representations.
export function set(a, i, v) {
  if (i < 0 || i >= length(a) || unsafeGet(a, i) === v) return a;
  if (isA(a) && a.length <= LIM) { const c = copy(a, 0); c[i] = v; return c; }
  a = trie(a);
  const o = a.n - a.t.length;
  if (i >= o) { const t = a.t.slice(); t[i - o] = v; return node(a.n, a.s, a.r, t); }
  return node(a.n, a.s, setIn(a.r, a.s, i, v), a.t);
}
export function push(a, v) {
  if (isA(a) && a.length < LIM) { const n = a.length; if (n >= 64) return a.concat([v]); /* never a.concat(v): v may be an array */ const c = copy(a, 1); c[n] = v; return c; }
  a = trie(a);
  if (a.t.length < 32) { const t = a.t.slice(); t.push(v); return node(a.n + 1, a.s, a.r, t); }
  const [r, s] = addLeaf(a.r, a.s, a.n - 32, a.t);
  return node(a.n + 1, s, r, [v]);
}
export function pop(a) {
  if (isA(a) && a.length <= LIM) return a.slice(0, -1);
  return triePop(trie(a));
}
export function slice(a, s, e) {
  if (isA(a)) return cowSlice(a, s, e);
  const n = a.n;
  if (s < 0) s = Math.max(0, n + s);
  if (e < 0) e = Math.max(0, n + e);
  if (e > n) e = n;
  if (s === 0 && e === n) return a;
  return trieToArray(a).slice(s, e);
}
export function append(a, b) {
  if (isA(a)) return cowConcat(a, plain(b));
  // a trie keeps its tree and takes b onto its tail
  return length(b) === 0 ? a : trieConcat(a, isA(b) ? trieFromArray(b) : b);
}
export const fromList = (l) => cowFromCons(l);
const NIL = { $: 0, a: null, b: null };
// cons list interop: {$:1, a, b} / {$:0}; one loop for both representations, over the chunks
export const toList = (a) => {
  let l = NIL;
  const cs = chunksOf(a);
  for (let c = cs.length - 1; c >= 0; c--) for (let x = cs[c], i = x.length - 1; i >= 0; i--) l = { $: 1, a: x[i], b: l };
  return l;
};
export const sortWith = (a, f) => (isA(a) ? a.slice() : trieToArray(a)).sort((x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; }); // toArray already copies

// The two host-side entry points: the decoder's hand-over of a fresh JS array it owns (adopted),
// and what the DOM runtime and a JS API read.
export const fromJs = (arr) => arr;
export const toJs = (a) => plain(a);
// the runtime's way through an array without copying it: the plain array itself, or the trie's
// leaves in order and then its tail (report 38 §12.2: "walks the trie's leaves otherwise")
export const chunks = (a) => chunksOf(a);
