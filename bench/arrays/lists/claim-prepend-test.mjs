// The persistence test of ports/first-tail-prepend.js (E1tp, research/46 §11): its claimable head
// and its claimable tail, on shared versions. Random `x :: xs`, `push`, `pop`, `$tl`, `set`,
// `append` and `slice` on randomly chosen OLD versions, every version checked against a plain-array
// model (by `toJs`, `unsafeGet`, `$hd`, the runtime's walk and `chunks`) after every step; then long
// single-lineage runs that grow the root left and right past three levels. `node lists/claim-prepend-test.mjs`
import * as E from '../ports/first-tail-prepend.js';

let seed = 4711;
const rnd = (k) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >>> 8) % k; }; // high bits: an LCG's low bits cycle fast
let checks = 0;
const kinds = {};
function check(v, model) {
  const got = E.toJs(v);
  if (E.length(v) !== model.length || got.length !== model.length || got.some((x, i) => x !== model[i])) throw new Error(`mismatch after ${checks} checks: ${E.kind(v)} ${got.length} vs ${model.length}`);
  if (model.length && E.$hd(v) !== model[0]) throw new Error('$hd mismatch');
  if (E.$isNil(v) !== (model.length === 0)) throw new Error('$isNil mismatch');
  for (let i = 0; i < model.length; i += 1 + rnd(7)) if (E.unsafeGet(v, i) !== model[i]) throw new Error(`unsafeGet mismatch at ${i} of ${model.length}`);
  let k = 0; E.walk(v, (x, j) => { if (x !== model[j] || j !== k++) throw new Error('walk mismatch'); });
  if (k !== model.length) throw new Error('walk length');
  if (E.kind(v) === 'trie') { const c = [].concat(...E.chunksOf(v)); if (c.length !== model.length || c.some((x, i) => x !== model[i])) throw new Error('chunks mismatch'); }
  kinds[E.kind(v)] = (kinds[E.kind(v)] ?? 0) + 1;
  checks++;
}

// 1. random operations on random old versions
const versions = [[E.$nil, []]];
let largest = 0;
const seen = {}, NAMES = [...Array(7).fill('cons'), 're-cons', 're-cons', ...Array(4).fill('push'), 'pop', 'tl', 'tl', 'set', 'append', 'slice', 'walk'];
for (let step = 0; step < 60000; step++) {
  const pick = rnd(3) === 0 ? rnd(versions.length) : Math.max(0, versions.length - 1 - rnd(4));
  const [v, m] = versions[pick];
  const op = rnd(20);
  let nv, nm;
  if (op < 7) { const x = step; nv = E.$cons(x, v); nm = [x, ...m]; }
  else if (op < 9 && m.length) { nv = E.$cons(m[0], E.$tl(v)); nm = m.slice(); } // re-cons what was matched
  else if (op < 13) { const x = -step; nv = E.push(v, x); nm = [...m, x]; }
  else if (op < 14) { nv = E.pop(v); nm = m.slice(0, -1); }
  else if (op < 16 && m.length) { nv = E.$tl(v); nm = m.slice(1); }
  else if (op < 17 && m.length) { const i = rnd(m.length); nv = E.set(v, i, 1e9 + step); nm = m.slice(); nm[i] = 1e9 + step; }
  else if (op < 18) { const extra = Array.from({ length: rnd(step % 11 === 0 ? 3000 : 40) }, (_, j) => step * 100000 + j); nv = E.append(v, extra); nm = [...m, ...extra]; }
  else if (op < 19 && m.length) { const a = rnd(m.length + 1), b = rnd(m.length + 1); nv = E.slice(v, Math.min(a, b), Math.max(a, b)); nm = m.slice(Math.min(a, b), Math.max(a, b)); }
  else if (m.length > 1) { let w = v; const k = 1 + rnd(Math.min(m.length - 1, 80)); for (let j = 0; j < k; j++) w = E.$tl(w); nv = w; nm = m.slice(k); } // a walk that stops
  else continue;
  const tr = `${NAMES[op]} ${E.kind(v)}`; seen[tr] = (seen[tr] ?? 0) + 1;
  versions.push([nv, nm]);
  largest = Math.max(largest, nm.length);
  if (versions.length > 3000) versions.splice(1 + rnd(1000), 1);
  if (step % 60 === 0) for (const [w, wm] of versions) check(w, wm);
  else { check(nv, nm); check(v, m); }
}
for (const [w, wm] of versions) check(w, wm);
const random = checks;

// 2. one lineage each: 60 000 prepends (the root grows left three times), then a walk by `$tl`
// that re-conses every 97th step, then pushes onto what is left and prepends onto that; old
// versions kept along the way and checked at the end
const kept = [];
let v = E.$nil, m = [];
for (let i = 0; i < 60000; i++) { v = E.$cons(i, v); m.unshift(i); if (i % 7919 === 0) kept.push([v, m.slice()]); }
check(v, m);
for (let i = 0; i < 45000; i++) {
  if (i % 97 === 0) { const w = E.$cons(-i, v); kept.push([w, [-i, ...m]]); }
  v = E.$tl(v); m.shift();
  if (i % 4999 === 0) kept.push([v, m.slice()]);
}
check(v, m);
for (let i = 0; i < 40000; i++) { v = E.push(v, 1e6 + i); m.push(1e6 + i); if (i % 6007 === 0) kept.push([v, m.slice()]); }
for (let i = 0; i < 40000; i++) { v = E.$cons(2e6 + i, v); m.unshift(2e6 + i); if (i % 6007 === 0) kept.push([v, m.slice()]); }
for (let i = 0; i < 70000; i++) { v = E.pop(v); m.pop(); if (i % 9001 === 0) kept.push([v, m.slice()]); }
kept.push([v, m.slice()]);
for (const [w, wm] of kept) check(w, wm);

console.log(`operations by input form: ${Object.entries(seen).sort().map(([k, n]) => `${k} ${n}`).join(", ")}`);
console.log(`E1tp claimable head and tail: ${random} checks of random operations on shared versions (largest ${largest}), ${checks - random} of long lineages; all versions intact; forms checked ${JSON.stringify(kinds)}`);
