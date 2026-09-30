// hybrid1024: report 38 §12's recommendation, a plain array up to 1 024 elements and the trie above
// (ports/hybrid.js with HYB_T = 1024, unchanged). The representation is canonical for a length.
export { toArray, length, get, set, push, pop, slice, concat, insert, remove, swap, sort, forEach } from '../ports/hybrid.js';
import * as T from '../ports/trie.js';
export const empty = [];
export const fromArray = (arr) => (arr.length <= 1024 ? arr : T.fromArray(arr));
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
export const chunks = (a) => { if (Array.isArray(a)) return [a]; const out = leaves(a.r, a.s, []); out.push(a.t); return out; };
export const consFrom = (v, b, o) => { if (!Array.isArray(b)) return null; const c = b.slice(o - 1); c[0] = v; return fromArray(c); };
