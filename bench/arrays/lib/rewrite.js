// The rewrite of beni's list syntax into calls of a candidate's primitives (research/38 §16.2).
// Shared by lists.mjs and all.mjs.
//
// beni emits `::` as a call of `List$cons` already; what it writes inline is the empty list
// `{ $: 0, a: null, b: null }`, a literal's cells `{ $: 1, a: h, b: t }`, the case tests
// `s.$ === 0` / `s.$ === 1`, and the cell reads `s.a` / `s.b` of a subject it has tested. The rewrite
// turns exactly those into `$nil`, `$cons(h, t)`, `$isNil(s)` / `$isCons(s)`, `$hd(s)` and `$tl(s)` —
// what a patched `js/Lower.zig` (`nilNode`, `consNode`, `fanDiscriminant`/`edgeKey` for `.list`,
// `bindings` for `.pat_cons`/`.pat_list`) would emit. A subject is recognised by its test; a read of
// `.a`/`.b` is rewritten only on a subject or on the tail of one, so a tuple's `.a` and a
// constructor's `.a` are left alone.
//
// Since 2026-09-30 beni also emits TAIL CALLS MODULO CONS (backend.md §8): a self call under `::`
// becomes a loop that fills a chain of cells through a destination, `$last.b = { $: 1, a: e, b: null }`.
// A representation other than cons cells cannot be written through `.b`, so `trmc` turns the three
// statements of that shape into calls of a builder the loop owns: `$trmcStart()`, `$trmcAdd(root, e)`
// and `$trmcDone(root, tail)`. That is what the same patched lowering would emit for them. Over cons
// cells the three calls are the destination-passing loop again (seq/cons.js).

export const NIL = '{ $: 0, a: null, b: null }';
const CONS = '{ $: 1, a: ';

export function scanExpr(s, i, stops) { // from i to the first depth-0 occurrence of one of `stops`
  let d = 0;
  for (; i < s.length; i++) {
    const c = s[i];
    if (c === '"' || c === "'" || c === '`') { const q = c; for (i++; i < s.length && s[i] !== q; i++) if (s[i] === '\\') i++; continue; }
    if (d === 0) for (const st of stops) if (s.startsWith(st, i)) return i;
    if (c === '(' || c === '[' || c === '{') d++;
    else if (c === ')' || c === ']' || c === '}') d--;
  }
  throw new Error('unbalanced');
}

// the destination-passing loop of tail calls modulo cons, as builder calls
export function trmc(src) {
  if (!/(?<![\w$])\$last\b/.test(src)) return src;
  let s = src.replace(`const $root = ${CONS}null, b: null };`, 'const $root = $trmcStart();').replace(/\n\s*let \$last = \$root;/, '');
  // `$last.b = { $: 1, a: E, b: null };  $last = $last.b;`  ->  `$trmcAdd($root, E);`
  for (let k = s.indexOf(`$last.b = ${CONS}`); k >= 0; k = s.indexOf(`$last.b = ${CONS}`)) {
    const e0 = k + `$last.b = ${CONS}`.length, e1 = scanExpr(s, e0, [', b: null }']);
    const rest = s.slice(e1 + ', b: null }'.length);
    const m = /^;\s*\$last = \$last\.b;/.exec(rest);
    if (!m) throw new Error('trmc: a cell written without advancing the destination');
    s = s.slice(0, k) + `$trmcAdd($root, ${s.slice(e0, e1)});` + rest.slice(m[0].length);
  }
  // `$last.b = T;  return $root.b;`  ->  `return $trmcDone($root, T);`
  for (let k = s.indexOf('$last.b = '); k >= 0; k = s.indexOf('$last.b = ')) {
    const t0 = k + '$last.b = '.length, t1 = scanExpr(s, t0, [';']);
    const rest = s.slice(t1);
    const m = /^;\s*return \$root\.b;/.exec(rest);
    if (!m) throw new Error('trmc: a destination closed without returning the root');
    s = s.slice(0, k) + `return $trmcDone($root, ${s.slice(t0, t1)});` + rest.slice(m[0].length);
  }
  if (/(?<![\w$])\$(last|root)\b/.test(s.replaceAll('$root = $trmcStart()', '').replace(/\$trmc\w+\(\$root/g, ''))) throw new Error('trmc: the destination survived the rewrite:\n' + s);
  return s;
}

export function rewriteDecl(src) {
  let s = trmc(src).split(NIL).join('$nil');
  for (let k = s.lastIndexOf(CONS); k >= 0; k = s.lastIndexOf(CONS)) {
    const h0 = k + CONS.length, h1 = scanExpr(s, h0, [', b: ']);
    const t0 = h1 + ', b: '.length, t1 = scanExpr(s, t0, [' }']);
    s = s.slice(0, k) + `$cons(${s.slice(h0, h1)}, ${s.slice(t0, t1)})` + s.slice(t1 + 2);
  }
  if (s.includes('reduceRight')) throw new Error('a list literal longer than the cons limit: not handled');
  // a call tested without being bound (`case drop list n of [] -> …`: `List$drop(l, n).$ === 0`)
  for (let k = s.indexOf(').$ === '); k >= 0; k = s.indexOf(').$ === ')) {
    let d = 0, i = k;
    for (; i >= 0; i--) { if (s[i] === ')') d++; else if (s[i] === '(' && --d === 0) break; }
    let c = i;
    while (c > 0 && /[\w$]/.test(s[c - 1])) c--;
    const bit = s[k + ').$ === '.length];
    s = s.slice(0, c) + `${bit === '0' ? '$isNil' : '$isCons'}(${s.slice(c, k + 1)})` + s.slice(k + ').$ === 0'.length);
  }
  const subjects = new Set();
  for (const m of s.matchAll(/(?<![\w$.])([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\.\$ === [01]\b/g)) subjects.add(m[1]);
  s = s.replace(/(?<![\w$.])([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)( === [01]\b)?/g, (all, ch, test) => {
    const t = ch.split('.');
    let cur = t[0], raw = t[0], isList = subjects.has(raw);
    for (let i = 1; i < t.length; i++) {
      const f = t[i];
      if (isList && f === '$') {
        if (i !== t.length - 1 || !test) throw new Error(`a list tag read that is not a test: ${all}`);
        return `${test.endsWith('0') ? '$isNil' : '$isCons'}(${cur})`;
      }
      if (isList && (f === 'a' || f === 'b')) { cur = f === 'a' ? `$hd(${cur})` : `$tl(${cur})`; raw += '.' + f; isList = f === 'b' || subjects.has(raw); }
      else { cur += '.' + f; raw += '.' + f; isList = subjects.has(raw); }
    }
    return cur + (test ?? '');
  });
  if (/\.\$ === [01]\b/.test(s) || s.includes('{ $: 1') || s.includes('{ $: 0')) throw new Error('list syntax survived the rewrite:\n' + s);
  return s;
}

export const splitDecls = (text) => text.split(/\n(?=const |export |import )/);

export function rewriteModule(text, extraImport = '') {
  const out = splitDecls(text).map((d) => (d.startsWith('const ') ? rewriteDecl(d) : d)).join('\n');
  const trmcNames = out.includes('$trmcStart(') ? ', $trmcStart, $trmcAdd, $trmcDone' : '';
  return `import { $nil, $cons, $isNil, $isCons, $hd, $tl, $fromArray${trmcNames} } from "list-syntax";\n${extraImport}${out}`;
}
