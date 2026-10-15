// Markup split by generated kind: tN HTML templates, kN mount factories,
// pN patch functions, bN, and direct's dg/dp/dr; alone and ordered. Also
// the HTML template strings of the Solid reference, for comparison.
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, readGz, apply, walk} from './lib.mjs';
import {units} from './units.mjs';

const out = {};
const htmlOf = code => {
  let raw = 0, n = 0;
  walk(acorn.parse(code, {ecmaVersion: 'latest', sourceType: 'module'}), x => {
    if (x.type === 'Literal' && typeof x.value === 'string' && /^</.test(x.value)) { raw += Buffer.byteLength(x.raw); n++; }
    if (x.type === 'TemplateLiteral' && x.quasis[0]?.value.raw.startsWith('<')) { raw += Buffer.byteLength(code.slice(x.start, x.end)); n++; }
  });
  return {count: n, raw};
};
for (const p of ['tea', 'direct']) {
  const src = readGz(`bench/output-size/results/beni-${p}.mjs.gz`), {units: us} = units(src, JSON.parse(readGz(`bench/output-size/results/beni-${p}.mjs.map.gz`)));
  const base = br(src), rows = []; let edits = [], prev = base;
  for (const [g, re] of [['t: HTML templates', /^t\d+$/], ['k: mount factories (clone, walk, wire)', /^k\d+$/], ['p: patch functions', /^p\d+$/], ['b: shared', /^b\d+$/], ['dg: group descriptors', /^dg\d+_\d+$/], ['dp: patch entries', /^dp\d+_\d+$/], ['dr: restate entries', /^dr\d+_\d+$/]]) {
    const gs = us.filter(u => u.owner.startsWith('app/') && re.test(u.orig ?? '')); if (!gs.length) continue;
    const e = gs.map(u => u.stub).filter(s => s.node), alone = base - br(apply(src, e)); edits.push(...e);
    const s = apply(src, edits); acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'}); const now = br(s);
    rows.push({group: g, units: gs.length, raw: gs.reduce((n, u) => n + u.raw, 0), alone, ordered: prev - now}); prev = now;
  }
  out[p] = {rows, htmlStrings: htmlOf(src)}; console.log(p, out[p].htmlStrings); for (const r of rows) console.log(' ', JSON.stringify(r));
}
out.solidHtmlStrings = htmlOf(readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.gz'));
console.log('solid', out.solidHtmlStrings);
fs.writeFileSync('bench/output-size/results/markup.json', JSON.stringify(out, null, 2) + '\n');
