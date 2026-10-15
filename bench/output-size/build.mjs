// Build Conduit's --release bundles (plain and mapped) for both platforms,
// check mapped == plain, and archive them under results/.
// BENI selects the compiler (default zig-out/bin/beni).
import fs from 'node:fs';
import {execFileSync as exec} from 'node:child_process';
import {size, hash, writeGz} from './lib.mjs';

const beni = process.env.BENI ?? 'zig-out/bin/beni', work = 'zig-out/output-size', out = 'bench/output-size/results';
fs.mkdirSync(out, {recursive: true});
const manifest = {date: new Date().toISOString(), commit: exec('git', ['rev-parse', 'HEAD'], {encoding: 'utf8'}).trim(),
  node: process.version, compilerSha256: hash(fs.readFileSync(beni)), subjects: {}};
for (const p of ['tea', 'direct']) {
  for (const maps of [false, true])
    exec(beni, ['build', `--platform=browser-${p}`, '--release', '--no-cache', ...(maps ? ['--source-maps'] : []),
      `--out=${work}/${p}${maps ? '-mapped' : ''}`, 'examples/conduit/src'], {stdio: 'inherit'});
  const plain = fs.readFileSync(`${work}/${p}/_main.mjs`, 'utf8');
  const mapped = fs.readFileSync(`${work}/${p}-mapped/_main.mjs`, 'utf8').replace(/\/\/# sourceMappingURL=.*\n?$/, '');
  if (plain !== mapped) throw Error(`mapped build differs: ${p}`);
  const files = fs.readdirSync(`${work}/${p}`);
  if (files.filter(f => /\.m?js$/.test(f)).length !== 1) throw Error(`expected one JS file: ${files}`);
  fs.copyFileSync(`${work}/${p}/_main.mjs`, `${work}/${p}.mjs`);
  writeGz(`${out}/beni-${p}.mjs.gz`, plain);
  writeGz(`${out}/beni-${p}.mjs.map.gz`, fs.readFileSync(`${work}/${p}-mapped/_main.mjs.map`, 'utf8'));
  manifest.subjects[p] = {sha256: hash(plain), ...size(plain)};
  console.log(p, manifest.subjects[p]);
}
fs.writeFileSync(`${out}/manifest.json`, JSON.stringify(manifest, null, 2) + '\n');
