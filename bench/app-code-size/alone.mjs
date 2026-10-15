// What deleting some top-level declarations alone takes out of a response.
//   node bench/app-code-size/alone.mjs <bundle(.gz)> name...
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {br, readGz} from '../output-size/lib.mjs';

export function alone(src, names) {
  const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
  const spans = [];
  for (const s of ast.body) {
    if (s.type === 'VariableDeclaration') for (const d of s.declarations) { if (names.includes(d.id.name)) spans.push([d.start, d.end]); }
    else if (s.type === 'FunctionDeclaration' && names.includes(s.id.name)) spans.push([s.start, s.end]);
  }
  let out = src, raw = 0;
  for (const [a, b] of spans.sort((x, y) => y[0] - x[0])) { raw += Buffer.byteLength(src.slice(a, b)); out = out.slice(0, a) + out.slice(b); }
  return {found: spans.length, raw, alone: br(src) - br(out)};
}
if (import.meta.url === `file://${process.argv[1]}`) {
  const [file, ...names] = process.argv.slice(2);
  const src = file.endsWith('.gz') ? readGz(file) : fs.readFileSync(file, 'utf8');
  console.log(JSON.stringify(alone(src, names)));
}
