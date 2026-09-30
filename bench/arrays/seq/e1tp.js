// E1tp: E1t with cheap prepend (research/46 §11), ports/first-tail-prepend.js unchanged: a claimable
// head buffer stored reversed, a radix offset on the trie, `$tl` of a trie by offset. The host's
// hooks are E1t's (seq/e1t.js): `toJs` converts a trie without its cached plain copy, and `chunks`
// walks the head, the leaves and the tail.
export * from '../ports/first-tail-prepend.js';
import * as E from '../ports/first-tail-prepend.js';
export const FULL = true;
export const fromJs = (arr) => arr;
export const toJs = (x) => (Array.isArray(x) ? x : x instanceof E.V ? x.b.slice(x.o) : E.tflatFresh(x));
export const chunks = (a) => (Array.isArray(a) ? [a] : a instanceof E.V ? [a.b.slice(a.o)] : E.chunksOf(a));
