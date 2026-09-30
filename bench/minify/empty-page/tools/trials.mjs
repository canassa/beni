// Single edits to the shipped empty page, each applied ALONE to a base file and
// priced in raw / gzip-9 / brotli-11 bytes (the skill's §1.2 item 4: a Δ under
// 10 brotli bytes is a direction, not a magnitude). Positive = bigger.
//   node tools/trials.mjs   (TRIALS on the baseline, LIMIT_TRIALS on step 24)
// Correctness is not checked here; kept edits become steps, which are.
import fs from "node:fs";
import { sizes } from "../measure.mjs";

const all = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.split(a).join(b); };
const one = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.replace(a, () => b); };
const re = (a, b) => (s) => { const t = s.replace(a, b); if (t === s) throw new Error(`no match: ${a}`); return t; };
const seq = (...fs) => (s) => fs.reduce((x, f) => f(x), s);

export const LIMIT_TRIALS = [
  // Priced on steps/24-nothing-observable.mjs (the limit, before its last step):
  ["`insertBefore(x,null)` → `appendChild(x)`", one("S.insertBefore(globalThis.document.createComment(\"\"),null)", "S.appendChild(globalThis.document.createComment(\"\"))")],
  ["`S===null` → `!S` (twice)", all("S===null", "!S")],
  ["one `let D=globalThis.document`", seq(one("let S=globalThis.document.body;", "let D=globalThis.document,S=D.body;"), one("globalThis.document.createComment", "D.createComment"))],
  ["the error thrown from a conditional message built first", one("if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id \"null\" to mount a program at':\"the page's body already holds a program\")", "if(S===null)throw new Error('no element has the id \"null\" to mount a program at');if(S.$$root!==undefined)throw new Error(\"the page's body already holds a program\")")],
  ["`export let flush=()=>{}` → `let N=()=>{};…export{N as flush}`", seq(one("export let flush=()=>{};", "export{N as flush};"), one("let S=", "let N=()=>{};let S="))],
];

