// Prototype: inline every top-level binding that is read exactly once, when
// its initialiser is pure to evaluate (a function, or an array or object
// literal of literals and functions) and its one read is evaluated once, at
// module initialisation: in a LATER top-level initialiser and not under any
// function, loop, class body or accessor (anything that may run it twice or
// later). Evaluation count, order of effects and identity are unchanged:
// the value is still created exactly once, by the same expression, before
// anything can observe it. References are resolved with scopes (beni's
// release locals reuse short names that also name top-level bindings).
// usage: node inline-toplevel.mjs <in.mjs> <out.mjs>
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, apply} from './lib.mjs';

const [inFile, outFile] = process.argv.slice(2);
let src = fs.readFileSync(inFile, 'utf8');
const pure = n => {
  if (!n) return false;
  switch (n.type) {
    case 'ArrowFunctionExpression': case 'FunctionExpression': case 'Literal': return true;
    case 'Identifier': return n.name === 'undefined';
    case 'UnaryExpression': return pure(n.argument);
    case 'ArrayExpression': return n.elements.every(e => e && pure(e));
    case 'ObjectExpression': return n.properties.every(p => p.type === 'Property' && !p.computed && pure(p.value));
    default: return false;
  }
};
const patternNames = (p, out = []) => {
  if (!p) return out;
  if (p.type === 'Identifier') out.push(p.name);
  else if (p.type === 'ObjectPattern') p.properties.forEach(q => patternNames(q.type === 'RestElement' ? q.argument : q.value, out));
  else if (p.type === 'ArrayPattern') p.elements.forEach(e => patternNames(e, out));
  else if (p.type === 'RestElement') patternNames(p.argument, out);
  else if (p.type === 'AssignmentPattern') patternNames(p.left, out);
  return out;
};
// names a block-like list of statements declares directly (let/const/class/function; var hoists to the function)
const blockNames = body => body.flatMap(s => s.type === 'VariableDeclaration' ? s.declarations.flatMap(d => patternNames(d.id))
  : s.type === 'FunctionDeclaration' || s.type === 'ClassDeclaration' ? [s.id.name] : []);
const varNames = fnBody => { const out = []; (function w(n) { if (!n?.type || (/Function/.test(n.type) && n.body !== fnBody)) return; if (n.type === 'VariableDeclaration' && n.kind === 'var') n.declarations.forEach(d => patternNames(d.id, out)); for (const v of Object.values(n)) { if (Array.isArray(v)) v.forEach(w); else if (v?.type) w(v); } })(fnBody); return out; };

