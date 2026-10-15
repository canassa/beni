// Prototype: spell each string literal with the quote that needs fewer
// escapes (what Terser's printer does). Same values; only the spelling of
// literals holding `"` changes. usage: node quotes.mjs <in.mjs> <out.mjs>
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, apply, walk} from './lib.mjs';

const [inFile, outFile] = process.argv.slice(2);
const src = fs.readFileSync(inFile, 'utf8'), edits = [];
walk(acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'}), n => {
  if (n.type !== 'Literal' || typeof n.value !== 'string' || !n.raw.startsWith('"')) return;
  const doubles = (n.raw.match(/\\"/g) ?? []).length, singles = (n.raw.match(/'/g) ?? []).length;
  if (doubles <= singles) return;
  const body = n.raw.slice(1, -1).replace(/\\"/g, '"').replace(/'/g, "\\'");
  edits.push({start: n.start, end: n.end, text: `'${body}'`});
});
const out = apply(src, edits);
walk(acorn.parse(out, {ecmaVersion: 'latest', sourceType: 'module'}), () => {});
fs.writeFileSync(outFile, out);
console.log(JSON.stringify({inFile, literals: edits.length, before: br(src), after: br(out)}));
