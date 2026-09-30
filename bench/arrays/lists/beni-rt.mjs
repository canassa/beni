// The `beni` candidate's harness hooks (all.mjs): the programs compiled by this repository's own
// compiler over the shipped core/List.js, with no rewrite of the list syntax, read the way every
// runtime outside core/List.js reads a list — backend.md §4's protocol: `length`,
// `Array.isArray`, `$plain()`.
const plain = (xs) => (Array.isArray(xs) ? xs : xs.$plain());
// a fresh JS array is a plain list, and may be adopted
export const fromJs = (arr) => arr;
// to read, never to write
export const toJs = (xs) => plain(xs);
// the DOM runtime's way through a list (platforms/browser/runtime.js's `Elements`)
export const walk = (xs, visit) => {
  const a = plain(xs);
  for (let i = 0; i < a.length; i++) visit(a[i], i);
};
export const length = (xs) => xs.length;
export const MUTABLE = false;
// the array-first programs keep a stack's top at the END (lists/harness.js's differential test)
export const stackTopLast = typeof STYLE_FIRST === 'boolean' ? STYLE_FIRST : false;
