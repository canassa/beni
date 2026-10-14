// Same-compiler TodoMVC release bytes for browser-direct.md's effects criterion.
// direnv exec . node bench/todomvc/direct-size.mjs [--beni=<compiler>]
import { spawnSync } from 'node:child_process';
import { readFileSync, mkdirSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, constants } from 'node:zlib';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const arg = (name, fallback) => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const beni = resolve(repo, arg('beni', 'zig-out/safe/bin/beni'));
const out = resolve(repo, arg('out', 'bench/todomvc/out/direct-effects'));
mkdirSync(out, { recursive: true });
const rows = [];
for (const variant of ['Sandbox', 'NoEditing']) {
  for (const platform of ['browser-tea', 'browser-direct']) {
    const dir = join(out, `${platform}-${variant}`);
    const built = spawnSync(beni, ['build', `--platform=${platform}`, '--release', '--no-cache', `--out=${dir}`, `bench/todomvc/apps/beni/${variant}.beni`], { cwd: repo, encoding: 'utf8' });
    if (built.status !== 0) {
      process.stderr.write(built.stdout + built.stderr);
      throw new Error(`${variant} on ${platform}: build exit ${built.status}`);
    }
    const bytes = readFileSync(join(dir, '_main.mjs'));
    rows.push({ variant, platform, raw: bytes.length, brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length, entry: join(dir, '_main.mjs') });
  }
}
console.log(JSON.stringify({ node: process.version, quality: 11, rows }, null, 2));
