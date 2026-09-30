// mori 0.3.2: ClojureScript's `PersistentVector`, compiled (report 38 §1's adapter). `subvec` is an
// O(1) view that keeps its vector alive, so the list syntax's tail is native; `::` builds a vector.
import m from 'mori';
const V = m.vector();
export const empty = V;
export const fromArray = (arr) => m.into(V, arr);
export const toArray = (a) => m.intoArray(a);
export const length = (a) => m.count(a);
export const get = (a, i) => m.nth(a, i);
export const set = (a, i, v) => m.assoc(a, i, v);
export const push = (a, v) => m.conj(a, v);
export const pop = (a) => m.pop(a);
export const slice = (a, s, e) => m.subvec(a, s, e);
export const concat = (a, b) => m.into(a, b);
export const insert = (a, i, v) => m.into(m.conj(m.into(V, m.subvec(a, 0, i)), v), m.subvec(a, i));
export const remove = (a, i) => m.into(m.into(V, m.subvec(a, 0, i)), m.subvec(a, i + 1));
export const prepend = (a, v) => m.into(m.vector(v), a);
export const tail = (a) => m.subvec(a, 1);
export const sort = (a, cmp) => m.into(V, m.sort(cmp, a));
export const forEach = (a, f) => { m.reduce((_, x) => { f(x); return null; }, null, a); };
export function eqWith(a, b, f) {
  const n = m.count(a);
  for (let i = 0; i < n; i++) if (!f(m.nth(a, i), m.nth(b, i))) return false;
  return true;
}
