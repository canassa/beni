// One candidate's whole sequence surface (report 46): every `foreign` sibling the three compiled
// programs of all.mjs call, plus the harness's hooks, from the candidate's own primitives. all.mjs
// bundles it with `seq-core` resolved to seq/<candidate>.js, and resolves every sibling import of
// the compiled beni to this one module:
//
//   _core/Array.foreign.mjs   §15's Array (scenarios/Array.beni): length, unsafeGet, set, push, pop,
//                             slice, append, fromList, toList, sortWith
//   _core/List.foreign.mjs    today's List (core/List.js): cons, eq, compare — or the array-first
//                             List (lists/first-core/List.js): the same plus length … swap, builder,
//                             add, done
//   list-syntax               lib/rewrite.js's lowering of `[]`, `::`, `x :: rest` and tail calls
//                             modulo cons: $nil, $cons, $isNil, $isCons, $hd, $tl, $trmc*
//   Basics' `++`              basicsAppend
//   the harness               fromJs (adopt a fresh JS array), toJs (a JS array to read, never to
//                             write), walk (the DOM runtime's way through a sequence), chunks
//
// A candidate module provides primitives over its own representation (the contract is below, and
// every seq/*.js file states which it has). What it does not provide is derived here the same way
// for everyone, so a difference between two columns is a difference between their primitives:
//
// * `x :: rest`: a candidate with a native tail (`tail`: funkia, Immutable.js, mori) uses it; every
//   other one gets the O(1) VIEW V {b, o, length} of research/38 §16 over its own value, whose head
//   is the candidate's `get(b, o)`. Every operation that is not a read turns a view back into the
//   candidate's value first, with the candidate's own `slice`.
// * `x :: xs` as an expression: the candidate's `prepend`, or its `insert` at 0.
// * the builders (`builder`/`add`/`done`, the core-private build of lists/first-core, and the
//   tail-call-modulo-cons loop): a fresh JS array, handed to the candidate's `fromArray` at the end.
//
// Contract of a candidate module (seq/*.js). Indices are in range and slices non-empty and partial;
// the surface checks and normalises first.
//   fromArray(arr)      the candidate's value holding arr's elements; arr is fresh and may be adopted
//   toArray(x)          a JS array of the elements, to read only (a plain array may return itself)
//   length(x), get(x, i), set(x, i, v), push(x, v), pop(x) (x not empty), slice(x, s, e),
//   concat(a, b) (both non-empty), insert(x, i, v), remove(x, i), sort(x, cmpNumber)
//   optional: swap(x, i, j), prepend(x, v), tail(x), consFrom(v, plainBacking, offset), forEach(x, f),
//   chunks(x), eqWith(a, b, f), empty, MUTABLE (writes land in place: not persistent)
// A module that implements the whole surface itself (cons.js, e1.js, e1t.js) exports FULL = true, and
// only what it leaves out is derived.
import * as K from 'seq-core';

// all.mjs defines SEQ_FULL per candidate, so a bundle keeps only the half of each export it uses
const FULL = typeof SEQ_FULL === 'boolean' ? SEQ_FULL : K.FULL === true;
export const MUTABLE = K.MUTABLE === true;
// the array-first programs keep a stack's top at the END (lists/harness.js's differential test)
export const stackTopLast = typeof STYLE_FIRST === 'boolean' ? STYLE_FIRST : false;

// ---- views ---------------------------------------------------------------------------------------
export class V {
  constructor(b, o, length) { this.b = b; this.o = o; this.length = length; }
}
const NATIVE_TAIL = typeof K.tail === 'function';
const isV = (x) => x instanceof V;
const flat = (x) => (isV(x) ? K.slice(x.b, x.o, x.o + x.length) : x);
const EMPTY = FULL ? K.$nil : K.empty !== undefined ? K.empty : K.fromArray([]);
const klen = K.length;

// ---- the list syntax -----------------------------------------------------------------------------
const gLength = (x) => (isV(x) ? x.length : klen(x));
export const length = FULL ? K.length : gLength;
export const $nil = FULL ? K.$nil : EMPTY;
export const $isNil = FULL ? K.$isNil : (x) => !isV(x) && klen(x) === 0;
export const $isCons = FULL ? K.$isCons : (x) => isV(x) || klen(x) !== 0;
export const $hd = FULL ? K.$hd : (x) => (isV(x) ? K.get(x.b, x.o) : K.get(x, 0));
export const $tl = FULL ? K.$tl : NATIVE_TAIL
  ? (x) => (klen(x) > 1 ? K.tail(x) : EMPTY)
  : (x) => {
    if (isV(x)) return x.length > 1 ? new V(x.b, x.o + 1, x.length - 1) : EMPTY;
    const n = klen(x);
    return n > 1 ? new V(x, 1, n - 1) : EMPTY;
  };
function gCons(h, t) {
  if (isV(t)) {
    if (K.consFrom) { const c = K.consFrom(h, t.b, t.o); if (c !== null) return c; } // null: not over a plain backing
    t = flat(t);
  } else if (klen(t) === 0) return K.fromArray([h]);
  return K.prepend ? K.prepend(t, h) : K.insert(t, 0, h);
}
export const $cons = FULL ? K.$cons : gCons;
export const cons = FULL && K.cons ? K.cons : $cons;
export const $fromArray = FULL && K.$fromArray ? K.$fromArray : (arr) => K.fromArray(arr);

