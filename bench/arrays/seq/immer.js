// Immer 11.1.18 (production build, auto-freeze on: its default): a plain JS array, and every write
// (set, push, pop, insert, remove, swap, `::`, sort) goes through `produce`, whose result is frozen
// (report 38 §1, §14). What builds a fresh array (fromArray, the builders, slice, concat) is cow's,
// as in §3 and §14: Immer has nothing else to build with.
import { produce } from 'immer';
export { toArray, length, get, slice, concat, forEach } from '../ports/cow.js';
export const empty = Object.freeze([]);
export const fromArray = (arr) => arr;
export const set = (a, i, v) => produce(a, (d) => { d[i] = v; });
export const push = (a, v) => produce(a, (d) => { d.push(v); });
export const pop = (a) => produce(a, (d) => { d.pop(); });
export const insert = (a, i, v) => produce(a, (d) => { d.splice(i, 0, v); });
export const remove = (a, i) => produce(a, (d) => { d.splice(i, 1); });
export const swap = (a, i, j) => produce(a, (d) => { const t = d[i]; d[i] = d[j]; d[j] = t; });
export const prepend = (a, v) => produce(a, (d) => { d.unshift(v); });
export const sort = (a, cmp) => produce(a, (d) => { d.sort(cmp); });
export const chunks = (a) => [a];
