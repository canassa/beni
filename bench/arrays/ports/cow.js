// A minimal beni-specific copy-on-write array: the value IS a plain JS array, never mutated after
// construction. What core/Array's foreign sibling would contain.
export const empty = [];
// copy with room for `extra` more: a loop below 64 elements (V8's slice/concat have a high fixed cost), concat above (one exact-size memcpy)
function copy(a, extra) {
  const n = a.length;
  if (n >= 64) return a.concat();
  const c = new Array(n + extra);
  for (let j = 0; j < n; j++) c[j] = a[j];
  return c;
}
export const length = (a) => a.length;
export const get = (a, i) => a[i];
export function set(a, i, v) {
  if (i < 0 || i >= a.length || a[i] === v) return a;
  const c = copy(a, 0); c[i] = v; return c;
}
export function push(a, v) { const n = a.length; if (n >= 64) return a.concat([v]); /* never a.concat(v): v may be an array */ const c = copy(a, 1); c[n] = v; return c; }
export const pop = (a) => a.slice(0, -1);
export function slice(a, s, e) {
  const r = a.slice(s, e);
  return r.length === a.length ? a : r;
}
export const concat = (a, b) => (b.length === 0 ? a : a.length === 0 ? b : a.concat(b));
export function insert(a, i, v) { const c = a.slice(0, i); c.push(v); for (let k = i; k < a.length; k++) c.push(a[k]); return c; }
export function remove(a, i) { const c = a.slice(0, i); for (let k = i + 1; k < a.length; k++) c.push(a[k]); return c; }
export function map(a, f) { const c = []; for (let i = 0; i < a.length; i++) c.push(f(a[i])); return c; }
export function filter(a, f) {
  const c = []; for (let i = 0; i < a.length; i++) { const x = a[i]; if (f(x)) c.push(x); }
  return c.length === a.length ? a : c;
}
export function foldl(a, f, z) { for (let i = 0; i < a.length; i++) z = f(a[i], z); return z; }
export function forEach(a, f) { for (let i = 0; i < a.length; i++) f(a[i]); }
export function eq(a, b, f) {
  if (a === b) return true;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (!f(a[i], b[i])) return false;
  return true;
}
export const fromArray = (arr) => arr.slice();
export const toArray = (a) => a; // zero-copy: it already is one (a reader must not mutate it)
export function fromCons(l) { const c = []; for (; l.$ === 1; l = l.b) c.push(l.a); return c; }
export function toCons(a, nil) { let l = nil; for (let i = a.length - 1; i >= 0; i--) l = { $: 1, a: a[i], b: l }; return l; }
export const sort = (a, cmp) => a.slice().sort(cmp);
export function swap(a, i, j) { const x = a[i], y = a[j]; if (x === y) return a; const c = copy(a, 0); c[i] = y; c[j] = x; return c; }
