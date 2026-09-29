// Adaptive: every array starts, and stays, a plain JS array — whatever its size — until the first
// single-element write (`set`, `push`, `pop`, `swap`) lands on a plain array longer than T. That write
// converts it to the trie once (O(n)) and applies itself there; later writes to the result stay in
// the trie. Everything that builds a fresh array anyway — `fromArray`, `fromCons`, `map`, `filter`,
// `slice`, `insert`, `remove`, `sort`, and `concat` onto a plain array — returns a plain array, so
// a value that is only ever read never leaves the plain representation. The old version stays valid
// (neither representation is mutated), and the no-ops of report 38 §7 return their input.
// T is fixed at build time via ADA_T (research/38 §15).
import * as C from './cow.js';
import * as T from './trie.js';
const LIM = typeof ADA_T === 'number' ? ADA_T : 1024;
const isA = Array.isArray;
const plain = (a) => (isA(a) ? a : T.toArray(a));
export const empty = [];
export const length = (a) => (isA(a) ? a.length : a.n);
export const get = (a, i) => (isA(a) ? a[i] : T.get(a, i));
export function set(a, i, v) {
  if (!isA(a)) return T.set(a, i, v);
  if (a.length <= LIM) return C.set(a, i, v);
  if (i < 0 || i >= a.length || a[i] === v) return a; // a no-op never converts
  return T.set(T.fromArray(a), i, v);
}
export function push(a, v) {
  if (!isA(a)) return T.push(a, v);
  return a.length < LIM ? C.push(a, v) : T.push(T.fromArray(a), v);
}
export function pop(a) {
  if (!isA(a)) return T.pop(a);
  return a.length <= LIM ? C.pop(a) : T.pop(T.fromArray(a));
}
export function swap(a, i, j) {
  if (isA(a)) {
    if (a.length <= LIM || a[i] === a[j]) return C.swap(a, i, j);
    a = T.fromArray(a);
  }
  const x = T.get(a, i), y = T.get(a, j);
  return T.set(T.set(a, i, y), j, x);
}
export function slice(a, s, e) {
  if (isA(a)) return C.slice(a, s, e);
  const n = a.n;
  if (s < 0) s = Math.max(0, n + s);
  if (e < 0) e = Math.max(0, n + e);
  if (e > n) e = n;
  if (s === 0 && e === n) return a;
  return T.toArray(a).slice(s, e);
}
export function concat(a, b) {
  if (isA(a)) return C.concat(a, plain(b));
  // a trie keeps its tree and takes b onto its tail
  return length(b) === 0 ? a : T.concat(a, isA(b) ? T.fromArray(b) : b);
}
export const insert = (a, i, v) => C.insert(plain(a), i, v);
export const remove = (a, i) => C.remove(plain(a), i);
export function map(a, f) {
  if (isA(a)) return C.map(a, f);
  const out = [];
  T.forEach(a, (x) => { out.push(f(x)); });
  return out;
}
export function filter(a, f) {
  if (isA(a)) return C.filter(a, f);
  const out = [];
  T.forEach(a, (x) => { if (f(x)) out.push(x); });
  return out.length === a.n ? a : out;
}
export const foldl = (a, f, z) => (isA(a) ? C.foldl(a, f, z) : T.foldl(a, f, z));
export const forEach = (a, f) => (isA(a) ? C.forEach(a, f) : T.forEach(a, f));
export function eq(a, b, f) {
  if (a === b) return true;
  if (length(a) !== length(b)) return false;
  if (isA(a) && isA(b)) return C.eq(a, b, f);
  if (!isA(a) && !isA(b)) return T.eq(a, b, f);
  return C.eq(plain(a), plain(b), f); // the representation is not canonical for a length
}
export const fromArray = (arr) => arr.slice();
export const toArray = plain;
export const fromCons = C.fromCons;
export const toCons = (a, nil) => (isA(a) ? C.toCons(a, nil) : T.toCons(a, nil));
export const sort = (a, cmp) => (isA(a) ? a.slice() : T.toArray(a)).sort(cmp); // toArray already copies
