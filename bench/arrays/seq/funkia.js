// funkia `list` 2.0.19: an RRB tree with prefix and suffix buffers (research/38 §16's candidate D).
// `prepend` is O(1) amortised and `tail` a slice, O(log n); `slice`, `concat`, `insert` and `remove`
// are O(log n). The same library as ports/funkia.js and lists/core-funkia.js.
import * as L from 'list';
export const empty = L.empty();
export const fromArray = (arr) => L.from(arr);
export const toArray = (l) => L.toArray(l);
export const length = (l) => l.length;
export const get = (l, i) => L.nth(i, l);
export const set = (l, i, v) => (L.nth(i, l) === v ? l : L.update(i, v, l));
export const push = (l, v) => L.append(v, l);
export const pop = (l) => L.pop(l);
export const slice = (l, s, e) => L.slice(s, e, l);
export const concat = (a, b) => L.concat(a, b);
export const insert = (l, i, v) => L.insert(i, v, l);
export const remove = (l, i) => L.remove(i, 1, l);
export const prepend = (l, v) => L.prepend(v, l);
export const tail = (l) => L.tail(l);
export const sort = (l, cmp) => L.sortWith(cmp, l);
export const forEach = (l, f) => L.forEach(f, l);
export const eqWith = (a, b, f) => L.equalsWith(f, a, b);
