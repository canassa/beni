// Candidate D of research/38 §16: funkia `list` 2.0.19 (an RRB tree with prefix and suffix
// buffers: O(1) amortised prepend and append, O(log n) slice and concat) as the ONE sequence type.
// This file is the Array port API of §15 (scenarios.mjs) over it; lists/core-funkia.js is the
// `core/List` side.
import * as L from 'list';

export const empty = L.empty();
export const length = (l) => l.length;
export const get = (l, i) => L.nth(i, l);
export const set = (l, i, v) => (i < 0 || i >= l.length || L.nth(i, l) === v ? l : L.update(i, v, l));
export const push = (l, v) => L.append(v, l);
export const pop = (l) => L.pop(l);
export function slice(l, s, e) {
  const n = l.length;
  if (s < 0) s = Math.max(0, n + s);
  if (e < 0) e = Math.max(0, n + e);
  if (e > n) e = n;
  if (s === 0 && e === n) return l;
  return L.slice(s, e, l);
}
export const concat = (a, b) => (b.length === 0 ? a : a.length === 0 ? b : L.concat(a, b));
export function fromCons(c) { const out = []; for (; c.$ === 1; c = c.b) out.push(c.a); return L.from(out); }
export const toCons = (l, nil) => L.foldr((x, z) => ({ $: 1, a: x, b: z }), nil, l);
export const sort = (l, cmp) => L.sortWith(cmp, l);
export const toArray = (l) => L.toArray(l);
export const fromArray = (arr) => L.from(arr);
