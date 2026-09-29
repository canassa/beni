// `core/List` for candidate D (research/38 §16): funkia `list` as the one sequence type. The list
// syntax lowers to:
//
//   []            $nil = L.empty()
//   x :: xs       $cons(x, xs) = L.prepend(x, xs)      O(1) amortised, shares xs
//   case: []      $isNil(s) = s.length === 0
//   case: x :: r  $hd(s) = L.first(s), $tl(s) = L.tail(s) = L.slice(1, n, s)
//
// and the library functions are funkia's own, adapted to beni's argument order.
import * as L from 'list';

export const $nil = L.empty();
export const $isNil = (x) => x.length === 0;
export const $isCons = (x) => x.length !== 0;
export const $hd = (x) => L.first(x);
export const $tl = (x) => L.tail(x);
export const $cons = (h, t) => L.prepend(h, t);
export const $fromArray = (arr) => L.from(arr);

export const List$cons = $cons;
export const List$foldl = (xs, acc, f) => L.foldl((z, x) => f(x, z), acc, xs);
export const List$foldr = (xs, acc, f) => L.foldr(f, acc, xs);
export const List$map = (xs, f) => L.map(f, xs);
export const List$filter = (xs, keep) => { const r = L.filter(keep, xs); return r.length === xs.length ? xs : r; };
export const List$reverse = (xs) => L.reverse(xs);
export const List$range = (lo, hi) => L.range(lo, hi + 1);
export const List$sum = (xs) => L.foldl((s, x) => s + x, 0, xs);
export const List$append = (xs, ys) => (ys.length === 0 ? xs : xs.length === 0 ? ys : L.concat(xs, ys));
export const List$concat = (xss) => L.flatten(xss);
export const List$concatMap = (xs, f) => L.flatMap(f, xs);
export const List$map2 = (xs, ys, f) => L.zipWith(f, xs, ys);
export const append = (a, b) => (typeof a === 'string' ? a + b : List$append(a, b));

export const fromJs = (arr) => L.from(arr);
export const toJs = (xs) => L.toArray(xs);
export function walk(xs, visit) { let k = 0; L.forEach((x) => visit(x, k++), xs); }
export const kind = () => 'rrb';
