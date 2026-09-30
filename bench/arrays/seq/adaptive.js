// adaptive: report 38 §15's adaptive array (ports/adaptive.js, unchanged) with T = ADA_T, 256 for the
// adaptive256 column (§15.11's setting) and 1 024 for the check of research 40's minified sibling.
// Plain until the first single-element write to a plain array longer than T, the trie after it; every
// operation that builds a fresh array returns a plain one. It is today's `Array` in the two-type
// design. `x :: rest` is the surface's view, so on list code this column is research/38 §16's single
// type B without E1's builder and tail cache.
export { toArray, length, get, set, push, pop, slice, concat, insert, remove, swap, sort, forEach } from '../ports/adaptive.js';
export const empty = [];
export const fromArray = (arr) => arr;
function leaves(x, s, out) { if (s === 5) { for (let i = 0; i < x.length; i++) out.push(x[i]); } else for (let i = 0; i < x.length; i++) leaves(x[i], s - 5, out); return out; }
export const chunks = (a) => { if (Array.isArray(a)) return [a]; const out = leaves(a.r, a.s, []); out.push(a.t); return out; };
export const consFrom = (v, b, o) => { if (!Array.isArray(b)) return null; const c = b.slice(o - 1); c[0] = v; return c; };
