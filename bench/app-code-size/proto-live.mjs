// Price static liveness, executable for Conduit: no markup in Conduit can be
// live (no view value evaluated on every render, and a controlled input no
// longer makes an instance live: backend.md §15.4 as amended 2026-10-08), so
// every restate returns at once and every liveness store writes false. A
// compiler that proved it would emit neither: the restate calls and their
// `else` branches, the `a.l = …` stores and the kinds' `l:true` go.
//   node bench/app-code-size/proto-live.mjs <in.mjs(.gz)> <out.mjs>
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz} from '../output-size/lib.mjs';

const [inp, outp] = process.argv.slice(2);
const src = inp.endsWith('.gz') ? readGz(inp) : fs.readFileSync(inp, 'utf8');
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
// Rt.restate, found by its body: a=>{let b=a.w;if(b)b(a,0);if(a.l){…}}
let restate = null;
for (const s of ast.body) if (s.type === 'VariableDeclaration') for (const d of s.declarations)
  if (/^\w=>\{let \w=\w\.w;if\(\w\)\w\(\w,0\);if\(\w\.l\)/.test(src.slice(d.init?.start ?? 0, d.init?.end ?? 0))) restate = d.id.name;
if (!restate) throw Error('restate not found');
const prop = n => n?.type === 'MemberExpression' && !n.computed ? n.property.name : null;
const isRestate = s => s?.type === 'ExpressionStatement' && s.expression.type === 'CallExpression' && s.expression.callee.type === 'Identifier' && s.expression.callee.name === restate;
const onlyRestates = s => isRestate(s) || s?.type === 'BlockStatement' && s.body.length > 0 && s.body.every(isRestate);
const edits = []; let n = {restates: 0, elses: 0, stores: 0, flags: 0};
const visit = (node, parent) => {
  if (!node?.type) return;
  if (node.type === 'IfStatement' && node.alternate && onlyRestates(node.alternate)) {
    edits.push({start: node.consequent.end, end: node.alternate.end, text: ''}); n.elses++;
    visit(node.test, node); visit(node.consequent, node); return;
  }
  if (isRestate(node) && (parent?.type === 'BlockStatement' || parent?.type === 'Program')) { edits.push({start: node.start, end: node.end, text: ''}); n.restates++; return; }
  if (node.type === 'ExpressionStatement' && node.expression.type === 'AssignmentExpression' && prop(node.expression.left) === 'l' && (parent?.type === 'BlockStatement')) { edits.push({start: node.start, end: node.end, text: ''}); n.stores++; return; }
  if (node.type === 'ObjectExpression') node.properties.forEach((p, i) => {
    if (p.key?.name === 'l' && p.value.type === 'Literal' && p.value.value === true && node.properties.some(q => q.key?.name === 'm')) {
      edits.push(i > 0 ? {start: node.properties[i - 1].end, end: p.end, text: ''} : {start: p.start, end: node.properties[1]?.start ?? p.end, text: ''}); n.flags++;
    }
  });
  for (const v of Object.values(node)) { if (Array.isArray(v)) v.forEach(x => visit(x, node)); else if (v?.type) visit(v, node); }
};
// only emitted application markup: kinds and patches, not the runtime itself
for (const s of ast.body) if (s.type === 'VariableDeclaration') for (const d of s.declarations) if (d.id.name !== restate && d.init) visit(d.init, d);
let out = src;
for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.writeFileSync(outp, out);
console.log(JSON.stringify({restate, ...n, before: size(src), after: size(out), saved: size(src).brotli - size(out).brotli}));
