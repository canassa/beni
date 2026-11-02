// The sibling JavaScript of `List.beni` (docs/design/boundary.md §4): the
// operations the code generator writes in place (backend.md §4, *`List.beni`'s
// loops read and write in place*), for a value of one. The list runtime itself
// is beni (research 50).
export const length = (xs) => xs.length;
export const at = (a, i) => a[i];
export const traverseAt = (a, i) => a[i];
export const put = (b, i, x) => {
  b[i] = x;
  return b;
};
export const half = (n) => n >>> 1;
export const builder = (n) => new Array(n > 0 ? n : 0);
export const done = (b, n) => { b.length = n; return b; };
export const base = (xs) => Array.isArray(xs) ? xs : xs.b;
export const offset = (xs) => Array.isArray(xs) ? 0 : xs.o;
export const viewOf = (b, o) => ({ b, o, length: b.length - o });
