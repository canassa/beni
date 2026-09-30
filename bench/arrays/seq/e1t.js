// E1t: research/38 §17's E1 with a representation built for `push`, ports/first-tail.js unchanged (a
// claimable trie tail, a push threshold of 32, T = 256 for `set` and `pop`). Only the host's hooks are
// set here, as ports/first-tail-array.js set them for §17.7: `toJs` converts a trie without its cached
// plain copy (the interop cells call it repeatedly on one value; a cache hit would measure the
// cache), and `chunks` walks the leaves.
export * from '../ports/first-tail.js';
import * as E from '../ports/first-tail.js';
export const FULL = true;
export const fromJs = (arr) => arr;
export const toJs = (x) => (Array.isArray(x) ? x : x instanceof E.V ? x.b.slice(x.o) : E.tflatFresh(x));
export const chunks = (a) => (Array.isArray(a) ? [a] : a instanceof E.V ? [a.b.slice(a.o)] : E.chunksOf(a));
