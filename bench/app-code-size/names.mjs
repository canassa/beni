// Names, across the construct account: the bytes of every identifier and
// property name in each area, by kind, and what deleting each kind alone
// takes out of the response (a location of cost, not a saving: code needs
// names). Kinds: instance protocol fields (g0_0, a2, w1, c3, …), record and
// constructor fields (title, $, a, b, …), references to top-level names, and
// locals (parameters and lets).
//   node bench/app-code-size/names.mjs [results dir]
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {br, readGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';
import {areaOf as beniArea} from './classify.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const field = /^([gawcxld]\d+(_\d+)?|[sqe]|[lw]|m|p|t|v)$/;
const out = {};
// Solid's app units: views are pages, components and templates; logic the rest.
const solidArea = (u, text) => /^app\/(solid|web|store)\.js$/.test(u.owner) || u.owner === 'unmapped' ? null
  : /^\w+=ge\(/.test(text) || /app\/(NavLink|NavBar|ArticlePreview|ArticleList|Home|ListErrors|Comments|Article|Profile|Editor|Settings|Auth|App)\.js$/.test(u.owner) && !/^\w+=oe\(/.test(text) ? 'views' : 'logic';
for (const p of ['tea', 'direct', 'solid']) {
  const src = p === 'solid' ? readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.gz') : readGz(`${dir}/beni-${p}.mjs.gz`);
  const map = JSON.parse(p === 'solid' ? readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.map.gz') : readGz(`${dir}/beni-${p}.mjs.map.gz`));
  const {units: us} = units(src, map);
  const areaOf = p === 'solid' ? u => solidArea(u, src.slice(u.start, u.end)) : beniArea;
  const topNames = new Set(us.map(u => u.js));
  const kind = new Array(src.length).fill(null), area = new Array(src.length).fill(null);
  for (const u of us) {
    const ar = areaOf(u); if (!ar) continue;
    for (let i = u.start; i < u.end; i++) area[i] = ar;
    const text = src.slice(u.start, u.end), pre = u.js === '(stmt)' || /^(async )?function/.test(text) ? '' : 'let ', off = u.start - pre.length;
    const ast = acorn.parse(pre + text, {ecmaVersion: 'latest', sourceType: 'module'});
    const mark = (n, k) => { for (let i = n.start + off; i < n.end + off; i++) kind[i] = k; };
    const locals = [];
    const walk = (n, parent, key) => {
      if (!n?.type) return;
      if (n.type === 'Identifier') {
        if (parent?.type === 'MemberExpression' && key === 'property' && !parent.computed) mark(n, field.test(n.name) && ar === 'views' ? 'field' : 'record');
        else if (parent?.type === 'Property' && key === 'key' && !parent.computed) mark(n, field.test(n.name) && ar === 'views' ? 'field' : 'record');
        else if (n.start === pre.length && /VariableDeclarator|FunctionDeclaration/.test(parent?.type)) mark(n, 'top'); // the unit's own binding
        else mark(n, topNames.has(n.name) && !locals.some(s => s.has(n.name)) ? 'top' : 'local');
        return;
      }
      let pushed = false;
      if (/Function/.test(n.type)) { const s = new Set(); const pat = q => { if (!q) return; if (q.type === 'Identifier') s.add(q.name); else if (q.type === 'AssignmentPattern') pat(q.left); else if (q.type === 'ObjectPattern') q.properties.forEach(x => pat(x.value)); else if (q.type === 'ArrayPattern') q.elements.forEach(pat); }; n.params.forEach(pat);
        const v = x => { if (!x?.type || x !== n && /Function/.test(x.type)) return; if (x.type === 'VariableDeclarator') pat(x.id); for (const y of Object.values(x)) { if (Array.isArray(y)) y.forEach(v); else if (y?.type) v(y); } }; v(n.body); locals.push(s); pushed = true; }
      for (const [k, v] of Object.entries(n)) { if (k === 'type') continue; if (Array.isArray(v)) v.forEach(x => walk(x, n, k)); else if (v?.type) walk(v, n, k); }
      if (pushed) locals.pop();
    };
    walk(ast.body[0], null, null);
  }
  const base = br(src);
  const without = keep => { let s = ''; for (let i = 0; i < src.length; i++) if (keep(i)) s += src[i]; return s; };
  out[p] = {};
  for (const ar of ['views', 'logic']) {
    out[p][ar] = {};
    for (const k of ['field', 'record', 'top', 'local']) {
      let raw = 0, count = 0; for (let i = 0; i < src.length; i++) if (area[i] === ar && kind[i] === k) { raw++; if (kind[i - 1] !== k) count++; }
      out[p][ar][k] = {count, raw, alone: base - br(without(i => !(area[i] === ar && kind[i] === k)))};
    }
    console.log(p, ar, JSON.stringify(out[p][ar]));
  }
}
fs.writeFileSync(`${dir}/names.json`, JSON.stringify(out, null, 2) + '\n');
