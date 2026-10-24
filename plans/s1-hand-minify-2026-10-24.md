# S1 hand-minify pass — beni `master-cb8f0662f` against tea-inline

Brotli-11 bytes only (`~/s1-bins/br.cjs`, lgwin 24, Node 24.19.0). Every edit is a text rewrite of
the real `_main.mjs`, applied by script to all 12 builds (N = 1, 16, 64, 256 × seeds 1–3), measured
alone and in combination; the final files were re-measured on dagon and match the local figures
byte for byte. Every edited output passes `node --check`. No behaviour test was run (that needs a
DOM); each change carries its equivalence argument below, and the two I am less sure of say so.

*Manager's note (2026-10-24, after review).* This pass was made from the minified outputs only, without the compiler's source.
- **Overlap with #934.** S1 is #934's item 2 (the decoder field pattern). S2 is a better form of #934's item 1 (#930): fusing the decoder into `replace` removes the wrapper and the sentinel together. E1 widens #934's item 4: inlining is safe when everything evaluated before the use is a pure read, which does not need totality. The #934 agent has been told to use these forms.
- **Belongs to the benchmark, not the compiler.** F3, c11 and c12 change the subscription in reactivity-research's `frameworks/beni/template/Push.beni` (`globalThis.window`, the dispatch wrapper). F3 also moves the `detail` read outside the dispatch guard. #916 declined that shape under the defect rule, and this report argues `detail` is a pure getter. The owner decides both.
- **Verify before building.** E5: a `Show` reader is registered with its condition's groups only. That needs proof that the body's holes always have their own readers. E6 costs about 150 B once and pays only above about 64 widgets.
- **Measures.** The report's slope is the 64→256 slope, 165.0 at the baseline. The manager's 12-build fit was 174.6 at the same commit. Read the −8 as a slope change, not as a fit value.

The scratch scripts are kept in `~/worktree-evidence/s1-hand/` on dagon.

**Baselines (brotli).** N = 1: 1 522 / 1 445 / 1 687 (mean 1 551). N = 16: 6 266 / 6 256 / 6 055.
N = 64: 15 572 / 15 561 / 15 519. N = 256: 46 642 / 46 817 / 48 229. Slope 64→256:
161.8 / 162.8 / 170.4 (mean **165.0**). tea-inline seed 1: 1 251 at N = 1, slope 131.0.

**Two regimes.** N = 1 and N = 16 validate pushed state with specialised decoders
(`B=(a,b)=>{if(typeof b!=="object"…let c=b.coins;if(!Number.isSafeInteger(c))return a.a;…`); N = 64
and N = 256 use shape tables interpreted by a library (`S=[P,0,["coins",K,0,"f"],…]`). The slope
lives in the table regime, the N = 1 fixed cost in the specialised one, so the two are reported
separately. The per-widget edits E1, E2, E5 apply to both; E6, E7 to the table regime; S1, S2 and
step B to the specialised one.

**Where the 64→256 slope goes today** (deletion, seed 1; tea-inline in brackets): markup 48.9
[51.4]; widget functions (bindings + handlers) ≈ 78 [≈ 71]; shape tables 10.4 [0]; custom `replace`
functions 5.0 [0]; model init 9.4 [8.5]; wiring entries 3.8, route entries 3.7, groups 1.2, tick 1.7
[all 0]. So the gap is ≈ 7 inside the widget functions, ≈ 10 in loader shape, ≈ 15 in validation.

---

## 1. What I tried — the ledger

Δ = brotli bytes against the baseline of the same build. Slope = (Δ256 − Δ64) / 192, per seed.
"fired" = replacements made at N = 256 seed 1.

