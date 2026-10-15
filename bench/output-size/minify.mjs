// Run third-party minifiers over beni's --release bundles and reprice them.
// usage: node bench/output-size/minify.mjs <dir-with-subject.mjs>...
// Writes <dir>/minify.json. Each variant is an independent minifier config.
import fs from 'node:fs';
import path from 'node:path';
import {minify} from 'terser';
import * as esbuild from 'esbuild';
import {size} from './lib.mjs';

const base = {module: true, ecma: 2020, toplevel: true};
const variants = {
  'terser-default': {...base, compress: {passes: 2}, mangle: true},
  'terser-compress-only': {...base, compress: {passes: 2}, mangle: false},
  'terser-mangle-only': {...base, compress: false, mangle: true},
  'terser-whitespace-only': {...base, compress: false, mangle: false},
  'terser-unsafe': {...base, compress: {passes: 3, unsafe: true, unsafe_arrows: true, unsafe_methods: true, pure_getters: true, hoist_funs: true}, mangle: true},
  'terser-mangle-props': {...base, compress: {passes: 2}, mangle: {properties: {regex: /^[a-zA-Z_$][\w$]{2,}$/, reserved: []}}},
};
const out = {};
for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const rec = {baseline: size(src), variants: {}};
  for (const [name, opts] of Object.entries(variants)) {
    const r = await minify(src, opts);
    fs.writeFileSync(file.replace(/\.mjs$/, `.${name}.mjs`), r.code);
    rec.variants[name] = size(r.code);
  }
  const e = await esbuild.transform(src, {minify: true, format: 'esm', target: 'es2022'});
  fs.writeFileSync(file.replace(/\.mjs$/, '.esbuild.mjs'), e.code);
  rec.variants.esbuild = size(e.code);
  out[path.basename(file)] = rec;
  console.log(path.basename(file), rec.baseline.brotli, Object.fromEntries(Object.entries(rec.variants).map(([k, v]) => [k, `${v.raw}/${v.brotli} (${v.brotli - rec.baseline.brotli})`])));
}
fs.writeFileSync(process.env.OUT ?? 'minify.json', JSON.stringify(out, null, 2) + '\n');
