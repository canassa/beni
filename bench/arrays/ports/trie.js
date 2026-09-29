// A minimal beni-specific 32-way persistent vector with a tail (Clojure/Elm shape),
// uncurried, variable-length nodes, leaves are plain JS arrays.
// Representation: {n, s, r, t}: length, shift of root (>=5), root node, tail (plain array).
// Invariant: tail holds elements [n - t.length, n); t.length is 1..32 unless n===0.
const E = { n: 0, s: 5, r: [], t: [] };
const tailOff = (n) => (n === 0 ? 0 : ((n - 1) >>> 5) << 5);

export const empty = E;
export const length = (a) => a.n;

export function get(a, i) {
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

export function set(a, i, v) {
  if (i < 0 || i >= a.n) return a;
  const o = a.n - a.t.length;
  if (i >= o) {
    if (a.t[i - o] === v) return a;
    const t = a.t.slice(); t[i - o] = v;
    return { n: a.n, s: a.s, r: a.r, t };
  }
  if (get(a, i) === v) return a;
  return { n: a.n, s: a.s, r: setIn(a.r, a.s, i, v), t: a.t };
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

export function push(a, v) {
  if (a.t.length < 32) { const t = a.t.slice(); t.push(v); return { n: a.n + 1, s: a.s, r: a.r, t }; }
  const [r, s] = addLeaf(a.r, a.s, a.n - 32, a.t);
  return { n: a.n + 1, s, r, t: [v] };
}

function popLeaf(x, s, i) {
  const j = (i >>> s) & 31;
  if (s === 5) return j === 0 ? null : x.slice(0, j);
  const c = popLeaf(x[j], s - 5, i);
  if (c === null) return j === 0 ? null : x.slice(0, j);
  const y = x.slice(); y[j] = c; return y;
}

export function pop(a) {
  if (a.n <= 1) return E;
  if (a.t.length > 1) return { n: a.n - 1, s: a.s, r: a.r, t: a.t.slice(0, -1) };
  const i = a.n - 33; // first index of the last leaf in the tree
  let x = a.r;
  for (let s = a.s; s > 0; s -= 5) x = x[(i >>> s) & 31];
  let r = popLeaf(a.r, a.s, i) || [], s = a.s;
  if (s > 5 && r.length === 1) { r = r[0]; s -= 5; }
  return { n: a.n - 1, s, r, t: x };
}

// build from a plain array; `own` = arr may be adopted
export function fromArray(arr) {
  const n = arr.length;
  if (n === 0) return E;
  const o = tailOff(n);
  if (o === 0) return { n, s: 5, r: [], t: arr.slice() };
  let xs = [];
  for (let i = 0; i < o; i += 32) xs.push(arr.slice(i, i + 32));
  let s = 5;
  while (xs.length > 32) {
    const up = [];
    for (let i = 0; i < xs.length; i += 32) up.push(xs.slice(i, i + 32));
    xs = up; s += 5;
  }
  return { n, s, r: xs, t: arr.slice(o) };
}

function eachNode(x, s, f) {
  if (s === 0) { for (let i = 0; i < x.length; i++) f(x[i]); }
  else for (let i = 0; i < x.length; i++) eachNode(x[i], s - 5, f);
}
export function forEach(a, f) {
  eachNode(a.r, a.s, f);
  const t = a.t;
  for (let i = 0; i < t.length; i++) f(t[i]);
}

function leaves(x, s, out) {
  if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); }
  else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out);
  return out;
}
export function toArray(a) {
  const ls = leaves(a.r, a.s, []);
  ls.push(a.t);
  let out = [];
  for (let i = 0; i < ls.length; i += 8192) out = out.concat.apply(out, ls.slice(i, i + 8192));
  return out;
}

function foldNode(x, s, f, z) {
  if (s === 0) { for (let i = 0; i < x.length; i++) z = f(x[i], z); }
  else for (let i = 0; i < x.length; i++) z = foldNode(x[i], s - 5, f, z);
  return z;
}
export function foldl(a, f, z) {
  z = foldNode(a.r, a.s, f, z);
  const t = a.t;
  for (let i = 0; i < t.length; i++) z = f(t[i], z);
  return z;
}
function foldrNode(x, s, f, z) {
  if (s === 0) { for (let i = x.length - 1; i >= 0; i--) z = f(x[i], z); }
  else for (let i = x.length - 1; i >= 0; i--) z = foldrNode(x[i], s - 5, f, z);
  return z;
}
export function foldr(a, f, z) {
  const t = a.t;
  for (let i = t.length - 1; i >= 0; i--) z = f(t[i], z);
  return foldrNode(a.r, a.s, f, z);
}

function mapLeaf(x, f) { const c = []; for (let i = 0; i < x.length; i++) c.push(f(x[i])); return c; }
function mapNode(x, s, f) {
  if (s === 0) return mapLeaf(x, f);
  const c = []; for (let i = 0; i < x.length; i++) c.push(mapNode(x[i], s - 5, f)); return c;
}
export function map(a, f) {
  return { n: a.n, s: a.s, r: mapNode(a.r, a.s, f), t: mapLeaf(a.t, f) };
}

export function filter(a, f) {
  const out = [];
  forEach(a, (x) => { if (f(x)) out.push(x); });
  return out.length === a.n ? a : fromArray(out);
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
  return { n, s, r, t };
}
export function concat(a, b) {
  if (b.n === 0) return a;
  if (a.n === 0) return b;
  return appendArray(a, toArray(b));
}

export function slice(a, s, e) {
  const n = a.n;
  if (s < 0) s = Math.max(0, n + s);
  if (e < 0) e = Math.max(0, n + e);
  if (e > n) e = n;
  if (s === 0 && e === n) return a;
  if (s >= e) return E;
  return fromArray(toArray(a).slice(s, e));
}

export function insert(a, i, v) { const c = toArray(a); c.splice(i, 0, v); return fromArray(c); }
export function remove(a, i) { const c = toArray(a); c.splice(i, 1); return fromArray(c); }

function eqNode(x, y, s, f) {
  if (x === y) return true;
  if (x.length !== y.length) return false;
  if (s === 0) { for (let i = 0; i < x.length; i++) if (!f(x[i], y[i])) return false; return true; }
  for (let i = 0; i < x.length; i++) if (!eqNode(x[i], y[i], s - 5, f)) return false;
  return true;
}
export function eq(a, b, f) {
  if (a === b) return true;
  if (a.n !== b.n) return false;
  return eqNode(a.r, b.r, a.s, f) && eqNode(a.t, b.t, 0, f);
}

// cons list interop: {$:1, a, b} / {$:0}
export function fromCons(l) { const out = []; for (; l.$ === 1; l = l.b) out.push(l.a); return fromArray(out); }
export function toCons(a, nil) { return foldr(a, (x, z) => ({ $: 1, a: x, b: z }), nil); }
export const sort = (a, cmp) => fromArray(toArray(a).sort(cmp)); // toArray already copies
