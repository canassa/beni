# S1: beni-inline against tea-inline, byte by byte (master `05019dcfa`, seed 1)

Read-only comparison of the two minified outputs for reactivity-research's unique-components
scenario, `--lists none`. beni: `~/s1-bins/work/master-05019dcfa/n<N>-s1/dist/_main.mjs` (built by
the manager, `--release --no-source-maps`). tea-inline:
`generated/unique-components/n<N>-s1-lists=none/tea-inline/dist/assets/index-*.js` (Vite's build,
already present). All sizes are brotli 11 (lgwin 24, same parameters as `~/s1-bins/br.cjs`), Node
24.19.

*Manager's note (2026-10-23, after review).* The quotes were checked against the files on dagon.
This compares master `05019dcfa`. Two items have changed since then:
- **Item 4 (rerun list `.flat()`) is done:** #909 (`227b61fb6`) writes it as `t.flat()` and shrinks
  the group runner and loader. S1 is now 204.4 B/widget, N = 1 1 667 B.
- **Item 3 (hoisted `let`s) is partly in flight:** the #896 agent's release-optimiser fold writes a
  binding's single read at its use.

The scratch scripts are kept in `~/worktree-evidence/s1-compare/s1/` on dagon.

## Summary

- **Seed 1 sizes.** beni: 1 705 / 6 981 / 17 886 / 55 285 at N = 1 / 16 / 64 / 256. tea-inline:
  1 251 / 4 644 / 12 944 / 38 102. **Slopes:** 16→64 is 227.2 against 172.9 (+54.3). 64→256 is
  194.8 against 131.0 (+63.8). The 12-build fit is 207.7 against 145.0.
- **tea-inline's N = 1 file is not all app.** 255 B is Vite's `modulepreload` polyfill and 59 B is
  the `window.rr` adapter. beni's adapter is a separate file that is not measured. tea-inline's app
  alone is **935 B**. beni's app is 1 705 B, so the app-to-app fixed gap is about 770 B. The bar
  (1.1 × 1 251 = 1 376 at seed 1) already lets beni use the polyfill's bytes.
- **Per widget, most of the gap is validation shape.** At 64→256, where both sides have a stable
  shape, beni's validation and loader cost 31.9 B per widget (cumulative deletion) and tea-inline
  pays 0. Of that, the shape table (the guarantee itself) is 8.6–11.2. The rest, **about 21–23 B
  per widget, is shape only**: the replace wrapper, the copy-plan route entry, the route table,
  the snapshot record, its permutation, and the snapshot loader's two lists. They name each widget
  3–4 times.
- **The other differences are small, and every one is shape:** program-site wiring and element
  lookup (+8–11), bindings (+4–8, about half of it hoisted `let`s), the state slice (+5 at 64→256,
  but −1 at 16→64), the "rerun every group after a push" list (+3–4), handlers (+0–4) and markup
  (+1–6).
- **Measured edits to the real output** (section 4) save **≈ 32 B per widget at 64→256** in pure
  shape: one route table, a wiring table, `G.flat()`, an inline model literal, `==`. Adding the
  `let`-inlining that #618 targets gives **≈ 36**. This puts the 64→256 slope at about 158–162,
  against a bar of 144 there (131 × 1.1). On the fit it is about 172 against 159.5. A further
  8–10 B per widget is still needed after these edits.
- **Fixed cost:** beni's runtime is 451 B by deletion and tea-inline's is 224. Event validation is
  277 B and tea-inline has none. Measured shape-only edits at N = 1 save about 100 B: dead
  Tick/Notify validation 59, `Object.assign` in place of the copy-plan walker 36, `.flat()` 5,
  `void 0` 2. The rest of the fixed gap is guarantee cost (D3 synchronous dispatch, a defect stops
  the program, pushed-state validation), and the owner must decide on it.

## Method

- **Pretty-printing:** esbuild (from `reactivity-research/harness/parse`, run on dagon) made the
  side-by-side copies. All measurements are on the original minified bytes.
- **Fixed cost:** the N = 1 file is cut into sections at the declaration boundaries. Each section is
  measured two ways. "del" is the whole file minus the file with the section removed. "iso" is the
  section compressed alone. Deletion is the better estimate of a section's share. Isolation is an
  upper bound, because the section loses its context.
- **Per widget:** the outputs are parsed with acorn 8.19 (copied from the same harness). Every byte
  that belongs to a widget is put in a category by AST shape (rules in the scratch script
  `cat.cjs`). Each category is measured by deleting it at both sizes:
  slope = (Δ_big − Δ_small) / ΔN. It is also measured cumulatively (categories deleted in a
  fixed, alphabetical order), and the cumulative figures add up to the measured slope. Brotli
  costs are **not additive**: the individual deletions over-count or under-count by 5–25 %, and
  each cumulative figure depends on the order.
