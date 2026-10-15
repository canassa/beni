// Build a (hand-edited) copy of Conduit on both platforms and price it
// against the archived baseline. usage: node proto.mjs <label> <src-dir>
// Appends to results/prototypes.json.
import fs from 'node:fs';
import {execFileSync as exec} from 'node:child_process';
import {size, readGz, writeGz} from './lib.mjs';

const [label, dir] = process.argv.slice(2);
const beni = process.env.BENI ?? 'zig-out/bin/beni', results = 'bench/output-size/results';
const rec = {label, dir, note: process.env.NOTE ?? '', platforms: {}};
for (const p of ['tea', 'direct']) {
  const out = `zig-out/proto/out-${label}-${p}`;
  exec(beni, ['build', `--platform=browser-${p}`, '--release', '--no-cache', `--out=${out}`, dir], {stdio: 'inherit'});
  exec(beni, ['build', `--platform=browser-${p}`, '--release', '--no-cache', '--source-maps', `--out=${out}-mapped`, dir], {stdio: 'inherit'});
  const s = fs.readFileSync(`${out}/_main.mjs`, 'utf8');
  if (fs.readFileSync(`${out}-mapped/_main.mjs`, 'utf8').replace(/\/\/# sourceMappingURL=.*\n?$/, '') !== s) throw Error('mapped build differs');
  writeGz(`${results}/proto-${label}-${p}.mjs.gz`, s);
  writeGz(`${results}/proto-${label}-${p}.mjs.map.gz`, fs.readFileSync(`${out}-mapped/_main.mjs.map`, 'utf8'));
  const base = size(readGz(`${results}/beni-${p}.mjs.gz`)), now = size(s);
  rec.platforms[p] = {baseline: base.brotli, brotli: now.brotli, raw: now.raw, saved: base.brotli - now.brotli};
  console.log(label, p, rec.platforms[p]);
}
const file = `${results}/prototypes.json`;
const all = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : {};
all[label] = rec;
fs.writeFileSync(file, JSON.stringify(all, null, 2) + '\n');
