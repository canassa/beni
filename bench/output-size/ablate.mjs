// Which Terser transforms buy the bytes? Leave-one-out from compress
// {passes: 2} + mangle, and add-one-in from whitespace+mangle.
// usage: node bench/output-size/ablate.mjs <bundle.mjs>... ; writes $OUT.
import fs from 'node:fs';
import path from 'node:path';
import {minify} from 'terser';
import {br} from './lib.mjs';

const options = ['sequences', 'join_vars', 'collapse_vars', 'reduce_vars', 'inline', 'unused', 'dead_code',
  'conditionals', 'booleans', 'comparisons', 'evaluate', 'if_return', 'hoist_props', 'loops', 'properties',
  'side_effects', 'typeofs', 'arrows', 'computed_props', 'switches', 'directives', 'reduce_funcs', 'arguments',
  'toplevel', 'negate_iife', 'unsafe_arrows', 'unsafe_methods'];
const base = {module: true, ecma: 2020, toplevel: true};
const result = {};
for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const full = br((await minify(src, {...base, compress: {passes: 2}, mangle: true})).code);
  const mangleOnly = br((await minify(src, {...base, compress: false, mangle: true})).code);
  const rec = {baseline: br(src), full, mangleOnly, leaveOneOut: {}, oneIn: {}};
  for (const o of options) {
    const on = !o.startsWith('unsafe');
    rec.leaveOneOut[o] = br((await minify(src, {...base, compress: {passes: 2, [o]: !on}, mangle: true})).code) - full;
    // one in: every compress option off but this one
    const offAll = Object.fromEntries(options.map(x => [x, false]));
    rec.oneIn[o] = mangleOnly - br((await minify(src, {...base, compress: {...offAll, passes: 2, [o]: true}, mangle: true})).code);
  }
  result[path.basename(file)] = rec;
  console.log(path.basename(file), JSON.stringify(rec));
}
fs.writeFileSync(process.env.OUT ?? 'ablate.json', JSON.stringify(result, null, 2) + '\n');
