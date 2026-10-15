// Prototype: a compiled schema reader's per-field block, written once as a
// shared helper instead of inline in every field of every schema. Each
// field still gets exactly the same checks, issue codes and messages, in
// the same order (missing key, depth limit, type), and the same value.
// The issue context argument is evaluated eagerly per field where the
// compiler had inlined it lazily; results are identical, an allocation per
// field is not (a real lowering would pass it lazily or hoist it once).
// usage: node schema-outline.mjs <in.mjs> <out.mjs>
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br} from './lib.mjs';

const [inFile, outFile] = process.argv.slice(2);
let src = fs.readFileSync(inFile, 'utf8');
const I = '[\\w$]+', CTX = '[\\w$]+(?:\\([\\w$]+,[\\w$]+,[\\w$]+\\))?';
// J value, K raw, F object, KEY, H depth flag, P problem fn, A context, C ctx expr
const head = `(?<=let |,)(${I}),(${I})=(${I})\\["([\\w$]+)"\\];if\\(\\2!==undefined\\)\\{if\\((${I})\\)\\1=(${I})\\((${I}),(${CTX}),"\\4","\\4",5,"the depth limit is reached",\\2\\);else `;
const tail = `\\}else \\1=\\6\\(\\7,\\8,"\\4","\\4",1,"missing key \\\\"\\4\\\\"",\\3\\);if\\(\\1===\\7\\.a&&true\\)return \\7\\.a;`;
const shapes = [
  ['string', `if\\(typeof \\2!=="string"\\)\\1=\\6\\(\\7,\\8,"\\4","\\4",0,"expected a string",\\2\\);else \\1=\\2`, '$$s'],
  ['boolean', `if\\(typeof \\2!=="boolean"\\)\\1=\\6\\(\\7,\\8,"\\4","\\4",0,"expected a boolean",\\2\\);else \\1=\\2`, '$$b'],
  ['int', `if\\(typeof \\2!=="number"\\)\\1=\\6\\(\\7,\\8,"\\4","\\4",0,"expected a number",\\2\\);else if\\(!Number\\.isSafeInteger\\(\\2\\)\\)\\1=\\6\\(\\7,\\8,"\\4","\\4",4,"expected a safe integer",\\2\\);else \\1=\\2`, '$$i'],
  ['nullable string', `if\\(\\2===null\\)\\1=(${I});else\\{let (${I});if\\(typeof \\2!=="string"\\)\\10=\\6\\(\\7,\\8,"\\4","\\4",0,"expected a string",\\2\\);else \\10=\\2;\\1=\\10===\\7\\.a\\?\\7\\.a:\\{\\$:1,a:\\10\\}\\}`, '$$u'],
  ['nested', `\\1=(${I})\\(\\7,(${I})\\+1,\\8,"\\4","\\4",\\2\\)`, null],
];
const counts = {};
let P;
for (const [name, body, helper] of shapes) {
  const re = new RegExp(head + body + tail, 'g');
  counts[name] = 0;
  src = src.replace(re, (...m) => {
    counts[name]++; P = m[6];
    const [J, , F, KEY, H, , A, C] = m.slice(1, 9);
    if (name === 'nested') return `${J}=$$n(${A},${C},${F},${H},"${KEY}",${m[9]},${m[10]});if(${J}===${A}.a)return ${A}.a;`;
    if (name === 'nullable string') return `${J}=$$f(${A},${C},${F},${H},"${KEY}",$$u);if(${J}===${A}.a)return ${A}.a;`;
    return `${J}=$$f(${A},${C},${F},${H},"${KEY}",${helper});if(${J}===${A}.a)return ${A}.a;`;
  });
}
if (!P) throw Error('no schema field block matched');
// The nullable helper needs the shared Nothing constant the reader used; find it.
const nothing = /if\(\w+===null\)\w+=([\w$]+);else\{let/.exec(fs.readFileSync(inFile, 'utf8'))[1];
const helpers = `const $$k=(a,c,k,v,f)=>v===undefined?${P}(a,c,k,k,1,'missing key "'+k+'"',f):${P}(a,c,k,k,5,"the depth limit is reached",v),` +
  `$$f=(a,c,f,h,k,t)=>{let v=f[k];return v===undefined||h?$$k(a,c,k,v,f):t(a,c,k,v)},` +
  `$$n=(a,c,f,h,k,r,b)=>{let v=f[k];return v===undefined||h?$$k(a,c,k,v,f):r(a,b+1,c,k,k,v)},` +
  `$$s=(a,c,k,v)=>typeof v!=="string"?${P}(a,c,k,k,0,"expected a string",v):v,` +
  `$$b=(a,c,k,v)=>typeof v!=="boolean"?${P}(a,c,k,k,0,"expected a boolean",v):v,` +
  `$$i=(a,c,k,v)=>typeof v!=="number"?${P}(a,c,k,k,0,"expected a number",v):!Number.isSafeInteger(v)?${P}(a,c,k,k,4,"expected a safe integer",v):v,` +
  `$$u=(a,c,k,v)=>v===null?${nothing}:(v=$$s(a,c,k,v),v===a.a?a.a:{$:1,a:v});`;
// Insert after the declaration statement that defines P (helpers run only after module init).
const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
const declares = n => (n.declarations ?? []).some(d => d.id.name === P || d.id.name === nothing);
const last = ast.body.filter(declares).at(-1);
for (const h of ['$$k', '$$f', '$$n', '$$s', '$$b', '$$i', '$$u']) if (new RegExp(`[^\\w$.]${h.replace(/\$/g, "\\$")}[^\\w$]`).test(fs.readFileSync(inFile, 'utf8'))) throw Error(`helper name ${h} is taken`);
src = src.slice(0, last.end) + helpers + src.slice(last.end);
acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
fs.writeFileSync(outFile, src);
console.log(JSON.stringify({inFile, counts, before: br(fs.readFileSync(inFile, 'utf8')), after: br(src)}));
