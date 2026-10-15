// Price a Solid-like instance encoding over every view of the tea bundle,
// executable: each kind's kept values, node references and slots move from
// fields of an instance record into locals of its mount function, and its
// patch function becomes a closure over them, as dom-expressions' effects
// close over their nodes. The instance keeps only what the runtime reads
// (s, q, e, l) and one closure, u; every kind's p is one shared function.
//
//   before:  K={m:(a,b)=>{let c=T(),…,j={s:c,q:null,e:c,w1:e,a2_0:undefined,g0_0:NaN};P(j,a);return j},p:P,l:true}
//            P=(a,b)=>{let c=b[0],d=c.title;if(d!==a.g0_0){a.g0_0=d;a.w1.data=d}…}
//   after:   K={m:(a,b)=>{let c=T(),…,w1=e,a2_0,g0_0=NaN,j={s:c,q:null,e:c};(j.u=(a,b)=>{let c=b[0],d=c.title;if(d!==g0_0){g0_0=d;w1.data=d}…})(j,a);return j},p:U,l:true}
//            U=(a,b)=>a.u(a,b)
//
// Nothing else changes: the same tests, the same writes in the same order,
// the same restates and liveness. Field names become local names unchanged
// (g0_0, w1, …), so the transform adds no naming decision of its own.
// Kinds whose fields could collide with a name the code uses are left alone.
//   node bench/app-code-size/proto-closures.mjs [results dir]
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, readGz, walk} from '../output-size/lib.mjs';


