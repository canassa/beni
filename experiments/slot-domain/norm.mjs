// norm.mjs <dump>: per declaration, its verdicts (positions dropped) and contract, sorted.
import fs from 'fs';
const out = new Map(); let pending = [];
for (const l of fs.readFileSync(process.argv[2], 'utf8').split('\n')) {
  let m = /^ {4}\d+:\d+ (.*)$/.exec(l);
  if (m) { pending.push(m[1].replace(/ and is read at \d+:\d+/, '')); continue; }
  m = /^  (contract|unsupported) (\S+?): (.*)$/.exec(l);
  if (m) { const e = out.get(m[2]) || []; e.push(...pending.map(x => 'verdict ' + x), m[1] + ' ' + m[3]); out.set(m[2], e); pending = []; }
}
for (const k of [...out.keys()].sort()) console.log(k + '\n  ' + out.get(k).sort().join('\n  '));
