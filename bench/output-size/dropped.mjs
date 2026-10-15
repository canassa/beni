// What does Terser's `unused` delete? Run compress (no mangle) with and
// without `unused` and list the top-level bindings that vanish, with their
// source module and raw bytes, and price deleting exactly those in the
// original bundle. usage: node dropped.mjs <bundle.mjs> <bundle.mjs.map.gz>
import fs from 'node:fs';
import {minify} from 'terser';
import * as acorn from 'acorn';
import {TraceMap, originalPositionFor} from '@jridgewell/trace-mapping';
import {br, readGz, apply} from './lib.mjs';

const [file, mapFile] = process.argv.slice(2);
const src = fs.readFileSync(file, 'utf8');
const map = new TraceMap(JSON.parse(readGz(mapFile)));
const lines = [0]; for (let i = 0; i < src.length; i++) if (src[i] === '\n') lines.push(i + 1);
const pos = off => { let l = 0, h = lines.length - 1; while (l < h) { const m = (l + h + 1) >> 1; if (lines[m] <= off) l = m; else h = m - 1; } return {line: l + 1, column: off - lines[l]}; };
const topNames = code => {
  const ast = acorn.parse(code, {ecmaVersion: 'latest', sourceType: 'module'}), m = new Map();
  for (const s of ast.body) {
    if (s.type === 'VariableDeclaration') for (const d of s.declarations) m.set(d.id.name, {start: d.start, end: d.end, init: d.init, decl: s});
    if (s.type === 'FunctionDeclaration') m.set(s.id.name, {start: s.start, end: s.end, decl: s});
  }
  return m;
};
const before = topNames(src);
const after = topNames((await minify(src, {module: true, toplevel: true, compress: {passes: 2, inline: false, collapse_vars: false, reduce_vars: true, unused: true}, mangle: false})).code);
const gone = [...before].filter(([n]) => !after.has(n));
// Inlined vs truly dead: a name that still occurs in the output text was not dropped.
const bySource = {};
for (const [n, d] of gone) {
  const o = originalPositionFor(map, pos(d.init ? d.init.start : d.start));
  const s = (o.source ?? 'unmapped').replace(/^.*examples\/conduit\/src\//, 'app/').replace('beni:///', '');
  (bySource[s] ??= {count: 0, raw: 0, names: []});
  bySource[s].count++; bySource[s].raw += Buffer.byteLength(src.slice(d.start, d.end)); bySource[s].names.push(n);
}
// Price: is each gone binding referenced anywhere else in the original? (an unreferenced one is dead code)
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const refs = new Map();
(function walk(n, parent) { if (!n?.type) return; if (n.type === 'Identifier') refs.set(n.name, (refs.get(n.name) ?? 0) + 1); for (const [k, v] of Object.entries(n)) { if (k === 'key' && parent?.type === 'Property' && !n.computed) continue; if (Array.isArray(v)) v.forEach(x => walk(x, n)); else if (v?.type) walk(v, n); } })(ast);
const dead = gone.filter(([n]) => refs.get(n) === 1);
const edits = dead.filter(([, d]) => d.init).map(([, d]) => ({start: d.init.start, end: d.init.end, text: '0'}));
const stubbed = apply(src, edits);
const summary = {file, topLevel: before.size, gone: gone.length, goneRaw: gone.reduce((n, [, d]) => n + Buffer.byteLength(src.slice(d.start, d.end)), 0),
  unreferenced: dead.length, stubUnreferencedSaves: br(src) - br(stubbed),
  bySource: Object.fromEntries(Object.entries(bySource).sort((a, b) => b[1].raw - a[1].raw).map(([k, v]) => [k, {count: v.count, raw: v.raw}]))};
console.log(JSON.stringify(summary));
if (process.env.OUT) fs.writeFileSync(process.env.OUT, JSON.stringify({...summary, names: Object.fromEntries(Object.entries(bySource).map(([k, v]) => [k, v.names]))}, null, 1) + '\n');
