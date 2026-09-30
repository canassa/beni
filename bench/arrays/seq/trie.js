// trie: report 38 §1's port, a 32-way persistent vector with a tail (ports/trie.js, unchanged).
// `x :: rest` is the surface's view over the trie; its head is a descent.
export { empty, fromArray, toArray, length, get, set, push, pop, slice, concat, insert, remove, sort, forEach, eq as eqWith } from '../ports/trie.js';
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
// the runtime's way through the trie without copying it: its leaves in order, then its tail
export const chunks = (a) => { const out = leaves(a.r, a.s, []); out.push(a.t); return out; };
