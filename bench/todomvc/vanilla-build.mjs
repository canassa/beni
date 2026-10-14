// Vendored tastejs vanilla-es6, unchanged. Checksums precede bundling.
import { createHash } from 'node:crypto';
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, constants } from 'node:zlib';
import { build } from './apps/vanilla-es6/node_modules/esbuild/lib/main.js';

const here = dirname(fileURLToPath(import.meta.url));
const source = join(here, 'apps/vanilla-es6');
const upstream = JSON.parse(readFileSync(join(source, 'upstream.json')));
for (const [name, expected] of Object.entries(upstream.sha256)) {
  const actual = createHash('sha256').update(readFileSync(join(source, name))).digest('hex');
  if (actual !== expected) throw new Error(`vanilla-es6/${name}: checksum ${actual}, expected ${expected}`);
}
const out = join(here, 'out/direct-effects/vanilla-es6');
mkdirSync(out, { recursive: true });
await build({ entryPoints: [join(source, 'src/app.js')], outfile: join(out, '_main.mjs'), bundle: true, minify: true, format: 'iife', target: 'es2022' });
// Keep the app's HTML, omitting common CSS/base.js consistently with size.mjs.
const html = readFileSync(join(source, 'index.html'), 'utf8');
writeFileSync(join(out, 'body.html'), html.match(/<body>([\s\S]*?)<script/)[1]);
const bytes = readFileSync(join(out, '_main.mjs'));
console.log(JSON.stringify({ platform: 'vanilla-es6', commit: upstream.commit, raw: bytes.length,
  brotli: brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11 } }).length }, null, 2));
