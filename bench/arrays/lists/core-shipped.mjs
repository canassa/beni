// The shipped runtime, core/List.js, behind the hooks claim-prepend-test.mjs reads of a prototype
// port: `$cons` is `cons`, `$tl` a pattern's tail (`view(xs, 1)`), `$hd` element 0, and the plain
// copy, the walk and the chunks all go through the reader protocol (`length`, `Array.isArray`,
// `$plain()`), which is all any code outside core/List.js may use (backend.md §4).
export * from '../../../core/List.js';
import * as L from '../../../core/List.js';
export const $nil = [];
export const $cons = (x, xs) => L.cons(x, xs);
export const $tl = (xs) => L.view(xs, 1);
export const $hd = (xs) => L.unsafeGet(xs, 0);
export const $isNil = (xs) => xs.length === 0;
const plain = (xs) => (Array.isArray(xs) ? xs : xs.$plain());
export const toJs = (xs) => plain(xs).slice();
export const walk = (xs, visit) => plain(xs).forEach((x, i) => visit(x, i));
export const kind = (xs) => (Array.isArray(xs) ? 'plain' : xs.o !== undefined ? 'view' : 'trie');
export const chunksOf = (xs) => [plain(xs)];
