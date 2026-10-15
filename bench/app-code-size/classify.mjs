// Paint every byte of Conduit's app code (research 102's two areas: views and
// update/init/requests) with the construct that emitted it. A byte belongs to
// the innermost classified AST node containing it; a byte no rule claims takes
// its unit's default. Names are resolved with scope, so a local `m` is never
// taken for core/Task's top-level `m`.
import * as acorn from '../output-size/node_modules/acorn/dist/acorn.mjs';
import {units} from '../output-size/units.mjs';

// ---- areas (research 102's grouping, unchanged) ---------------------------
const isSchema = o => /\$\$/.test(o ?? '');
const isMarkup = o => /^(p|k|t|b)\d+$|^(dg|dp|dr)\d+_\d+$/.test(o ?? '');
const isUpdate = o => /^(update|init|initEdit|changeRouteTo|updateForm|updateWith|save|validate|toSession|savingError|currentUsername)$/.test(o ?? '');
const isViewFn = o => /^view|Button$|^(frame|navbarLink|footer|loading|loadingError|avatar|avatarSrc|defaultAvatar|link|href|timestamp|tags|body|fields|formBody|slowThreshold)$/.test(o ?? '');
export const areaOf = u => {
  if (!u.owner.startsWith('app/') || isSchema(u.orig)) return null;
  if (isMarkup(u.orig) || u.orig === 'main') return 'views';
  return 'logic';
};
export const subAreaOf = u => u.orig === 'main' ? 'main' : isMarkup(u.orig) ? 'markup' : isUpdate(u.orig) ? 'update/init' : isViewFn(u.orig) ? 'view functions' : 'requests, routes, helpers';

// ---- construct classes, in the order of the ordered account ---------------
export const VIEW_CLASSES = [
  ['html', 'HTML template strings'],
  ['tdecl', 'template constants: the template(…, flags) call and binding'],
  ['walk', 'clone and walk to holes (firstChild/nextSibling)'],
  ['slotmk', 'slot and text-node creation at mount'],
  ['irefs', 'instance record: node and slot references'],
  ['iinit', 'instance record: initial values of kept fields'],
  ['kind', 'kind objects {m,p,l}: mount function shells'],
  ['pshell', 'patch function shells and statement syntax (let, if, braces)'],
  ['hoisted', 'hoisted constant blocks {t,v:null} and static kinds'],
  ['prologue', 'patch prologue: binding inputs from the argument vector'],
  ['gguard', 'group guards: path tests and kept-path stores'],
  ['letcache', 'view let cache (derived values kept in the instance)'],
  ['hguard', 'hole guards: value tests and kept-value stores'],
  ['write', 'DOM writes (data, setAttribute, classList, control, safeUrl)'],
  ['value', 'value expressions (the view\'s own computations)'],
  ['place', 'slot placement: childHtml/childMaybe calls'],
  ['restate', 'restate calls and their else branches'],
  ['live', 'liveness bookkeeping (a.l = …, l:true, w:true)'],
  ['block', 'blocks built per render {t:kind,v:[inputs]}'],
  ['helper', 'helper and component calls (callee and arguments)'],
  ['msg', 'message constructors {$:tag,…}'],
  ['event', 'event wiring ($$click, extractors, $$cx, listen, handler closures)'],
  ['row', 'list rows: forKeyed/forPosition calls, row objects, key functions'],
  ['map', 'Html.map / taggers'],
  ['dgroup', 'direct: group descriptors and templateGroup attachment'],
  ['dentry', 'direct: templatePatch entries and their shells'],
  ['dpath', 'direct: path IDs (call-site strings)'],
  ['dctx', 'direct: context capture, templatePlace/Value, templateInputs'],
  ['matrix', 'direct: consumer matrix (masks per call path)'],
  ['handler', 'direct: per-key handlers (shared update call, root patch, title, commands)'],
  ['dispatch', 'direct: message dispatcher tree'],
  ['rootsel', 'direct: root selector and document arms'],
  ['mount', 'direct: program mount and host wiring'],
  ['braces', 'redundant nested block braces'],
  ['other', 'other (syntax of the unit not claimed above)'],
];
export const LOGIC_CLASSES = [
  ['dispatch', 'message dispatch: switch/case and tag tests'],
  ['spread', 'record updates: spreads {...r, f: v}'],
  ['tuple', 'tuples and records built ({a,b} pairs, new records)'],
  ['msg', 'message and constructor values {$:tag,…}'],
  ['cmd', 'commands: Cmd.task/batch/map/none and their thunks'],
  ['http', 'requests: Api/Http/Url.Builder calls and route tables'],
  ['string', 'strings and string formatting'],
  ['list', 'List and Maybe/Result library calls'],
  ['block', 'markup blocks and view wrappers {t,v}'],
  ['bind', 'bindings, parameters and returns'],
  ['braces', 'redundant nested block braces'],
  ['other', 'other (control flow, operators, punctuation)'],
];

