// Price two sharing rules, executable, over a tea bundle:
//  1. one cloner per distinct template: identical `template(html, flags)`
//     calls are bound once (backend.md §15.2 already lets a lowering share a
//     template string between sites; kinds stay one per site);
//  2. one factory for markup with nothing to patch: every static kind
//     `{m:()=>{let c=T();return{s:c,q:null,e:c}},p:()=>{}}` becomes `S(T)`,
//     still a distinct kind object per site.
//   node bench/app-code-size/proto-static.mjs <in.mjs(.gz)> <out.mjs>
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz} from '../output-size/lib.mjs';

const [inp, outp] = process.argv.slice(2);
const src = inp.endsWith('.gz') ? readGz(inp) : fs.readFileSync(inp, 'utf8');
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const decls = [];
for (const s of ast.body) if (s.type === 'VariableDeclaration') s.declarations.forEach((d, i) => decls.push({d, s, i}));
const text = n => src.slice(n.start, n.end);
// the template function: the callee of the most common `X("<…",n)` initialiser
const counts = new Map();
for (const {d} of decls) if (d.init?.type === 'CallExpression' && d.init.callee.type === 'Identifier' && d.init.arguments[0]?.type === 'Literal' && /^</.test(d.init.arguments[0].value ?? '')) counts.set(d.init.callee.name, (counts.get(d.init.callee.name) ?? 0) + 1);
const tpl = [...counts].sort((a, b) => b[1] - a[1])[0][0];
const free = n => !new RegExp(`(?<![\\w$.])${n}(?![\\w$])`).test(src);
const S = 'Gt'; if (!free(S)) throw Error(`${S} taken`);
const edits = [], rename = new Map(), seen = new Map();
const del = ({d, s, i}) => { const ds = s.declarations; edits.push(i < ds.length - 1 ? {start: d.start, end: ds[i + 1].start, text: ''} : {start: ds[i - 1].end, end: d.end, text: ''}); };
let dupes = 0, statics = 0;
for (const x of decls) {
  const {d} = x;
  if (d.init?.type === 'CallExpression' && d.init.callee.type === 'Identifier' && d.init.callee.name === tpl) {
    const key = text(d.init);
    if (seen.has(key)) { rename.set(d.id.name, seen.get(key)); del(x); dupes++; } else seen.set(key, d.id.name);
  }
}
let firstStatic = null;
for (const {d} of decls) {
  const m = /^\{m:\(\)=>\{let (\w+)=([\w$]+)\(\);return\{s:\1,q:null,e:\1\}\},p:\(\)=>\{\}\}$/.exec(d.init ? text(d.init) : '');
  if (!m) continue;
  edits.push({start: d.init.start, end: d.init.end, text: `${S}(${rename.get(m[2]) ?? m[2]})`, tplRef: m[2]});
  firstStatic ??= d.start; statics++;
}
// references to a removed duplicate cloner point at the kept one
const refs = [];
const walk = (n, parent) => {
  if (!n?.type) return;
  if (n.type === 'Identifier' && rename.has(n.name) && !(parent?.type === 'MemberExpression' && parent.property === n && !parent.computed) && !(parent?.type === 'Property' && parent.key === n) && !(parent?.type === 'VariableDeclarator' && parent.id === n)) refs.push({start: n.start, end: n.end, text: rename.get(n.name)});
  for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => walk(x, n)); else if (v?.type) walk(v, n); }
};
walk(ast);
const all = [...edits, ...refs.filter(r => !edits.some(e => r.start >= e.start && r.end <= e.end))];
all.push({start: firstStatic, end: firstStatic, text: `${S}=a=>({m:()=>{let c=a();return{s:c,q:null,e:c}},p:()=>{}}),`});
let out = src;
for (const e of all.sort((a, b) => b.start - a.start || (b.end - b.start) - (a.end - a.start))) out = out.slice(0, e.start) + e.text + out.slice(e.end);
acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'});
fs.writeFileSync(outp, out);
console.log(JSON.stringify({template: tpl, duplicateClonersRemoved: dupes, staticKinds: statics, before: size(src), after: size(out), saved: size(src).brotli - size(out).brotli}));
