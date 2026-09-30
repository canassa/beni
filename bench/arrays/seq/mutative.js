// Mutative 1.3.0 in report 38 §14's fastest honest configuration ("Mutative fast"): the production
// build, no freeze (its default), and `mark` telling it the elements are opaque values, so a read of
// `d[i]` inside a recipe returns the element instead of drafting it. A plain JS array; every write
// goes through `create`. What builds a fresh array is cow's, as in §14.
import { create } from 'mutative/dist/mutative.cjs.production.min.js';
export { toArray, length, get, slice, concat, forEach } from '../ports/cow.js';
const O = { mark: (v, t) => (Array.isArray(v) ? undefined : t.mutable) };
export const empty = [];
export const fromArray = (arr) => arr;
export const set = (a, i, v) => create(a, (d) => { d[i] = v; }, O);
export const push = (a, v) => create(a, (d) => { d.push(v); }, O);
export const pop = (a) => create(a, (d) => { d.pop(); }, O);
export const insert = (a, i, v) => create(a, (d) => { d.splice(i, 0, v); }, O);
export const remove = (a, i) => create(a, (d) => { d.splice(i, 1); }, O);
export const swap = (a, i, j) => create(a, (d) => { const t = d[i]; d[i] = d[j]; d[j] = t; }, O);
export const prepend = (a, v) => create(a, (d) => { d.unshift(v); }, O);
export const sort = (a, cmp) => create(a, (d) => { d.sort(cmp); }, O);
export const chunks = (a) => [a];
