// cons: today's `List`, cons cells `{ $: 1, a, b }` and `{ $: 0, a: null, b: null }` (core/List.js),
// the whole surface written over cells. The list syntax and the tail-call loop are what beni emits
// inline; `eq`, `compare` and `++` are core/List.js's and core/Basics.js's own. The indexed half (the
// array-first core's first-order sibling, and §15's `Array`) is what a linked list can do: `length`
// and `unsafeGet` walk, a write copies the cells before it and shares the rest.
export const FULL = true;
export { eq, compare } from '../../../core/List.js';
export { append as basicsAppend } from '../../../core/Basics.js';

export const $nil = { $: 0, a: null, b: null };
export const $isNil = (x) => x.$ === 0;
export const $isCons = (x) => x.$ === 1;
export const $hd = (x) => x.a;
export const $tl = (x) => x.b;
export const $cons = (h, t) => ({ $: 1, a: h, b: t });
export const cons = $cons;
export const $fromArray = (arr) => fromJs(arr);
// tail calls modulo cons (lib/rewrite.js): beni's destination-passing loop, with the root cell's
// unused head holding the last cell
export const $trmcStart = () => { const r = { $: 1, a: null, b: null }; r.a = r; return r; };
export const $trmcAdd = (r, h) => { const c = { $: 1, a: h, b: null }; r.a.b = c; r.a = c; };
export const $trmcDone = (r, t) => { r.a.b = t; return r.b; };

export function length(l) { let n = 0; for (; l.$ === 1; l = l.b) n++; return n; }
export function unsafeGet(l, i) { for (; i > 0; i--) l = l.b; return l.a; }
// the first `i` cells copied onto `tail`
function prefixOnto(l, i, tail) {
  if (i === 0) return tail;
  const root = { $: 1, a: null, b: null };
  let last = root;
  for (; i > 0; i--, l = l.b) { const c = { $: 1, a: l.a, b: null }; last.b = c; last = c; }
  last.b = tail;
  return root.b;
}
function drop(l, i) { for (; i > 0 && l.$ === 1; i--) l = l.b; return l; }
export function set(l, i, v) {
  if (i < 0) return l;
  const at = drop(l, i);
  if (at.$ === 0 || at.a === v) return l;
  return prefixOnto(l, i, { $: 1, a: v, b: at.b });
}
export const push = (l, v) => prefixOnto(l, length(l), { $: 1, a: v, b: $nil });
export const pop = (l) => { const n = length(l); return n === 0 ? l : prefixOnto(l, n - 1, $nil); };
export function slice(l, from, to) {
  const n = length(l);
  if (from < 0) from = Math.max(0, n + from);
  if (to < 0) to = Math.max(0, n + to);
  if (to > n) to = n;
  if (from === 0 && to === n) return l;
  if (from >= to) return $nil;
  const start = drop(l, from);
  return to === n ? start : prefixOnto(start, to - from, $nil);
}
export function append(a, b) { if (b.$ === 0) return a; return a.$ === 0 ? b : prefixOnto(a, length(a), b); }
export function insertAt(l, i, v) { const n = length(l); if (i < 0 || i > n) return l; return prefixOnto(l, i, { $: 1, a: v, b: drop(l, i) }); }
export function removeAt(l, i) { const n = length(l); if (i < 0 || i >= n) return l; return prefixOnto(l, i, drop(l, i + 1)); }
export function swap(l, i, j) {
  const n = length(l);
  if (i < 0 || j < 0 || i >= n || j >= n) return l;
  const a = unsafeGet(l, i), b = unsafeGet(l, j);
  return set(set(l, i, b), j, a);
}
// the array-first core's builder: a JS array, handed over as cells
export const builder = (n) => [];
export const add = (b, x) => { b.push(x); return b; };
export const done = (b) => fromJs(b);

// §15's Array over cells: its `List` is already cells
export const fromList = (l) => l;
export const toList = (l) => l;
export const sortWith = (l, f) => fromJs(toJs(l).sort((x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; }));

export function fromJs(arr) { let l = $nil; for (let i = arr.length - 1; i >= 0; i--) l = { $: 1, a: arr[i], b: l }; return l; }
export function toJs(l) { const out = []; for (; l.$ === 1; l = l.b) out.push(l.a); return out; }
export function walk(l, visit) { for (let k = 0; l.$ === 1; l = l.b, k++) visit(l.a, k); }
export const chunks = (l) => [toJs(l)];
