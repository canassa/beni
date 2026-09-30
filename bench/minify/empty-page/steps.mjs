// The kept steps, in order. Each is the one before plus ONE technique.
//
// kind "source": an edit of the runtime's source (src/runtime.js, cumulative);
//   the page is rebuilt through `Minify.zig` against a copy of the platform, so
//   the step file is exactly what beni would ship from that source. Verified by
//   `measure.mjs test` on the page and `measure.mjs corpus` on every
//   `browser/dom/` and `browser/tea/` page, built against the same source.
// kind "output": a text edit of the shipped file (cumulative, after every
//   source step). `generic`, when present, is the same rewrite written for ANY
//   release page, applied by `measure.mjs corpus` to every corpus page's one
//   file — the differential test of a compiler pass. Without `generic` the
//   step is a whole-program fact of THIS page (`bin: "specific"`), verified by
//   `measure.mjs test` alone.
//
// `bin` is the skill's §5 classification: "source" (a rule for runtime.js
// authors), "minify" (a token-level pass `Minify.zig` could add), "print" (the
// emitter/printer: `Print.zig`, `Opt.zig`), "spec" (whole-program
// specialisation, `backend.md` §9: what `Spec.zig` does for a runtime written
// in beni), "specific" (this file only).

import { SOURCE } from "./tools/edits.mjs";

const one = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.replace(a, () => b); };
const all = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.split(a).join(b); };
const seq = (...fs) => (s) => fs.reduce((x, f) => f(x), s);
const re = (a, b) => (s) => { const t = s.replace(a, b); if (t === s) throw new Error(`no match: ${a}`); return t; };
// The emitted half begins at the Browser sibling (`let b=c=>[`), the first
// statement after the runtime's.
const emitted = (f) => (s) => { const k = s.indexOf("let b=c=>["); if (k < 0) throw new Error("no emitted half"); return s.slice(0, k) + f(s.slice(k)); };

