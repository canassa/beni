// Price research 102's items 4 and 8 one transform at a time on a release
// bundle, as the release printer would write each (backend.md §9,
// *Explicitly not built*, re-measured 2026-10-15). Each transform is a set
// of exact source edits, applied alone to the unchanged bundle; the
// result must parse. Prints, per transform, how many sites it edits and
// the brotli delta (negative saves).
// usage: node bench/output-size/transforms.mjs <bundle.mjs>...
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, apply} from './lib.mjs';

const parse = s => acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'});
// every node with its parent and key
const each = (root, f) => {
  const go = (n, parent, key) => {
    if (!n || typeof n.type !== 'string') return;
    f(n, parent, key);
    for (const [k, v] of Object.entries(n)) {
      if (k === 'type' || k === 'start' || k === 'end') continue;
      if (Array.isArray(v)) v.forEach(x => go(x, n, k));
      else if (v && typeof v.type === 'string') go(v, n, k);
    }
  };
  go(root, null, null);
};
// precedence of an expression, roughly as JS printers rank them
const prec = n => {
  switch (n.type) {
    case 'SequenceExpression': return 1;
    case 'AssignmentExpression': case 'ArrowFunctionExpression': case 'YieldExpression': return 2;
    case 'ConditionalExpression': return 3;
    case 'LogicalExpression': return {'??': 4, '||': 4, '&&': 5}[n.operator];
    case 'BinaryExpression': return 6;
    case 'UnaryExpression': return 15;
    default: return 20;
  }
};
const text = (src, n) => src.slice(n.start, n.end);
const wrap = (src, n, min) => prec(n) < min ? `(${text(src, n)})` : text(src, n);
const single = s => s.type === 'BlockStatement' ? (s.body.length === 1 ? s.body[0] : null) : s;
const startsWithBrace = t => t.startsWith('{') || t.startsWith('function') || t.startsWith('class') || t.startsWith('let[');

