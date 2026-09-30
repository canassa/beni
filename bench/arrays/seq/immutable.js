// Immutable.js 5.1.9's `List`: a 32-way trie with a tail and an origin offset, so `unshift` and
// `shift` (the list syntax's `::` and tail) are native and do not copy (report 38 §1's adapter).
import { List } from 'immutable';
export const empty = List();
export const fromArray = (arr) => List(arr);
export const toArray = (a) => a.toArray();
export const length = (a) => a.size;
export const get = (a, i) => a.get(i);
export const set = (a, i, v) => a.set(i, v);
export const push = (a, v) => a.push(v);
export const pop = (a) => a.pop();
export const slice = (a, s, e) => a.slice(s, e);
export const concat = (a, b) => a.concat(b);
export const insert = (a, i, v) => a.insert(i, v);
export const remove = (a, i) => a.remove(i);
export const prepend = (a, v) => a.unshift(v);
export const tail = (a) => a.shift();
export const sort = (a, cmp) => a.sort(cmp);
export const forEach = (a, f) => { a.forEach((x) => { f(x); }); };
export function eqWith(a, b, f) {
  const ia = a.values(), ib = b.values();
  for (let x = ia.next(); !x.done; x = ia.next()) if (!f(x.value, ib.next().value)) return false;
  return true;
}
