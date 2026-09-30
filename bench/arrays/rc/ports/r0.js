// research/42's R0: no counts and no flags. The array is ports/adaptive.js's, unchanged, and
// every write the compiler could NOT prove unique calls its persistent operation. A write it
// DID prove unique — the value is fresh or a consumed-unique parameter, and dead after the
// write (research/42 §4) — calls the `…U` twin here, which mutates. The proof is the compiler's; nothing is
// checked at run time, so a wrong proof is a wrong answer (§15.2's lesson).
//
// A caller that must hand a consumed-unique parameter a value it cannot prove unique copies it
// first with `copy`, which returns a fresh plain array (O(n)).
import * as A from '../../ports/adaptive.js';
import * as T from '../../ports/trie.js';
export * from '../../ports/adaptive.js';
const isA = Array.isArray;
// a unique trie is flattened once, as in rc-adaptive.js
const own = (a) => (isA(a) ? a : T.toArray(a));
export function setU(a, i, v) {
  if (i < 0 || i >= A.length(a)) return a;
  const p = own(a); p[i] = v; return p;
}
export function pushU(a, v) { const p = own(a); p.push(v); return p; }
export function popU(a) { const p = own(a); if (p.length) p.pop(); return p; }
export function concatU(a, b) {
  const p = own(a);
  if (isA(b)) for (let i = 0; i < b.length; i++) p.push(b[i]); else T.forEach(b, (x) => { p.push(x); });
  return p;
}
export const copy = (a) => (isA(a) ? a.slice() : T.toArray(a));
export const adopt = (a) => a;
export const pin = (a) => a;
export const isPlain = isA;
