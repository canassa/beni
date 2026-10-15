// Solid single-chunk reference (research 101's build): the same unit and
// stub method as attribute.mjs, by source file group, alone and ordered.
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, readGz, apply} from './lib.mjs';
import {units} from './units.mjs';

const src = readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.gz');
const map = JSON.parse(readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.map.gz'));
const {units: us, whole} = units(src, map);
const groupOf = o => /^app\/(solid|web|store)\.js$/.test(o) ? `runtime: ${o.slice(4)}` : /createAgent/.test(o) ? 'app: HTTP agent (createAgent)' :
  /^app\/(create|index\.js$)/.test(o) ? 'app: stores, router, startup' : 'app: pages and components (views, handlers)';
const order = ['runtime: solid.js', 'runtime: web.js', 'runtime: store.js', 'app: HTTP agent (createAgent)', 'app: stores, router, startup', 'app: pages and components (views, handlers)'];
const base = br(src), rows = []; let edits = [], prev = base;
for (const g of order) {
  const gs = us.filter(u => groupOf(u.owner) === g), e = gs.map(u => u.stub).filter(s => s.node);
  const alone = base - br(apply(src, e)); edits.push(...e);
  const s = apply(src, edits); acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'});
  const now = br(s); rows.push({group: g, units: gs.length, raw: gs.reduce((n, u) => n + u.raw, 0), alone, ordered: prev - now}); prev = now;
}
rows.push({group: 'residual', raw: Buffer.byteLength(src) - rows.reduce((n, r) => n + r.raw, 0), ordered: prev});
fs.writeFileSync('bench/output-size/results/solid.json', JSON.stringify({baseline: base, mappedRawBySource: whole, rows}, null, 2) + '\n');
console.log(base); for (const r of rows) console.log(JSON.stringify(r));