const [inp = 'bench/app-code-size/results/beni-tea.mjs.gz', outp = 'zig-out/app-code-size/proto-closures-tea.mjs'] = process.argv.slice(2);
const src = inp.endsWith('.gz') ? readGz(inp) : fs.readFileSync(inp, 'utf8');
// Kinds are found by shape, so the script runs on an already edited bundle:
// a top-level {m: function, p: name, …} whose m builds a record with s, q, e.
const us = [];
for (const s of acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'}).body) if (s.type === 'VariableDeclaration') for (const d of s.declarations) {
  const ks = d.init?.type === 'ObjectExpression' ? d.init.properties.map(p => p.key?.name) : [];
  us.push({js: d.id.name, start: d.start, end: d.end, kind: ks.includes('m') && ks.includes('p') && !ks.includes('t') && /\{s:/.test(src.slice(d.start, d.end))});
}
const runtimeFields = new Set(['s', 'q', 'e', 'l', 't', 'b', 'x', 'y', 'k', 'n', 'kv', 'kc', 'kt', 'u']);
const parse = s => acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'});
const refCount = name => (src.match(new RegExp(`(?<![\\w$.])${name.replace(/\$/g, '\\$')}(?![\\w$])`, 'g')) ?? []).length;
const shared = 'Ft';
if (refCount(shared)) throw Error(`${shared} is taken`);
const edits = [];
let done = 0, skipped = [];
for (const k of us.filter(u => u.kind)) {
  const ktext = src.slice(k.start, k.end);
  const kast = parse(`let ${ktext}`).body[0].declarations[0].init;
  const pprop = kast.properties.find(p => p.key.name === 'p');
  if (pprop.value.type !== 'Identifier') continue; // a static kind: nothing to patch
  const pname = pprop.value.name, pu = us.find(u => u.js === pname);
  if (!pu || refCount(pname) !== 3) { skipped.push(`${k.js}: ${pname} shared`); continue; }
  const ptext = src.slice(pu.start, pu.end);
  const past = parse(`let ${ptext}`).body[0].declarations[0].init; // (a,b)=>{…}
  const mfn = kast.properties.find(p => p.key.name === 'm').value;
  // the instance record and the call of the patch
  let inst = null, call = null;
  walk(mfn.body, n => {
    if (n.type === 'VariableDeclarator' && n.init?.type === 'ObjectExpression' && n.init.properties.some(p => p.key?.name === 's')) inst = n;
    if (n.type === 'CallExpression' && n.callee.type === 'Identifier' && n.callee.name === pname) call = n;
  });
  if (!inst || !call || mfn.params.length > 2) { skipped.push(`${k.js}: shape`); continue; }
  const fields = inst.init.properties.filter(p => !runtimeFields.has(p.key.name));
  const keep = inst.init.properties.filter(p => runtimeFields.has(p.key.name));
  const names = new Set(fields.map(p => p.key.name));
  // fields the patch writes that the record did not list (none expected)
  const pa = past.params[0].name;
  let extra = null;
  // a field name that is also a name the code reads would be shadowed
  const idents = new Set();
  const names0 = (n, parent) => {
    if (!n?.type) return;
    if (n.type === 'Identifier' && !(parent?.type === 'MemberExpression' && parent.property === n && !parent.computed) && !(parent?.type === 'Property' && parent.key === n)) idents.add(n.name);
    for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => names0(x, n)); else if (v?.type) names0(v, n); }
  };
  names0(past); names0(mfn);
  let clash = [...names].find(f => idents.has(f));
  // rewrite the patch body: a.F → F where `a` is the patch's own parameter (not shadowed)
  const pedits = [];
  const visit = (n, shadowed) => {
    if (!n?.type) return;
    if (n !== past && /Function/.test(n.type)) {
      const binds = new Set(); n.params.forEach(p => walk(p, x => { if (x.type === 'Identifier') binds.add(x.name); }));
      walk(n.body, x => { if (x.type === 'VariableDeclarator') walk(x.id, y => { if (y.type === 'Identifier') binds.add(y.name); }); });
      if (binds.has(pa)) shadowed = true;
    }
    if (!shadowed && n.type === 'MemberExpression' && !n.computed && n.object.type === 'Identifier' && n.object.name === pa) {
      if (names.has(n.property.name)) { pedits.push({start: n.start, end: n.end, text: n.property.name}); return; }
      if (!runtimeFields.has(n.property.name)) extra = n.property.name;
    }
    for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => visit(x, shadowed)); else if (v?.type) visit(v, shadowed); }
  };
  visit(past, false);
  if (extra || clash) { skipped.push(`${k.js}: ${extra ? `extra field ${extra}` : `name clash ${clash}`}`); continue; }
  let body = `let ${ptext}`;
  for (const e of pedits.sort((a, b) => b.start - a.start)) body = body.slice(0, e.start) + e.text + body.slice(e.end);
  const pfn = body.slice(body.indexOf('=') + 1);
  // rewrite the kind: fields become locals declared with the record, the call becomes the closure
  const off = -4; // `let ` prefix of ktext's parse
  const kedits = [];
  const decls = fields.map(p => {
    const v = src.slice(k.start + p.value.start + off, k.start + p.value.end + off);
    return v === 'undefined' ? p.key.name : `${p.key.name}=${v}`;
  });
  const rec = `{${keep.map(p => src.slice(k.start + p.start + off, k.start + p.end + off)).join(',')}}`;
  kedits.push({start: inst.start, end: inst.end, text: `${[...decls, `${inst.id.name}=${rec}`].join(',')}`});
  kedits.push({start: call.callee.start, end: call.callee.end, text: `(${inst.id.name}.u=${pfn})`});
  kedits.push({start: pprop.value.start, end: pprop.value.end, text: shared});
  let ktext2 = `let ${ktext}`;
  for (const e of kedits.sort((a, b) => b.start - a.start)) ktext2 = ktext2.slice(0, e.start) + e.text + ktext2.slice(e.end);
  edits.push({start: k.start, end: k.end, text: ktext2.slice(4)});
  edits.push({del: pu});
  done++;
}
// apply: kind texts replaced; patch declarators deleted
const ast = parse(src);
const flat = [];
for (const s of ast.body) if (s.type === 'VariableDeclaration') s.declarations.forEach((d, i) => {
  const e = edits.find(x => x.start === d.start && x.end === d.end);
  if (e) flat.push(e);
  if (edits.some(x => x.del && x.del.start === d.start)) {
    const ds = s.declarations;
    flat.push(i < ds.length - 1 ? {start: d.start, end: ds[i + 1].start, text: ''} : {start: ds[i - 1].end, end: d.end, text: ''});
  }
});
// the shared patch, once, before the first kind
const firstKind = Math.min(...flat.filter(e => e.text).map(e => e.start));
flat.push({start: firstKind, end: firstKind, text: `${shared}=(a,b)=>a.u(a,b),`});
let out = src;
for (const e of flat.sort((a, b) => b.start - a.start || (b.end - b.start) - (a.end - a.start))) out = out.slice(0, e.start) + e.text + out.slice(e.end);
parse(out);
fs.mkdirSync(outp.replace(/\/[^/]*$/, ''), {recursive: true});
fs.writeFileSync(outp, out);
console.log(JSON.stringify({kindsRewritten: done, skipped, before: size(src), after: size(out), saved: size(src).brotli - size(out).brotli}));
