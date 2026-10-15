// What a minifier would still take out of each area: run Terser (research
// 102's default: compress passes 2 + mangle, module, toplevel) with the
// release map as its input map, then price each area in both bundles the same
// way: the whole response minus the response without that area's units.
// Units are owned through the composed map, so a unit Terser inlined into
// another is charged to the unit it now lives in.
//   node bench/app-code-size/terser.mjs [results dir]
import fs from 'node:fs';
import {minify} from '../output-size/node_modules/terser/main.js';
import {size, br, readGz, writeGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';
import {areaOf, subAreaOf} from './classify.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const out = {method: 'Terser 5 compress {passes:2} + mangle, module, toplevel, input map = release map. Area cost = brotli(all) - brotli(all minus the area units).', subjects: {}};
const cost = (src, map) => {
  const {units: us} = units(src, map);
  const base = br(src), res = {total: base};
  for (const ar of ['views', 'logic']) {
    const keep = us.filter(u => areaOf(u) === ar).sort((a, b) => b.start - a.start);
    let s = src; for (const u of keep) s = s.slice(0, u.start) + s.slice(u.end);
    res[ar] = base - br(s);
    const subs = {};
    for (const u of us) if (areaOf(u) === ar) subs[subAreaOf(u)] = (subs[subAreaOf(u)] ?? 0) + Buffer.byteLength(src.slice(u.start, u.end));
    res[`${ar}Raw`] = subs;
  }
  return res;
};
for (const p of ['tea', 'direct']) {
  const src = readGz(`${dir}/beni-${p}.mjs.gz`), map = JSON.parse(readGz(`${dir}/beni-${p}.mjs.map.gz`));
  const r = await minify(src, {module: true, ecma: 2020, toplevel: true, compress: {passes: 2}, mangle: true, sourceMap: {content: map, asObject: true}});
  writeGz(`${dir}/terser-${p}.mjs.gz`, r.code);
  const before = cost(src, map), after = cost(r.code, r.map);
  out.subjects[p] = {before, after, sizes: {before: size(src), after: size(r.code)}};
  console.log(p, JSON.stringify(out.subjects[p]));
}
fs.writeFileSync(`${dir}/terser.json`, JSON.stringify(out, null, 2) + '\n');
