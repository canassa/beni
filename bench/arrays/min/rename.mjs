// Report 40 §7 (a), transformation A2: renaming without scope analysis. Every identifier token
// that is bound somewhere in the file, is not exported, is not a standard global and never stands
// where a property name can (after `.`, before `:`, as a `{x}` shorthand) is replaced EVERYWHERE by
// one fresh short name, most frequent first. Because the map is injective onto names the file never
// uses, every binding of a name moves together with every use of it, so shadowing cannot change
// what a use refers to: this is alpha-renaming, and it needs tokens, not scopes. A prototype over
// the output of beni's compactor, for measurement only (a regular-expression tokenizer that is right
// for these files, which have no regular expressions and no identifiers inside strings).
//
//   node min/rename.mjs <file> [export…]    prints the renamed file
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

export function rename(src, exported) {
  const KEYWORDS = new Set('break case catch class const continue debugger default delete do else export extends false finally for function if import in instanceof let new null of return super switch this throw true try typeof var void while with yield async await static get set undefined NaN Infinity'.split(' '));
  const GLOBALS = new Set('Array Math Object String Number Boolean Symbol JSON Map Set WeakMap WeakSet Promise Error TypeError RangeError Date RegExp globalThis window document console'.split(' '));
  const tokens = [...src.matchAll(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|[A-Za-z_$][\w$]*|\d[\w.]*|\?\.|=>|[^\sA-Za-z_$\d]/g)];
  const text = tokens.map((m) => m[0]);
  const isIdent = (t) => /^[A-Za-z_$][\w$]*$/.test(t) && !KEYWORDS.has(t);
  const count = new Map(), refused = new Set(exported);
  text.forEach((t, i) => {
    if (!isIdent(t)) return;
    const prev = text[i - 1], next = text[i + 1];
    if (prev === '.' || prev === '?.') return; // a property: never renamed, never a reason to refuse
    // a key (`x:` inside an object literal, or a label) or a shorthand property `{x}` / `{…, x}`
    const shorthand = (prev === '{' || prev === ',') && (next === '}' || next === ',') && text.lastIndexOf('{', i) > text.lastIndexOf('(', i);
    if (next === ':' || shorthand) refused.add(t);
    count.set(t, (count.get(t) || 0) + 1);
  });
  // a name is renamed only if the file binds it: after let/const/var/function, or as a parameter
  const bound = new Set();
  text.forEach((t, i) => {
    if (['let', 'const', 'var', 'function'].includes(text[i - 1]) && isIdent(t)) bound.add(t);
    if ((text[i + 1] === ',' || text[i + 1] === ')' || text[i + 1] === '=' || text[i + 1] === '=>') && isIdent(t)) bound.add(t);
  });
  const names = [...count.keys()].filter((t) => bound.has(t) && !refused.has(t) && !GLOBALS.has(t)).sort((a, b) => count.get(b) - count.get(a));
  const used = new Set(text.filter(isIdent));
  const fresh = [];
  for (const c of 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ') if (!used.has(c) || names.includes(c)) fresh.push(c);
  const map = new Map();
  for (const n of names) {
    if (n.length === 1) continue; // already as short as it gets
    const f = fresh.find((c) => !map.has(c) && ![...map.values()].includes(c) && (!used.has(c)));
    if (f) map.set(n, f);
  }
  return text.map((t, i) => (map.has(t) && text[i - 1] !== '.' && text[i - 1] !== '?.' ? map.get(t) : t)).reduce((out, t, i) => {
    const prev = out.at(-1);
    return out + (prev && /[\w$]$/.test(out) && /^[\w$]/.test(t) ? ' ' : '') + t;
  }, '');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const src = fs.readFileSync(process.argv[2], 'utf8');
  process.stdout.write(rename(src, process.argv.slice(3)));
}
