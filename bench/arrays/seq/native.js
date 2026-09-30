// native mut: a plain JS array written IN PLACE (a[i] = v, push, pop, splice, unshift). The ceiling
// of report 38 §3, and NOT persistent: a write changes every holder of the array, so a cell that
// reads an old version after writing a new one (a "first" cell repeated on one input, a history, an
// undo stack, kept paths) cannot be measured honestly and is skipped (all.mjs, `needsPersistence`).
// The shared empty array is never written: a write to an empty array starts a fresh one.
export const MUTABLE = true;
export const empty = [];
export const fromArray = (arr) => arr;
export const toArray = (a) => a;
export const length = (a) => a.length;
export const get = (a, i) => a[i];
export const set = (a, i, v) => { a[i] = v; return a; };
export const push = (a, v) => { if (a.length === 0) return [v]; a.push(v); return a; };
export const pop = (a) => { a.pop(); return a; };
export const slice = (a, s, e) => a.slice(s, e);
export const concat = (a, b) => { const m = b.length; for (let i = 0; i < m; i++) a.push(b[i]); return a; };
export const insert = (a, i, v) => { a.splice(i, 0, v); return a; };
export const remove = (a, i) => { a.splice(i, 1); return a; };
export const swap = (a, i, j) => { const t = a[i]; a[i] = a[j]; a[j] = t; return a; };
export const prepend = (a, v) => { a.unshift(v); return a; };
// a sort that returns its input sorted in place would hand the next call sorted input; the ceiling
// for a sort is a copy and a sort, as for cow
export const sort = (a, cmp) => a.slice().sort(cmp);
export const consFrom = (v, b, o) => { const c = b.slice(o - 1); c[0] = v; return c; };
export function forEach(a, f) { for (let i = 0; i < a.length; i++) f(a[i]); }
export const chunks = (a) => [a];