let total = 0;
for (let round = 0; round < 6; round++) {
  const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
  const decls = new Map();
  ast.body.forEach((s, i) => { if (s.type === 'VariableDeclaration') for (const d of s.declarations) if (d.id.type === 'Identifier') decls.set(d.id.name, {d, s, i}); });
  const refs = new Map(); // top-level name -> uses that resolve to it
  const visit = (n, parent, key, scopes, underFn, top) => {
    if (!n?.type) return;
    if (n.type === 'Identifier') {
      const isKey = (parent?.type === 'Property' && key === 'key' && !parent.computed) || (parent?.type === 'MemberExpression' && key === 'property' && !parent.computed) || parent?.type === 'LabeledStatement' || parent?.type === 'BreakStatement' || parent?.type === 'ContinueStatement';
      const isDecl = parent?.type === 'VariableDeclarator' && key === 'id';
      if (!isKey && !isDecl && !scopes.some(s => s.has(n.name))) {
        if (!refs.has(n.name)) refs.set(n.name, []);
        refs.get(n.name).push({n, parent, key, underFn, top, shorthand: parent?.type === 'Property' && parent.shorthand, exported: /Export/.test(parent?.type ?? '')});
      }
      return;
    }
    let inner = scopes, fn = underFn || /^(For|ForIn|ForOf|While|DoWhile)Statement$|^Class(Body|Declaration|Expression)$|^(MethodDefinition|PropertyDefinition|StaticBlock)$/.test(n.type) || (n.type === 'Property' && n.kind !== 'init');
    if (/Function/.test(n.type)) {
      fn = true;
      const names = n.params.flatMap(p => patternNames(p));
      if (n.id && n.type === 'FunctionExpression') names.push(n.id.name);
      if (n.body.type === 'BlockStatement') names.push(...varNames(n.body));
      inner = [new Set(names), ...scopes];
    } else if (n.type === 'BlockStatement' || n.type === 'SwitchStatement') {
      const body = n.type === 'BlockStatement' ? n.body : n.cases.flatMap(c => c.consequent);
      inner = [new Set(blockNames(body)), ...scopes];
    } else if (/^(For|ForIn|ForOf)Statement$/.test(n.type)) {
      const init = n.type === 'ForStatement' ? n.init : n.left;
      inner = [new Set(init?.type === 'VariableDeclaration' ? init.declarations.flatMap(d => patternNames(d.id)) : []), ...scopes];
    } else if (n.type === 'CatchClause') {
      inner = [new Set(patternNames(n.param)), ...scopes];
    }
    for (const [k, v] of Object.entries(n)) {
      if (k === 'params' || (k === 'id' && /Function/.test(n.type))) continue;
      if (Array.isArray(v)) v.forEach(x => visit(x, n, k, inner, fn, top));
      else if (v?.type) visit(v, n, k, inner, fn, top);
    }
    if (/Function/.test(n.type)) for (const p of n.params) if (p.type === 'AssignmentPattern') visit(p.right, p, 'right', inner, true, top);
  };
  ast.body.forEach((s, i) => visit(s, null, null, [], false, i));
  const remove = new Set(), uses = [], taken = [];
  const overlaps = (a, b) => a[0] < b[1] && b[0] < a[1];
  for (const [name, {d, i}] of decls) {
    const rs = refs.get(name) ?? [];
    if (rs.length !== 1 || !pure(d.init)) continue;
    const r = rs[0];
    if (r.underFn || r.n.start < d.end || r.shorthand || r.exported) continue;
    const span = [d.start, d.end], use = [r.n.start, r.n.end];
    if (taken.some(t => overlaps(t, span) || overlaps(t, use))) continue;
    taken.push(span, use);
    remove.add(d);
    const safe = (/^(CallExpression|NewExpression)$/.test(r.parent?.type) && r.key === 'arguments') || r.parent?.type === 'ArrayExpression' || (r.parent?.type === 'Property' && r.key === 'value') || (r.parent?.type === 'VariableDeclarator' && r.key === 'init');
    const text = src.slice(d.init.start, d.init.end);
    uses.push({start: use[0], end: use[1], text: safe || !/Function/.test(d.init.type) ? text : `(${text})`});
  }
  if (!remove.size) break;
  // rebuild each touched declaration statement from its kept declarators
  const edits = [...uses];
  for (const s of ast.body) {
    if (s.type !== 'VariableDeclaration' || !s.declarations.some(d => remove.has(d))) continue;
    const kept = s.declarations.filter(d => !remove.has(d));
    const inner = uses.filter(u => s.start <= u.start && u.end <= s.end);
    // uses inside this statement are applied within the rebuilt text
    const piece = d => apply(src.slice(d.start, d.end), inner.filter(u => d.start <= u.start && u.end <= d.end).map(u => ({...u, start: u.start - d.start, end: u.end - d.start})));
    edits.splice(0, edits.length, ...edits.filter(e => !inner.includes(e)));
    edits.push({start: s.start, end: s.end, text: kept.length ? `${s.kind} ${kept.map(piece).join(',')};` : ''});
  }
  src = apply(src, edits);
  try { acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'}); } catch (e) { console.error(src.slice(e.pos - 300, e.pos + 100)); throw e; }
  total += remove.size;
}
fs.writeFileSync(outFile, src);
console.log(JSON.stringify({inFile, inlined: total, before: br(fs.readFileSync(inFile, 'utf8')), after: br(src)}));
