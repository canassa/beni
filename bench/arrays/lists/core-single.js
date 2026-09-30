// `core/List` for candidates B and C (research/38 §16): the functions the scenarios reach, written
// as a `foreign` sibling would write them over ports/single.js — plain loops over the backing array,
// which is what a single-type core would ship (compiled beni `foldl`-then-`reverse` over copying
// `::` would be quadratic in core itself). It replaces the compiled `_core/List.mjs` at bundle time
// and exports the same names, plus the lowering's `$` primitives and the harness's hooks.
import * as S from '../ports/single.js';
export { $nil, $isNil, $isCons, $hd, $tl, $cons, $fromArray } from '../ports/single.js';
import { $nil, $cons, span, plain, len } from '../ports/single.js';

export const List$cons = $cons;

export function List$foldl(xs, acc, f) {
  span(xs); const a = S.SA, n = a.length;
  for (let i = S.SO; i < n; i++) acc = f(a[i], acc);
  return acc;
}
export function List$foldr(xs, acc, f) {
  span(xs); const a = S.SA, o = S.SO;
  for (let i = a.length - 1; i >= o; i--) acc = f(a[i], acc);
  return acc;
}
export function List$map(xs, f) {
  span(xs); const a = S.SA, n = a.length, out = [];
  for (let i = S.SO; i < n; i++) out.push(f(a[i]));
  return out;
}
// keeps the input's identity when every element is kept (§7)
export function List$filter(xs, keep) {
  span(xs); const a = S.SA, n = a.length, o = S.SO, out = [];
  for (let i = o; i < n; i++) { const x = a[i]; if (keep(x)) out.push(x); }
  return out.length === n - o ? xs : out;
}
export function List$reverse(xs) {
  span(xs); const a = S.SA, o = S.SO, out = [];
  for (let i = a.length - 1; i >= o; i--) out.push(a[i]);
  return out;
}
export function List$range(lo, hi) {
  const out = [];
  for (let i = lo; i <= hi; i++) out.push(i);
  return out;
}
export const List$sum = (xs) => List$foldl(xs, 0, (x, s) => s + x);
export function List$append(xs, ys) {
  if (len(ys) === 0) return xs;
  if (len(xs) === 0) return ys;
  return plain(xs).concat(plain(ys));
}
export function List$concat(xss) {
  span(xss); const a = S.SA, n = a.length, out = [];
  for (let i = S.SO; i < n; i++) { span(a[i]); const b = S.SA, m = b.length; for (let j = S.SO; j < m; j++) out.push(b[j]); }
  return out;
}
export function List$concatMap(xs, f) {
  span(xs); const a = S.SA, n = a.length, out = [];
  for (let i = S.SO; i < n; i++) { span(f(a[i])); const b = S.SA, m = b.length; for (let j = S.SO; j < m; j++) out.push(b[j]); }
  return out;
}
export function List$map2(xs, ys, f) {
  span(xs); const a = S.SA, i0 = S.SO; span(ys); const b = S.SA, j0 = S.SO;
  const m = Math.min(a.length - i0, b.length - j0), out = [];
  for (let k = 0; k < m; k++) out.push(f(a[i0 + k], b[j0 + k]));
  return out;
}
// `++`, over the two appendable representations (core/Basics.js's `append`)
export const append = (a, b) => (typeof a === 'string' ? a + b : List$append(a, b));

// ---- what candidate C's rewrites call ------------------------------------------------------------
// A builder is a fresh JS array that only the loop owning it can see. `e :: acc` on a builder that
// stores the list back to front is `acc.push(e)`; `List.reverse acc` of it is the array itself.
export const $fromBuilder = (b) => b;
export const $fromBuilderRev = (b) => b.reverse();
// a loop's (array, start) for a sequence, read from the live bindings SA / SO after span(x)
export { span, SA, SO } from '../ports/single.js';

// ---- harness hooks ----------------------------------------------------------------------------------
export const fromJs = (arr) => arr.slice();
export const toJs = (xs) => plain(xs).slice();
export function walk(xs, visit) {
  span(xs); const a = S.SA, n = a.length, o = S.SO;
  for (let i = o; i < n; i++) visit(a[i], i - o);
}
export const kind = (xs) => (Array.isArray(xs) ? 'plain' : xs instanceof S.V ? 'view' : 'trie');

// tail calls modulo cons (lib/rewrite.js's `trmc`): a builder the loop owns
export const $trmcStart = () => [];
export const $trmcAdd = (b, h) => { b.push(h); };
export const $trmcDone = (b, t) => (len(t) === 0 ? b : b.concat(plain(t)));
