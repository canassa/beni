// The update/init/requests area unit by unit: each declaration's raw bytes and
// what deleting it alone takes out of the response, largest first.
//   node bench/app-code-size/logic-units.mjs [results dir]
import fs from 'node:fs';
import {br, readGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';
import {areaOf, subAreaOf} from './classify.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const out = {};
for (const p of ['tea', 'direct']) {
  const src = readGz(`${dir}/beni-${p}.mjs.gz`), {units: us} = units(src, JSON.parse(readGz(`${dir}/beni-${p}.mjs.map.gz`)));
  const base = br(src);
  out[p] = us.filter(u => areaOf(u) === 'logic').map(u => ({unit: `${u.owner.slice(4)}.${u.orig}`, sub: subAreaOf(u), raw: u.raw, alone: base - br(src.slice(0, u.start) + src.slice(u.end))}))
    .sort((a, b) => b.alone - a.alone);
  console.log(p); for (const r of out[p].slice(0, 25)) console.log(`  ${r.unit.padEnd(36)} ${r.sub.padEnd(26)} ${String(r.raw).padStart(6)} ${String(r.alone).padStart(5)}`);
}
fs.writeFileSync(`${dir}/logic-units.json`, JSON.stringify(out, null, 2) + '\n');