| # | edit | N = 1 (s1/s2/s3) | N = 16 | slope s1 / s2 / s3 | kept |
|---|---|---|---|---|---|
| E1 | inline a `let` used once in the next statement's argument | 0 / 0 / 0 | −47 / −14 / −27 | −1.01 / −0.74 / −1.08 | yes |
| E2 | inline a single-use handler lambda into its listener | 0 / 0 / 0 | −25 / −59 / −45 | −2.16 / −1.66 / −2.08 | yes |
| E5 | register a `Show` reader with its condition's groups only | 0 | 0 | −0.54 / −0.41 / −0.08 (31 of 57 sites) | yes, small |
| E7 | `replace` = "decoded fields + constants" → constants object on the route entry | — | — | −3.67 / −2.57 / −2.82 (72/64/63 fns, all match) | yes |
| E6 | one per-widget table built into model, groups, routes and wiring at load | — | — | −1.22 / −1.63 / −1.86 (N = 64: −32 / −72 / +11) | yes, pays above ≈ 64 widgets |
| E3 | drop the `0` mode slot from shape entries (`["coins",K,0,"f"]` → `["coins",K,"f"]`) | — | — | −0.73 / −0.07 / +0.19 | no: noise |
| E4 | custom `replace`: compare with the sentinel instead of building a `Result` | — | — | −0.38 / +0.03 / −0.36 | no: noise, and E7 removes the function |
| F1 | wiring loop `apply(null,[…].concat(…))` → call with spread | 0 | +6 / +27 / +21 | −0.60 / +0.20 / −0.34 | no: noise |
| F2 | `c===undefined?"value":c` → default parameter (`m`, `q`, N = 1's `l`) | −17 / −4 / −10 | −3 / +11 / +14 | −0.14 / −0.03 / −0.33 | yes, at N = 1 |
| F3 | subscription calls `send` directly, no second dispatch wrapper | −16 / −12 / −16 | +4 / −4 / −10 | 0 | yes (platform sibling) |
| F4 | after a push, run the registration list instead of `x(E.flat())` | (c6: −2) | +6 / +38 / +15 | +0.16 / +0.07 / −0.10 | bytes no; CPU yes |
| F6 | `Ja.filter(b=>b[0]===a).slice(0,1)` → drop `.slice(0,1)` | −9 / −8 / −4 | −5 / +21 / +15 | noise | yes, at N = 1 |
| S1 | a `Value`/record field needs no presence dance | −46 / −33 / −30 | −158 / −122 / −158 | — | yes |
| S2 | fuse the record decoder with its only caller (`replace`) | −10 / −2 / −8 | −133 / −121 / −76 | — | yes |
| B | fuse the event decoder, snapshot and widgets decoders into the dispatcher, sentinel-free (hand) | −97 / −89 / −88 on top of A | not built | — | yes |
| C | micro-edits on top of B (see below) | −28 / −30 / −28 | — | — | yes |

Step A = E1 + E2 + F2 + F3 + S1 + S2 scripted: N = 1 −68 / −54 / −67; N = 16 −359 / −406 / −380.

**Step C micro-edits, priced alone on step B (N = 1 s1, base 1 357):** c12 bare `addEventListener`
in place of `globalThis.window.addEventListener` −13; c11 inline `y=a=>a.detail` −5; c7
`let p=z(a=>{e(l,a)});i(p)` → `i(z(a=>e(l,a)))` −4; c2 drop `.slice(0,1)` −2; c6 run the
registration list after a push −2. **Dropped:** c1 `d.shift()` → index +8; c4
`g.querySelectorAll("*")[0]` → `g.firstElementChild` +11; c5 `[...new Set(…)]` +2; c9 `if` → `&&`
in `k`/`l` +4; c8 queue as an always-array −1; c3 stop hooks as an array +14 alone (−14 when
combined with c8 — brotli non-additivity; not kept, unexplained).

### The edits, with real excerpts

**E1 — inline a hoisted `let` into the next statement.** Before / after (N = 16 s1):
```js
t(()=>{m(a[1],b.a);let d=E(b.a)>=1?0:1;n(a[3],d);let f=E(b.a)>6?"High":"Some";l(a[4],f)},c[0]);
t(()=>{m(a[1],b.a);n(a[3],E(b.a)>=1?0:1);l(a[4],E(b.a)>6?"High":"Some")},c[0]);
```
also `let f=E(b.b)+1;l(a[15],`Next: ${f}`)` → `l(a[15],`Next: ${E(b.b)+1}`)`. Raw −2 136 at N = 256 s1
(267 sites). *Equivalence:* the only evaluation moved across is the receiver `a[N]`, an index into
a static `NodeList`, which has no side effect and cannot throw; so whatever `E(…)` does (throw,
loop) happens at the same point relative to every DOM write. This does not need totality of `E`:
it is the single-use inlining rule plus "the intervening evaluation is a pure read". Guarantee 5
holds. Condition for the compiler: the `let` is used exactly once, in the immediately following
statement, as a direct argument (or inside a template literal argument), and every operand
evaluated before that use is a local, a literal or an index into a local.

**E2 — inline a single-use handler into its listener.** Before / after:
```js
let d=a=>{b.a=a;u(c[0])};p(a[1],a=>{d(J(a))},"input")
p(a[1],a=>{b.a=J(a);u(c[0])},"input")
```
and when the body uses its parameter more than once the parameter is rebound:
```js
let e=a=>{let d=U(a,46);if(d.$===0)b.b=d.a,b.c=D;else b.c={$:0,a:a};w([c[0],c[1],c[2]])};p(a[5],a=>{e(J(a))},"input")
p(a[5],a=>{a=J(a);let d=U(a,46);if(d.$===0)b.b=d.a,b.c=D;else b.c={$:0,a:a};w([c[0],c[1],c[2]])},"input")
```
292 sites at N = 256 s1, raw −3 868. *Equivalence:* `J(a)` (`a.target.value`) is evaluated once,
before the body, exactly as the call `d(J(a))` did; the body still runs inside `p`'s
`a=>g(b,a)` dispatch, so the try/finally and stop flag are unchanged (guarantee 1). Condition: the
`let`-bound arrow has exactly one call site in the enclosing function, and that site is the body of
a listener lambda of the form `a=>{f(g(a))}`.

**E5 — a `Show` reader registered with its condition's fields only.** Before / after:
```js
u(()=>{o(a[9],b.a!=="Brisk"?0:1)},[c[0],c[3]])
u(()=>{o(a[9],b.a!=="Brisk"?0:1)},c[3])
```
The outer `<aside>` of W5 (`if model.size ≠ "Brisk"`) is registered in the `cups` group too,
because its body contains `if model.cups < 2`. But that inner `Show` is its own reader
(`u(()=>{o(a[10],b.d<2?0:1)},c[0])`), and `o` only swaps the pre-rendered element with its
placeholder; it re-renders nothing. So the outer toggle reads only `size`. 57 of 64 single-`Show`
bindings at N = 256 s1 are over-registered this way (489 raw bytes); my inference recovered the
field→group map for 31 of them, so −0.34 is a lower bound (≈ −0.6 if all). *Equivalence:* the
toggle runs after every write to a field it reads; the body's holes have their own readers; the
toggle is idempotent (`replaceWith` on a detached node is a no-op). Guarantee 4 holds. Condition
for the compiler: a `Show` site's dependency set is the free variables of its *condition*; the
body's are the body's own sites'.

**E7 — `replace` as "decoded fields + constants".** Every custom `replace` in the corpus
(72 / 64 / 63 at N = 256) has this exact shape:
```js
ha=[P,0,["cups",K,0,"d"],["size",I,0,"a"]],ia=(a,b)=>{let c=A(ha,a);if(c.$===0){let d=c.a;return{d:d.d,e:B,a:d.a}}return b}
… ["w5",ia,"nd"] …
```
after:
```js
ha=[P,0,["cups",K,0,"d"],["size",I,0,"a"]]
… ["w5",ha,"nd",{e:B}] …
// the route runner, once:
return typeof e==="function"?e(f,g):(e=c(A(e,f),g))===g?g:Object.assign(e,b[3])
```
*Equivalence:* the decoded record carries exactly the fields the literal copies under the same
names (checked for every function: no renamed field); the constant `e:B` is assigned onto the
decoded record before the second pass copies it onto the live model with `Object.assign`. The key
order of the decoded record differs (`d,a,e` instead of `d,e,a`), which nothing can observe: it is
never enumerated and the live model keeps its own key order. On failure `c(A(e,f),g)` returns the
model `g` as before, and `Object.assign(e,0)` for a route without constants is a no-op. All-or-nothing
is untouched (the first pass still validates every widget before any assign). Condition for the
compiler: `replace state model = case decode state of Ok new → { f1 = new.f1, …, fk = C } ; Err _ → model`
where every non-constant field copies the same-named decoded field.

**E6 — one per-widget table.** Today a widget is named in four lists: the route table
`["w1",S,"f"]`, the init `f:{f:0,d:-1,a:"Sunny",b:"Chat"}`, the groups `[[],[],[],[]]` and the
wiring `[R,_g.f]` (plus extra `_g.k` for cross-widget reads). After:
```js
const rl=[[R,"w1",S,"f",{f:0,d:-1,a:"Sunny",b:"Chat"},4,0],[ba,"w4",ca,"Aa",{c:true,d:"",b:false},5,0,"f"],[ga,"w5",ha,"nd",{d:3,e:B,a:"Brisk"},4,{e:B}],…];
// in mount:
Zg={},_g=Zg;for(let t of rl)Zg[t[3]]=t[4];
let gh=rl.map(t=>Array.from({length:t[5]},()=>[]));
rl.forEach((t,i)=>t[0](p(ah.children[i]),Zg[t[3]],...t.slice(7).map(k=>Zg[k]),gh[i],gh));
```
The route readers move one index (`b[1]`, `b[3]`). *Equivalence:* the same functions receive the
same elements, models and group arrays; the model object is built with keys in route order instead
of record-declaration order, which is unobservable here (the model is never enumerated; this is not
a host value, so guarantee 2's read order does not apply). One caveat: the N = 256 builds have one
widget with no groups that is wired by a direct call (`Mc(eh,_g.xd)`, seed 2 `$h(gh,bh.Zb,bh.L,bh.X,hh)`);
under one loop it must take the uniform parameter list, which is the emitter's choice. The loader
costs ≈ 150 B once, so it pays only above ≈ 64 widgets (N = 64: −32 / −72 / +11). *App-shaped?*
Partly: it merges four parallel tables that the compiler already emits for "a record whose every
field is a sub-model with a view, an init and a route"; the generic form is "parallel per-field
tables indexed by the same record fields fold into one".

**S1 — a `Value` or record field needs no presence dance** (specialised regime). Before / after:
```js
let c,d=b.w1;if(d!==undefined)c=d;else c=a.a;if(c===a.a)return a.a;
let c=b.w1;if(c===undefined)return a.a;
let c,d=b.widgets;if(d!==undefined)c=La(a,d);else c=a.a;if(c===a.a)return a.a;
let c=La(a,b.widgets);if(c===a.a)return a.a;
```
*Equivalence:* for a `Value` field the inner decoder is the identity, so the only failure is
"absent", and a present value can never equal the fresh sentinel; a record decoder's first check
(`typeof b!=="object"`) already rejects `undefined`, so the presence check is subsumed. Same reads,
same order. Condition: emit the presence check only for a field type whose decoder accepts
`undefined` — none does.

**S2 — fuse a record decoder with `replace`** (specialised regime):
```js
w=(a,b)=>{if(typeof b!=="object"||b===null||Array.isArray(b))return a.a;let c=b.coins;if(!Number.isSafeInteger(c))return a.a;…return{d:c,a:d,c:e,b:f}},x=(a,b)=>{let c=u(),d=w(c,a);return d===c.a?b:d}
x=(a,b)=>{if(typeof a!=="object"||a===null||Array.isArray(a))return b;let c=a.coins;if(!Number.isSafeInteger(c))return b;…return{d:c,a:d,c:e,b:f}}
```
and for a `replace` that re-shapes, the final literal is composed: `return d===c.a?b:{b:d.b,c:D,a:d.a}`
becomes `return{b:d,c:D,a:e}` with the decoder's locals. *Equivalence:* the decoder already returns
at the first failing field; every `return a.a` was followed by `return b` in the caller, so the
failure continuation is `return b`. No sentinel, no context object. Condition: a decoder with one
call site whose result is immediately matched (`Result.withDefault`, or a `case`).

**Step B — fuse the event decoder into the dispatcher** (N = 1, by hand; the N = 16 form is the
same with 16 `let x=e.wN;if(x===undefined)return b;` lines). Before (after S1):
```js
C=(a,b)=>{…let c=b.w1;if(c===undefined)return a.a;return{a:c}},D=(a,b)=>{…let c=C(a,b.widgets);if(c===a.a)return a.a;return{a:c}},
E=(a,b)=>{…let c=b.type;if(c==="serverSet"){let d=b.widget;if(typeof d!=="string")return a.a;let e=b.state;if(e===undefined)return a.a;return{$:"ServerSet",a:{a:e,b:d}}}if(c==="snapshot"){let g=D(a,b.state);if(g===a.a)return a.a;return{$:"Snapshot",a:{a:g}}}return a.a},
F=(a,b)=>{let c=u(),d=E(c,a);if(d===c.a)return b;if(d.$==="ServerSet"){let e=d.a;return B(e.b,e.a,b)}let g=d.a.a.a;t(b,A,a=>g[a[2]]);return b}
```
after:
```js
F=(a,b)=>{if(typeof a!=="object"||a===null||Array.isArray(a))return b;let c=a.type;if(c==="serverSet"){let d=a.widget;if(typeof d!=="string")return b;let e=a.state;if(e===undefined)return b;return B(d,e,b)}if(c==="snapshot"){let d=a.state;if(typeof d!=="object"||d===null||Array.isArray(d))return b;let e=d.widgets;if(typeof e!=="object"||e===null||Array.isArray(e))return b;let f=e.w1;if(f===undefined)return b;let g={a:f};t(b,A,a=>g[a[2]])}return b}
```
`u=()=>({a:[]})` and the `$:"ServerSet"` / `$:"Snapshot"` records disappear. *Equivalence:* the
same host reads in the same order (`type`, then `widget`, `state` or `state`, `widgets`, `w1`…),
every failure returns the model, every snapshot read completes before `t` writes (guarantee 2),
and the arm bodies run exactly where the constructors were built. Condition: `case Schema.read s v of`
with the decoder used once → each constructor `return` becomes the arm's body; the failure
continuation is the `Err` arm.

**F2, F3, F6, step C (fixed).** F2: `m=(a,b,c)=>{let d=c===undefined?"value":c;…}` →
`m=(a,b,c="value")=>{…}` (a default parameter fires on `undefined` exactly as the ternary did;
`.length` no longer matters in the hoisted file). F3: `g=d=>b?null:c?a(y(d)):e(d=>a(y(d)),d)` →
`g=d=>a(y(d))`: the program's `send` is `a=>e(l,a)` and `e` itself queues when a dispatch is
running and refuses when stopped, so both branches of the wrapper did what `send` does on its own;
`y(d)` is `d.detail`, a pure getter. F6: `A.filter(b=>b[0]===a).slice(0,1)` → `A.filter(b=>b[0]===a)`:
`replaced`'s `case` has distinct string literals, so at most one route matches. c12: `globalThis.window.addEventListener`
→ bare `addEventListener` — the `browser` platform runs in a window; a portability choice, not a
guarantee. c6: after a push every group is dirty, and the de-duplicated ordinal-sorted union of
every group is the registration list itself (`let n=o;o=[];q(n)`), so `s(k[0])` → `q(n)`; byte-neutral
at N ≥ 16 but it removes a `Set` + sort over every reader per push.

---

## 2. The plan — kept changes, ranked by saving

B/widget is the 64→256 slope, mean of three seeds; fixed is N = 1, mean of three seeds.

| rank | change | B/widget | fixed | guarantees touched | compiler bin |
|---|---|---|---|---|---|
| 1 | **E7** `replace` idiom → constants object on the route entry, runner does `Object.assign(decoded, consts)` | **−3.0** | 0 | 2 (preserved: validate-all-then-write unchanged) | emitter of `replace` routes; needs "record literal of same-named decoded fields + constants" recognition |
| 2 | **E2** inline a single-use handler lambda into its listener; rebind the parameter when used more than once | **−2.0** | 0 | 1, 5 (preserved) | `Opt.zig` single-use inlining across one lambda boundary |
| 3 | **E6** one per-widget table; model, groups, routes and wiring built from it at load | **−1.6** (≈ 0 at N = 64) | +≈150 | none (model key order unobservable) | emitter's loader; fold parallel per-field tables; uniform widget-function parameter list |
| 4 | **E1** inline a `let` used once in the next statement's argument when the operands before it are pure reads | **−0.9** | 0 | 5 (preserved by the purity condition) | `Opt.zig`; needs "intervening evaluation is a local/index read" |
| 5 | **E5** a `Show` reader depends on its condition only | **−0.3** (≈ −0.6 at full coverage) | 0 | 4 (preserved) | `dom` lowering dependency analysis |
| 6 | **Step B + S1 + S2** fused, sentinel-free schema decode (specialised regime) | — (N = 16: ≈ −12/widget for S1+S2 alone) | **−91** (B) **−39** (S1) **−7** (S2) | 2 (preserved) | schema decoder emission: presence check only for types accepting `undefined`; fuse with the single `case`/`withDefault` continuation |
| 7 | **F2** default parameters in the hoisted runtime | ≈ 0 | −10 | none | `Print.zig`/`Minify.zig` for the hoisted file |
| 8 | **F3 + c11 + c12** subscription: call `send` directly, inline `detail`, bare `addEventListener` | 0 | −15, −5, −13 | 1 (preserved: `send` dispatches through the scheduler) | platform sibling source (`Push.onPush`); c12 is a portability decision |
| 9 | **F6 / c2** no `.slice(0,1)` after the route filter | ≈ 0 | −7 | none | emitter: distinct literal patterns match at most once |
| 10 | **c7** `i(z(a=>e(l,a)))` | 0 | −4 | none | emitter |
| 11 | **c6** rerun = registration list | ≈ 0 | −2 | 3, 4 (preserved: same order) | emitter; a CPU win (no `Set`/sort per push) |

Not kept, with reason: E3 (shape entries without `0`), E4, F1, c1, c3, c4, c5, c8, c9 — noise or
positive; F4 at N ≥ 16 — positive bytes (kept only as c6 at N = 1 for CPU).

---

## 3. What the best combination reaches

**Slope (64→256), E1 + E2 + E5 + E7 + E6:** seed 1 161.8 → **153.3** (−8.48); seed 2 162.8 →
**154.9** (−7.87); seed 3 170.4 → **162.7** (−7.68). Mean **165.0 → 157.0**, −8.0 B/widget.
Absolute: N = 64 −410 / −502 / −499; N = 256 −2 039 / −2 013 / −1 973. Dagon confirms seed 1:
N = 64 15 572 → 15 162, N = 256 46 642 → 44 603.

**N = 1, step A + B + C:** 1 522 → **1 329**, 1 445 → **1 272**, 1 687 → **1 504**; mean
**1 551 → 1 368** (−183), against the target of about 1 358. Steps alone: A −68 / −54 / −67,
B −97 / −89 / −88, C −28 / −30 / −28.

**N = 16, scripted part only** (E1 + E2 + F2 + F3 + S1 + S2): 6 266 → 5 907, 6 256 → 5 850,
6 055 → 5 675 (−359 / −406 / −380). Step B was not built at N = 16; by its N = 1 size it is worth
about −90 more there.

The slope target of 159.5 is on the 12-build fit; on the 64→256 slope the combination lands at
157.0 against a baseline of 165.0, so it closes about half of the gap to tea-inline's 131 that is
not validation. Everything else per widget is in §4.

---

## 4. Owner decisions

Savings that need a weaker guarantee or a change to the benchmark source; the size is the 64→256
deletion cost at seed 1.

- **Shape tables, 10.4 B/widget.** The validation itself (guarantee 2). Nothing shape-only is left
  in them: the `0` slot is noise (E3).
- **`cupsTyped : Maybe String` in the benchmark's widgets, ≈ 4–6 B/widget.** It is what makes the
  custom `replace` exist (5.0 B/widget, of which E7 recovers 3.0), the `{$:0,a:a}` / `B` writes in
  the typed-input handler, the `fa(b.e,b.d)` shown-value reader and one extra group per such
  widget. tea-inline drops invalid input instead. The source's choice, not the compiler's.
- **The widget names and the event envelope**, 3.7 B/widget of route entries (`"w5"` is needed by
  `replaced`'s `case`) and the fixed ServerSet/Snapshot validation that remains after step B
  (≈ 90 B): guarantee 2.
- **The synchronous scheduler with ordinal sort and stop-on-defect**, fixed ≈ 120 B over
  tea-inline's microtask batch (D3, guarantee 1). Unchanged by this pass; the micro-edits that
  touched it (c1, c3, c5, c8, c9) were noise or positive.
- **Code-point `String.length`** (`E=a=>Array.from(a).length`), ≈ 25 B fixed and ≈ 0.2/widget:
  guarantee 7.
- **Bare `addEventListener`** (c12, −13 fixed): a platform portability choice, listed here because
  it is the platform's call, not a compiler rule.

## 5. Not "nothing found"

Compiler-side shape worth ≈ −8 B/widget on the 64→256 slope and ≈ −183 B at N = 1 exists and is
listed above with conditions. The remaining ≈ 26 B/widget over tea-inline is validation and loader
data that the guarantees or the benchmark source own.

Scratch (local only): `edits.cjs` (E1–E5, F*, S1, S2 and the 12-build table), `tables.cjs` (E6, E7,
combinations), `n1trials.cjs` / `n1gen.cjs` (steps B and C per seed), `cost.cjs` (deletion costing),
kept in ~/worktree-evidence/s1-hand/ on dagon; `~/s1-hand` on dagon was deleted.

---

## 6. E6, measured again after step B and E7 (2026-10-24, #946)

I applied E6 by script to the real outputs of `master` at `2556986c6`, after step B (#948) and E7 (#949). The script is `~/worktree-evidence/s1-946/e6/e6.cjs` on dagon.

What the script does:
- It builds one table of `[fn, key, shape, field, init, groups, constants, holders…]`.
- It builds the model, the groups, the route rows and the wiring from that table at load.
- Each route reader moves one index.
- A widget wired by a direct call takes the uniform parameter list.

Every output passes `node --check`. No behaviour test was run.

| N | seed 1 | seed 2 | seed 3 |
|---|--:|--:|--:|
| 16 | 5 802 → 5 818 (+16) | 5 793 → 5 821 (+28) | 5 623 → 5 636 (+13) |
| 64 | 15 036 → 15 013 (−23) | 15 010 → 14 958 (−52) | 14 929 → 14 859 (−70) |
| 256 | 44 650 → 44 291 (−359) | 45 233 → 44 722 (−511) | 46 080 → 45 594 (−486) |

On the 64→256 slope this is −1.75 / −2.39 / −2.17 B/widget (mean −2.1). E6 grows the page at N = 16 and saves only from about 64 widgets. At N = 1 there is nothing to merge.

**Dropped.** No size rule picks E6 only where it pays:
- The raw bytes shrink at every size (at N = 16, 22 362 → 22 196, 22 241 → 22 055 and 21 876 → 21 697). So a raw-size proxy would pick E6 at N = 16, where brotli grows.
- Brotli-compressing both forms in the compiler would cost more than the build-time budget allows (`fast-compiler.md` §2).
- What is left is a widget-count threshold tuned to this benchmark's brotli behaviour. That is a cap that special-cases a benchmark, and the brief rules it out.

If the owner wants that threshold anyway, it is the owner's decision. The cost of not taking E6 is about 2 B/widget above 64 widgets.