const LIST = [
  { name: "baseline", kind: "source", edit: (s) => s, bin: "-", what: "the page as `master` ships it: `--platform=browser --release`, one file" },

  // ---- A: the runtime's source ------------------------------------------------
  { name: "child-put", kind: "source", edit: SOURCE.childPut[1], bin: "source",
    what: "`childHtml` puts its first instance itself: it calls `place` only when the slot is empty, where `place`'s `swap` arm is dead, so on a page with no `Show` `place` is not shipped",
    speed: "one call and one branch fewer on a first mount; timed equal within noise (tools/timing.mjs)" },
  { name: "concise-ends", kind: "source", edit: SOURCE.conciseEnds[1], bin: "source",
    what: "`head` and `tail` are one conditional expression each, concise arrows like `first` and `last`, instead of `if (…) return …; return …` blocks",
    speed: "the same tests in the same order; the engine compiles both forms alike" },

  // ---- B: the emitted half, and the one file (compiler passes) --------------
  { name: "const-let", kind: "output", edit: all("const ", "let "), generic: (s) => s.replace(/\bconst\b/g, "let"), bin: "minify",
    what: "`const` is `let` throughout the one file (A3's all-or-none, decided over the kept tokens and the emitted half together)",
    sound: "no `const` binding is assigned: a program whose `const` were assigned threw `TypeError` before; A3 decides it by name, so the runtime's `patch` must not name its `const` like `put`'s assigned `let n` (source rule)" },
  { name: "kind-params", kind: "output", edit: emitted(seq(one("m:(b,d)=>", "m:()=>"), one("p:(f,g)=>{}", "p:()=>{}"))), bin: "print",
    what: "a kind's `m`/`p` arrows drop the trailing parameters their bodies never read",
    sound: "an arrow has no `arguments`, and nothing reads a kind's `.length`; `Opt` knows which parameters are read" },
  { name: "emitted-newlines", kind: "output", edit: emitted((s) => s.replace(/([,;])\n(?!$)/g, "$1")), generic: (s) => s.replace(/([,;])\n(?!$)/g, "$1"), bin: "print",
    what: "the emitted half's statements and `const` run on one line, as the hand-written half is" },
  { name: "block-newlines", kind: "output", edit: all("}\n", "}"), generic: (s) => s.replace(/\}\n(?=[A-Za-z_$])/g, "}"), bin: "minify",
    what: "no newline after a `}` that closes a block: the compactor keeps one before `return`, `let` and an assignment because the `}` might close an object literal, where the newline would be automatic semicolon insertion's",
    sound: "the `}` closes a block — an `if`/`else`/loop body or a function body — which the tokens decide when its `{` follows a statement head's `)`, `else`, `do`, `try`, `finally` or `=>`; refused otherwise" },

  // ---- C: the whole program in view ---------------------------------------
  // From here on each step uses a fact about THIS program that only the whole
  // program shows. Every one is exact for this page and would be derived by a
  // compiler that sees the runtime and the program together.
  { name: "record-fields", kind: "output", bin: "types",
    edit: seq(one("V=T.init;", "V=T.i;"), all("T.view(V)", "T.v(V)"), one("V=T.update(ca,V)", "V=T.u(ca,V)"), one("{init:{},update:(a,c)=>c,view:e}", "{i:{},u:(a,c)=>c,v:e}")),
    what: "the program record's fields `init`, `update`, `view` are `i`, `u`, `v`: every writer (the emitted record) and every reader (the runtime's mount) is in view",
    needs: "type-directed field renaming (`backend.md` §9 item 4) extended across the runtime: the runtime's reads must be renamed with the record, so the runtime must be compiled with the program (written in beni, or its reads typed)" },
  { name: "template-flags", kind: "output", bin: "spec",
    edit: seq(
      one('let l=(aa,U)=>{let R=null;return()=>{if(R===null){let document=globalThis.document;let t=document.createElement("template");t.innerHTML=aa;R=t.content;if(U&2)R=R.firstChild;if(U&4){if(U&2){let f=document.createDocumentFragment();while(R.firstChild!==null)f.appendChild(R.firstChild);R=f}}else R=R.firstChild}return U&1?globalThis.document.importNode(R,true):R.cloneNode(true)}};',
        'let l=()=>{let R=null;return()=>{if(R===null){let t=globalThis.document.createElement("template");t.innerHTML="<!>";R=t.content.firstChild}return R.cloneNode(true)}};'),
      one('a=l("<!>",0)', "a=l()")),
    what: "`template` is called once, with the html `\"<!>\"` and flags 0: both are folded into its body, its three flag branches go, and the `document` local read once is written where it is read",
    needs: "`Spec.zig` fact 1 (constant arguments) and folding — built for a runtime written in beni; the hand-written runtime would need the same pass over parsed JavaScript" },
  { name: "no-hosted-mount", kind: "output", bin: "spec",
    edit: seq(one("P(m.h?m.h(S,N,f=>(M=f,L)):m.a,S)", "P(m.a,S)"), one("let M=null;", ""), one("for(let Y of da)Y();M?.()}", "for(let Y of da)Y()}")),
    what: "the program record has no `h` (no hosted mount): `m.h` is `undefined`, the hosted arm goes, and with it the only write of `phase`, which is then `null` for good, so `flush` no longer calls it",
    needs: "`Spec.zig` fact 3 (a property no reachable write gives the object) then fact 2 (a `let` nothing assigns) — the property is written by the `Browser` sibling, so the sibling must be analysed too" },
  { name: "mount-at-body", kind: "output", bin: "spec+",
    edit: seq(
      one('let document=globalThis.document;for(let m of T){let S=m.n===null?document.body:document.getElementById(m.n);if(S===null||S.$$root!==undefined)throw new Error(S===null?`no element has the id "${m.n}" to mount a program at`:`${m.n===null?"the page\'s body":`the element "${m.n}"`} already holds a program`);',
        'for(let m of T){let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?\'no element has the id "null" to mount a program at\':"the page\'s body already holds a program");'),
      one("[{a:c,n:null}]", "[{a:c}]")),
    what: "every mount record's `n` is `null` (the one record, from `Browser.program`): the mount node is `document.body`, `getElementById` goes, the two messages fold to literals (`${null}` is `\"null\"`, exactly as before), and `n` is then read by nothing, so it goes from the record",
    needs: "a fact `Spec.zig` does not have: a property whose every write is the same literal (fact 3 only folds a property never written); then template-literal folding" },
  { name: "slot-fields", kind: "output", bin: "spec",
    edit: seq(
      one("let F=(parent,ba,cx)=>({p:parent,m:ba,cx,i:null,u:null,b:null,x:null,y:null,z:null,d:false});", "let F=parent=>({p:parent,m:null,i:null});"),
      one("let s=F(S,null,null);", "let s=F(S);"),
      one("let H=(b,cx)=>{let i=b.t.m(b.v,cx);", "let H=b=>{let i=b.t.m(b.v,null);"),
      one("let I=(i,b,cx)=>{", "let I=(i,b)=>{"), one("let Q=H(b,cx);E(i,Q);return Q}", "let Q=H(b);E(i,Q);return Q}"),
      one("let i=H(b,s.cx);", "let i=H(b);"), one("else s.i=I(s.i,b,s.cx)}", "else s.i=I(s.i,b)}")),
    what: "the one slot is made with a `null` marker and a `null` context: both fold into `slot`, `cx` becomes a constant every reader folds (so `unit` and `patch` lose the parameter), and the list fields `u`, `b`, `x`, `y`, `z`, `d` — which nothing reads on this slot — go from its literal",
    needs: "`Spec.zig` facts 1 and 3 (built for a runtime in beni: `EmptyPage`'s `{cx:null,i:null,m:null,p:a}`); this goes one further and drops `cx`, whose every read folds to `null`" },
  { name: "kind-args", kind: "output", bin: "spec+",
    edit: seq(one("let i=b.t.m(b.v,null);", "let i=b.t.m();"), one("b.t.p(i,b.v);", "b.t.p();")),
    what: "the only kind (`c`) takes no parameters (step 03), so the calls through `b.t.m`/`b.t.p` pass none: `b.v` and `null` were read into parameters that do not exist",
    needs: "points-to (fact 3's allocation sites) resolving a call through a property to its one target, then dropping arguments past its arity when they are inert" },
  { name: "one-view", kind: "output", bin: "spec+",
    edit: seq(
      one("let I=(i,b)=>{if(b===i.b)return i;if(b.t===i.t){b.t.p();i.b=b;return i}let Q=H(b);E(i,Q);return Q};", ""),
      one("else s.i=I(s.i,b)}", "}"),
      re(/let D=i=>\{[^]*?\};let E=\(\$,i\)=>\{[^]*?\};/, "")),
    what: "`view` returns the one block `d` whatever the model, and the one instance was mounted from `d`, so `patch(i, d)` always returns at `b === i.b`: `patch` goes, and with it `swap` and `drop`, which only its other arms reached",
    needs: "must-alias on a singleton allocation site (a module-level object literal is one object): `view`'s every return is `d` and `i.b` is only ever written `d`" },
  { name: "render-noop", kind: "output", bin: "spec+",
    edit: one("let Y=()=>{Z=false;J(s,T.v(V))};", "let Y=()=>{Z=false};"),
    what: "a render after the mount is `childHtml(s, view(model))` with `s.i` set, which after step 12 does nothing; `view` is a pure beni function, so its call goes too",
    needs: "flow facts: the render is queued only by `send`, after the mount set `s.i` (the mount runs no program code that could send); purity of an emitted function (`Opt` has it)" },
  { name: "instance-ends", kind: "output", bin: "spec+",
    edit: seq(one("let n=i=>(i.s!==null?i.s:A(i.q));let w=i=>(i.e!==null?i.e:B(i.q));", "let n=i=>i.s;let w=i=>i.e;"),
      re(/let A=s=>\(s\.u[^;]*;let B=s=>\(s\.m[^;]*w\(s\.i\)\);/, "")),
    what: "every instance is the kind's literal `{s:e,q:null,e:e}` with `e` a fresh clone, never `null`: `first`/`last` read `s`/`e` and `head`/`tail`, the slot-at-an-end arms, go",
    needs: "a non-null fact per field: the one allocation site's `s` and `e` are written with a clone's result (a DOM node, never `null`)" },
  { name: "unread-keys", kind: "output", bin: "spec",
    edit: seq(one("let H=b=>{let i=b.t.m();i.t=b.t;i.b=b;return i};", "let H=b=>b.t.m();"), one("c={m:()=>{let e=a();return{s:e,q:null,e:e}},p:()=>{}},d={t:c,v:null}", "c={m:()=>{let e=a();return{s:e,q:null,e:e}}},d={t:c}")),
    what: "with `patch` gone nothing reads an instance's `t` and `b`, a kind's `p` or a block's `v`: their writes and keys go",
    needs: "`Spec.zig` fact 3, *never read* (built: a key goes from its literal and its writes go)" },
  { name: "dead-model", kind: "output", bin: "spec+",
    edit: seq(one("let V=T.i;", ""), one("V=T.u(ca,V)};J(s,T.v(V))};", "};J(s,T.v())};"), one("f=b({i:{},u:(a,c)=>c,v:e})", "f=b({v:e})")),
    what: "`update` is `(a, c) => c`, so `model = update(msg, model)` assigns the model itself, and `view` never reads its argument: the model, `update`'s call and the record's `i` and `u` go",
    needs: "a call through a record field resolved to its one target (points-to), that target inlined when it is an identity, `x = x` dropped (`Print.skipped` has it), then a parameter no body reads dropped with its argument" },
  { name: "inline-once", kind: "output", bin: "spec+",
    edit: () => `let K=[];let L=false;let N=()=>{L=false;let da=K;K=[];for(let Y of da)Y()};let R=null;let a=()=>{if(R===null){let t=globalThis.document.createElement("template");t.innerHTML="<!>";R=t.content.firstChild}return R.cloneNode(true)};let c={m:()=>{let e=a();return{s:e,q:null,e:e}}},d={t:c},e=(a)=>d,f=[{a:{v:e}}];for(let m of f){let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");let T=m.a;let s={p:S,m:null,i:null};let Z=false;let Y=()=>{Z=false};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}};let b=T.v();if(s.i===null){let i=b.t.m();let parent=s.p!==null?s.p:s.m.parentNode;let W=i.e;let Q=i.s;for(;;){let X=Q.nextSibling;parent.insertBefore(Q,s.m);if(Q===W)break;Q=X}s.i=i}}export{N as flush};`,
    what: "every function called from one place is written there — `first`, `last`, `put`, `parentOf`, `unit`, `childHtml`, `slot`, `mount`, `run`, `template` (its cache becomes a top-level `let`) and the `Browser.program` sibling — each argument an atom or evaluated in the same order as before",
    needs: "`backend.md` §9's *A function called once is written where it is called*, which beni has for its own code, extended to the hand-written runtime and siblings (a JavaScript parser) and to a function whose result is a closure (its locals become the caller's)" },
  { name: "scalar-slot", kind: "output", bin: "spec+",
    edit: () => `let K=[];let L=false;let N=()=>{L=false;let da=K;K=[];for(let Y of da)Y()};let R=null;let a=()=>{if(R===null){let t=globalThis.document.createElement("template");t.innerHTML="<!>";R=t.content.firstChild}return R.cloneNode(true)};let c={m:()=>{let e=a();return{s:e,q:null,e:e}}},d={t:c},e=(a)=>d,f=[{a:{v:e}}];for(let m of f){let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");let T=m.a;let Z=false;let Y=()=>{Z=false};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}};let b=T.v();let i=b.t.m();S.insertBefore(i.s,null)}export{N as flush};`,
    what: "the slot object never escapes the mount, so its fields are locals: `s.i` is `null` at the test, `s.p` is `S` (not `null`: the guard threw), `s.m` is `null`; and the instance's `s` and `e` are one node, so `put`'s loop runs once — its `nextSibling` read (a DOM getter with no effect) goes",
    needs: "escape analysis and scalar replacement of an object literal, a flow fact from the guard (`S !== null` after it), and loop peeling from `s === e` on the one allocation site" },
  { name: "dead-record", kind: "output", bin: "spec+",
    edit: () => `let K=[];let L=false;let N=()=>{L=false;let da=K;K=[];for(let Y of da)Y()};let R=null;let a=()=>{if(R===null){let t=globalThis.document.createElement("template");t.innerHTML="<!>";R=t.content.firstChild}return R.cloneNode(true)};let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");let Z=false;let Y=()=>{Z=false};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}};S.insertBefore(a(),null);export{N as flush};`,
    what: "`view()` is the constant block `d`, whose kind's `m` is the one mount: the program record, the block, the kind and `view` are read once each and go; the loop over the one mount record is its one iteration",
    needs: "constant propagation through object literals that do not escape (the record, the block, the kind), then the mount function inlined at its one call; a `for…of` over an array literal of one element peeled" },
  { name: "template-once", kind: "output", bin: "spec+",
    edit: () => `let K=[];let L=false;let N=()=>{L=false;let da=K;K=[];for(let Y of da)Y()};let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");let Z=false;let Y=()=>{Z=false};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}};let t=globalThis.document.createElement("template");t.innerHTML="<!>";S.insertBefore(t.content.firstChild,null);export{N as flush};`,
    what: "the cloner is called once, so its cache is never read again: the template is parsed where the node is needed and its node inserted itself, not a clone of it",
    needs: "a closure called once (from the mount, which runs once): its memo cell is written and never re-read, so the memo and the clone go" },
  { name: "comment-node", kind: "output", bin: "emitter",
    edit: () => `let K=[];let L=false;let N=()=>{L=false;let da=K;K=[];for(let Y of da)Y()};let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");let Z=false;let Y=()=>{Z=false};S.$$root=ca=>{if(!Z){Z=true;K.push(Y);if(!L){L=true;queueMicrotask(()=>{if(L)N()})}}};S.insertBefore(globalThis.document.createComment(""),null);export{N as flush};`,
    what: "the template `<!>` is one empty comment: `createComment(\"\")` makes it without parsing HTML",
    needs: "the `dom` lowering: a template of one comment (the fragment's and every empty hole's marker) is `createComment`, not a parsed template — a rule for every page, timed (tools/timing.mjs)" },
  { name: "one-program", kind: "output", bin: "spec+",
    edit: () => `let Z=false;let N=()=>{Z=false};let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");S.$$root=ca=>{if(!Z){Z=true;queueMicrotask(()=>{if(Z)N()})}};S.insertBefore(globalThis.document.createComment(""),null);export{N as flush};`,
    what: "one program: the render queue holds its one render or nothing, exactly when `waiting` is set, and `scheduled` is set exactly when `waiting` is; so the queue is the flag, the two flags are one, and a flush clears it",
    needs: "whole-program cardinality (one mount record, one `mount`) and an invariant between two module variables — beyond any planned pass" },
  { name: "nothing-observable", kind: "output", bin: "spec+",
    edit: () => `let S=globalThis.document.body;if(S===null||S.$$root!==undefined)throw new Error(S===null?'no element has the id "null" to mount a program at':"the page's body already holds a program");S.$$root=ca=>{};S.insertBefore(globalThis.document.createComment(""),null);export let flush=()=>{};`,
    what: "the flag is read only by the render machinery itself, and a render writes nothing: `send` and `flush` have no effect anyone can observe, so they are empty functions (still two, each with its arity, so neither identity nor `length` changes)",
    needs: "an effect analysis that proves the render loop's state unobservable — the limit, not a plan" },
  { name: "append-child", kind: "output", bin: "print",
    edit: one('S.insertBefore(globalThis.document.createComment(""),null)', 'S.appendChild(globalThis.document.createComment(""))'),
    what: "`insertBefore(x, null)` is `appendChild(x)`: the DOM defines append as insertion before `null`",
    needs: "a peephole wherever the reference node is a literal `null` (the runtime writes `put(parent, i, null)` in two places; after inlining, `insertBefore(n, null)`)" },
];

// Ids are positions, so a step can be inserted without renumbering by hand.
export const STEPS = LIST.map((s, k) => ({ ...s, id: String(k).padStart(2, "0") }));
