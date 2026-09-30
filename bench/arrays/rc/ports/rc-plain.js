// research/42's R2-plain: every beni array is a plain JS array, always, with the sticky shared
// bit of rc/rt.js in its `rc` field. There is no trie. A write lands in place while the array is
// unique and copies the whole array when it is shared; the copy is unique, so a run of writes on
// a shared array pays one copy. Reads are `a[i]` and `a.length` everywhere — the emitted code
// calls no reader at all (rc/rc.mjs rewrites `unsafeGet`/`length` away, as §15's proven-plain
// build did, but here the proof is the representation itself).
//
// Ownership as in rc-adaptive.js: `a` of set/push/pop/append is owned, everything else borrowed.
// Mode r1 is accepted too (a count in the same field), though the report measures r2.
import * as C from '../../ports/cow.js';
const R1 = RC_MODE === 'r1';
const PIN = R1 ? 1 << 29 : 2;
const fresh = (a) => { a.rc = 1; return a; };
const dup = R1 ? (a) => { a.rc++; return a; } : (a) => { a.rc = 2; return a; };
const release = R1 ? (a) => { a.rc--; } : () => {};
// V8's Array.prototype.concat leaves its fast path when the receiver has a named property such as
// `rc`: 7–15× slower on 10 000 elements (rc/probe-builtins.mjs, §7.3). Every copy here is a slice,
// which does not.
const cset = (a, i, v) => { const c = a.slice(); c[i] = v; return c; };
const cpush = (a, v) => { const c = a.slice(); c.push(v); return c; };
const ccat = (a, b) => { const c = a.slice(); for (let i = 0; i < b.length; i++) c.push(b[i]); return c; };

export const length = (a) => a.length;
export const get = (a, i) => a[i];
export function set(a, i, v) {
  if (i < 0 || i >= a.length || a[i] === v) return a;
  if (a.rc === 1) { a[i] = v; return a; }
  release(a);
  return fresh(cset(a, i, v));
}
export function push(a, v) {
  if (a.rc === 1) { a.push(v); return a; }
  release(a);
  return fresh(cpush(a, v));
}
export function pop(a) {
  if (a.length === 0) return a;
  if (a.rc === 1) { a.pop(); return a; }
  release(a);
  return fresh(a.slice(0, -1));
}
export function concat(a, b) {
  const nb = b.length;
  if (nb === 0) return a;
  if (a.rc === 1) { for (let i = 0; i < nb; i++) a.push(b[i]); return a; }
  release(a);
  if (a.length === 0) return dup(b);
  return fresh(ccat(a, b));
}
export function slice(a, s, e) { const r = C.slice(a, s, e); return r === a ? dup(a) : fresh(r); }
export const fromCons = (l) => fresh(C.fromCons(l));
export const toCons = C.toCons;
export const sort = (a, cmp) => fresh(a.slice().sort(cmp));
export const toArray = (a) => a;
export const adopt = fresh;
export const pin = (a) => { a.rc = PIN; return a; };
export const isPlain = () => true;
