// cmp.mjs <v2 dump> <slots dump>: per demand position, v2's verdict(s) and the slot evaluator's.
import fs from 'fs';
const parse = (f, slots) => {
  const m = new Map();
  for (const l of fs.readFileSync(f, 'utf8').split('\n')) {
    const r = /^ {2,4}(\d+):(\d+) (.*?): (accepted|rejected)(.*)$/.exec(l);
    if (!r) continue;
    const k = `${r[1]}:${r[2]}`;
    const e = m.get(k) || { acc: 0, rej: 0, text: [] };
    if (r[4] === 'accepted') e.acc++; else e.rej++;
    e.text.push(`${r[3]}: ${r[4]}${r[5]}`);
    m.set(k, e);
  }
  return m;
};
const a = parse(process.argv[2]), b = parse(process.argv[3]);
const keys = [...new Set([...a.keys(), ...b.keys()])].sort((x, y) => { const [l1, c1] = x.split(':').map(Number), [l2, c2] = y.split(':').map(Number); return l1 - l2 || c1 - c2; });
let same = 0, a2r = 0, r2a = 0, only = 0, partial = 0;
for (const k of keys) {
  const x = a.get(k), y = b.get(k);
  const vx = x ? (x.rej ? (x.acc ? 'partial' : 'refused') : 'accepted') : 'none';
  const vy = y ? (y.rej ? (y.acc ? 'partial' : 'refused') : 'accepted') : 'none';
  let tag = vx === vy ? 'same' : (vx === 'accepted' && vy !== 'accepted' && vy !== 'none') ? 'A→R' : (vy === 'accepted' && vx !== 'accepted' && vx !== 'none') ? 'R→A' : 'diff';
  if (tag === 'same') same++; else if (tag === 'A→R') a2r++; else if (tag === 'R→A') r2a++; else only++;
  console.log(`${tag.padEnd(4)} ${k.padEnd(7)} v2 ${vx.padEnd(8)} slots ${vy.padEnd(8)} | ${(y ? y.text[0] : x.text[0])}`);
}
console.log(`summary: same ${same}, accept→refuse ${a2r}, refuse→accept ${r2a}, other ${only}`);
