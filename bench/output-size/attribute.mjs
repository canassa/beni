// Attribute every byte of Conduit's --release bundle by origin (research 99's
// two accounts). A unit is a top-level declarator, function or statement; its
// group is the source owning its raw bytes (every unit here is >=90% one
// source). App units are split again by kind, from the original beni name the
// release source map carries at the binding.
//   alone:   stub one group's units in the original bundle, recompress.
//   ordered: stub groups cumulatively in table order; the residual (keywords,
//            commas, stubs and compression interactions) closes the account.
// Stubbed variants are syntax-checked and never run: these are costs in
// context, not available savings.
import fs from 'node:fs';
import * as acorn from 'acorn';
import {size, br, readGz, apply, writeGz} from './lib.mjs';
import {units} from './units.mjs';

const results = 'bench/output-size/results';
const kindOf = (u, platform) => {
  const o = u.orig ?? '';
  if (/\$\$/.test(o)) return 'app: schemas (generated parse/print/description)';
  if (o === 'main') return 'app: main (direct: the mounted program and consumer matrix)';
  if (/^(p|k|t|b)\d+$|^(dg|dp|dr)\d+_\d+$/.test(o)) return 'app: markup (generated templates, patches, direct protocol)';
  if (/^(update|init|initEdit|changeRouteTo|updateForm|updateWith|save|validate|toSession|savingError|currentUsername)$/.test(o)) return 'app: update / init';
  if (/^view|Button$|^(frame|navbarLink|footer|loading|loadingError|avatar|avatarSrc|defaultAvatar|link|href|timestamp|tags|body|fields|formBody|slowThreshold)$/.test(o)) return 'app: view functions';
  return 'app: requests, routes, helpers';
};
const groupOf = (u, platform) => {
  if (u.owner === 'unmapped') return 'unmapped (JS siblings, shared constant constructors)';
  if (u.owner.startsWith('app/')) return kindOf(u, platform);
  if (/^platforms\/browser\/(Hosted|Cmd|Sub|Listen|Storage|Browser)$/.test(u.owner)) return 'platforms/browser: Hosted, Cmd, Sub, Listen, Storage, Browser';
  if (/^core\/(Basics|Maybe|Result|String)$/.test(u.owner)) return 'core: Basics, Maybe, Result, String';
  if (/^core\/Url/.test(u.owner)) return 'core: Url, Url.Parser, Url.Builder';
  if (u.owner === 'platforms/html/Html') return 'platforms/browser: Hosted, Cmd, Sub, Listen, Storage, Browser';
  return u.owner;
};
const order = ['core/Task', 'core/List', 'core/Dict', 'core/Schema', 'core: Basics, Maybe, Result, String', 'core: Url, Url.Parser, Url.Builder',
  'unmapped (JS siblings, shared constant constructors)',
  'platforms/browser/Rt', 'platforms/browser/Http', 'platforms/browser/Browser/Navigation', 'platforms/browser: Hosted, Cmd, Sub, Listen, Storage, Browser',
  'platforms/browser-tea/Tea', 'platforms/browser-direct/Tea', 'platforms/browser-direct/Direct',
  'app: schemas (generated parse/print/description)', 'app: markup (generated templates, patches, direct protocol)', 'app: main (direct: the mounted program and consumer matrix)', 'app: update / init', 'app: view functions', 'app: requests, routes, helpers'];

const report = {method: 'Per-response brotli 11 with size hint. Units = top-level declarators/functions/statements, owned by the source with most mapped raw bytes. Stub = initializer→0, body→{}, statement→0;. alone = one group from the original; ordered = cumulative in table order. Nonexecutable; costs in context, not savings.', subjects: {}};
for (const platform of ['tea', 'direct']) {
  const src = readGz(`${results}/beni-${platform}.mjs.gz`), map = JSON.parse(readGz(`${results}/beni-${platform}.mjs.map.gz`));
  const {units: us, whole} = units(src, map);
  const baseline = size(src);
  const groups = new Map();
  for (const u of us) { const g = groupOf(u, platform); if (!groups.has(g)) groups.set(g, []); groups.get(g).push(u); }
  for (const g of groups.keys()) if (!order.includes(g)) throw Error(`unordered group ${g}`);
  const check = s => { acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'}); return s; };
  const rows = [];
  let edits = [], prev = baseline.brotli;
  for (const g of order) {
    const gs = groups.get(g); if (!gs) continue;
    const e = gs.map(u => u.stub).filter(s => s.node);
    const alone = baseline.brotli - br(check(apply(src, e)));
    edits.push(...e);
    const cumulative = br(check(apply(src, edits)));
    rows.push({group: g, units: gs.length, raw: gs.reduce((n, u) => n + u.raw, 0), alone, ordered: prev - cumulative});
    prev = cumulative;
  }
  const residualText = apply(src, edits);
  writeGz(`${results}/attribution-${platform}-residual.mjs.gz`, residualText);
  rows.push({group: 'residual (declaration keywords, separators, stubs, interactions)', units: 0, raw: baseline.raw - rows.reduce((n, r) => n + r.raw, 0), alone: null, ordered: prev});
  // per app module, alone
  const modules = {};
  for (const u of us) if (u.owner.startsWith('app/')) (modules[u.owner] ??= []).push(u);
  const moduleRows = Object.entries(modules).map(([m, gs]) => ({module: m, units: gs.length, raw: gs.reduce((n, u) => n + u.raw, 0),
    alone: baseline.brotli - br(check(apply(src, gs.map(u => u.stub).filter(s => s.node))))})).sort((a, b) => b.alone - a.alone);
  const impure = us.filter(u => u.purity < 0.9);
  report.subjects[platform] = {baseline, mappedRawBySource: whole, impureUnits: impure.length, rows, moduleRows};
  console.log(platform, baseline.brotli);
  for (const r of rows) console.log(`  ${r.group.padEnd(70)} ${String(r.units).padStart(5)} ${String(r.raw).padStart(7)} ${String(r.alone).padStart(6)} ${String(r.ordered).padStart(6)}`);
  for (const r of moduleRows) console.log(`  ${r.module.padEnd(30)} ${r.units} ${r.raw} ${r.alone}`);
}
fs.writeFileSync(`${results}/attribution.json`, JSON.stringify(report, null, 2) + '\n');
