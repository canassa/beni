// research/42: direct checks of rc/ports/rc-adaptive.js's in-place paths, which the scenario test
// reaches only in the orders the scenarios happen to use. Prints `ok` or the first failure.
import * as P from './ports/rc-adaptive.js';
const R1 = RC_MODE === 'r1';
const snap = (a) => JSON.stringify(P.toArray(a));
const fail = (m) => { console.log('FAIL', m); process.exit(1); };
const big = () => { const a = []; for (let i = 0; i < 5000; i++) a.push(i); return P.adopt(a); };

// a unique plain array is written in place and keeps its identity
{ const a = big(); const b = P.set(a, 3, -3); if (b !== a || P.get(a, 3) !== -3) fail('plain in place'); }
// a shared plain array is not touched
{ const a = big(); a.rc = 2; const s = snap(a); const b = P.set(a, 3, -3); if (snap(a) !== s || P.get(b, 3) !== -3) fail('plain shared'); }
// a trie: made by a write to a shared plain array; then unique writes in place, a share, a
// persistent write, and writes through both roots — neither may see the other's
{
  const a = big(); a.rc = 2;
  let t = P.set(a, 10, -10);                       // shared plain above T: a trie, fresh
  if (P.isPlain(t)) fail('expected a trie');
  const t1 = P.set(t, 20, -20);                    // unique: in place
  if (t1 !== t) fail('trie in place');
  for (let i = 0; i < 5000; i += 97) t = P.set(t, i, -i - 1);
  const before = snap(t);
  t.rc = R1 ? 2 : 2;                               // a second holder appears
  const u = P.set(t, 4000, 7);                     // persistent: a new root
  if (u === t || snap(t) !== before) fail('shared trie written');
  for (let i = 1; i < 300; i += 31) P.set(u, i, 1e6 + i); // u is unique: in place, its own paths copied
  if (snap(t) !== before) fail('writes through the new root reached the old one');
  const uSnap = snap(u);
  if (R1) {
    t.rc = 1;                                      // the other holder dropped its count (r1 only)
    for (let i = 2; i < 5000; i += 29) P.set(t, i, -7);
    if (snap(u) !== uSnap) fail('writes through the old root, unique again, reached the new one');
  }
  // tail writes
  const w = P.set(u, 4999, 42);
  if (P.get(w, 4999) !== 42) fail('tail');
}
// push and pop in place on a unique plain array; a pinned one is copied
{ const a = P.adopt([1, 2, 3]); const b = P.push(a, 4); if (b !== a || a.length !== 4) fail('push in place');
  const p = P.pin(P.adopt([1, 2, 3])); const q = P.push(p, 4); if (q === p || p.length !== 3) fail('push pinned'); }
console.log('ok');
