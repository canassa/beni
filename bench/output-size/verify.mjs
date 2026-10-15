// Run Conduit's three corpus scripts (Editor, Reader, Tour) against a
// bundle and compare each transcript with the corpus golden, under happy-dom
// exactly as the gates' driver does (direct with --no-comments, as the corpus
// walker runs it). Also compared with the unchanged bundle's transcript.
// usage: node verify.mjs <tea|direct> <bundle.mjs> [label]
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const [platform, bundle, label = 'check'] = process.argv.slice(2);
const dir = `zig-out/verify/${label}-${platform}`;
fs.rmSync(dir, {recursive: true, force: true});
fs.cpSync(`zig-out/output-size/${platform}`, dir, {recursive: true});
fs.copyFileSync(bundle, `${dir}/_main.mjs`);
let ok = true;
const flags = platform === 'direct' ? ['--no-comments'] : [];

for (const c of ['ConduitEditor', 'ConduitReader', 'ConduitTour']) {
  const fx = `tests/corpus/browser/${platform}/${c}/_expected`;
  const r = spawnSync('node', ['tests/browser/driver.mjs', '--dom=tests/browser/happy-dom.mjs', ...flags, `${dir}/_main.mjs`, `${fx}.steps`], {encoding: 'utf8'});
  const base = spawnSync('node', ['tests/browser/driver.mjs', '--dom=tests/browser/happy-dom.mjs', ...flags, `zig-out/output-size/${platform}/_main.mjs`, `${fx}.steps`], {encoding: 'utf8'});
  const golden = fs.readFileSync(`${fx}.expected`, 'utf8');
  const same = r.status === 0 && r.stdout === base.stdout && r.stdout === golden;
  if (!same) { ok = false; fs.writeFileSync(`${dir}/${c}.txt`, r.stdout + '\n--- stderr ---\n' + r.stderr); }
  console.log(`${label} ${platform} ${c}: ${same ? 'matches the golden and the unchanged bundle' : `DIFFERS (exit ${r.status}, transcript in ${dir}/${c}.txt)`}`);
}
process.exit(ok ? 0 : 1);
