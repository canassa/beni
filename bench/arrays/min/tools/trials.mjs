// Report 40 §4.2: single edits to the hand-minified file, each applied ALONE, priced in brotli-11
// bytes on steps/10-hand.js (before the order search) and on array.min.js (after it). Positive =
// the edit makes the file bigger, so the file keeps the other spelling. Correctness of the kept
// spellings is covered by `measure.mjs test`/`fuzz`; the rejected ones here are only priced.
//   node min/tools/trials.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';

const br = (s) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
const FILES = ['../steps/10-hand.js', '../array.min.js'].map((f) => fs.readFileSync(new URL(f, import.meta.url), 'utf8'));
const all = (a, b) => (s) => s.split(a).join(b);
const one = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.replace(a, b); };
const seq = (...fs) => (s) => fs.reduce((x, f) => f(x), s);

const TRIALS = [
  ['`const` everywhere instead of `let`', all('let ', 'const ')],
  ['`export const` instead of `export let`', all('export let ', 'export const ')],
  ['threshold as `L=1024` instead of `1024` three times', seq(all('1024', 'L'), one('let A=Array.isArray;', 'let A=Array.isArray;let L=1024;'))],
  ['`===` everywhere instead of `==` where types are known', all('==', '===')],
  ['`new Array(` instead of `Array(`', all('Array(n+k)', 'new Array(n+k)')],
  ['object literals instead of the node constructor `M`', seq(
    one('let M=(n,s,r,t)=>({n,s,r,t});', ''),
    one('M(a.n,a.s,a.r,a.t.slice())', '{n:a.n,s:a.s,r:a.r,t:a.t.slice()}'),
    one('M(a.n+t.length,s,S(r,s,i,a.t,5),t)', '{n:a.n+t.length,s,r:S(r,s,i,a.t,5),t}'),
    one('M(n,s,r,a.slice(e))', '{n,s,r,t:a.slice(e)}'),
    one('M(a.n,a.s,S(a.r,a.s,i,v,0),a.t)', '{n:a.n,s:a.s,r:S(a.r,a.s,i,v,0),t:a.t}'),
    one('M(a.n,a.s,a.r,S(a.t,0,i-o,v,0))', '{n:a.n,s:a.s,r:a.r,t:S(a.t,0,i-o,v,0)}'),
    one('M(n+1,a.s,a.r,c)', '{n:n+1,s:a.s,r:a.r,t:c}'),
    one('M(n-1,a.s,a.r,a.t.slice(0,-1))', '{n:n-1,s:a.s,r:a.r,t:a.t.slice(0,-1)}'),
    one('M(n-1,s,r,F(a,n-33))', '{n:n-1,s,r,t:F(a,n-33)}'))],
  ['one joined `let a=…,b=…` for the internal statements (breaks elimination)', all(';let ', ',')],
  ['a newline after every `;`', all(';', ';\n')],
  ['`set` writes the tail with a slice instead of the path copy `S`', one('M(a.n,a.s,a.r,S(a.t,0,i-o,v,0))', '(c=a.t.slice(),c[i-o]=v,M(a.n,a.s,a.r,c))')],
  ['`push` writes the tail with the path copy `S` instead of slice+push', one('if(a.t.length<32)return(c=a.t.slice()).push(v),M(n+1,a.s,a.r,c);return V(a,[v])', 'return a.t.length<32?M(n+1,a.s,a.r,S(a.t,0,a.t.length,v,0)):V(a,[v])')],
  ['comparator `(x=f(x,y))=="GT"|-(x=="LT")` instead of the ternary chain', one('(x=f(x,y))=="LT"?-1:x=="GT"?1:0', '(x=f(x,y))=="GT"|-(x=="LT")')],
  ['`!r[1]` instead of `r.length==1`', one('r.length==1', '!r[1]')],
  ['`G` without its default parameter', one('let G=(a,i,o)=>{if(i<0||i>=a.n)return;o=a.n-a.t.length;', 'let G=(a,i)=>{if(i<0||i>=a.n)return;let o=a.n-a.t.length;')],
  ['`G` without the bounds check `unsafeGet`\'s contract makes dead', one('let G=(a,i,o)=>{if(i<0||i>=a.n)return;o=a.n-a.t.length;return i>=o?a.t[i-o]:F(a,i)[i&31]};', 'let G=(a,i,o=a.n-a.t.length)=>i>=o?a.t[i-o]:F(a,i)[i&31];')],
  ['`sortWith` copies through `[...P(a)]`', one('(A(a)?a.slice():T(a)).sort(', '[...P(a)].sort(')],
];
console.log(`| edit, alone | Δ raw | Δ brotli, 10-hand.js (${br(FILES[0])}) | Δ brotli, array.min.js (${br(FILES[1])}) |\n|---|--:|--:|--:|`);
const d = (x) => (x > 0 ? '+' : '') + x;
for (const [label, f] of TRIALS) {
  const [a, b] = FILES.map((src) => f(src));
  console.log(`| ${label} | ${b.length - FILES[1].length} | ${d(br(a) - br(FILES[0]))} | ${d(br(b) - br(FILES[1]))} |`);
}