export const TRIALS = [
  // Priced on the baseline (built/_main.mjs):
  ["property renaming: a slot's `cx` → `c`", seq(re(/\.cx\b/g, ".c"), one(",cx,i:null", ",c:cx,i:null"))],
  ["property renaming: the program record's `init`/`update`/`view` → `i`/`u`/`v`", seq(re(/\.init\b/g, ".i"), re(/\.update\(/g, ".u("), re(/\.view\(/g, ".v("), one("{init:{},update:(a,c)=>c,view:e}", "{i:{},u:(a,c)=>c,v:e}"))],
  ["`const` → `let` everywhere", all("const ", "let ")],
  ["`const` → `let` in the emitted half only", one('const a=l("<!>"', 'let a=l("<!>"')],
  ["`(a)=>` → `a=>` in the emitted half", one("e=(a)=>d", "e=a=>d")],
  ["a kind's unused parameters dropped: `m:(b,d)=>` → `m:()=>`, `p:(f,g)=>` → `p:()=>`", seq(one("m:(b,d)=>", "m:()=>"), one("p:(f,g)=>", "p:()=>"))],
  ["shorthand `e:e` → `e` in the emitted instance", one("e:e}", "e}")],
  ["the emitted const run's newlines dropped", re(/,\n/g, ",")],
  ["the emitted half's statement newlines dropped", re(/;\n/g, ";")],
  ["`parent` (a host global, never renamed) → a renamed name", seq(one("const C=(parent,i,aa)=>", "const C=(ga,i,aa)=>"), one("parent.insertBefore(R,aa)", "ga.insertBefore(R,aa)"), one("const F=(parent,ca,cx)=>({p:parent,", "const F=(ga,ca,cx)=>({p:ga,"))],
  ["`cx` (a shorthand key, never renamed) → a renamed name", seq(one("const F=(parent,ca,cx)=>({p:parent,m:ca,cx,", "const F=(parent,ca,fa)=>({p:parent,m:ca,cx:fa,"), one("const H=(b,cx)=>{const i=b.t.m(b.v,cx);", "const H=(b,fa)=>{const i=b.t.m(b.v,fa);"), one("const I=(i,b,cx)=>{", "const I=(i,b,fa)=>{"), one("const R=H(b,cx);E(i,R)", "const R=H(b,fa);E(i,R)"))],
  ["`document` locals (a host global, never renamed) → a renamed name", seq(one("const document=globalThis.document;const t=document.createElement(\"template\")", "const ga=globalThis.document;const t=ga.createElement(\"template\")"), one("const f=document.createDocumentFragment()", "const f=ga.createDocumentFragment()"), one("const document=globalThis.document;for(const m of U){const T=m.n===null?document.body:document.getElementById(m.n)", "const ga=globalThis.document;for(const m of U){const T=m.n===null?ga.body:ga.getElementById(m.n)"))],
  ["`x!==null?x:y` → `x??y` (first, last, parentOf)", seq(one("i.s!==null?i.s:A(i.q)", "i.s??A(i.q)"), one("i.e!==null?i.e:B(i.q)", "i.e??B(i.q)"), one("s.p!==null?s.p:s.m.parentNode", "s.p??s.m.parentNode"))],
  ["`s.u!==null&&s.u.length!==0` → `s.u?.length`", all("s.u!==null&&s.u.length!==0", "s.u?.length")],
  ["`!==null` → `!=null` everywhere", all("!==null", "!=null")],
  ["`===null` → `==null` everywhere", all("===null", "==null")],
  ["`T.$$root!==undefined` → `T.$$root`", one("T.$$root!==undefined", "T.$$root")],
  ["`false`/`true` → `!1`/`!0`", seq(all("false", "!1"), all("true", "!0"))],
  ["`let L=[];let M=false;let N=null;` joined", one("let L=[];let M=false;let N=null;", "let L=[],M=false,N=null;")],
  ["`}\\n` → `};` (three block ends before a statement)", all("}\n", "};")],
  ["mount's first render calls `Z()` instead of repeating it", one("W=U.update(da,W)};K(s,U.view(W))}", "W=U.update(da,W)};Z()}")],
  ["`for(;;)` loops of put and drop as `do…while`", seq(
    one("let R=n(i);for(;;){const Y=R.nextSibling;parent.insertBefore(R,aa);if(R===X)return;R=Y}", "let R=n(i),Y;do{Y=R.nextSibling;parent.insertBefore(R,aa)}while(R!==X&&(R=Y))"),
  )],
  ["template: `flags&2` peeled before the `flags&4` test", one("if(V&2)S=S.firstChild;if(V&4){if(V&2){const f=document.createDocumentFragment();while(S.firstChild!==null)f.appendChild(S.firstChild);S=f}}else S=S.firstChild", "if(V&2)S=S.firstChild;if(!(V&4))S=S.firstChild;else if(V&2){const f=document.createDocumentFragment();while(S.firstChild!==null)f.appendChild(S.firstChild);S=f}")],
  ["the export as `export{O as flush}` → `flush` named at declaration", seq(one("const O=()=>{", "const flush=()=>{"), all("O()", "flush()"), one("m.h(T,O,", "m.h(T,flush,"), one("export{O as flush};", "export{flush};"))],
];

const d = (x) => (x > 0 ? "+" : "") + x;
const price = (file, trials) => {
  const base = fs.readFileSync(new URL(`../${file}`, import.meta.url), "utf8");
  const b = sizes(Buffer.from(base));
  console.log(`${file}: raw ${b.raw}, gz ${b.gz}, br ${b.br}\n\n| edit, alone | Δ raw | Δ gz | Δ br |\n|---|--:|--:|--:|`);
  for (const [label, f] of trials) {
    let t;
    try { t = f(base); } catch (e) { console.log(`| ${label} | n/a (${e.message.slice(0, 40)}) | | |`); continue; }
    const s = sizes(Buffer.from(t));
    console.log(`| ${label} | ${d(s.raw - b.raw)} | ${d(s.gz - b.gz)} | ${d(s.br - b.br)} |`);
  }
  console.log("");
};
price("built/_main.mjs", TRIALS);
price("steps/24-nothing-observable.mjs", LIMIT_TRIALS);