- **Two slopes:** 16→64 (what was asked for) and 64→256. beni switches from per-widget decoder
  functions to a shared shape-table reader between 16 and 64 (the reader comes into the output at
  29 shape runs, #653/#659). So 16→64 carries about 6 B per widget of runtime that arrives once,
  and 64→256 is the cleaner per-widget figure. The fit (207.7) is dominated by the 256 point.
- **One seed** (seed 1). The fit numbers in the brief are means over three seeds.
- **The edit experiments** (section 4) rewrite the real minified output text into the target shape.
  They do not add the generic runtime that a shape needs (for example, a route-table loader), so
  they are slope estimates, and the fixed cost of each is noted separately.

---

## 1. Fixed cost (N = 1, seed 1)

beni 1 705 B (4 572 raw) against tea-inline 1 251 B (3 110 raw).

| section | beni raw | beni del | beni iso | tea raw | tea del | tea iso |
|---|---:|---:|---:|---:|---:|---:|
| **runtime** (scheduler, cleanup, setters, groups) | 842 | 328 | 432 | 539 | 182 | 279 |
| **loader** (copy plan / `structuredClone`) | 324 | 123 | 199 | 91 | 42 | 74 |
| **validation** (sentinel, widget decoder, event decoders) | 1 272 | 277 | 362 | 0 | 0 | 0 |
| **pushed-state handling** (subscription, route table, dispatch) | 484 | 184 | 295 | 160 | 65 | 111 |
| **program shell + mount** | 352 | 164 | 259 | 274 | 112 | 193 |
| widget closure (bindings + handlers) | 766 | 288 | 347 | 787 | 268 | 331 |
| markup | 532 | 189 | 201 | 453 | 142 | 176 |
| Vite modulepreload polyfill | — | — | — | 670 | 255 | 325 |
| `window.rr` adapter | — (separate file) | — | — | 136 | 59 | 90 |

The finer split, by deletion (raw / del):

- **beni runtime:** clamp helper 31/13. Scheduler `e` 241/92. Cleanup chain and `stop` 105/45.
  DOM setters, lookup and listener 191/60. Groups (register, run, ordinal sort) 274/110.
- **beni validation:** sentinel factory 21/10. Widget decoder and `replace` 349/77. Event decoders
  `H`, `I`, `J` 902/151.
- **beni push:** subscription 162/67. Route table and `G` 128/59. Dispatcher `K` 194/56.
- **beni mount:** head and model 119/50. The rest 209/90. Start and export 24/15.
- **tea-inline runtime:** scheduler 218/81. Setters 160/49. `section` template 161/45.

### Runtime

beni (pretty-printed). The scheduler is a synchronous dispatcher: it queues a dispatch made while
another runs, and after a throw it stops the program (D3 and the defect rule):

```js
let b = false, c = false, d = null;
const e = (a2, f2) => {
  if (!b) if (c) { if (d === null) d = []; d.push(a2, f2); }
  else { c = true; let g2 = false;
    try { a2(f2); while (d !== null) { let a3 = d; d = null;
        for (let f3 = 0; f3 < a3.length && !b; f3 += 2) a3[f3](a3[f3 + 1]); }
      g2 = true;
    } finally { c = false; if (!g2) { b = true; d = null; } } }
}
```

Groups: `q` registers a binding with an ordinal. `r` runs one group. `t` runs several groups,
each binding once, in document order:

```js
q = (a2, b2) => { a2.$o = o.length; o.push(a2);
  if (b2[0] instanceof Array) { for (let c2 of b2) c2.push(a2); } else b2.push(a2); return a2; },
r = (a2) => { for (let b2 of a2) b2(); },
s = (a2, b2) => a2.$o - b2.$o,
t = (a2) => { p++; let b2 = p, c2 = [];
  for (let d2 of a2) { for (let a3 of d2) if (a3.$s !== b2) { a3.$s = b2; c2.push(a3); } }
  c2.sort(s); r(c2); }
```

tea-inline's whole scheduler: a microtask flush over a `Set`, with no defect handling:

```js
var e=new Set,t=null;function n(...n){for(let t of n.flat(1/0))t&&e.add(t);t||=Promise.resolve().then(r)}
function r(){t=null;for(let t of e)e.delete(t),t()}
```

### Loader (pushed state into a held slice)

beni writes each validated field into the slice that the closures hold, by a copy plan. `w` is
the snapshot form: it computes every slice first, then writes.

```js
u=(a,b,c)=>{for(let d of c)if(typeof d==="string")a[d]=b[d];else{let e=d[0];u(a[e],b[e],d[1])}},
v=(a,b,c)=>{let d=a[b[1]],e=b[0](c,d);if(e!==d)u(d,e,b[2])},
w=(a,b,c)=>{let d=[];for(let f=0;f<b.length;f++){let e=b[f];d.push(e[0](c[f],a[e[1]]))}let e=0;
  while(e<b.length){let c=b[e],f=a[c[1]],g=d[e];if(g!==f)u(f,g,c[2]);e++}}
```

tea-inline (it does not validate):

```js
var u=(e,t,r)=>(n(t),Object.assign(r=>{Object.assign(e,structuredClone(r)),n(t)},r))
```

No copy plan has a nested entry at N = 16, 64 or 256 (checked). Every one is a flat list of field
names, and the record that `replace` returns always has the slice's full key set.

### Validation (no counterpart in tea-inline)

The widget decoder and its `replace`, and the event decoders. Each decoder repeats the object
test, and each `Value` field is a presence test:

```js
z=(a,b)=>{if(typeof b!=="object"||b===null||Array.isArray(b))return a.a;let c=b.coins;
  if(!Number.isSafeInteger(c))return a.a; … return{d:c,a:d,c:e,b:f}},
A=(a,b)=>{let c=x(),d=z(c,a);return d===c.a?b:d};
…
J=(a,b)=>{if(typeof b!=="object"||b===null||Array.isArray(b))return a.a;let c=b.type;switch(c){
  case"serverSet":{let c=b.widget;if(typeof c!=="string")return a.a;let d,e=b.state;
    if(e!==undefined)d=e;else d=a.a;if(d===a.a)return a.a;return{$:"ServerSet",a:{a:d,b:c}}}
  case"tick":{return D}
  case"notify":{let c=b.widget;if(typeof c!=="string")return a.a;let d,e=b.item;
    if(e!==undefined)d=e;else d=a.a;if(d===a.a)return a.a;return{$:"Notify",a:{b:c}}}
  case"snapshot":{…c=I(a,d)…return{$:"Snapshot",a:{a:c}}}default:{return a.a}}}
```

### Pushed-state handling

beni: the subscription, the route table, and a dispatcher that validates and then switches:

```js
C=a=>{let d="rr-push",f=globalThis.window,g=d=>b?null:c?a(B(d)):e(d=>a(B(d)),d);
  f.addEventListener(d,g);return()=>f.removeEventListener(d,g)};
const D={$:"Tick",a:null},E=[A,"a",["a","c","d","b"]],F=[["w1",E]],G=(a,b,c)=>{for(let d of F)if(d[0]===a)v(c,d[1],b);return c},
K=(a,b)=>{let c=x(),d=J(c,a);if(d===c.a)return b;switch(d.$){case"ServerSet":{let a=d.a;return G(a.b,a.a,b)}
  case"Tick":{return b}case"Notify":{return b}default:{w(b,[E],[d.a.a.a.a]);return b}}}
```

At N = 1, Tick and Notify both return `model`, and so does every failed validation. So the
`tick` and `notify` decoding, and the `D` constant, cannot change what the program does.

tea-inline: one switch with no validation (a missing `widget` throws a `TypeError`):

```js
function s(e){switch(e.type){case`serverSet`:o[e.widget.slice(1)](e.state);break;
  case`snapshot`:for(let t in e.state.widgets)o[t.slice(1)](e.state.widgets[t])}}
```

### Program shell and mount

beni:

```js
L=()=>{let b=document.getElementById("root"),d={a:{d:0,a:-1,c:"Sunny",b:"Chat"}},f=d;
  b.insertAdjacentHTML("beforeend","<div data-role=dashboard><section data-key=w1 data-role=widget>…</section>");
  let g=b.lastChild;i(()=>{g.remove()});let h=g.querySelectorAll("*"),j=m(h[0]),k=[[[],[],[],[]]],
  l=a=>{K(a,f);t([k[0][0],k[0][1],k[0][2],k[0][3]])};y(j,f.a,k[0]);let n=o;o=[];r(n);
  let p=C(a=>{e(l,a)});i(p)};f(L);export{j as stop};
```

tea-inline:

```js
function f(e){let t=[,{cups:-1,season:`Sunny`,coins:0,status:`Chat`}];e.insertAdjacentHTML(`beforeend`,`<div data-role=dashboard>`);
  let n=e.lastChild,i=[],o=d.map(([e,r],a)=>u(t[a],i[a]=[],r(l(n,a,e),t[a],i[a],i,t)));r(); … return{receive:s,stop:c}}
```

### Fixed-cost reading

The app-to-app gap at N = 1 is about 770 B: 1 705 against 935. By deletion:

| | beni | tea | gap |
|---|---:|---:|---:|
| runtime + loader | 451 | 224 | +227 |
| validation | 277 | 0 | +277 |
| pushed-state handling | 184 | 65 | +119 |
| shell + mount | 164 | 112 | +52 |
| widget + markup | 477 | 410 | +67 |

Measured shape-only edits to the N = 1 file (each alone):

| edit | saves |
|---|---:|
| drop the Tick/Notify decode and dispatch arms, which end in `model` either way | 59 |
| `Object.assign` in place of `u`/`v`/`w`'s copy-plan walk, with the two-phase snapshot kept | 36 |
| `t(k.flat(2))` in place of the explicit group list | 5 |
| `void 0` in place of `undefined` | 2 |
| a shared `O(b)` object test in the decoders | −6 (does not pay at N = 1) |
| `Math.min`/`Math.max` in place of `clamp` | 14 (generator knowledge, not available to a compiler) |
| **all the edits that keep beni's semantics** | **≈ 100** |

---

## 2. Per widget

### The widget compared: W5, "Garden corner 6vmz"

W5's source is the same at N = 16 and N = 64, in both trees (`cmp` checked). It is an enum
field and an int field with a number input. In beni's source the model also keeps the typed text.

```text
pub type alias Model =
    size : String
    cups : Int
    cupsTyped : Maybe String
…
replace state model =
    case Json.decodeValue state of
        Ok new → { size = new.size, cups = new.cups, cupsTyped = Nothing }
        Err _ → model
```

**beni, N = 64, the widget module's code** (636 raw):

```js
const oa={$:1,a:null},pa=(a,b,c)=>{
u(()=>{let c=b.a==="Calm"?"default":"custom";l(a[3],`${c} size`)},c[3]);
u(()=>{let c=na(b.b,b.d);m(a[5],c)},[c[0],c[1],c[2]]);
u(()=>{let c=b.a!=="Brisk"?0:1;n(a[9],c)},[c[0],c[3]]);
u(()=>{let c=b.d<2?0:1;n(a[10],c)},c[0]);
let e=a=>{let d=ma(a,0,46);if(d.$===0)b.d=d.a,b.b=oa;else b.b={$:0,a:a};x([c[0],c[1],c[2]])};
p(a[1],()=>{let a=b.a==="Calm"?"Brisk":b.a==="Brisk"?"Loud":"Calm";b.a=a;v(c[3])});
p(a[5],a=>{e(aa(a))},"input");
p(a[8],()=>{b.d=3,b.a="Brisk";x([c[0],c[3]])})},
qa=[Q,0,["cups",L,0,"d"],["size",J,0,"a"]],
ra=(a,b)=>{let c=I(qa,a);if(c.$===0){let d=c.a;return{d:d.d,b:oa,a:d.a}}return b};
```

**beni, N = 64, W5's pieces at the program site**:

```js
ce=[ra,"_",["a","d","b"]]                      // route entry: replace, model key, copy plan
["w5",ce]                                       // in the ServerSet route table jf
["w5",M,0,"_"]                                  // in the Snapshot.widgets shape lf, plus a slot in its permutation [0,11,22,…]
A(b,[…,ce,…],[…,d._,…])                         // the snapshot loader's two lists
i={d:3,b:oa,a:"Brisk"} … _:i                    // the initial slice, then its entry in the model record
Ra=o(Ja[53])                                    // element lookup
[[],[],[],[]]                                   // its four groups
Fc[4][0],Fc[4][1],Fc[4][2],Fc[4][3],            // in the after-push "rerun everything" list
pa(Ra,Fa._,Fc[4]);                              // the wiring call
'<section data-key=w5 data-role=widget><h2>Garden corner 6vmz</h2>…<p>Printing is free for members.</aside></header></section>'
```

At N = 16 the shape table and the wrapper are, instead, a decoder function and a wrapper. The
`Snapshot.widgets` record is an unrolled presence test:

```js
_=(a,b)=>{if(typeof b!=="object"||b===null||Array.isArray(b))return a.a;let c=b.cups;if(!Number.isSafeInteger(c))return a.a;
  let d=b.size;if(typeof d!=="string")return a.a;return{b:c,a:d}},
aa=(a,b)=>{let c=B(),d=_(c,a);return d===c.a?b:{b:d.b,c:Z,a:d.a}};
Ua=[aa,"n",["a","b","c"]]
let k,l=b.w5;if(l!==undefined)k=l;else k=a.a;if(k===a.a)return a.a;     // in gb, the Widgets record
I=o(D[53]) … $(I,A.n,X[4]);
```

**tea-inline, N = 64, all of W5** (the same at N = 16, apart from the array's name):

```js
f.push([`<h2>Garden corner 6vmz</h2><button data-role=cycleSize>Next</button><fieldset><p></p><label>Cups<input type=number data-role=typeCups></label><small>Board 6vmz</small></fieldset><header><button data-role=startOver>Reset all</button><aside><aside><p>Use the blue form for refunds.</aside><p>Printing is free for members.`,
(e,t,r)=>{r.push([()=>o(e[2],`${t.size==`Calm`?`default`:`custom`} size`),()=>l(e[7],t.size!=`Brisk`)],
                 [()=>s(e[3],String(t.cups)),()=>l(e[8],t.cups<2)]),
c(e[0],()=>{t.size=t.size==`Loud`?`Calm`:t.size==`Calm`?`Brisk`:`Loud`,n(r[0])}),
c(e[3],e=>{let i=e.target.valueAsNumber;!Number.isInteger(i)||i<0||i>46||(t.cups=i,n(r[1]))},`input`),
c(e[6],()=>{t.cups=3,t.size=`Brisk`,n(r[1],r[0])})}]),
// and its slice in the model array:
{size:`Brisk`,cups:3},
```

tea-inline has nothing per widget at the program site. `section()` builds the wrapper and finds
the elements, the `W.map` loop wires every widget, and the loader is generic.

### Category slopes (B per widget, brotli)

"ind" is the category deleted alone. "cum" is cumulative deletion, which sums to the measured
slope.

**64 → 256** (both sides in their stable shape):

| category | beni ind | beni cum | tea ind | tea cum | gap (cum) | beni raw/w | tea raw/w |
|---|---:|---:|---:|---:|---:|---:|---:|
| markup and template | 51.9 | 53.4 | 51.4 | 49.4 | +4.0 | 423 | 357 |
| element lookup (`Ra=o(Ja[53])`) | 2.9 | 2.9 | 0 | 0 | +2.9 | 15 | 0 |
| bindings and readers (`u(()=>…,g)` / `r.push([…])`) | 48.1 | 48.1 | 40.1 | 40.1 | +8.0 | 295 | 240 |
| handlers (`p(…)`, typed-input helpers / `c(…)`) | 32.0 | 30.3 | 27.5 | 27.9 | +2.4 | 222 | 230 |
| state slice (literal, model-record entry, `Nothing` constant) | 14.2 | 13.4 | 8.5 | 8.6 | +4.8 | 38 | 34 |
| validation and loader (all six below) | 38.5 | 31.9 | 0 | 0 | +31.9 | 172 | 0 |
| · shape table `qa=[Q,0,…]` | 11.2 | 8.6 | | | | 64 | |
| · replace wrapper `ra=(a,b)=>…` | 8.0 | 6.8 | | | | 44 | |
| · route entry `ce=[ra,"_",[…]]` | 9.5 | 8.2 | | | | 28 | |
| · route table `["w5",ce]` | 2.7 | 2.3 | | | | 12 | |
| · snapshot record `["w5",M,0,"_"]` and its permutation | 3.9 | 3.8 | | | | 22 | |
| · snapshot loader `ce,` / `d._,` | 3.2 | 2.2 | | | | 8 | |
| registration (groups `[[],…]`, rerun list / tea's cross `r[0].push(r[4])`) | 4.7 | 4.1 | 2.9 | 2.9 | +1.2 | 58 | 22 |
| program-site wiring and closure shell | 9.5 | 8.8 | 0.5 | 0.5 | +8.3 | 40 | 25 |
| tick arms | 1.6 | 2.0 | 0.9 | 1.4 | +0.6 | 4 | 7 |
| residue | | 0.2 | | 0.3 | | | |
| **total** | | **194.8** | | **131.0** | **+63.8** | 1 279 | 917 |

**16 → 64** (beni crosses the shape-reader threshold here):

| category | beni ind | beni cum | tea ind | tea cum | gap (cum) |
|---|---:|---:|---:|---:|---:|
| markup and template | 69.1 | 73.3 | 67.5 | 67.4 | +5.9 |
| element lookup | 1.6 | 1.3 | 0 | 0 | +1.3 |
| bindings and readers | 54.4 | 54.4 | 50.1 | 50.1 | +4.3 |
| handlers | 36.3 | 36.8 | 35.2 | 36.6 | +0.2 |
| state slice | 7.8 | 12.2 | 12.2 | 12.9 | −0.7 |
| validation and loader (net: decoder functions out, shape tables in) | 19.3 | 29.7 | 0 | 0 | +29.7 |
| registration | 1.6 | 4.1 | 4.0 | 3.4 | +0.7 |
| program-site wiring and closure shell | 6.5 | 10.7 | 0.9 | 1.1 | +9.6 |
| tick / other | 0.1 | −0.4 | 0.9 | 1.2 | −1.6 |
| residue: the shape reader's runtime, arriving once at N ≥ 29 | | 6.2 | | 0.2 | +6.0 |
| **total** | | **227.2** | | **172.9** | **+54.3** |

**Check against the slopes.** At 64→256 the cumulative columns sum to 194.8 and 131.0, the
measured slopes, and the per-category gaps sum to +63.8. At 16→64 they sum to 227.2 and 172.9
(+54.3). The fit's 207.7 against 145.0 (+62.7) is closer to the 64→256 picture: about 32 of the
gap is validation, about 11 is wiring and lookup, 8 is bindings, and 5 each is state and markup.
At 16→64, beni's individual deletions sum to only about 197 of 227, so its categories share
context. Read "ind" as a rough share and "cum" as the bookkeeping.

---

## 3. What beni writes that tea-inline does not, and why

Each item gives the guarantee it serves, or "shape only", then a smaller shape and the measured or
estimated saving.

1. **Pushed-state validation: the shape table.**
   `qa=[Q,0,["cups",L,0,"d"],["size",J,0,"a"]]`. *Guarantee:* no runtime exceptions, and no
   silent wrong answer from a malformed push. (tea-inline's `structuredClone` + `Object.assign`
   accepts anything, and `e.widget.slice(1)` throws when `widget` is missing.) It costs
   8.6–11.2 B per widget, which agrees with Part 3's +8.5 for beni's shape table added to
   tea-inline. *Smaller:* each entry could be shorter: `["cups",L,"d"]` without the `0`, and with
   the order slot only when it is needed. That is about 1 B per widget, and Part 3's #659
   experience says name changes do not pay under brotli. **The owner must decide on any change to
   what is checked.**
2. **Everything around the shape table: the wrapper, the route entry, the route table, the
   snapshot record and permutation, and the loader lists.** About 23 B per widget (cumulative,
   64→256). *Shape only.* The widget's identity appears four times ("w5" twice, `ce` twice, `"_"`
   three times), and the copy plan `["a","d","b"]` repeats the model's keys, which the shape
   table and `replace` already know. The snapshot's permutation `[0,11,22,…]` orders field checks
   whose failure order no one can see: the result is all-or-nothing and the error is discarded.
   *Smaller:* one table, `[["w5",qa,"_"],…]`, read by the ServerSet route, by the snapshot (which
   iterates it and keeps all-or-nothing by checking every key first) and by a generic loader that
   writes with `Object.assign`. The `replace` that resets `cupsTyped` becomes a defaults object,
   or stays as a function only for the widgets whose `replace` is not "decode or keep". **Measured
   on the real output: −21.2 B per widget at 64→256, −13.1 at 16→64.** The edit text ends
   `…,["w52",jd,"aa"],["w53",md,"ba"],…`. It needs a generic loader in the runtime, about
   60–80 B once, not measured. This is the largest single item.
3. **Program-site wiring, element lookup and closure shells.** `pa(Ra,Fa._,Fc[4]);`,
   `Ra=o(Ja[53])` and `const oa=…,pa=(a,b,c)=>{…}`: 8–11 B per widget. *Shape only:* a
   consequence of "handlers and readers live at the program site" as fix 7 built it. tea-inline
   uses one `W.map` loop over `[html, fn]` pairs, and each section runs its own
   `querySelectorAll`. *Smaller:* a wiring table, `[[T,"a"],[ba,"l"],[ha,"o","a"],…]`, walked by
   one loop that finds each section as a child of the dashboard. **Measured: −5.4 B per widget at
   64→256, −3.6 at 16→64**, plus a loop of about 40 B once.
4. **The after-push list "rerun every group".**
   `x([Fc[0][0],Fc[0][1],…,Fc[63][3]])`: 3.4–4.0 B per widget, 40 raw. *Shape only:* `x` sorts by
   ordinal, so the order of the list does not matter. *Smaller:* `x(Fc.flat())`. **Measured: −4.1
   B per widget at 64→256, −1.4 at 16→64, −5 B at N = 1.** One step further: rerun only the
   widgets a push changed, as tea-inline's loader does (`n(all)` per widget). That is CPU, not
   bytes.
5. **Bindings: hoisted `let`s.** `u(()=>{let c=b.d<2?0:1;n(a[10],c)},c[0])`, where tea-inline
   has `()=>l(e[8],t.cups<2)`. *Guarantee:* evaluation order. The `let` keeps the view's order of
   evaluation when the value could throw or diverge, and that is what #618's totality work
   removes for total expressions. *Smaller:* write the expression at its use. **Measured (a regex
   rewrite of the simple cases): −4.3 B per widget at 64→256, −2.5 at 16→64.** The rest of the
   +8 binding gap is `?0:1` toggles where a boolean would do (`n(a[9],!(…))`), multi-group
   registration lists `[c[0],c[1],c[2]]` (tea-inline pushes the reader into the field's group
   once: `r[0].push(r[4])`), `===` (about 0.4), and the code-point length helper `X(b.a)` in
   place of `.length` (Part 3: +0.2, a guarantee, keep it). tea-inline in turn pays for long
   field names (`t.cups`, `t.size`), and beni's short names (`b.d`) partly offset this.
6. **Handlers.** The typed-input path is
   `let e=a=>{let d=ma(a,0,46);if(d.$===0)b.d=d.a,b.b=oa;else b.b={$:0,a:a};x([c[0],c[1],c[2]])}`
   plus `p(a[5],a=>{e(aa(a))},"input")`. Part of this comes from **beni's source program**, not
   from a guarantee: the model keeps `cupsTyped : Maybe String`, and tea-inline drops invalid
   input instead. Part 3 puts this at about 4 B per widget across the handler, binding and slice.
   *Shape only:* the extra `e` indirection, and the enum-cycle `let a=…;b.a=a;` in place of
   `b.a=…` (evaluation order, as in item 5). Saves 0.4–0.9 by regex at 64→256, about 0 at 16→64.
   *D3:* `x([c[0],c[3]])` against tea-inline's `n(r[1],r[0])` is 2–4 raw characters per
   multi-group handler (the array brackets) and well under 1 B per widget.
7. **The state slice.** `i={d:3,b:oa,a:"Brisk"}` then `_:i` in the model record. Also one
   `{$:1,a:null}` constant per widget module (`oa`, `sa`, `Ga`, … 1.2 B per widget at 64→256),
   and a duplicated `Maybe.withDefault` (`S=` and `ka=`, identical, fixed). *Shape only.*
   *Smaller:* write each slice literal inside the model record, `{a:{c:0,d:-1,…},b:{…},…}`
   (**measured −2.9 B per widget at 64→256, −0.8 at 16→64**). Share one `Nothing` constant
   (about −1).
8. **Markup.** `<section data-key=w5 data-role=widget>` and the trailing closers
   `</aside></header></section>`. *Shape only.* tea-inline's runtime writes the section prefix
   from a template and leaves the closers out. *Smaller:* drop the closers before `</section>`
   (the `</section>` end tag closes them; **−1.1 B per widget at 64→256**), and a prefix template
   (**−2.6 to −3.6 B per widget**, about 20 B once).
9. **`==` against literals.** `b.a==="Calm"`: 0.3–0.4 B per widget, shape only (both sides are
   strings).
10. **Fixed: the scheduler, groups with ordinal sort, and stop on a defect.** About 200 B against
    tea-inline's 81 (scheduler) and 0 (sort). *Guarantee:* D3 synchronous render, in document
    order, and the defect rule. **The owner's.**
11. **Fixed: event validation.** 151 B for `H`, `I`, `J`. *Guarantee:* no runtime exceptions.
    The Tick and Notify arms are **shape only** at N = 1: both outcomes are `model`. *Smaller:*
    when every arm of a tag (and the failure arm) returns the same value, skip that tag's decode.
    **Measured −59 B at N = 1.** At N ≥ 16, Tick is live (ticking widgets), so only Notify goes.
12. **Fixed: the copy-plan walker.** `u`, `v` and `w`: 123 B. *Shape only*, for these programs:
    every copy plan is flat, and every `replace` returns the full key set. *Smaller:*
    `Object.assign(d,e)`, keeping the two-phase snapshot. **Measured −36 B at N = 1.** A nested
    record would still need a walk, so the compiler would emit the walker only when some plan
    nests.

---

## 4. Opportunities, ranked

"Measured" means the real minified output was edited into the shape and re-compressed (seed 1).
"Estimate" means it was not built. Fixed costs are bytes paid once.

| # | Opportunity | B/widget (64→256) | B/widget (16→64) | Fixed | Kind |
|---|---|---:|---:|---:|---|
| 1 | One route table `["w5",shape,key]` serving ServerSet, Snapshot and a generic `Object.assign` loader, in place of wrapper, route entry, route table, snapshot record, permutation and loader lists | **−21.2** measured | −13.1 measured | +60–80 estimate (loader) | shape |
| 2 | Wiring table + one loop (no per-widget call, no per-widget lookup) | **−5.4** measured | −3.6 measured | +≈40 estimate | shape |
| 3 | Inline hoisted `let`s where the expression is total (#618) | **−4.3** measured | −2.5 measured | — | evaluation order: settled by totality, no owner choice needed if #618's rule holds |
| 4 | `x(G.flat())` in place of the explicit rerun list | **−4.1** measured | −1.4 measured | −5 measured | shape |
| 5 | Section-prefix template in the runtime | −2.6 to −3.6 measured | −2.6 measured | +≈20 estimate | shape |
| 6 | Slice literals inside the model record | **−2.9** measured | −0.8 measured | — | shape |
| 7 | One shared `Nothing` constant, one `Maybe.withDefault` | ≈ −1.2 (deletion) | ≈ 0 | small | shape |
| 8 | Drop closing tags before `</section>` | −1.1 measured | ≈ 0 | — | shape |
| 9 | `==`/`!=` against string literals | −0.4 measured | −0.3 measured | small | shape |
| 10 | Booleans in place of `?0:1` toggles; reader pushed into its group once in place of `[g0,g1,g2]` registration lists | ≈ −1 to −2 (estimate) | | | shape |
| 11 | Skip the decode of a tag whose every outcome is `model` (Tick/Notify at N = 1, Notify at N ≥ 16) | 0 | 0 | **−59** measured | shape (no observable change) |
| 12 | `Object.assign` in place of the copy-plan walker when no plan nests | 0 | 0 | **−36** measured | shape |
| 13 | `void 0`; `window` in place of `globalThis.window`; direct `e(a,B(d))` in the subscription | 0 | 0 | ≈ −2 to −15 (estimate) | shape |
| 14 | Shorter shape-table entries (no `0` order slot) | ≈ −1 (estimate) | | | shape |
| — | The shape table itself (what is validated) | 8.6–11.2 is its cost | | | **guarantee: owner** |
| — | Code-point length helper | ≈ 0.2 (Part 3) | | ≈ 25 | **guarantee: owner** |
| — | Synchronous scheduler, ordinal-sorted multi-group run, stop on defect | < 1 | | ≈ 200 vs 81 | **guarantee (D3, defect rule): owner** |
| — | Event-envelope validation (ServerSet, Snapshot) | 0 | | ≈ 90 after #11 | **guarantee: owner** |
| — | `cupsTyped : Maybe String` kept by beni's source | ≈ 4 (Part 3) | | | **the benchmark source: owner / S1 team** |
| — | `clamp` with both bounds (tea-inline uses `Math.min`, from generator knowledge) | ≈ 0 | | 14 | not available to a compiler without range analysis |

**What the measured shape edits buy together.** At 64→256 the measured edits, applied together
(1, 2, 4, 6 and 9), save **32.3 B per widget**, against 34.0 for the separate figures summed. At
16→64 they save 27.1. Adding #3 gives about 36. The 64→256 slope then falls from 194.8 to about
158–162, against a bar there of 144.1. On the fit that is about 172 against 159.5. Items 5, 7, 8
and 10 (about 6–8 more) bring it close to the bar. To close it fully, the owner must also accept
the guarantee costs as they stand, or choose to change the benchmark source's `cupsTyped`.

**N = 1.** The mean is 1 732 against a bar of 1 358.5, so about −374 B is needed. The fixed
shape edits measured here (#11, #12, #4, `void 0`) save about 100 B. Items #1 and #2 each add a
small loop, about +100–120 B together (estimated), so they must be paid for by removing the
per-widget machinery they replace: at N = 1 the route table, `G`, the wrapper and the snapshot
lists. That roughly cancels out. The rest of the fixed gap, about 270 B, sits in the guarantee
runtime (synchronous scheduler and ordinal sort, about 120 B over tea-inline's) and in event
validation (about 90 B after #11). Those are the owner's.

## Caveats

- One seed. Shape thresholds (#659's 29) and the widget mix change by seed.
- Brotli is not additive: the "ind" figures over-count or under-count by up to 25 %, and the
  "cum" figures depend on the order of deletion.
- The edit experiments are text rewrites of the output. They leave out the generic runtime a
  shape needs. Item 3's regex covers only the simple `let x=E;f(a[N],x)` forms, so it is a lower
  bound. Item 6's regexes depend on how locals are named, which is why its 16→64 figures are
  noisy.
- tea-inline's N = 1 and N = 256 files both include the 255 B Vite polyfill and the 59 B adapter,
  which beni's measured file does not. This affects only the fixed part of the bar.

Scratch scripts (local only): `cat.cjs` (categoriser), `exp.cjs` and `exp2.cjs` (per-widget edits),
`fx.cjs` (N = 1 edits), `sec.cjs` and `grp.cjs` (section sizes), in
`~/worktree-evidence/s1-compare/s1/` on dagon.
