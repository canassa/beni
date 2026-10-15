// Run research 103's executable prototypes over the tea bundle, alone and
// stacked in order, each verified against the three Conduit corpus scripts,
// and record their sizes (and Terser's on top of the stack).
//   node bench/app-code-size/prototypes.mjs [results dir]
import fs from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import {minify} from '../output-size/node_modules/terser/main.js';
import {size, readGz, writeGz} from '../output-size/lib.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results', work = 'zig-out/app-code-size';
fs.mkdirSync(work, {recursive: true});
const base = `${dir}/beni-tea.mjs.gz`;
const steps = [['guards', 'proto-guards.mjs'], ['closures', 'proto-closures.mjs'], ['static', 'proto-static.mjs'], ['live', 'proto-live.mjs']];
// the three corpus scripts, and on tea also the feed favorite no corpus script clicks
const verify = (file, label, platform = 'tea') => {
  const r = spawnSync('node', ['bench/output-size/verify.mjs', platform, file, label], {encoding: 'utf8'});
  if (r.status !== 0 || platform !== 'tea') return r;
  return spawnSync('node', ['bench/app-code-size/verify-favorite.mjs', file, label], {encoding: 'utf8'});
};
const out = {baseline: size(readGz(base)), alone: {}, stacked: []};
for (const [name, script] of steps) {
  const f = `${work}/alone-${name}.mjs`;
  execFileSync('node', [`bench/app-code-size/${script}`, base, f]);
  const v = verify(f, `alone-${name}`);
  out.alone[name] = {...size(fs.readFileSync(f, 'utf8')), corpus: v.status === 0 ? 'matches' : 'DIFFERS'};
  out.alone[name].saved = out.baseline.brotli - out.alone[name].brotli;
  console.log('alone', name, JSON.stringify(out.alone[name]));
}
let prev = base;
for (const [name, script] of steps) {
  const f = `${work}/stack-${name}.mjs`;
  execFileSync('node', [`bench/app-code-size/${script}`, prev, f]);
  const v = verify(f, `stack-${name}`);
  const s = size(fs.readFileSync(f, 'utf8'));
  out.stacked.push({step: name, ...s, savedFromBaseline: out.baseline.brotli - s.brotli, corpus: v.status === 0 ? 'matches' : 'DIFFERS'});
  console.log('stack', name, JSON.stringify(out.stacked.at(-1)));
  prev = f;
}
writeGz(`${dir}/proto-stack-tea.mjs.gz`, fs.readFileSync(prev, 'utf8'));
const t = await minify(fs.readFileSync(prev, 'utf8'), {module: true, ecma: 2020, toplevel: true, compress: {passes: 2}, mangle: true});
out.stackPlusTerser = size(t.code);
console.log('stack + terser', JSON.stringify(out.stackPlusTerser));
// two probes priced alone: constructor padding (both platforms) and direct's unread kept-value stores
out.probes = {};
for (const p of ['tea', 'direct']) {
  const r = JSON.parse(execFileSync('node', ['bench/app-code-size/proto-padding.mjs', p, dir], {encoding: 'utf8'}));
  r.corpus = verify(`${work}/proto-padding-${p}.mjs`, `padding-${p}`, p).status === 0 ? 'matches' : 'DIFFERS';
  out.probes[`padding-${p}`] = r; console.log('padding', p, JSON.stringify(r));
}
{
  const f = `${work}/proto-dead-direct.mjs`;
  const r = JSON.parse(execFileSync('node', ['bench/app-code-size/proto-dead-stores.mjs', `${dir}/beni-direct.mjs.gz`, f], {encoding: 'utf8'}));
  r.corpus = spawnSync('node', ['bench/output-size/verify.mjs', 'direct', f, 'dead-direct'], {encoding: 'utf8'}).status === 0 ? 'matches' : 'DIFFERS';
  out.probes['dead-stores-direct'] = r; console.log('dead stores', JSON.stringify(r));
}
fs.writeFileSync(`${dir}/prototypes.json`, JSON.stringify(out, null, 2) + '\n');
