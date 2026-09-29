// Report 40 §7: the three A3 token rewrites one after another on the compactor's output (without
// A2), and terser's renaming for comparison. Needs dist/minify (node min/measure.mjs minify).
//   node min/tools/a3.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';
import { spawnSync } from 'node:child_process';
import { minify } from 'terser';
const dir = new URL('../../', import.meta.url).pathname;
const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const SURFACE = ['length', 'unsafeGet', 'set', 'push', 'pop', 'slice', 'append', 'fromList', 'toList', 'sortWith', 'fromJs', 'toJs', 'chunks'];
for (const f of ['min/original.js', 'min/rewritten.js']) {
  const b = spawnSync(dir + 'dist/minify', [dir + f, ...SURFACE], { encoding: 'utf8' }).stdout;
  const steps = [
    ['beni today', b],
    ['+ ;} -> }', (s) => s.replace(/;}/g, '}')],
    ['+ (x)=> -> x=>', (s) => s.replace(/\((\w+)\)=>/g, '$1=>')],
    ['+ const -> let', (s) => s.replace(/\bconst /g, 'let ')],
  ];
  let cur = b;
  console.log(f);
  for (const [l, t] of steps) { cur = typeof t === 'string' ? t : t(cur); console.log('  ', l.padEnd(30), cur.length, br(cur)); }
  const m = (await minify(b, { module: false, compress: false, mangle: { toplevel: false } })).code;
  console.log('   beni + locals renamed only    ', m.length, br(m));
  const m2 = (await minify(cur, { module: false, compress: false, mangle: { toplevel: false } })).code;
  console.log('   all three + locals renamed    ', m2.length, br(m2));
  const m3 = (await minify(b, { module: true, compress: false, mangle: { toplevel: true } })).code;
  console.log('   beni + all names renamed      ', m3.length, br(m3));
}
