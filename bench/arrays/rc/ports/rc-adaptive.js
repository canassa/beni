// research/42's R1 and R2 over §15's adaptive array (T = ADA_T, 256). The representation is
// ports/adaptive.js's — a plain JS array until a write lands on a SHARED one longer than T, the
// trie after it — plus an `rc` field on every array this module returns (rc/rt.js has what it
// means under each mode). The only new behaviour is at a write:
//
//   * a plain array with rc === 1 is written in place (`a[i] = v`, `a.push(v)`, `a.pop()`,
//     `a.push(...b)`), and the same array is returned;
//   * a `set` on a trie with rc === 1 lands in place along the path, transient-style (below);
//     push, pop and append on a trie stay persistent;
//   * a shared value is written exactly as ports/adaptive.js writes it (copy up to T, trie above),
//     and the result is fresh (rc 1). Under r1 the input loses the holder the write consumed.
//
// Every argument named `a` of set/push/pop/append is OWNED (consumed); every other array
// parameter is BORROWED. A function that returns a borrowed input unchanged (a no-op slice)
// dups it, because its result is owned.
import * as C from '../../ports/cow.js';
import * as T from '../../ports/trie.js';
const LIM = typeof ADA_T === 'number' ? ADA_T : 256;
const R1 = RC_MODE === 'r1';
const PIN = R1 ? 1 << 29 : 2;
const isA = Array.isArray;
const fresh = (a) => { a.rc = 1; return a; };
const dup = R1 ? (a) => { a.rc++; return a; } : (a) => { a.rc = 2; return a; };
const release = R1 ? (a) => { a.rc--; } : () => {};
const plain = (a) => (isA(a) ? a : T.toArray(a));
// V8's Array.prototype.concat leaves its fast path when the receiver has a named property such as
// `rc`: 7–15× slower on 10 000 elements (rc/probe-builtins.mjs, §7.3). Every copy of a counted
// plain array is a slice, which does not; cow.js's copies use concat.
const cset = (a, i, v) => { const c = a.slice(); c[i] = v; return c; };
const cpush = (a, v) => { const c = a.slice(); c.push(v); return c; };
const ccat = (a, b) => { const c = a.slice(); if (isA(b)) for (let i = 0; i < b.length; i++) c.push(b[i]); else T.forEach(b, (x) => { c.push(x); }); return c; };
// T's empty trie is a module constant: never hand it out as a fresh value
const trieOut = (t) => (t.n === 0 ? fresh([]) : fresh(t));

export const length = (a) => (isA(a) ? a.length : a.n);
export const get = (a, i) => (isA(a) ? a[i] : T.get(a, i));
// A unique trie is written in place the way Clojure's transients are: its root carries an
// ownership token `e`, and a node stamped with that token was made by a write through this root
// and is reachable from nowhere else. The write copies (once) and stamps each node on its path that
// is not stamped, then mutates. A persistent write through a SHARED root retires its token first,
// because the nodes it stamped are about to be shared with the new root; that matters under r1,
// where a shared root's count can come back down to 1.
function ownedSet(a, i, v) {
  const tok = a.e ?? (a.e = {});
  const o = a.n - a.t.length;
  if (i >= o) {
    if (a.t.e !== tok) { a.t = a.t.slice(); a.t.e = tok; }
    a.t[i - o] = v;
    return a;
  }
  if (a.r.e !== tok) { a.r = a.r.slice(); a.r.e = tok; }
  let x = a.r;
  for (let s = a.s; s > 0; s -= 5) {
    const j = (i >>> s) & 31;
    let c = x[j];
    if (c.e !== tok) { c = c.slice(); c.e = tok; x[j] = c; }
    x = c;
  }
  x[i & 31] = v;
  return a;
}
const retire = (a) => { a.e = undefined; };
export function set(a, i, v) {
  if (isA(a)) {
    if (i < 0 || i >= a.length || a[i] === v) return a; // a no-op keeps its identity (research 38 §7)
    if (a.rc === 1) { a[i] = v; return a; }
    release(a);
    return a.length <= LIM ? fresh(cset(a, i, v)) : trieOut(T.set(T.fromArray(a), i, v));
  }
  if (i < 0 || i >= a.n || T.get(a, i) === v) return a;
  if (a.rc === 1) return ownedSet(a, i, v);
  release(a); retire(a);
  return trieOut(T.set(a, i, v));
}
// push, pop and append on a trie stay persistent (a new root, O(log n) copied), unique or not
export function push(a, v) {
  if (isA(a)) {
    if (a.rc === 1) { a.push(v); return a; }
    release(a);
    return a.length < LIM ? fresh(cpush(a, v)) : trieOut(T.push(T.fromArray(a), v));
  }
  release(a); retire(a);
  return trieOut(T.push(a, v));
}
export function pop(a) {
  if (isA(a)) {
    if (a.length === 0) return a;
    if (a.rc === 1) { a.pop(); return a; }
    release(a);
    return a.length <= LIM ? fresh(a.slice(0, -1)) : trieOut(T.pop(T.fromArray(a)));
  }
  release(a); retire(a);
  return trieOut(T.pop(a));
}
// a is owned, b borrowed
export function concat(a, b) {
  const nb = length(b);
  if (nb === 0) return a;
  if (isA(a) && a.rc === 1) {
    if (isA(b)) for (let i = 0; i < nb; i++) a.push(b[i]);
    else T.forEach(b, (x) => { a.push(x); });
    return a;
  }
  if (length(a) === 0) { release(a); return isA(b) ? dup(b) : fresh(T.toArray(b)); }
  release(a);
  if (!isA(a)) retire(a);
  if (isA(a)) return fresh(ccat(a, b));
  return trieOut(T.concat(a, isA(b) ? T.fromArray(b) : b));
}
// a borrowed
export function slice(a, s, e) {
  if (isA(a)) { const r = C.slice(a, s, e); return r === a ? dup(a) : fresh(r); }
  const n = a.n;
  if (s < 0) s = Math.max(0, n + s);
  if (e < 0) e = Math.max(0, n + e);
  if (e > n) e = n;
  if (s === 0 && e === n) return dup(a);
  return fresh(T.toArray(a).slice(s, e));
}
export const fromCons = (l) => fresh(C.fromCons(l));
export const toCons = (a, nil) => (isA(a) ? C.toCons(a, nil) : T.toCons(a, nil));
export const sort = (a, cmp) => fresh((isA(a) ? a.slice() : T.toArray(a)).sort(cmp));
export const toArray = plain;
// the decoder hands over a fresh array it built and forgets: adopted, unique
export const adopt = fresh;
// JavaScript keeps what it is given: pinned shared, and never written in place again
export const pin = (a) => { a.rc = PIN; return a; };
export const isPlain = isA;
