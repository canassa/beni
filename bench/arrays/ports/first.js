// Candidate E1 of research/38 §17: the sibling of an array-first `core/List`
// (lists/first-core/List.beni), where the ONE sequence type is §16's single type — §15's adaptive
// array (T = ADA_T, 256) plus the O(1) view an `x :: rest` pattern makes (ports/single.js). This file
// is the first-order `foreign` surface that List.beni declares, under its names and parameter lists,
// plus the list syntax's `$` primitives (the same as single.js) and `++`. Everything higher-order
// is beni, compiled by beni (§12.2).
//
// The only thing here that single.js does not have is the core-private BUILDER: `builder`, `add`
// and `done`. A builder is a fresh JS array that only the core loop which made it can see; `add`
// pushes in place, `done` hands the array over as a plain sequence. That is what lets core's `map`,
// `filter`, `range` … build in O(n) without a cons list to reverse.
import * as S from './single.js';
import * as A from './adaptive.js';
import * as T from './trie.js';

export { $nil, $isNil, $isCons, $hd, $cons, $fromArray, V, plain, span, SA, SO } from './single.js';
const isA = Array.isArray;
const isV = (x) => x instanceof S.V;

// The one change to single.js: the tail of a trie converts it to a plain array ONCE per trie, not
// once per `$tl`. The emitter binds both tails of `( x :: xt, y :: yt )` before it knows which one
// the branch uses, so a loop that matches a trie without advancing it would otherwise copy the whole
// trie on every step. The cache is derived data, so it is invisible.
const flatOf = new WeakMap();
export function $tl(x) {
  if (isV(x)) return x.length > 1 ? new S.V(x.b, x.o + 1, x.length - 1) : S.$nil;
  if (isA(x)) return x.length > 1 ? new S.V(x, 1, x.length - 1) : S.$nil;
  if (x.n <= 1) return S.$nil;
  let b = flatOf.get(x);
  if (b === undefined) { b = T.toArray(x); flatOf.set(x, b); }
  return new S.V(b, 1, x.n - 1);
}

export const cons = (head, tail) => S.$cons(head, tail);
export const length = (xs) => (isA(xs) || isV(xs) ? xs.length : xs.n);
export const unsafeGet = (xs, i) => (isA(xs) ? xs[i] : isV(xs) ? xs.b[xs.o + i] : T.get(xs, i));
export const set = (xs, i, v) => S.set(xs, i, v);
export const push = (xs, v) => S.push(xs, v);
export const pop = (xs) => (length(xs) === 0 ? xs : S.pop(xs));
// a view is sliced straight from its backing, with no copy of the whole view first
export function slice(xs, from, to) {
  if (!isV(xs)) return S.slice(xs, from, to);
  const n = xs.length;
  if (from < 0) from = Math.max(0, n + from);
  if (to < 0) to = Math.max(0, n + to);
  if (to > n) to = n;
  if (from >= to) return S.$nil;
  return xs.b.slice(xs.o + from, xs.o + to);
}
export function append(xs, ys) {
  if (length(ys) === 0) return xs;
  if (length(xs) === 0) return ys;
  return A.concat(S.plain(xs), isV(ys) ? S.plain(ys) : ys);
}
export const builder = (n) => [];
export const add = (b, x) => { b.push(x); return b; };
export const done = (b) => b;

export function eq(m0, xs, ys) {
  if (xs === ys) return true;
  const n = length(xs);
  if (n !== length(ys)) return false;
  for (let i = 0; i < n; i++) if (!m0(unsafeGet(xs, i), unsafeGet(ys, i))) return false;
  return true;
}
export function compare(m0, xs, ys) {
  const n = length(xs), m = length(ys), k = Math.min(n, m);
  for (let i = 0; i < k; i++) { const o = m0(unsafeGet(xs, i), unsafeGet(ys, i)); if (o !== 'EQ') return o; }
  return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
}

// `++`, over the two appendable representations (core/Basics.js's `append`)
export const basicsAppend = (a, b) => (typeof a === 'string' ? a + b : append(a, b));

// ---- harness hooks ----------------------------------------------------------------------------------
export const fromJs = (arr) => arr.slice();
export const toJs = (xs) => S.plain(xs).slice();
export function walk(xs, visit) {
  if (isA(xs) || isV(xs)) { S.span(xs); const a = S.SA, n = a.length, o = S.SO; for (let i = o; i < n; i++) visit(a[i], i - o); return; }
  let k = 0; T.forEach(xs, (x) => visit(x, k++)); // the runtime walks a trie's leaves, no copy
}
export const stackTopLast = true; // the harness's differential test: §17's stacks push at the end
export const kind =(xs) => (isA(xs) ? 'plain' : isV(xs) ? 'view' : 'trie');
