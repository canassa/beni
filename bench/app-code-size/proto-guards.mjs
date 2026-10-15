// Price one test per hole, executable, over every view of the tea bundle: a
// hole guard nested in a group guard (`if (v !== a.a3) { a.a3 = v; w.data = v }`
// inside `if (path !== a.g1_0) { … }`) is dropped when its body is a plain DOM
// write (text data, setAttribute, classList.toggle), and its kept field with
// it. The write then runs whenever the group's inputs changed, as a Solid
// effect writes when its accessor's inputs changed; writing a property its
// own value again changes nothing on the page. Slot placements keep their
// argument tests: those skip a helper call (language.md §11.6), not a write.
//   node bench/app-code-size/proto-guards.mjs <in.mjs(.gz)> <out.mjs>
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz} from '../output-size/lib.mjs';

const [inp, outp] = process.argv.slice(2);
const src = inp.endsWith('.gz') ? readGz(inp) : fs.readFileSync(inp, 'utf8');
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const prop = n => n?.type === 'MemberExpression' && !n.computed ? n.property.name : null;
const isWrite = s => s.type === 'ExpressionStatement' && (
  s.expression.type === 'AssignmentExpression' && ['data'].includes(prop(s.expression.left)) ||
  s.expression.type === 'CallExpression' && ['setAttribute', 'toggle'].includes(prop(s.expression.callee)));
const edits = []; let n = 0; const dropped = new Map(); // field name → count, per function
const visit = (node, inGroup, fnFields) => {
  if (!node?.type) return;
  if (node.type === 'IfStatement') {
    const t = node.test;
    const field = t.type === 'BinaryExpression' && t.operator === '!==' && /^a\d+(_\d+)?$/.test(prop(t.right) ?? '') && t.right.object.type === 'Identifier' ? t.right : null;
    const body = node.consequent.type === 'BlockStatement' ? node.consequent.body : [node.consequent];
    const store = s => s.type === 'ExpressionStatement' && s.expression.type === 'AssignmentExpression' && prop(s.expression.left) === prop(field) && s.expression.left.object.name === field.object.name;
    if (inGroup && field && !node.alternate && body.some(store) && body.every(s => store(s) || isWrite(s))) {
      const keep = body.filter(s => !store(s)).map(s => src.slice(s.start, s.end).replace(/;$/, '')).join(';') + ';';
      edits.push({start: node.start, end: node.end, text: keep});
      fnFields.push(prop(field)); n++;
      return;
    }
    const group = /g\d+/.test(src.slice(t.start, t.end));
    visit(t, inGroup, fnFields); visit(node.consequent, inGroup || group, fnFields); visit(node.alternate, inGroup, fnFields);
    return;
  }
  for (const v of Object.values(node)) { if (Array.isArray(v)) v.forEach(x => visit(x, inGroup, fnFields)); else if (v?.type) visit(v, inGroup, fnFields); }
};
// per top-level patch function: drop guards; then remove the kept fields from
// the instance records that initialise them, when nothing else reads them.
const top = [];
for (const s of ast.body) if (s.type === 'VariableDeclaration') for (const d of s.declarations) top.push(d);
const fieldsDropped = [];
for (const d of top) { const f = []; visit(d.init, false, f); if (f.length) fieldsDropped.push(...f.map(x => [d.id.name, x])); }
// the kind whose p is that function: drop the field's initialiser from its
// record when the patch, once edited, no longer names the field
let removedInit = 0;
const byPatch = new Map();
for (const [fn, f] of fieldsDropped) (byPatch.get(fn) ?? byPatch.set(fn, new Set()).get(fn)).add(f);
for (const [fn, fs_] of byPatch) {
  const pd = top.find(d => d.id.name === fn);
  let ptext = src.slice(pd.start, pd.end);
  for (const e of edits.filter(e => e.start >= pd.start && e.end <= pd.end).sort((a, b) => b.start - a.start)) ptext = ptext.slice(0, e.start - pd.start) + e.text + ptext.slice(e.end - pd.start);
  const kd = top.find(d => d.init?.type === 'ObjectExpression' && d.init.properties.some(p => p.key?.name === 'p' && p.value.type === 'Identifier' && p.value.name === fn));
  if (!kd) continue;
  for (const f of fs_) {
    if (new RegExp(`\\.${f}\\b`).test(ptext)) continue;
    const at = src.slice(kd.start, kd.end).indexOf(`,${f}:`);
    if (at < 0) continue;
    const m = /^,[\w]+:(undefined|false|null)(?=[,}])/.exec(src.slice(kd.start + at, kd.end));
    if (!m) continue;
    edits.push({start: kd.start + at, end: kd.start + at + m[0].length, text: ''}); removedInit++;
  }
}
let out = src;
for (const e of edits.sort((a, b) => b.start - a.start)) out = out.slice(0, e.start) + e.text + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.writeFileSync(outp, out);
console.log(JSON.stringify({guardsDropped: n, initialisersDropped: removedInit, before: size(src), after: size(out), saved: size(src).brotli - size(out).brotli}));