const transforms = {
  // item 8: a string literal in the quote that needs fewer escapes
  quotes(src, ast) {
    const edits = [];
    each(ast, n => {
      if (n.type !== 'Literal' || typeof n.value !== 'string' || !n.raw.startsWith('"')) return;
      if ((n.raw.match(/\\"/g) ?? []).length <= (n.raw.match(/'/g) ?? []).length) return;
      edits.push({start: n.start, end: n.end, text: `'${n.raw.slice(1, -1).replace(/\\"/g, '"').replace(/'/g, "\\'")}'`});
    });
    return edits;
  },
  // `true` → `!0`, `false` → `!1`
  booleans(src, ast) {
    const edits = [];
    each(ast, (n, p, k) => {
      if (n.type === 'Literal' && typeof n.value === 'boolean') {
        let t = n.value ? '!0' : '!1';
        if (p && ((p.type === 'MemberExpression' && k === 'object') || (p.type === 'BinaryExpression' && p.operator === '**' && k === 'left'))) t = `(${t})`;
        edits.push({start: n.start, end: n.end, text: t});
      }
    });
    return edits;
  },
  // `undefined` → `void 0`
  void0(src, ast) {
    const edits = [];
    each(ast, (n, p, k) => {
      if (n.type !== 'Identifier' || n.name !== 'undefined') return;
      if (p && ((p.type === 'MemberExpression' && k === 'property' && !p.computed) || (p.type === 'Property' && k === 'key' && !p.computed))) return;
      let t = 'void 0';
      if (p && ((p.type === 'MemberExpression' && k === 'object') || (p.type === 'CallExpression' && k === 'callee'))) t = `(${t})`;
      edits.push({start: n.start, end: n.end, text: t});
    });
    return edits;
  },
  // `if(c)e;` → `c&&e;`
  ifAnd(src, ast) {
    const edits = [];
    each(ast, n => {
      if (n.type !== 'IfStatement' || n.alternate) return;
      const s = single(n.consequent);
      if (!s || s.type !== 'ExpressionStatement') return;
      let t = `${wrap(src, n.test, 5)}&&${wrap(src, s.expression, 6)}`;
      if (startsWithBrace(t)) t = `(${t})`;
      edits.push({start: n.start, end: n.end, text: t + ';'});
    });
    return outer(edits);
  },
  // `if(c)e1;else e2;` → `c?e1:e2;`
  ifElseExpr(src, ast) {
    const edits = [];
    each(ast, n => {
      if (n.type !== 'IfStatement' || !n.alternate) return;
      const a = single(n.consequent), b = single(n.alternate);
      if (!a || !b || a.type !== 'ExpressionStatement' || b.type !== 'ExpressionStatement') return;
      let t = `${wrap(src, n.test, 4)}?${wrap(src, a.expression, 2)}:${wrap(src, b.expression, 2)}`;
      if (startsWithBrace(t)) t = `(${t})`;
      edits.push({start: n.start, end: n.end, text: t + ';'});
    });
    return outer(edits);
  },
  // `if(c)x=a;else x=b;` → `x=c?a:b;`
  ifElseAssign(src, ast) {
    const edits = [];
    each(ast, n => {
      if (n.type !== 'IfStatement' || !n.alternate) return;
      const a = single(n.consequent), b = single(n.alternate);
      if (!a || !b || a.type !== 'ExpressionStatement' || b.type !== 'ExpressionStatement') return;
      const x = a.expression, y = b.expression;
      if (x.type !== 'AssignmentExpression' || y.type !== 'AssignmentExpression' || x.operator !== '=' || y.operator !== '=') return;
      if (x.left.type !== 'Identifier' || y.left.type !== 'Identifier' || x.left.name !== y.left.name) return;
      edits.push({start: n.start, end: n.end, text: `${x.left.name}=${wrap(src, n.test, 4)}?${wrap(src, x.right, 2)}:${wrap(src, y.right, 2)};`});
    });
    return outer(edits);
  },
  // `let x=<chain on B>;B=x;` → `B=<chain>;`
  rebind(src, ast) {
    const edits = [];
    each(ast, n => {
      const body = n.type === 'BlockStatement' ? n.body : n.type === 'SwitchCase' ? n.consequent : null;
      if (!body) return;
      for (let i = 0; i + 1 < body.length; i++) {
        const d = body[i], s = body[i + 1];
        if (d.type !== 'VariableDeclaration' || d.declarations.length !== 1) continue;
        const v = d.declarations[0];
        if (v.id.type !== 'Identifier' || !v.init) continue;
        let base = v.init;
        while (base.type === 'MemberExpression' && !base.computed) base = base.object;
        if (base.type !== 'Identifier') continue;
        if (s.type !== 'ExpressionStatement' || s.expression.type !== 'AssignmentExpression' || s.expression.operator !== '=') continue;
        const {left, right} = s.expression;
        if (left.type !== 'Identifier' || left.name !== base.name || right.type !== 'Identifier' || right.name !== v.id.name) continue;
        // x read nowhere else in this list
        const rest = body.slice(i + 2).map(x => text(src, x)).join(' ');
        if (new RegExp(`\\b${v.id.name.replace('$', '\\$')}\\b`).test(rest)) continue;
        edits.push({start: d.start, end: s.end, text: `${left.name}=${text(src, v.init)};`});
      }
    });
    return outer(edits);
  },
  // `const a=…;const b=…` at the top level → `const a=…,b=…`
  joinConst(src, ast) {
    const edits = [];
    const body = ast.body;
    for (let i = 0; i + 1 < body.length; i++) {
      const a = body[i], b = body[i + 1];
      if (a.type !== 'VariableDeclaration' || b.type !== 'VariableDeclaration' || a.kind !== 'const' || b.kind !== 'const') continue;
      const lastDecl = a.declarations[a.declarations.length - 1];
      edits.push({start: lastDecl.end, end: b.declarations[0].start, text: ','});
    }
    return edits;
  },
  // `if(c)return a;else return b;` / `if(c)return a;return b;` → `return c?a:b;`
  ifReturn(src, ast) {
    const edits = [];
    each(ast, n => {
      const body = n.type === 'BlockStatement' || n.type === 'Program' ? n.body : n.type === 'SwitchCase' ? n.consequent : null;
      if (!body) return;
      for (let i = 0; i < body.length; i++) {
        const s = body[i];
        if (s.type !== 'IfStatement') continue;
        const a = single(s.consequent);
        if (!a || a.type !== 'ReturnStatement' || !a.argument) continue;
        let b = s.alternate ? single(s.alternate) : body[i + 1], end = s.alternate ? s.end : body[i + 1]?.end;
        if (!b || b.type !== 'ReturnStatement' || !b.argument) continue;
        edits.push({start: s.start, end, text: `return ${wrap(src, s.test, 4)}?${wrap(src, a.argument, 2)}:${wrap(src, b.argument, 2)};`});
      }
    });
    return outer(edits);
  },
};
// keep only edits that do not overlap an earlier (outer) one
function outer(edits) {
  edits.sort((a, b) => a.start - b.start || b.end - a.end);
  const out = [];
  let end = -1;
  for (const e of edits) if (e.start >= end) { out.push(e); end = e.end; }
  return out;
}

for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const base = br(src);
  const row = {file, base};
  for (const [name, t] of Object.entries(transforms)) {
    const edits = t(src, parse(src));
    const out = apply(src, edits);
    parse(out);
    row[name] = `${edits.length}:${br(out) - base}`;
  }
  console.log(JSON.stringify(row));
}
