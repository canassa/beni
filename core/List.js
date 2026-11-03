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
export const base = (xs) => Array.isArray(xs) ? xs : xs.$h !== undefined ? xs.$plain() : xs.b;
export const offset = (xs) => Array.isArray(xs) || xs.$h !== undefined ? 0 : xs.o;
const View = function(b, o, token) {
  this.b = b;
  this.o = o;
  this.length = b.length - o;
  this.$t = token;
};
export const viewOf = (b, o, token) => new View(b, o, token);
export const isView = (xs) => xs instanceof View;
export const wrapTree = (length, header, plain, token) => ({ length, $h: header, $plain: plain, $t: token });
export const treeOf = (xs) => xs.$h;
export const isTree = (xs) => xs.$h !== undefined;
export const peekArray = (builder) => builder;
export const writeArray = (builder, index, value) => { builder[index] = value; return null; };
