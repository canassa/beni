// Which `compare` shape is slower, each in a process of its own.
import { spawnSync } from 'node:child_process';
const which = process.argv[2];
const all = ['hand', 'beni', 'beniBreak', 'stopOrd', 'stopTern'];
if (!which) {
  for (let r = 0; r < 3; r++)
    for (const w of all) process.stdout.write(spawnSync(process.execPath, [process.argv[1], w], { encoding: 'utf8' }).stdout);
  process.exit(0);
}
const base = (xs) => xs, offset = (xs) => 0;
const hand = (m0, xs, ys) => {
  const n = xs.length, m = ys.length, a = base(xs), i = offset(xs), b = base(ys), j = offset(ys);
  for (let k = 0; k < n && k < m; k++) {
    const o = m0(a[i + k], b[j + k]);
    if (o !== 'EQ') return o;
  }
  return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
};
const fa = (a2, b2, c2, d2, e2, f2, g2, h2) => {
  for (;;) {
    if (!(h2 < d2 && h2 < g2)) return d2 === g2 ? 'EQ' : d2 < g2 ? 'LT' : 'GT';
    let i2 = a2(b2[c2 + h2], e2[f2 + h2]);
    if (i2 !== 'EQ') return i2;
    h2++;
  }
};
const beni = (a2, b2, c2) => fa(a2, base(b2), offset(b2), b2.length, base(c2), offset(c2), c2.length, 0);
// the beni loop written inside the one function
const oneFnForever = (m0, xs, ys) => {
  const n = xs.length, m = ys.length, a = base(xs), i = offset(xs), b = base(ys), j = offset(ys);
  let k = 0;
  for (;;) {
    if (!(k < n && k < m)) return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
    let o = m0(a[i + k], b[j + k]);
    if (o !== 'EQ') return o;
    k++;
  }
};
// the hand loop in a helper of parameters
const fh = (m0, a, i, n, b, j, m) => {
  for (let k = 0; k < n && k < m; k++) {
    const o = m0(a[i + k], b[j + k]);
    if (o !== 'EQ') return o;
  }
  return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
};
const helperFor = (m0, xs, ys) => fh(m0, base(xs), offset(xs), xs.length, base(ys), offset(ys), ys.length);
const fc = (a2, b2, c2, d2, e2, f2, g2, h2) => {
  for (;;) {
    if (!(h2 < d2 && h2 < g2)) break;
    let i2 = a2(b2[c2 + h2], e2[f2 + h2]);
    if (i2 !== 'EQ') return i2;
    h2++;
  }
  return d2 === g2 ? 'EQ' : d2 < g2 ? 'LT' : 'GT';
};
const beniBreak = (a2, b2, c2) => fc(a2, base(b2), offset(b2), b2.length, base(c2), offset(c2), c2.length, 0);
const fd = (a2, b2, c2, d2, e2, f2, h2) => {
  for (;;) {
    if (!(h2 < d2)) return 'EQ';
    let i2 = a2(b2[c2 + h2], e2[f2 + h2]);
    if (i2 !== 'EQ') return i2;
    h2++;
  }
};
const beniNoLen = (a2, b2, c2) => fd(a2, base(b2), offset(b2), b2.length, base(c2), offset(c2), 0);
const ord = (n, m) => (n === m ? 'EQ' : n < m ? 'LT' : 'GT');
const fe = (a2, b2, c2, e2, f2, s, n, m, h2) => {
  for (;;) {
    if (h2 >= s) return ord(n, m);
    let i2 = a2(b2[c2 + h2], e2[f2 + h2]);
    if (i2 !== 'EQ') return i2;
    h2++;
  }
};
const stopOrd = (a2, b2, c2) => fe(a2, base(b2), offset(b2), base(c2), offset(c2), Math.min(b2.length, c2.length), b2.length, c2.length, 0);
const ff = (a2, b2, c2, e2, f2, s, n, m, h2) => {
  for (;;) {
    if (h2 >= s) return n === m ? 'EQ' : n < m ? 'LT' : 'GT';
    let i2 = a2(b2[c2 + h2], e2[f2 + h2]);
    if (i2 !== 'EQ') return i2;
    h2++;
  }
};
const stopTern = (a2, b2, c2) => ff(a2, base(b2), offset(b2), base(c2), offset(c2), Math.min(b2.length, c2.length), b2.length, c2.length, 0);
const x = (a2, b2) => (a2 < b2 ? 'LT' : a2 > b2 ? 'GT' : 'EQ');
const f = { hand, beni, oneFnForever, helperFor, beniBreak, beniNoLen, stopOrd, stopTern }[which];
const xs = Array.from({ length: 10000 }, (_, i) => i + 1);
let sink = 0;
const t = [];
for (let r = 0; r < 40; r++) {
  const s = process.hrtime.bigint();
  let c = 0;
  while (process.hrtime.bigint() - s < 10_000_000n) { sink ^= f(x, xs, xs).length; c++; }
  t.push(Number(process.hrtime.bigint() - s) / c / 1000);
}
t.sort((a, b) => a - b);
console.log(which.padEnd(14), t[20].toFixed(2));
