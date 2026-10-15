// Price constructor padding (backend.md §4: every constructor of a type with
// fields is padded to the type's widest shape, `{$:3,a:x,b:null}`), in the
// app code only: delete the `null` padding fields of every `{$:…}` literal
// the application's own declarations write. The pages run the same (no app
// code reads a padded field), but object shapes change, which is what the
// padding exists for (backend.md §9.4's 11% on Firefox): a size probe, not a
// proposal.
//   node bench/app-code-size/proto-padding.mjs <tea|direct> [results dir]
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';
import {areaOf} from './classify.mjs';

const [p, dir = 'bench/app-code-size/results'] = process.argv.slice(2);
const src = readGz(`${dir}/beni-${p}.mjs.gz`), {units: us} = units(src, JSON.parse(readGz(`${dir}/beni-${p}.mjs.map.gz`)));
const edits = []; const by = {views: 0, logic: 0};
for (const u of us) {
  const ar = areaOf(u); if (!ar) continue;
  const off = u.start - 4, ast = acorn.parse('let ' + src.slice(u.start, u.end), {ecmaVersion: 'latest', sourceType: 'module'});
  const w = n => {
    if (!n?.type) return;
    if (n.type === 'ObjectExpression' && n.properties[0]?.key?.name === '$') n.properties.forEach((q, i) => {
      if (i > 0 && q.value?.type === 'Literal' && q.value.value === null) { edits.push({start: n.properties[i - 1].end + off, end: q.end + off}); by[ar]++; }
    });
    for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(w); else if (v?.type) w(v); }
  };
  w(ast);
}
let out = src;
for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.mkdirSync('zig-out/app-code-size', {recursive: true});
fs.writeFileSync(`zig-out/app-code-size/proto-padding-${p}.mjs`, out);
console.log(JSON.stringify({fields: by, before: size(src).brotli, after: size(out).brotli, saved: size(src).brotli - size(out).brotli}));
