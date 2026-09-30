// §15's Array port API (scenarios.mjs) over ports/first-tail.js, so §15's array scenarios run on
// E1t's representation, as §16.5 ran them on single.js. `toArray` does NOT use the trie's cached
// plain copy: §15's interop cells call it repeatedly on one value, and a cache hit there would
// measure the cache, not the conversion.
import * as E from './first-tail.js';

const isA = Array.isArray;
const isV = (x) => x instanceof E.V;
const flat = (x) => (isA(x) ? x : isV(x) ? x.b.slice(x.o) : E.tflatFresh(x));
export const empty = E.$nil;
export const length = E.length;
export const get = E.unsafeGet;
export const set = E.set;
export const push = E.push;
export const pop = E.pop;
export const slice = E.slice;
export const concat = E.append;
export function fromCons(l) { const c = []; for (; l.$ === 1; l = l.b) c.push(l.a); return c; }
export function toCons(a, nil) { const x = flat(a); let l = nil; for (let i = x.length - 1; i >= 0; i--) l = { $: 1, a: x[i], b: l }; return l; }
export const sort = (a, cmp) => (isA(a) ? a.slice() : flat(a)).sort(cmp);
export const toArray = flat;
export const eq = (a, b, f) => E.eq(f, a, b);
export const chunks = (a) => (isA(a) ? [a] : isV(a) ? [a.b.slice(a.o)] : E.chunksOf(a));
