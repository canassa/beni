// cow: report 38 §1's port, a plain JS array never written after construction, copied on every
// write (ports/cow.js, unchanged). `x :: rest` is the surface's view over the array.
export { toArray, length, get, set, push, pop, slice, concat, insert, remove, swap, sort, forEach } from '../ports/cow.js';
export const empty = [];
export const fromArray = (arr) => arr;
// `x :: xs` onto a view: one copy from the backing, as research/38 §16's single.js does
export const consFrom = (v, b, o) => { const c = b.slice(o - 1); c[0] = v; return c; };
export const prepend = (a, v) => { const n = a.length; if (n >= 64) return [v].concat(a); const c = new Array(n + 1); c[0] = v; for (let i = 0; i < n; i++) c[i + 1] = a[i]; return c; };
export const chunks = (a) => [a];
export const eqWith = (a, b, f) => { for (let i = 0; i < a.length; i++) if (!f(a[i], b[i])) return false; return true; };