// ---- scope-aware resolution ------------------------------------------------
const declared = (fn) => {
  const s = new Set();
  const pat = p => {
    if (!p) return;
    if (p.type === 'Identifier') s.add(p.name);
    else if (p.type === 'ObjectPattern') p.properties.forEach(q => pat(q.value ?? q.argument));
    else if (p.type === 'ArrayPattern') p.elements.forEach(pat);
    else if (p.type === 'RestElement') pat(p.argument);
    else if (p.type === 'AssignmentPattern') pat(p.left);
  };
  fn.params?.forEach(pat);
  const visit = n => {
    if (!n?.type) return;
    if (n !== fn && /Function/.test(n.type)) { if (n.type === 'FunctionDeclaration') s.add(n.id.name); return; }
    if (n.type === 'VariableDeclarator') pat(n.id);
    if (n.type === 'CatchClause') pat(n.param);
    for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(visit); else if (v?.type) visit(v); }
  };
  visit(fn.body);
  return s;
};

// ---- the painter -----------------------------------------------------------
export function classify(src, map, platform) {
  const {units: us} = units(src, map);
  const top = new Map(us.map(u => [u.js, u]));
  const label = new Array(src.length).fill(null);
  const area = new Array(src.length).fill(null);
  const paint = (a, b, c) => { for (let i = a; i < b; i++) label[i] = c; };
  const rt = (name, scopes) => {
    if (!name || scopes.some(s => s.has(name))) return null;
    const u = top.get(name); return u ? {owner: u.owner, orig: (u.orig ?? '').replace(/\$s$/, '')} : null;
  };
  const prop = n => n.type === 'MemberExpression' && !n.computed ? n.property.name : null;
  const isChain = n => n.type === 'MemberExpression' && ['firstChild', 'nextSibling'].includes(prop(n)) && (n.object.type === 'Identifier' || isChain(n.object));
  const objKeys = n => n.type === 'ObjectExpression' ? n.properties.map(p => p.key?.name ?? p.key?.value ?? (p.type === 'SpreadElement' ? '...' : '?')) : [];
  const fieldOf = n => n.type === 'MemberExpression' && n.object.type === 'Identifier' ? prop(n) : null;
  const refsField = (n, re) => { let hit = false; const w = x => { if (!x?.type || hit) return; if (x.type === 'MemberExpression' && re.test(prop(x) ?? '')) hit = true; for (const v of Object.values(x)) { if (Array.isArray(v)) v.forEach(w); else if (v?.type) w(v); } }; w(n); return hit; };
  const onlyCalls = (n, pred) => { // a statement or block made only of calls satisfying pred
    if (!n) return false;
    if (n.type === 'BlockStatement') return n.body.length > 0 && n.body.every(s => onlyCalls(s, pred));
    return n.type === 'ExpressionStatement' && n.expression.type === 'CallExpression' && pred(n.expression);
  };
  const isPathString = n => n.type === 'Literal' && typeof n.value === 'string' && /^(\$[a-z]+\/?)?\/?\d+:\d+(\/\d+:\d+)*$|^\/\d+:\d+/.test(n.value);

  for (const u of us) {
    const ar = areaOf(u); if (!ar) continue;
    for (let i = u.start; i < u.end; i++) area[i] = ar;
    const o = u.orig ?? '';
    const dflt = ar === 'logic' ? 'other'
      : /^t\d+$/.test(o) ? 'tdecl' : /^k\d+$/.test(o) ? 'kind' : /^b\d+$/.test(o) ? 'hoisted'
      : /^dg/.test(o) ? 'dgroup' : /^dr/.test(o) ? 'restate' : /^(p\d+|dp)/.test(o) ? 'pshell' : o === 'main' ? 'mount' : 'other';
    paint(u.start, u.end, dflt);
    // the unit's top-level declarator node
    const ast = acorn.parse(src.slice(u.start, u.end).replace(/^/, 'let '), {ecmaVersion: 'latest', sourceType: 'module'});
    const off = u.start - 4;
    const P = (n, c) => paint(n.start + off, n.end + off, c);
    // a static kind {m:()=>{…return{s,q,e}},p:()=>{}} is a hoisted constant
    if (/^k\d+$/.test(o) && /p:\(\)=>\{\}\}$/.test(src.slice(u.start, u.end))) { paint(u.start, u.end, 'hoisted'); continue; }

    const walkN = (n, scopes, parent, ctx) => {
      if (!n?.type) return;
      if (/Function/.test(n.type)) scopes = [...scopes, declared(n)];
      const r = n.type === 'CallExpression' && n.callee.type === 'Identifier' ? rt(n.callee.name, scopes) : null;
      const ro = r ? `${r.owner}.${r.orig}` : '';
      if (ar === 'views' && o === 'main') {
        if (r && /\.templatePlan$/.test(ro)) { P(n, 'matrix'); return; }
        if (n.type === 'ObjectExpression' && objKeys(n)[0] === '$') P(n, 'msg');
        if (n.type === 'BlockStatement' && parent?.type === 'BlockStatement') { paint(n.start + off, n.start + off + 1, 'braces'); paint(n.end + off - 1, n.end + off, 'braces'); }
      } else if (ar === 'views') {
        if (r && /Rt\.template$/.test(ro)) { P(n, 'tdecl'); const h = n.arguments[0]; if (h) P(h, 'html'); return; }
        if (r && /\.(slot|insertText)$/.test(ro)) { P(n, 'slotmk'); return; }
        if (r && /\.(childHtml|childMaybe|childList)$/.test(ro)) { P(n, 'place'); }
        if (r && /\.(restate|restateValue)$/.test(ro)) { P(n, 'restate'); return; }
        if (r && /\.(forKeyed|forPosition|templateRow)$/.test(ro)) { P(n, 'row'); }
        if (r && /\.(map|templateMap\w*)$/.test(ro) && /Rt|Direct/.test(r.owner)) { P(n, 'map'); }
        if (r && /\.(safeUrl|control|attr|attrNS|classes|styles|rawHtml|edited)$/.test(ro)) { P(n, 'write'); }
        if (r && /\.listen$/.test(ro)) { P(n, 'event'); return; }
        if (r && /\.templateGroup$/.test(ro)) { P(n, 'dgroup'); }
        if (r && /\.templatePatch$/.test(ro)) { P(n, 'dentry'); }
        if (r && /\.(templatePlace|templateValue|templateInputs|templateCapture)$/.test(ro)) { P(n, 'dctx'); }
        if (r && /\.templatePlan$/.test(ro)) { P(n, 'matrix'); return; }
        if (r && r.owner.startsWith('app/') && isMarkup(r.orig) && /^t/.test(r.orig)) { P(n, 'walk'); return; } // clone
        if (r && r.owner.startsWith('app/') && !isMarkup(r.orig) && r.orig !== 'main' && !isSchema(r.orig)) { if (ctx !== 'main') P(n, 'helper'); }
        if (r && /Html\.preventDefault$/.test(ro)) { P(n, 'event'); }
        if (isPathString(n)) { P(n, 'dpath'); return; }
        if (isChain(n)) { P(n, 'walk'); return; }
        if (n.type === 'ObjectExpression') {
          const ks = objKeys(n);
          if (ks[0] === '$') P(n, 'msg');
          else if (ks.length === 2 && ks[0] === 't' && ks[1] === 'v') P(n, n.properties[1].value.type === 'Literal' ? 'hoisted' : 'block');
          else if (ks.includes('m') && ks.includes('p') && !(ctx === 'top' && /^k\d+$/.test(o))) P(n, 'row');
          else if (ks[0] === 's' && ks.includes('q') && ks.includes('e')) { // instance record
            for (const p of n.properties) {
              const v = p.value;
              const init = v.type === 'Identifier' && v.name === 'undefined' || v.type === 'Identifier' && v.name === 'NaN' || v.type === 'Literal' && (v.value === null || typeof v.value === 'boolean') && !/^[sqe]$/.test(p.key.name);
              P(p, init ? 'iinit' : 'irefs');
              if (isChain(v)) P(v, 'walk');
            }
            return;
          }
          if (ks.includes('l') || ks.includes('w')) for (const p of n.properties) if (['l', 'w'].includes(p.key?.name) && p.value.type === 'Literal') P(p, 'live');
        }
        if (n.type === 'ArrayExpression' && /^dg/.test(o)) { P(n, 'dgroup'); }
        // a block directly inside a block: braces no statement needs (left by the lowering)
        if (n.type === 'BlockStatement' && parent?.type === 'BlockStatement') { paint(n.start + off, n.start + off + 1, 'braces'); paint(n.end + off - 1, n.end + off, 'braces'); }
        if (n.type === 'VariableDeclaration' && (/^(p\d+|dp)/.test(o) || ctx === 'row')) P(n, 'value');
        if (n.type === 'VariableDeclarator' && n.init) {
          const ini = n.init;
          const ir = ini.type === 'CallExpression' && ini.callee.type === 'Identifier' ? rt(ini.callee.name, scopes) : null;
          if (isChain(ini) || ir && ir.owner.startsWith('app/') && /^t\d+$/.test(ir.orig)) P(n, 'walk');
          else if (ir && /^(slot|insertText)$/.test(ir.orig)) P(n, 'slotmk');
          else if (fieldOf(ini) && /^d\d+$/.test(fieldOf(ini))) P(n, 'letcache');
          else if (ini.type === 'ArrowFunctionExpression' && ini.body.type === 'MemberExpression') P(n, 'row'); // a row's key function
          else if (ini.type === 'ArrowFunctionExpression' && o !== 'main') P(n, 'event'); // a handler closure
          else if (ini.type === 'MemberExpression' && ini.computed && ini.object.type === 'Identifier' && ini.property.type === 'Literal') P(n, 'prologue');
          else if (ini.type === 'Identifier' && /^(p|dp)/.test(o)) P(n, 'prologue');
          else if (/^(p\d+|dp)/.test(o) || (ctx === 'row')) { P(n, 'value'); }
        }
        if (n.type === 'IfStatement') {
          const t = n.test;
          const guardKind = refsField(t, /^g\d+(_\d+)?$/) ? 'gguard' : refsField(t, /^l\d+_\d+$/) ? 'letcache' : refsField(t, /^a\d+(_\d+)?$|^x$/) ? 'hguard' : null;
          if (t.type === 'BinaryExpression' && t.operator === '!==' && t.right.type === 'Literal' && t.right.value === null && /\$\$cx/.test(src.slice(n.start + off, n.end + off))) { P(n, 'event'); return; }
          if (guardKind) P(n, guardKind);
          if (n.alternate && onlyCalls(n.alternate, c => { const q = c.callee.type === 'Identifier' && rt(c.callee.name, scopes); return q && /^(restate|restateValue)$/.test(q.orig); })) {
            paint(n.consequent.end + off, n.alternate.end + off, 'restate');
          }
        }
        if (n.type === 'ExpressionStatement' && n.expression.type === 'AssignmentExpression') {
          const L = n.expression.left, f = fieldOf(L) ?? prop(L);
          if (/^\$\$(click|input|submit|keydown|blur|change|cx|\w+X)$|^\$\$\w+$/.test(f ?? '') && !/^\$\$direct/.test(f)) { P(n, 'event'); return; }
          if (L.type === 'MemberExpression' && L.object.type === 'Identifier' && /^g\d+(_\d+)?$/.test(f ?? '')) { P(n, 'gguard'); return; }
          if (L.type === 'MemberExpression' && L.object.type === 'Identifier' && /^(l\d+_\d+|d\d+)$/.test(f ?? '')) { P(n, 'letcache'); walkN(n.expression.right, scopes, n, ctx); return; }
          if (L.type === 'MemberExpression' && L.object.type === 'Identifier' && /^(a\d+(_\d+)?|x)$/.test(f ?? '')) { P(n, 'hguard'); return; }
          if (f === 'l' || f === 'w') { P(n, 'live'); return; }
          if (L.type === 'MemberExpression' && ['data', 'className', 'value', 'checked', 'disabled', 'textContent'].includes(f)) { P(n, 'write'); }
        }
        if (n.type === 'ExpressionStatement' && n.expression.type === 'CallExpression' && n.expression.callee.type === 'MemberExpression' && ['setAttribute', 'removeAttribute', 'toggle', 'setProperty'].includes(prop(n.expression.callee))) { P(n, 'write'); }
      } else { // logic
        if (n.type === 'BlockStatement' && parent?.type === 'BlockStatement') { paint(n.start + off, n.start + off + 1, 'braces'); paint(n.end + off - 1, n.end + off, 'braces'); }
        if (n.type === 'SwitchStatement') { P(n.discriminant, 'dispatch'); for (const c of n.cases) if (c.test) paint(c.start + off, c.test.end + off + 1, 'dispatch'); }
        if (n.type === 'BinaryExpression' && /^[!=]==$/.test(n.operator) && n.left.type === 'MemberExpression' && prop(n.left) === '$') { P(n, 'dispatch'); return; }
        if (n.type === 'ObjectExpression') {
          const ks = objKeys(n);
          if (ks[0] === '...') P(n, 'spread');
          else if (ks[0] === '$') P(n, 'msg');
          else if (ks.length === 2 && ks[0] === 't' && ks[1] === 'v') P(n, 'block');
          else P(n, 'tuple');
        }
        if (r && /Cmd\.|Tea\./.test(ro)) { P(n, 'cmd'); }
        if (n.type === 'Identifier' && !scopes.some(s => s.has(n.name))) { const q = top.get(n.name); if (q && /Cmd\.none/.test(`${q.owner}.${q.orig}`)) { P(n, 'cmd'); return; } }
        if (r && /Http|Url\/Builder|Url\/Parser|Navigation|Storage|core\/Task/.test(r.owner)) { P(n, 'http'); }
        if (r && r.owner === 'app/Route') { P(n, 'http'); }
        if (r && r.owner.startsWith('app/') && /^(get|post|put|delete|url|request|ignored|errorMessages|href|routeToPieces|fromUrl|replaceUrl|parser|storeCred|storedViewer|logout)$/.test(r.orig)) { P(n, 'http'); }
        if (r && /String$|Basics\.append$/.test(r.owner + (r.orig === 'append' ? '.append' : ''))) { P(n, 'string'); }
        if (r && /core\/(String)/.test(r.owner)) { P(n, 'string'); }
        if (r && /core\/(List|Maybe|Result|Dict)/.test(r.owner)) { P(n, 'list'); }
        if (n.type === 'TemplateLiteral' || n.type === 'Literal' && typeof n.value === 'string') { P(n, 'string'); return; }
        if (n.type === 'VariableDeclarator') paint(n.id.start + off, n.id.end + off + 1, 'bind');
        if (n.type === 'ReturnStatement') paint(n.start + off, n.start + off + 6, 'bind');
        if (/Function/.test(n.type) && parent) { if (n.params.length) paint(n.params[0].start + off, n.params.at(-1).end + off, 'bind'); }
      }
      // main: handlers / dispatcher / root selector (direct)
      if (o === 'main' && platform === 'direct' && n.type === 'VariableDeclarator' && n.init && /Function/.test(n.init.type) && ctx !== 'deep') {
        const body = src.slice(n.init.start + off, n.init.end + off);
        const kind = /Jf\(|templateProgram/.test(body) && /^\w=a=>\{\w+\(null\)/.test(src.slice(n.start + off, n.end + off)) ? 'handler'
          : /^\(\)=>\{let a=\w+\(\w+\(d\)\)/.test(body) || /switch\(d\.\$\)/.test(body) ? 'rootsel'
          : /return\}if\(a\.\$===|^a=>\{if\(a\.\$===/.test(body) ? 'dispatch' : null;
        if (kind) { P(n, kind); ctx = 'deep'; for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => walkN(x, scopes, n, ctx)); else if (v?.type) walkN(v, scopes, n, ctx); } return; }
      }
      const nctx = ctx === 'top' && n.type === 'ObjectExpression' && /^k\d+$/.test(o) ? 'kindtop' : (o === 'main' ? (ctx === 'deep' ? 'deep' : 'main') : (ctx === 'kindtop' ? 'kind' : ctx));
      for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(x => walkN(x, scopes, n, nctx)); else if (v?.type) walkN(v, scopes, n, nctx); }
    };
    const decl = ast.body[0]?.declarations?.[0];
    if (decl?.init) walkN(decl.init, [], decl, 'top');
  }
  return {us, label, area};
}
