// E1: research/38 §17's one array-first sequence type, ports/first.js unchanged (§16's adaptive
// array with T = 256, plus the O(1) view `x :: rest` makes, a core-private builder and a per-trie cache
// of the plain copy a tail needs). Only the host's hooks are set here: `toJs` hands a plain array over
// without copying it, as §15's `toJs` does, and `chunks` walks a trie's leaves.
export * from '../ports/first.js';
import * as F from '../ports/first.js';
export const FULL = true;
export const fromJs = (arr) => arr;
export const toJs = (x) => F.plain(x);
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
export const chunks = (a) => { if (Array.isArray(a)) return [a]; if (a instanceof F.V) return [F.plain(a)]; const out = leaves(a.r, a.s, []); out.push(a.t); return out; };