// ---- the first-order sibling ----------------------------------------------------------------------
export const unsafeGet = FULL ? K.unsafeGet : (x, i) => (isV(x) ? K.get(x.b, x.o + i) : K.get(x, i));
export const set = FULL ? K.set : (x, i, v) => {
  x = flat(x);
  return i < 0 || i >= klen(x) ? x : K.set(x, i, v);
};
export const push = FULL ? K.push : (x, v) => (!isV(x) && klen(x) === 0 && !MUTABLE ? K.fromArray([v]) : K.push(flat(x), v));
export const pop = FULL ? K.pop : (x) => (gLength(x) <= 1 ? (gLength(x) === 0 ? x : EMPTY) : K.pop(flat(x)));
export const slice = FULL ? K.slice : (x, from, to) => {
  const n = gLength(x);
  if (from < 0) from = Math.max(0, n + from);
  if (to < 0) to = Math.max(0, n + to);
  if (to > n) to = n;
  if (from === 0 && to === n) return x;
  if (from >= to) return EMPTY;
  return isV(x) ? K.slice(x.b, x.o + from, x.o + to) : K.slice(x, from, to);
};
export const append = FULL ? K.append : (xs, ys) => (gLength(ys) === 0 ? xs : gLength(xs) === 0 ? ys : K.concat(flat(xs), flat(ys)));
export const insertAt = FULL && K.insertAt ? K.insertAt : (x, i, v) => {
  const n = length(x);
  if (i < 0 || i > n) return x;
  if (!FULL && K.insert) return n === 0 ? K.fromArray([v]) : K.insert(flat(x), i, v);
  return append(push(slice(x, 0, i), v), slice(x, i, n));
};
export const removeAt = FULL && K.removeAt ? K.removeAt : (x, i) => {
  const n = length(x);
  if (i < 0 || i >= n) return x;
  if (!FULL && K.remove) return n === 1 ? EMPTY : K.remove(flat(x), i);
  return append(slice(x, 0, i), slice(x, i + 1, n));
};
export const swap = FULL && K.swap ? K.swap : (x, i, j) => {
  const n = length(x);
  if (i < 0 || j < 0 || i >= n || j >= n) return x;
  if (!FULL && K.swap) return K.swap(flat(x), i, j);
  const a = unsafeGet(x, i), b = unsafeGet(x, j);
  return set(set(x, i, b), j, a);
};

// the core-private builder of lists/first-core (and of the tail-call loop)
export const builder = FULL && K.builder ? K.builder : (n) => [];
export const add = FULL && K.add ? K.add : (b, x) => { b.push(x); return b; };
export const done = FULL && K.done ? K.done : (b) => K.fromArray(b);
export const $trmcStart = FULL && K.$trmcStart ? K.$trmcStart : () => [];
export const $trmcAdd = FULL && K.$trmcAdd ? K.$trmcAdd : (b, h) => { b.push(h); };
export const $trmcDone = FULL && K.$trmcDone ? K.$trmcDone : (b, t) => ($isNil(t) ? done(b) : append(done(b), t));

// ---- the host side -------------------------------------------------------------------------------
export const fromJs = FULL && K.fromJs ? K.fromJs : (arr) => K.fromArray(arr);
export const toJs = FULL && K.toJs ? K.toJs : (x) => K.toArray(flat(x));
export const chunks = K.chunks ? (x) => K.chunks(flat(x)) : (x) => [toJs(x)];
export const walk = FULL && K.walk ? K.walk : (x, visit) => {
  if (isV(x)) { const b = x.b, o = x.o, n = x.length; for (let i = 0; i < n; i++) visit(K.get(b, o + i), i); return; }
  if (K.forEach) { let k = 0; K.forEach(x, (e) => visit(e, k++)); return; }
  const a = K.toArray(x);
  for (let i = 0; i < a.length; i++) visit(a[i], i);
};

// ---- equality and order (the `where` siblings), and the conversions §15's Array needs -------------
export const eq = FULL && K.eq ? K.eq : (m0, xs, ys) => {
  if (xs === ys) return true;
  const n = length(xs);
  if (n !== length(ys)) return false;
  if (K.eqWith && !isV(xs) && !isV(ys)) return K.eqWith(xs, ys, m0);
  for (let i = 0; i < n; i++) if (!m0(unsafeGet(xs, i), unsafeGet(ys, i))) return false;
  return true;
};
export const compare = FULL && K.compare ? K.compare : (m0, xs, ys) => {
  const n = length(xs), m = length(ys), k = Math.min(n, m);
  for (let i = 0; i < k; i++) { const o = m0(unsafeGet(xs, i), unsafeGet(ys, i)); if (o !== 'EQ') return o; }
  return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
};
const NIL = { $: 0, a: null, b: null };
export const fromList = FULL && K.fromList ? K.fromList : (l) => { const out = []; for (; l.$ === 1; l = l.b) out.push(l.a); return done(out); };
export const toList = FULL && K.toList ? K.toList : (x) => { const a = toJs(x); let l = NIL; for (let i = a.length - 1; i >= 0; i--) l = { $: 1, a: a[i], b: l }; return l; };
const order = (f) => (x, y) => { const o = f(x, y); return o === 'LT' ? -1 : o === 'GT' ? 1 : 0; };
export const sortWith = FULL && K.sortWith ? K.sortWith : FULL
  ? (x, f) => done(toJs(x).slice().sort(order(f)))
  : (x, f) => K.sort(flat(x), order(f));

// `++`, over the two appendable representations (core/Basics.js's `append`)
export const basicsAppend = FULL && K.basicsAppend ? K.basicsAppend : (a, b) => (typeof a === 'string' ? a + b : append(a, b));
