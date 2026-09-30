// The persistence test of ports/first-tail.js's claimable tail (research/38 §17): random `push`,
// `pop`, `set`, `append` and `x :: rest` on randomly chosen OLD versions, every version checked
// against a plain-array model after every step. `node lists/claim-test.mjs`
import * as E from '../ports/first-tail.js';

let seed = 12345;
const rnd = (k) => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % k; };
const versions = [[E.$nil, []]];
let checks = 0;
function check(v, model) {
  const got = E.toJs(v);
  if (E.length(v) !== model.length || got.length !== model.length || got.some((x, i) => x !== model[i])) throw new Error(`mismatch after ${checks} checks: ${E.kind(v)} ${got.length} vs ${model.length}`);
  for (let i = 0; i < model.length; i += 1 + rnd(7)) if (E.unsafeGet(v, i) !== model[i]) throw new Error('unsafeGet mismatch');
  let k = 0; E.walk(v, (x, j) => { if (x !== model[j] || j !== k++) throw new Error('walk mismatch'); });
  checks++;
}
for (let step = 0; step < 40000; step++) {
  // prefer recent versions, but reach back to old ones often
  const pick = rnd(3) === 0 ? rnd(versions.length) : Math.max(0, versions.length - 1 - rnd(4));
  const [v, m] = versions[pick];
  const op = rnd(10);
  let nv, nm;
  if (op < 5) { const x = step; nv = E.push(v, x); nm = [...m, x]; }
  else if (op < 7) { nv = E.pop(v); nm = m.slice(0, -1); }
  else if (op < 8 && m.length) { const i = rnd(m.length); nv = E.set(v, i, -step); nm = m.slice(); nm[i] = -step; }
  else if (op < 9) { const extra = Array.from({ length: rnd(step % 7 === 0 ? 3000 : 40) }, (_, j) => step * 100 + j); nv = E.append(v, extra); nm = [...m, ...extra]; }
  else if (m.length) { nv = E.$tl(v); nm = m.slice(1); }
  else continue;
  versions.push([nv, nm]);
  if (versions.length > 3000) versions.splice(1 + rnd(1000), 1);
  if (step % 50 === 0) for (const [w, wm] of versions) check(w, wm);
  else { check(nv, nm); check(v, m); }
}
for (const [w, wm] of versions) check(w, wm);
console.log(`claimable tail: ${checks} checks, all versions intact; largest ${Math.max(...versions.map(([, m]) => m.length))}`);
