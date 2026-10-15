// Run feed-favorite.steps (favorite and unfavorite from the feed list, which
// no corpus script does) against a tea bundle and the unchanged one, and
// require identical transcripts, requests included.
//   node bench/app-code-size/verify-favorite.mjs <bundle.mjs> [label]
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';

const [bundle, label = 'favorite'] = process.argv.slice(2);
const dir = `zig-out/verify/${label}-favorite`;
fs.rmSync(dir, {recursive: true, force: true});
fs.cpSync('zig-out/output-size/tea', dir, {recursive: true});
fs.copyFileSync(bundle, `${dir}/_main.mjs`);
const run = entry => spawnSync('node', ['tests/browser/driver.mjs', '--dom=tests/browser/happy-dom.mjs', entry, 'bench/app-code-size/feed-favorite.steps'], {encoding: 'utf8'});
const a = run(`${dir}/_main.mjs`), b = run('zig-out/output-size/tea/_main.mjs');
const ok = a.status === 0 && b.status === 0 && a.stdout === b.stdout && /POST \/api\/articles\/[^ ]*\/favorite/.test(b.stdout) && /DELETE \/api\/articles\/[^ ]*\/favorite/.test(b.stdout);
if (!ok) fs.writeFileSync(`${dir}/transcript.txt`, a.stdout + '\n--- stderr ---\n' + a.stderr);
console.log(`${label} feed favorite: ${ok ? 'matches the unchanged bundle' : `DIFFERS (${dir}/transcript.txt)`}`);
process.exit(ok ? 0 : 1);
