// The Solid reference (research 101's adjusted single-chunk RealWorld) under
// the same byte account as account.mjs: its app code split into views (pages
// and components) and logic (agent, stores, router, startup), each byte
// painted by construct, alone and ordered brotli.
//   node bench/app-code-size/solid.mjs [results dir]
import fs from 'node:fs';
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {size, br, readGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const src = readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.gz');
const map = JSON.parse(readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.map.gz'));
const {units: us} = units(src, map);
const top = new Map(us.map(u => [u.js, u]));
export const SOLID_VIEW = [
  ['html', 'HTML template strings'],
  ['tdecl', 'template constants: template(…) call and binding'],
  ['walk', 'clone and walk (cloneNode, firstChild/nextSibling)'],
  ['insert', 'insert(parent, accessor, marker) calls'],
  ['effect', 'render effects and their previous-value objects'],
  ['write', 'DOM writes (setAttribute, className, classList, textContent, value)'],
  ['component', 'component calls createComponent(C, {props}) and prop getters'],
  ['control', 'control flow components (For, Show, Suspense, Switch/Match)'],
  ['event', 'event wiring ($$click, $$clickData, addEventListener, delegateEvents) and handlers'],
  ['state', 'store/router access (useStore, createStore, setters, actions called)'],
  ['other', 'other (component shells, expressions, punctuation)'],
];
export const SOLID_LOGIC = [
  ['http', 'HTTP agent: fetch wrapper and endpoint table'],
  ['state', 'stores and actions (createStore, setters, resources)'],
  ['router', 'hash router, lazy pages and startup'],
  ['other', 'other'],
];
const viewOwners = /app\/(NavLink|NavBar|ArticlePreview|ArticleList|Home|ListErrors|Comments|Article|Profile|Editor|Settings|Auth|App)\.js$/;
const runtime = o => /^app\/(solid|web|store)\.js$/.test(o);
const label = new Array(src.length).fill(null), area = new Array(src.length).fill(null);
const paint = (a, b, c) => { for (let i = a; i < b; i++) label[i] = c; };
const prop = n => n.type === 'MemberExpression' && !n.computed ? n.property.name : null;
const isChain = n => n.type === 'MemberExpression' && ['firstChild', 'nextSibling'].includes(prop(n));
const rtName = (n) => { const u = n?.type === 'Identifier' ? top.get(n.name) : null; return u ? `${u.owner.replace(/^app\//, '')}.${u.orig}` : ''; };
for (const u of us) {
  if (runtime(u.owner) || u.owner === 'unmapped') continue;
  const text = src.slice(u.start, u.end);
  const isTpl = /^\w+=ge\(/.test(text) || /^\w+=ge\(/.test(text);
  const ar = isTpl || viewOwners.test(u.owner) && !/^\w+=oe\(/.test(text) ? 'views' : 'logic';
  for (let i = u.start; i < u.end; i++) area[i] = ar;
  if (ar === 'logic') {
    const c = /createAgent|Provider/.test(u.owner + u.orig) ? 'state' : /^app\/create/.test(u.owner) ? 'state' : 'router';
    paint(u.start, u.end, c);
    // the agent inside the Provider: from `function([e,t]){async function n(` to its endpoint table's end
    const m = text.indexOf('d=function([e,t]){async function n(');
    if (m >= 0) { const end = text.indexOf('}}(u)', m); paint(u.start + m, u.start + (end > 0 ? end + 5 : text.length), 'http'); }
    if (u.orig === 'encode') paint(u.start, u.end, 'http');
    continue;
  }
  paint(u.start, u.end, 'other');
  const prefix = u.js === '(stmt)' || /^(async )?function/.test(text) ? '' : 'let ';
  const ast = acorn.parse(prefix + text, {ecmaVersion: 'latest', sourceType: 'module'});
  const off = u.start - prefix.length;
  const P = (n, c) => paint(n.start + off, n.end + off, c);
  const walkN = (n, parent) => {
    if (!n?.type) return;
    const callee = n.type === 'CallExpression' ? rtName(n.callee) : '';
    if (callee === 'web.js.template') { P(n, 'tdecl'); P(n.arguments[0], 'html'); return; }
    if (n.type === 'CallExpression' && prop(n.callee) === 'cloneNode') { P(n, 'walk'); return; }
    if (isChain(n)) { P(n, 'walk'); return; }
    if (n.type === 'VariableDeclarator' && n.init && (isChain(n.init) || n.init.type === 'CallExpression' && prop(n.init.callee) === 'cloneNode')) { P(n, 'walk'); return; }
    if (callee === 'web.js.insert') P(n, 'insert');
    if (callee === 'solid.js.createRenderEffect' || callee === 'solid.js.createComputed') P(n, 'effect');
    if (callee === 'web.js.setAttribute') { P(n, 'write'); }
    if (callee === 'web.js.addEventListener' || callee === 'web.js.delegateEvents') { P(n, 'event'); }
    if (callee === 'solid.js.createComponent') {
      const c = rtName(n.arguments[0]);
      P(n, /solid\.js\.(For|Show|Suspense|Switch|Match)$/.test(c) ? 'control' : 'component');
    }
    if (n.type === 'Property' && n.kind === 'get') { /* a prop getter: part of its component call */ }
    if (callee === 'app/index.js.useStore' || callee === 'index.js.useStore' || callee === 'index.js.useRouter' || /store\.js\.createStore|solid\.js\.createSignal/.test(callee)) P(n, 'state');
    if (n.type === 'AssignmentExpression') {
      const f = prop(n.left);
      if (/^\$\$/.test(f ?? '')) { P(n, 'event'); return; }
      if (['className', 'textContent', 'value', 'disabled', 'data', 'checked'].includes(f)) P(n, 'write');
    }
    if (n.type === 'CallExpression' && n.callee.type === 'MemberExpression' && ['toggle', 'setAttribute', 'addEventListener'].includes(prop(n.callee))) P(n, prop(n.callee) === 'addEventListener' ? 'event' : 'write');
    if (n.type === 'ObjectExpression' && n.properties.length && n.properties.every(p => /^_v\$\d*$/.test(p.key?.name ?? ''))) { P(n, 'effect'); return; }
    if (n.type === 'ConditionalExpression' || n.type === 'LogicalExpression') { /* expressions */ }
    if (n.type === 'VariableDeclarator' && n.init && /Function/.test(n.init.type) && parent && /e\.preventDefault|preventDefault\(\)|=>\w+\(\w+\.slug\)/.test(src.slice(n.start + off, n.end + off))) { P(n, 'event'); }
    for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => walkN(x, n)); else if (v?.type) walkN(v, n); }
  };
  walkN(ast.body[0]);
}
const without = keep => { let s = ''; for (let i = 0; i < src.length; i++) if (keep(i)) s += src[i]; return s; };
const base = size(src), out = {baseline: base, areas: {}};
for (const [ar, classes] of [['views', SOLID_VIEW], ['logic', SOLID_LOGIC]]) {
  const raw = {}; for (let i = 0; i < src.length; i++) if (area[i] === ar) raw[label[i]] = (raw[label[i]] ?? 0) + Buffer.byteLength(src[i]);
  const cost = base.brotli - br(without(i => area[i] !== ar));
  const rows = []; const gone = new Set(); let prev = base.brotli;
  for (const [k, title] of classes) {
    if (!raw[k]) continue;
    const alone = base.brotli - br(without(i => !(area[i] === ar && label[i] === k)));
    gone.add(k); const now = br(without(i => !(area[i] === ar && gone.has(label[i]))));
    rows.push({class: k, title, raw: raw[k], alone, ordered: prev - now}); prev = now;
  }
  out.areas[ar] = {raw: Object.values(raw).reduce((a, b) => a + b, 0), cost, rows};
  console.log(`solid ${ar}: raw ${out.areas[ar].raw}, cost ${cost}`);
  for (const r of rows) console.log(`  ${r.title.padEnd(78)} ${String(r.raw).padStart(7)} ${String(r.alone).padStart(6)} ${String(r.ordered).padStart(6)}`);
}
out.appCost = base.brotli - br(without(i => area[i] === null));
console.log('solid app (views+logic) cost', out.appCost);
if (process.argv[3] === '--show') {
  for (const u of us) { if (!area[u.start]) continue; let s = `// ${u.owner} ${u.orig}\n`, cur = null; for (let i = u.start; i < u.end; i++) { if (label[i] !== cur) { if (cur) s += '⟧'; cur = label[i]; s += `⟦${cur}:`; } s += src[i]; } console.log(s + '⟧\n'); }
}
fs.writeFileSync(`${dir}/solid-account.json`, JSON.stringify(out, null, 2) + '\n');
