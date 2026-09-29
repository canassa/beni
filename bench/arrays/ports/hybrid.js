// Plain JS array up to T elements, the trie above. T is fixed at build time via HYB_T.
import * as C from './cow.js';
import * as T from './trie.js';
const LIM = typeof HYB_T === 'number' ? HYB_T : 1024;
const isA = Array.isArray;
const norm = (arr) => (arr.length <= LIM ? arr : T.fromArray(arr));
const down = (t) => (t.n <= LIM ? T.toArray(t) : t);
export const empty = [];
export const length = (a) => (isA(a) ? a.length : a.n);
export const get = (a, i) => (isA(a) ? a[i] : T.get(a, i));
export const set = (a, i, v) => (isA(a) ? C.set(a, i, v) : T.set(a, i, v));
export const push = (a, v) => (isA(a) ? (a.length < LIM ? C.push(a, v) : T.push(T.fromArray(a), v)) : T.push(a, v));
export const pop = (a) => (isA(a) ? C.pop(a) : down(T.pop(a)));
export const slice = (a, s, e) => (isA(a) ? C.slice(a, s, e) : down(T.slice(a, s, e)));
export function concat(a, b) {
  if (isA(a) && isA(b)) return norm(C.concat(a, b));
  const ta = isA(a) ? T.fromArray(a) : a;
  return T.concat(ta, isA(b) ? T.fromArray(b) : b);
}
export const insert = (a, i, v) => (isA(a) ? norm(C.insert(a, i, v)) : T.insert(a, i, v));
export const remove = (a, i) => (isA(a) ? C.remove(a, i) : down(T.remove(a, i)));
export const map = (a, f) => (isA(a) ? C.map(a, f) : T.map(a, f));
export const filter = (a, f) => (isA(a) ? C.filter(a, f) : down(T.filter(a, f)));
export const foldl = (a, f, z) => (isA(a) ? C.foldl(a, f, z) : T.foldl(a, f, z));
export const forEach = (a, f) => (isA(a) ? C.forEach(a, f) : T.forEach(a, f));
export function eq(a, b, f) {
  if (isA(a) !== isA(b)) return false; // representation is canonical for a length
  return isA(a) ? C.eq(a, b, f) : T.eq(a, b, f);
}
export const fromArray = (arr) => norm(arr.slice());
export const toArray = (a) => (isA(a) ? a : T.toArray(a));
export const fromCons = (l) => norm(C.fromCons(l));
export const toCons = (a, nil) => (isA(a) ? C.toCons(a, nil) : T.toCons(a, nil));
export const sort = (a, cmp) => (isA(a) ? C.sort(a, cmp) : T.sort(a, cmp));
export const swap = (a, i, j) => (isA(a) ? C.swap(a, i, j) : T.set(T.set(a, i, T.get(a, j)), j, T.get(a, i)));
