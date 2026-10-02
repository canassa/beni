// The sibling JavaScript of `List.beni` (docs/design/boundary.md §4): the
// operations the code generator writes in place (backend.md §4, *`List.beni`'s
// loops read and write in place*), for a value of one. The list runtime itself
// is beni (research 50).
export const length = (xs) => xs.length;
export const at = (a, i) => a[i];
export const put = (b, i, x) => {
  b[i] = x;
  return b;
};
export const identical = (x, y) => x === y;
export const kept = (same, xs, ys) => (same ? xs : ys);
export const half = (n) => n >>> 1;
