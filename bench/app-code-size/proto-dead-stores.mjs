// Direct only: a group entry the consumer masks selected has lost its path
// test (`if (b !== a.g1_0)`), but still stores the kept path (`a.g1_0 = b`),
// and a hole whose test went the same way still stores its kept value
// (`a.a2_0 = d`). Price deleting every such store no code reads, executable:
// a store `x.F = …` in a top-level function is dropped when no other
// expression of the bundle reads a field named F (writes, and the record
// initialisers in the mount functions, do not count as reads).
//   node bench/app-code-size/proto-dead-stores.mjs <in.mjs(.gz)> <out.mjs>
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz} from '../output-size/lib.mjs';

const [inp, outp] = process.argv.slice(2);
const src = inp.endsWith('.gz') ? readGz(inp) : fs.readFileSync(inp, 'utf8');
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const prop = n => n?.type === 'MemberExpression' && !n.computed ? n.property.name : null;
const kept = /^(g\d+(_\d+)?|a\d+(_\d+)?)$/;
// every read of a kept-looking field anywhere
const reads = new Set();
const r = (n, parent) => {
  if (!n?.type) return;
  if (n.type === 'MemberExpression' && kept.test(prop(n) ?? '') && !(parent?.type === 'AssignmentExpression' && parent.left === n)) reads.add(prop(n));
  for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => r(x, n)); else if (v?.type) r(v, n); }
};
r(ast);
const edits = []; let dropped = 0;
const w = (n, parent) => {
  if (!n?.type) return;
  if (n.type === 'ExpressionStatement' && n.expression.type === 'AssignmentExpression' && n.expression.operator === '=' && kept.test(prop(n.expression.left) ?? '') && !reads.has(prop(n.expression.left)) && parent?.type === 'BlockStatement') {
    // keep the right side if it may have an effect; these are names and paths
    const rhs = n.expression.right;
    if (rhs.type === 'Identifier' || rhs.type === 'MemberExpression' || rhs.type === 'Literal') { edits.push({start: n.start, end: n.end, text: ''}); dropped++; return; }
  }
  for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => w(x, n)); else if (v?.type) w(v, n); }
};
w(ast);
let out = src;
for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.writeFileSync(outp, out);
console.log(JSON.stringify({dropped, before: size(src), after: size(out), saved: size(src).brotli - size(out).brotli}));
