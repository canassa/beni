# Core's hand-written JavaScript, moved to beni one piece at a time

*Started 2026-10-01.* The owner's direction: `core/`'s hand-written JavaScript is rewritten in beni
over the `Js` intrinsics (`core/Js.beni`, `boundary.md` §4.2), gradually, **each step at least as
good as the JavaScript it replaces** — R47-3's bar (`plans/browser-decisions.md`), which
`plans/runtime-in-beni.md` held the browser runtime to: release brotli no larger on the pages and
programs that use the piece, no real, reproducible slowdown (noise is not a slowdown, and a
figure is re-run before it is concluded from), and an equivalent shape, side by side. A piece that
cannot meet the bar stays hand-written until the compiler feature it needs lands, and the step
then builds that feature first. Where core must keep a `foreign` — an operation with no `Js`
spelling — it is kept minimal, and the step says why.

## The steps

| # | Piece | State |
|---|---|---|
| 1 | **Small primitives and thin wrappers**: `core/Int32.js`, `core/String.js`, `core/Char.js`, `core/Basics.js`; the browser platform's `Time.js`, `Url.js`, `Storage.js`, `Http.js` | **landed 2026-10-01**, below: all but `Char.js` and `Basics.js`, which the core module graph keeps out of `Js`'s reach |
| 2 | **`core/Task.js`**: the fiber runtime | **studied 2026-10-02**, below and research 49: all of it expressible with one new intrinsic (`Js.suspending`) and a one-line `Reach` fix; a prototype passes the gates, ships 182–279 brotli bytes less per fiber program and matches the sibling's instructions; the slices below |
| 3 | **`core/List.js`**: the array-backed list and its views | **studied 2026-10-02**, below and research 50: all of it expressible with two new intrinsics (`Js.object`, `Js.method`) and two one-line `Lower` fixes; a prototype prints every `run/` program right, keeps the persistence sweep, ties the sibling but for `compare` (1.16–1.19×, a loop-printing cause), and is 1 408 brotli bytes smaller in total but larger for 44 programs; an `abuse_wide` budget is the wall; the slices below |
| 4 | **The rest**: `Char.js` (**gone 2026-10-02**), `Basics.js` and `Debug.js` (**gone 2026-10-02**, below), `Js.js`'s value-passing half (**a contract change**, below), the browser platform's `Hosted.js`, `Browser.js` (**gone**, `plans/runtime-in-beni.md` step 6), `Dom.js`, `runtime.js`'s `safeUrl` (**gone**, `plans/runtime-in-beni.md` step 6), `html`'s `Html.js`, and the `node` platform | to come |
| 5 | **`core/Schema.js`**: the schema library's engine | **landed 2026-10-02**, below: all of it, the sibling deleted; the `--library` bench within 1–3 % on valid input and 4–6 % on failures, and the corpus's schema programs up to 8.5 % larger; **2026-10-03**: failures at parity in instructions (0.999–1.021) and 0–3 % in wall time once a release build keeps a top-level `const`, seven of the nine schema programs 15–192 brotli bytes smaller once the engine stopped pinning `Issue` (the other two +1 and +9), and what is left a wall (*The two gaps*, below) |

## Step 1 — primitives and thin wrappers (2026-10-01)

**What moved.** 350 lines of JavaScript are gone: `core/Int32.js` (all 15 exports),
`core/String.js` (all 20), and `platforms/browser/Time.js`, `Url.js`, `Storage.js` and `Http.js`.
Each `foreign` they answered is a beni declaration over `Js`; nothing in `Int32`, `String`, `Time`,
`Url`, `Storage` or `Http` is `foreign` now but the types. The `run/` corpus (both builds) and
every `browser/` page print what they printed before.

**The compiler features it needed**, each specified first (`boundary.md` §4.2, `backend.md` §4)
and red first (with the compiler before, `Js does not expose …`):

1. **`Js.catchIf body test handler`** — `try { … } catch (e) { if (!test) throw e; … }`, written in
   place: the one way beni may catch, and only what the test names (`CLAUDE.md` rule 9). JsIr's
   `try_stmt` gained a `catch` clause every pass walks. `Url`, `Storage` and `Http` are written over
   it; fixtures `run/JsCatchIf`, `emit/release/core/JsCatchIf`, `check/bad/core/CatchIfSuspends`.
2. **`Js.pure (\() -> body)`** — the body, and `foreign pure`'s promise: without it `String.length`
   (a `Js.get` of `Array.from`'s `length`) and every function that measured a string would have
   become `!impure` in its interface, and the release optimiser would have kept their unused calls.
   With it no interface moved.
3. **`Js.regExp "pattern" "flags"`** — a regular expression literal, so `words`, `lines`, `toInt`
   and `toFloat` keep `/\s+/` and the rest rather than `new RegExp("\\s+")`.
4. **`Js.bitOr`, `bitXor`, `shiftLeft`, `shiftRight`, `shiftRightZero`, `rem`, `typeOf`,
   `instanceOf`** — `|`, `^`, `<<`, `>>`, `>>>`, `%`, `typeof`, `instanceof`, each its operator, beside
   `bitAnd` (`run/JsOperators`).
5. **`Js` names no core type but `Basics`'s and `List`'s**: a property or global name and a regular
   expression's pattern are a type variable, and `typeOf` answers a `Value`. `Js`'s signatures named
   `String`, so `String` could not import `Js` — `String → Js → String`, an `import_cycle`.
6. **One-parameter arrows print bare under `--release`** (`backend.md` §9, *Compact statements*,
   amended): `a=>…`, as `Minify` writes the hand-written siblings. Without it every function moved
   from a sibling was two bytes longer than it had been.

`URIError`, `SyntaxError` and `DOMException` joined the globals a release build writes bare
(`Rename.bare_globals`).

**A defect found on the way, fixed, with its fixture.** `String.indexes` written as two loops
printed, under `--release`, as `for(let f=0;…;f=h){let g=e,h=f;…}` — the `for` head's update read
`h`, a `let` of the body, and in the head that name is outside the body's block: the answer was
`NaN` at exit 0. *Compact statements*' `for` rule (`Print.forHead`) now keeps an update in the body
when it reads a name the body declares. It was on master for any user program of that shape:
`run/ForHeadBodyName` prints `20` and `30` with master's compiler and `90` and `170` with this one
(and in both builds of this one).

**What stayed, and why.**

- **`core/Char.js`** (`toCode`, `fromCode`, `toUpper`, `toLower`). `String` names `Char` in its
  signatures, and `String` imports `Js`, so `Char` importing `Js` is `Char → Js → … → String →
  Char`, a cycle — and no `Js` call can be written without a property name, a string literal,
  which in `Char` is a `String` the module depends on (`resolve/Graph.zig`, `mintedModules`,
  whose own note says a rewrite of core needs a §6.8 exemption first). Tried: `import Js` in
  `Char` is `IMPORT CYCLE: Char → Js → String → Char`.
- **`core/Basics.js`**. `Basics` is below every module — `Js`'s signatures name its `Int` and `Bool`
  — so it can never import `Js`, and a string or list literal in it is the same cycle. Most of it
  is not shipped anyway: `+`, `-`, `*`, `/`, `^`, the comparisons, `&&` and `||` are written in place
  (`backend.md` §4, *Arithmetic is an operator*); what ships is `idiv`, `modBy`, `remainderBy`,
  `append`'s generic half, the conversions and `Math`'s functions, as the sibling's one-liners.
- **What would move them** is an exemption for `Js` from the graph's two rules: a string literal
  that is the name argument of a `Js` call mints no `String` edge, and `Js`'s signatures name no
  core type — every position a type variable, `Js.same`'s `Bool` and `bitAnd`'s `Int` included —
  so a module below `String` may import it. The first needs the checker to type such a literal
  without `String`'s interface (it reads `well_known.string` from it today, `check/Types.zig`
  `findWellKnown`), which is checker-v2 and static-dispatch §6.8 territory and the owner's call;
  `Basics` would further need `Js` itself to be below it. Step 4 is where that is decided.

**One effect beside the bytes.** A type a sibling's annotation named was in the field-renaming
boundary and kept its string constructor tags (`backend.md` §9, *Item 4, taken up*): `String.toInt`
named `Maybe`, `Http.start` named `Result` and `Http.Error`. Built in beni, they are ordinary
values, so under `--release` a page's `Maybe`, `Result` and `Http.Error` take integer tags unless
something else pins them — `{$:0,a:{$:1,a:{$:2,a:a.status}}}` where `Http.js` wrote
`{$:"Err",a:{$:"BadStatus",a:h.status}}`. `Http` hands its fiber the answer through a type
variable (`resumeWith : Resume a, a -> ()`), which is opaque at the door, so the private `Answer`
that carries a defect pins nothing either.

### Sizes

Release, brotli 11, the whole bundle (`bench/size.mjs`'s programs; `--allow-debug` where a program
logs), master at `9541d2ea` against this step, the same sources.

**`bench/size.mjs`, 332 programs:** release brotli **326 537 → 323 770 (−0.85 %)**, release raw
921 112 → 910 581 (−1.14 %) with **no program larger raw**; development brotli 2 254 050 →
1 840 761 (−18.3 %) — a development build copied `String.js` whole, comments and all, into every
program that used a string function. Release brotli: 224 smaller, 54 equal, 54 larger, and of
those 54, **48 are "names only"** — the same text once every identifier of three characters or
fewer is masked and `(a)=>` is read as `a=>`: a different order of short names, which moves a
few-hundred-byte file's brotli by a few bytes either way (+1 to +16 here; `runtime-in-beni.md`
steps 2 and 3 met the same). The other six are smaller raw and larger compressed by 1 to 8 bytes,
each a `String.compare` user:

| program | raw | brotli |
|---|--:|--:|
| `run/LetEvidenceCapture` | 4 206 → 4 165 | 1 792 → 1 800 (+8) |
| `run/DotCallDerivedDirect` | 1 973 → 1 893 | 849 → 856 (+7) |
| `run/EvidenceFunctionBodyPerCall` | 1 431 → 1 426 | 679 → 681 (+2) |
| `run/OrderValues` | 1 414 → 1 341 | 635 → 637 (+2) |
| `run/HiddenTypeDerivedRow` | 1 060 → 985 | 527 → 528 (+1) |
| `run/NestedConstrainedCalls` | 794 → 719 | 420 → 421 (+1) |

The hand-written `compare` repeated `return"LT"`/`return"GT"` four times, which compresses against
itself; the beni one says each once in a chain of conditionals (`…?"LT":"GT":f<g?"LT":…`). A faster
`compare` that made no array at all (a walk of code units, stepping back over a surrogate pair)
was built first and measured: 15–30 brotli bytes larger on these programs, so it is not the one
that landed (*Speed*).

**Pages** (`browser/`, the empty pages of `bench/size.mjs`, and the `bench/ui` app):

| page | master | step 1 | |
|---|--:|--:|--:|
| empty `browser`, `Tea.sandbox` | 537 | **536** | −1 |
| empty `Tea.element` | 1 237 | 1 242 | +5 (names only; raw −24) |
| `Tea.element` with effects (`Http`, `Time`) | 5 394 | **5 245** | −149 |
| `bench/ui` app | 5 667 | **5 666** | −1 (raw −38) |
| `tea/TodoMVC` (`Storage`, `Url`) | 8 120 | **7 979** | −141 |
| `tea/HttpDefect` | 4 888 | **4 753** | −135 |
| `tea/HttpResults` | 5 431 | **5 338** | −93 |
| `tea/StorageBasics` | 3 628 | **3 546** | −82 |
| `tea/UrlAddress` | 6 267 | **6 197** | −70 |
| `tea/StorageFaults` | 3 478 | **3 411** | −67 |
| `tea/DefectInFiber` | 3 497 | **3 448** | −49 |
| `tea/Policies` | 6 137 | **6 092** | −45 |
| `tea/LatestTagger`, `DefectInUpdate` | | | −41, −41 |
| `tea/ClockStops` (`Time`) | 4 807 | **4 768** | −39 |
| `tea/TupleKeyRestart`, `OwnedByProgram`, `DebouncedSearch`, `KeyOrder` | | | −37, −30, −26, −22 |
| other `tea/` pages (12) | | | −14 to +4, the growers names only |
| `dom/` pages (19) | | | −22 to +40, all names only but `DefectInHandler` −5 and `Events` 0 |

Every page that reaches a moved wrapper is smaller.

### Speed

`bench/primitives` (new): `Primitives.beni`'s workloads — `<` on two strings, `List.sort` of
strings, `length`, `slice`, `indexes`, `toInt`, `fromInt`, `join`, `words`, `split`, an FNV-1a over
`Int32.mul` and `xor`, and `Int32`'s guarded `div`/`rem`/`mod` — built `--release --library` by
master's compiler and by this one, each build timed in a process of its own, the two alternating
round by round. (Imported into one process, the build loaded second measured 1.3× slower than the
first when both were the same build; the harness's first version did that.)

Node 24.19, Ryzen 9 5950X, pinned to one core (`taskset -c 22`), `n` = 2 000, 12 rounds of 9
samples, 1-minute load 2.8 at the start and 2.6 at the end (taken when the machine, shared with
other builds, was quiet: runs at load 10–40 had medians 2–5× their minimums and are not quoted);
µs per call, median over rounds [range]:

| workload | master | step 1 | |
|---|--:|--:|--:|
| `<` on two strings | 290.0 [286.0–303.2] | 287.5 [284.2–289.1] | 0.99× |
| `List.sort` of strings | 3 333 [3 194–3 469] | 3 062 [2 875–3 115] | 0.92× |
| `String.length` | 122.3 [117.2–129.5] | 120.3 [115.3–150.4] | 0.98× |
| `String.slice` | 456.4 [448.7–467.6] | 453.6 [448.3–462.3] | 0.99× |
| `String.indexes` | 117.3 [115.9–118.1] | 118.4 [116.7–130.3] | 1.01× |
| `String.toInt` | 61.0 [60.2–61.9] | 62.0 [61.5–62.7] | 1.02× |
| `String.fromInt` | 24.8 [24.4–25.4] | 24.8 [24.5–25.2] | 1.00× |
| `String.join` | 26.5 [26.3–26.7] | 26.7 [26.2–27.4] | 1.01× |
| `String.words` | 73.8 [73.1–75.9] | 74.0 [73.6–78.0] | 1.00× |
| `String.split` | 99.4 [97.6–100.6] | 99.5 [97.8–101.7] | 1.00× |
| FNV-1a (`Int32.mul`, `xor`) | 237.6 [235.1–244.3] | 237.6 [234.8–240.4] | 1.00× |
| `Int32.div`, `rem`, `mod` | 15.2 [15.0–15.5] | 15.2 [15.0–15.6] | 1.00× |

Re-run, the two whose ranges did not overlap: `toInt` at 30 rounds (load 2.2), 69.6 [68.6–114.1]
against 69.7 [69.2–74.7], a tie; `indexes` at 20 rounds (load 2.2), 130.8 against 119.8 — it flipped.
No operation is slower. `sort` is faster: `compare` is called through a `List.sort` whose comparator
whole-program specialisation now sees, the sibling's was opaque to it.

**The `compare` that was not landed.** With one compiler and two cores (`--after-core`): the walk
of code units that makes no array — `while(i<h&&a.charCodeAt(i)===b.charCodeAt(i))i++`, then the
code points at the first that differ, one back over a surrogate pair — against the landed one
(10 rounds, load 2.3): `<` 284.4 → **67.8 µs (0.24×)**, `List.sort` 3 004 → **692 µs (0.23×)**. It is
four times faster on the 8–20-character strings `Primitives.strings` makes, and costs 15–30
brotli bytes on a small program that compares strings (`run/OrderingPrimitives` 402 → 432 when it
was measured). R47-3 takes the bytes; the owner may take the speed — `Dict String` is the common
case it serves.

**The `bench/ui` app** reaches nothing that moved; its release file differs from master's only in
`(a)=>` becoming `a=>` (raw −38, brotli −1) — the same program text with every one-parameter
arrow's brackets dropped, which is the same parse. Timed anyway: Chromium 153, `--taskset=8-15`,
n = 8, three batches of three operations (each under 5 minutes, load 1.5–2.5), release builds by
master's compiler and this one, and Solid 1; script median ms:

| | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| master | 5.30 | 10.5 | 1.50 | 1.45 | 1.12 | 0.54 | 55.0 | 5.00 | 22.8 |
| step 1 | 5.25 | 10.6 | 1.28 | 1.28 | 1.09 | 0.54 | 54.6 | 5.02 | 23.9 |
| Solid 1 | 5.46 | 11.8 | 2.02 | 1.96 | 1.83 | 0.67 | 61.4 | 5.31 | 23.4 |

`clear`'s step-1 range was [22.3–57.7], the load having reached 17 during it; re-run with
`replace1k` at n = 12 (load 15–21, the machine busy again): `clear` 27.6 / **26.6** / 24.9 and
`replace1k` 10.9 / **10.7** / 11.9 — it ties. No operation is slower.

### Shape

The hand-written function, as `Minify` left it in a release build, against the beni one.

```js
// Int32 (a --library build; a saturated call of most of these is written in place either way)
export let toInt=c=>c;export let toUnsignedInt=c=>c>>>0;export let add=(b,a)=>(b+a)|0;export let mul=(b,a)=>Math.imul(b,a);export let div=(b,a)=>(a===0?0:(b/a)|0);export let mod=(b,a)=>(a===0?0:(((b%a)+a)%a)|0);export let shiftRightZero=(c,d)=>(c>>>d)|0;
let G=a=>a,H=a=>a>>>0,y=(a,b)=>a+b|0,u=(a,b)=>Math.imul(a,b),v=(a,b)=>b===0?0:a/b|0,x=(a,b)=>b===0?0:(a%b+b)%b|0,F=(a,b)=>a>>>b|0;
// String.length, slice
let e=b=>Array.from(b);export let length=b=>e(b).length;export let slice=(b,l,m)=>{let q=e(b);let d=q.length;let from=l<0?Math.max(0,d+l):Math.min(l,d);let r=m<0?Math.max(0,d+m):Math.min(m,d);return r<=from?"":q.slice(from,r).join("")};
a=b=>Array.from(b).length,da=(a,b)=>a<0?Math.max(0,b+a):Math.min(a,b),b=(a,c,d)=>{let e=Array.from(a),f=e.length,g=da(c,f),h=da(d,f);return h<=g?"":e.slice(g,h).join("")}
// String.compare: the code points of both, then the first that differ
export let compare=(a,n)=>{let g=e(a);let h=e(n);let x=Math.min(g.length,h.length);for(let i=0;i<x;i++){let s=g[i].codePointAt(0);let t=h[i].codePointAt(0);if(s<t)return"LT";if(s>t)return"GT"}if(g.length<h.length)return"LT";if(g.length>h.length)return"GT";return"EQ"};
ea=a=>a.codePointAt(0),c=(a,b)=>{let d=Array.from(a),e=Array.from(b),f=d.length,g=e.length,h=Math.min(f,g),i=0;while(i<h&&d[i]===e[i])i++;return i<f&&i<g?ea(d[i])<ea(e[i])?"LT":"GT":f<g?"LT":f>g?"GT":"EQ"}
// String.words, indexes
export let words=b=>{let y=b.split(/\s+/).filter(z=>z.length!==0);return y};
fa=a=>a.length!==0,e=a=>a.split(/\s+/).filter(fa)
export let indexes=(o,j)=>{if(j.length===0)return[];let v=[];let k=0;let w=0;let f=o.indexOf(j);while(f!==-1){while(k<f){k+=o.codePointAt(k)>0xffff?2:1;w+=1}if(k===f)v.push(w);f=o.indexOf(j,f+j.length)}return v};
h=(a,b)=>{if(b==="")return[];let c=[],e=0,f=0;for(let d=ga(a,b,0);!(d<0);d=ga(a,b,d+b.length)){let g=e,i=f;while(g<d){g+=a.codePointAt(g)>65535?2:1;i++}if(g===d)c.push(i);e=g;f=i}return c}
// String.toInt (a --library build keeps `Maybe`'s string tags; a page's are integers)
export let toInt=b=>{if(!/^[+-]?\d+$/.test(b))return{$:"Nothing",a:null};let d=Number(b);return Number.isSafeInteger(d)?{$:"Just",a:d}:{$:"Nothing",a:null}};
i=a=>{if(/^[+-]?\d+$/.test(a)){let b=Number(a);return Number.isSafeInteger(b)?{$:"Just",a:b}:ca}return ca}
// Url.percentDecode: the sibling's `decodes`, then a second decode at the call; one in beni
let U=b=>{try{decodeURIComponent(b);return true}catch(a){if(a instanceof URIError)return false;throw a}}; … U(d)?{$:"Just",a:decodeURIComponent(d)}:V
ca=a=>{try{return{$:0,a:decodeURIComponent(a)}}catch(a){if(!(a instanceof URIError))throw a;return W}}
// Storage: the area, and `set`
let Ea=b=>{try{return b?globalThis.localStorage:globalThis.sessionStorage}catch(c){if(c instanceof globalThis.DOMException&&c.name==="SecurityError")return null;throw c}};
I=(a,b)=>a instanceof DOMException&&a.name===b,J=a=>{try{return a===0?localStorage:sessionStorage}catch(a){if(!I(a,"SecurityError"))throw a;return null}}
let I=(b,d,g)=>{let a=Ea(b);if(a==null)return 2;try{a.setItem(d,g);return 0}catch(c){if(c instanceof globalThis.DOMException&&c.name==="QuotaExceededError")return 1;throw c}};
L=(a,b,c)=>{let d=J(a);if(d==null)return{$:1,a:1};try{d.setItem(b,c);return{$:0,a:null}}catch(a){if(!I(a,"QuotaExceededError"))throw a;return{$:1,a:0}}}
// Time.now and the timer (whole-program specialisation writes the timer into the one callback, its delay a constant)
let M=a=>globalThis.Date.now();let N=(b,c)=>{let d=globalThis.setTimeout(()=>c(null),b);return a=>{globalThis.clearTimeout(d);return a}};
M=()=>({$:0,a:Date.now()}), … w(a=>{let b=setTimeout(()=>a(null),100);return()=>clearTimeout(b)})
// Http: the body's JSON check (a page's GET, specialised)
if(j){try{JSON.parse(l)}catch(b){if(!(b instanceof SyntaxError))return c({d:b});return c(Gb({$:"BadBody",a:"not JSON"}))}}return c({$:"Ok",a:l})
if(!b)return{$:0,a:{$:0,a:c}};try{JSON.parse(c);return{$:0,a:{$:0,a:c}}}catch(a){return a instanceof SyntaxError?{$:0,a:{$:1,a:{$:3,a:"not JSON"}}}:{$:1,a:a}}
```

Differences that are not bytes: `Url.percentDecode` decodes once where the sibling decoded twice
(once to test, once to answer); `String.compare` walks to the first code point that differs with
`===` on the code points' strings instead of reading both code points at every step; `Storage`'s
`keys` is a counted loop that `return`s its array, where the sibling `push`ed in a `for`; `Http`
resumes its fiber with an `Answer`, one object more per request than the bare `Result` (or
`{d: error}`) the sibling resumed with.
`Http`'s JSON check catches every throw of `JSON.parse` and answers each — a `SyntaxError` as
`BadBody`, anything else as the defect it is, thrown in the waiting fiber — exactly as the sibling
did; it is the one `catchIf` whose test holds of everything, because what it does with the rest is
throw it where the request was made (`boundary.md` §9.8.10 (c)).

### The wall: the gates are red by one budget

`zig build gates` fails on one test, and the step does not land until it passes (`CLAUDE.md` rule
10: the test is not weakened and the JavaScript does not come back). `abuse_wide_test`'s *a derived
row of more than 65 535 context entries checks* — a check, no Node — measured **4 294 million
instructions on master at `40396730` and 4 306 million with this step on it (+12 million, +0.3 %)**
against the budget of 4 300; on master at `1daf16f6` the step measures 4 324 million. The cause is
not the moved code's speed: every `beni` process checks all of core, and `String.beni` now holds
twenty function bodies (and `Js.beni` ten declarations more) where it held `foreign` signatures.
The test was 6 million under the line before the step. The fix being built elsewhere — a process
checks only the core it reaches — removes the cost the step adds; the rest of the gates pass, as
do `test-run-hashes` and every `run/` and `browser/` program in both builds.

### Landed (2026-10-01), on master at `dfc1cf2d`

**The wall is gone, narrowly.** With a process checking only the core it reaches (`0367d3c3`,
`66879eb6`), `abuse_wide_test`'s 65 535-entry check measures **4 288 million** with the step on
it: inside the budget by 12 million, because the prelude still reaches `String`, and `String`
now reaches `Js`. The next thing core adds to the prelude's closure will meet it again. The
cut-off and reach tests count `Js` among the modules every check reaches, which it is.

**A second budget the step met**: `rules_test`'s *no hash map is keyed by a dense id* reads all of
`src/` in a Debug build and measured **4 302 million** once the step's Zig was in it. The cost
was the test's own search, not the rule: `indexOfPos` for a needle of four bytes compares at
every byte in Debug, three passes over 6 MB of source, and a line number counted from the start
of the file for each candidate. One vectorised scalar scan per first byte, and the line number
counted only for a line reported: **651 million**, the rule unchanged.

**`String.compare` is the code-unit walk** (the owner, 2026-10-02, `browser-decisions.md` S7:
processing time beats bytes): units compared with `charCodeAt` until the first that differ,
then the code points there, or one unit back when the unit before opens a surrogate pair in
either string — written as "its code point is astral" (`codePointAt(i - 1) > 0xFFFF`), which
needs no `isHigh`/`isLow` helpers and costs half the bytes of the first version (+42 to +73
brotli). Same compiler, the two cores, 10 rounds, load 1.1, `taskset -c 22`:
`<` **314.7 → 69.6 µs (0.22×)**, `List.sort` of strings **3 112 → 700 µs (0.22×)**. Its price,
`bench/size.mjs` release brotli against the array version: 27 programs larger, every one a
`compare` user, **+8 to +26 B** (+45 raw); the 332 programs' total +481 B (+0.13 %).
`run/StringOrdering` gained a line that sorts a BMP character above the surrogates against
astral ones and two astral ones sharing their first unit (`a\u{FFFF}` below `a😀` below `a😁`).

**The step against master `dfc1cf2d`** (the same sources; master's emitted output had not moved
since `9541d2ea`): release brotli over the 332 programs **374 401 → 372 072 (−0.62 %)**, release
raw 1 059 658 → 1 049 864, **no program larger raw**; 222 smaller, 51 equal, 72 larger by brotli
(the 55 "names only" above, plus the `compare` users). `bench/primitives`, master's compiler
against this one, 10 rounds, load 1.0–1.3: `compare` 315.5 → **68.3** (0.22×), `sort` 3 342 →
**688** (0.21×), every other workload 0.98–1.01×.

**TodoMVC whole** (keyed rows, toggle-all, destroy, the `h1`) rides with the landing: 3 929
million instructions with Node running, 3 237 million on a recorded hash.

### What step 1 leaves

`Char.js` and `Basics.js`, for the graph's reason above. For step 3, `Js`'s list positions
(`call`'s, `apply`'s, `construct`'s and `array`'s arguments) name `List`, so `List` cannot import
`Js` as it stands; they become a type variable the way names did here, or `List` keeps its
sibling. `Http`'s `{d: error}` protocol is gone with `Http.js`; `core/Task.js` still has its own.

## The `Js` exemption (2026-10-02)

The owner's S7 (`browser-decisions.md`): **`Js` is exempt from the module graph**, so `Char` and
`Basics` can move. Specified first — `boundary.md` §4.2, `static-dispatch-spike.md` §6.8 (the stated
exemption that section asked for), `checker-v2.md` §30 and a row of `language.md` §5.4, all dated
2026-10-02 — then built, red first:

- **`Js`'s signatures name no core type.** `Bool`, `Int` and `List Value` became type variables
  (`same : a, a -> bool`, `bitAnd : int, int -> int`, `at : Value, index -> Value`,
  `call : Value, name, args -> Value`), so `Js` imports and mints nothing and is the bottom of the
  core graph: `core:Js -> core:Basics` and `core:Js -> core:List` left `TypeOwnerEdges`'s golden,
  and no edge to `Js` can close a cycle. `development` became **`() -> bool`**, called as
  `Js.development ()`: a `foreign` value that is not a function may not be polymorphic
  (`boundary.md` §4, check 1 — a guarantee, kept), and `JsIntrinsic.droppedArm` reads a `case` on
  the call as it read one on the value. Three fixtures and `browser`'s `Rt` changed spelling; no
  emitted byte changed (`emit/core/JsDevelopment` and its release twin are unchanged).
- **A literal a `Js` call writes in place mints nothing**: a string as `global`'s, `get`'s,
  `set`'s or `call`'s name or as `regExp`'s arguments, a list as `call`'s, `apply`'s,
  `construct`'s or `array`'s arguments (`JsIntrinsic.inPlaceLiterals`). `Graph.mintedModules`
  counts the file's string and list literals against the exempt ones — only for a file that
  imports core's `Js` and has the bit set — and the checker gives each a fresh variable instead of
  `String` or `List a` (`constrain/Expr.zig`'s `call`), so §6.8's invariant holds as it stood.
  A string handed to `Js.from` is still a `String` with its edge.

Tests: `check_test`'s *a Js call's property names and argument list mint no edge, so a core module
below String and List writes one* — a five-module core under `--core-root` where `Basics` writes
`[ Js.from x ]` below `List` and `Lower` writes `"toUpperCase"` below `String` — was red with the
compiler before (`IMPORT CYCLE: Basics → List → Basics`) and checks clean after, its graph pinned;
*a string a Js call hands to Js.from is a String…* holds the line: the same core with `Js.from
"name"` is one `import_cycle`, `Lower → String → Lower`. `check/bad/JsOutsidePlatform` gained a
property-name literal and is still `js_outside_platform`: the exemption lets no user package
import `Js`. Its cost was not measured: the second pass runs only in a module that imports core's
`Js`, about a dozen of core's and the platforms'.

## `Char` and `Basics` (2026-10-02)

With `Js` exempt, **`core/Char.js` is gone** and **`core/Basics.js` lost everything but the
operators, `append` and `eq`/`neq`**. `Char`'s `toCode`, `fromCode`, `toUpper` and `toLower` and
`Basics`' `toFloat`, `round`, `floor`, `ceiling`, `truncate`, `idiv`, `modBy`, `remainderBy`,
`sqrt`, `logBase`, `e`, `pi`, the six trigonometric functions, `isNaN` and `isInfinite` are beni
over `Js`, each the sibling's own body (`isInfinite` is `Math.abs(x) === Infinity`, one test where
the sibling made two; `NaN`'s absolute value is `NaN`).

**What stayed, and why.**

- **`add` `sub` `mul` `fdiv` `pow` `lt` `gt` `le` `ge`**: every saturated call is already the
  operator, written in place (`backend.md` §4, *Arithmetic is an operator*), so the sibling ships
  only for one passed as a value — and a beni body would be that same call of itself, a
  definition that only the in-place rule keeps from recursing. **`and` `or`**: a beni body
  evaluates both sides.
- **`append`** and **`eq`/`neq`** ask a value's JavaScript `typeof` — `"string"`, `"object"` —
  and compare it with a string: a `String` value, which `Basics`, below `String`, may not write;
  the exemption covers only literals a `Js` call writes in place. `Object(x) === x` would answer
  `eq`'s question without a string and `x.$plain === undefined && !Array.isArray(x)` `append`'s,
  each longer than `typeof`'s test; what would move them as they are is a `Js` test of a value's
  type that names no string (`Js.isString`, say) — a new intrinsic, not taken here.

**A wall met and fixed in the compiler.** `Basics` and `Char` with bodies put
`abuse_wide_test`'s 65 535-entry check at **4 300 million instructions**, on the budget. The test
was not the cause: `check/Effects.applyImported` and `applyPlain` asked an imported declaration's
effect block for each class and each class's first site by walking the block from its start —
quadratic in a declaration of many `where` methods, and 27 % of that check. The block is now read
once per use into reused arrays (`Effects.decode`): **4 294 → 3 195 million** for the same check,
the core move included, and no output changed.

**Sizes**, `bench/size.mjs`, the compiler before this step against this one: release brotli over
the 344 programs **372 018 → 371 385 (−0.17 %)**, release raw 1 050 071 → 1 048 276, **no program
larger raw**; 47 smaller, 292 equal, 5 larger by 1 to 14 bytes with the same or fewer raw bytes
(`run/PhantomParameterAcrossModules` +14 at the same 796 raw: a different order of short names).
`run/OperatorsInPlace` −58, `run/Arithmetic` −47, `run/CharOps` −29, `bench/corpus` −65; development
brotli 2 018 578 → 1 948 959 (−3.4 %). The pages: equal, but `browser-tea random` −4.
`emit/release/app/SpecSmall` re-blessed: whole-program specialisation now sees `idiv`'s body, so
`n // 2` became `Math.trunc(a/2)` with no zero test.

**Speed**, `bench/primitives` (new workloads `chars` — `Char`'s four over every character — and
`math` — `floor`, `round`, `sqrt`, `ceiling`, `logBase`, `truncate`, `sin`, `modBy`,
`remainderBy`, `//`), one compiler and two cores, `taskset -c 22`, load 1.2–1.3, 12 rounds of 15
samples of 30 ms: `chars` 1 883 → **1 852 µs (0.98×)**, `math` 72.1 → **71.8 (1.00×)**, `fnv` (`Char.toCode`)
1.00×. With the harness's default 10 ms samples `chars` read 1.06×; each of the four timed alone
is the sibling's to the tenth of a microsecond (`toUpper` 150 against 151 µs per 4 000), and the
gap is gone once V8 has optimised both, so it is warm-up and not the code. A first version shared
the case mappings' one-scalar test as a helper; it measured 1.02× with 30 ms samples, and each
mapping writes its test out now, as the sibling did.

## The rest of `Basics`, and `Debug` (2026-10-02)

**`core/Basics.js` and `core/Debug.js` are gone**; `Basics` keeps no `foreign` but `Int` and
`Float`, `Debug` none. Three commits, each through the gates.

- **The operators** (`add` … `ge`, `and`, `or`) are beni whose body is the operator,
  `add a b = a + b`, emitted as the sibling's arrow. *A wall met and fixed in the compiler*: inside
  `Basics` the body's `+` is `add` calling itself by name in tail position, and §8's tail-call
  loop took it for a self-call — `add`'s body came out as `for (;;) {}` and any program passing
  `Basics.add` as a value hung. A call `Operator` writes in place is now no self-call, tail callee
  or inlining site (`Lower.callsOperator`; `run/BasicsOperatorsAsValues`, red before).
- **`eq`, `neq`, `append`** ask `typeof` through a new intrinsic, **`Js.typeIs v "name"`**
  (`boundary.md` §4.2, amended; its name is an in-place literal, so `Basics` writes no `String`).
  **`Js.typeIs` is decided** (the owner confirmed it on 2026-10-02). Equality is the same loop over a stack of pairs. **Two defects fixed** on the way, both silent
  wrong answers of `Basics.eq` called by name (`==` was right): a list compared key by key never
  equalled the same elements in another form (a view, a trie), and a `()` a function returned as
  `undefined` under `--release` never equalled `()` — `run/BasicsEqStructural`, red before in both
  builds. The list half now walks the plain arrays by index.
  *Superseded the same day (the owner's decision):* `Basics.eq` and `neq` are
  `a, a → Bool where a.eq : a, a → Bool` with `==`/`≠` as their bodies, so called by name they
  run the type's own `eq` exactly as the operator does (`static-dispatch-spike.md` §3.1, amended).
  The structural walk ignored it — two values equal by their type's `eq` were unequal by
  `Basics.eq`, a silent wrong answer (`run/BasicsEqOwnEq`, red before). The walk is deleted; the
  one position that called it, the `undetermined` leaf, is `===` (`checker-v2.md` §31).
  `Basics.compare`, `lt`, `gt`, `le`, `ge` take `number` only and never had the defect. `bench/size.mjs`,
  master against this, 385 programs: development brotli 2 286 431 → 2 284 375 (−2 056), release
  492 853 → 490 767 (−2 086); larger only `run/WideRecordEqInts` (+1 031 development, `Basics.eq`
  on a 300-field record now ships its derived `eq`) and `run/CoreBasicsCalls` (+455, release +7).
  `bench/primitives`' `eqRecords`/`eqNested`/`eqLong` measure the derived `eq` now, not a walk.
  The `Dict` example of the defect is not one: `Dict` declares no `eq`, so `==` on two `Dict`s is
  the derived one over the tree and answers by shape exactly as `Basics.eq` did — both agree.
- **`Debug`**: `toString`'s printer, `log` and `todo` over `Js`, printing exactly what the
  sibling printed (every `run/` golden unchanged). `todo`'s throw is now a mapped frame in core's
  `Debug.beni`; `Debug` depends on `Basics` and `Js` (`check/good/TypeOwnerEdges`).

**Sizes**, `bench/size.mjs`, master against the three commits, 383 programs: development brotli
**2 281 441 → 2 130 141 (−6.6 %)**, 189 smaller and 1 larger (+9); release brotli **460 402 →
458 106 (−0.50 %)**, 114 smaller, 240 equal, 29 larger. The pages: development 1 053–1 238 smaller
each, release equal (`navigation` −28). Of the larger release programs, the ten that call
`Basics.eq` grew 57–88 bytes — the two fixes' code, not the code generator's: against a
hand-written sibling with the same fixes, the beni output is smaller raw on every one of eight and
−15 brotli in total (one +13, two +3/+5, five smaller). The rest are +1 to +23 from a different
order of short names at equal or fewer raw bytes.

**Speed**, `bench/primitives` (new workloads `eqRecords`, `eqNested`, `eqLong` — `Basics.eq` on
2 000 pairs of records, two lists of 200 ten-element lists, two lists of 40 000 — and `appends`, a
`++` the checker does not resolve), master's compiler against this one, `taskset -c 22`, load
6–9, 12 rounds of 15 samples of 30 ms, release: `eqRecords` 1 160 → **794 µs (0.68×)**,
`eqNested` 119 → **16.2 (0.14×)**, `eqLong` 5 217 → **1 383 (0.27×)**, `appends` 297 → 297
(1.00×); development the same within 0.02×. `Debug.toString` of 2 000 records: 26.9–31.2 ms
before, 26.6–28.9 after, three alternating runs.

**What is left in `core/Js.js`, and why.** Every export is the value form of an intrinsic whose
saturated call is written in place; a program reaches the file only by passing an intrinsic as a
value (in the corpus, `run/JsOperators` and `run/JsIntrinsics`, which do it on purpose). None can
be a beni body as the language stands: a body that is the intrinsic's own call (`same a b = same
a b`, as `Basics`' operators are) needs the backend to recognise `Js`'s intrinsics inside `Js`
itself, the module graph and the checker to exempt `Js`'s own literals, and — the wall — it would
**lose the declared rung**: a body's effect is inferred from the body, a self-call infers `pure`,
and `global`, `get`, `call` and the other impure intrinsics would become `pure` in the interface,
which the release optimiser may drop or merge. `call`, `apply`, `construct` and `array` passed a
list that is not a literal need the list protocol's conditional besides, and an `if` would make
`Bool` visible in `Js`, which names no core type. What would remove the file whole is the
backend writing an intrinsic passed as a value as an arrow of its in-place form —
`(a, b) => a === b`, `(o, n, xs) => o[n](...plain(xs))` — with check 2 exempting `Js`: a contract
change (`boundary.md` §4, §4.2), left for the owner.

## Step 5 — the schema engine (2026-10-01)

**What moved.** All of `core/Schema.js`, 626 lines: the builders, the traversal, the runners and
`describe` are beni in `core/Schema.beni` over `Js` (`schema.md` §5 and §16, both amended). **No
JavaScript is left**: every operation the engine performs — `typeof`, `Array.isArray`,
`Object.keys`, `Object.hasOwn`, `Object.create(null)`, `Number.isSafeInteger`/`isFinite`/`isInteger`,
`Map` and `Set` keyed by identity, `JSON.parse` with exactly its `SyntaxError` caught
(`Js.catchIf`), `JSON.stringify` — has a `Js` spelling, so the sibling is deleted rather than
shrunk. The nine `run/Schema*` programs print what they printed, in both builds. It needed no new
intrinsic: step 1's `typeOf`, `instanceOf`, `catchIf` and `pure` were enough.

**What made it possible** is not in this step: a process now checks only the core modules its
program reaches (`checker.md` §4, amended 2026-10-01). The S3 engine was withdrawn because every
`beni` process paid its check; now a program that does not import `Schema` pays nothing, and one
that does pays 3.6 ms on the ReleaseFast compiler (25.8 ms on the ReleaseSafe one the tests run —
the safe build is 7–8× slower on every module, `core/List` included, so there is no hotspot in the
engine's shape; `schema.md` §16 has the phases).

**How it is written, and why that is not bending the code.** Two choices are about the
representation contract, not about speed. The opaque types (`Schema`, `Fields`, `Variant`, …) stay
`foreign type`s and the engine's records are cast to and from them at a type variable
(`toHost`/`fromHost`): a `Js.from` at a named type would make that type one JavaScript "can see"
and keep its field names and string tags in a release build (`boundary.md` §4) — the first draft
did, and its release bundle was 1 370 brotli bytes larger. And the engine's own sequences are host
arrays: written over `List.push` and friends, a schema program pulled in `List`'s array-backed
trie, 1 100 brotli bytes. A run's failure mark is its issue array, and a tagged value's payload is
returned with its variant rather than parked in a cell, which removed three allocations an
operation.

### Measured

| | JavaScript engine | beni engine | |
|---|--:|--:|--:|
| `SchemaSize`, `--release`, brotli 11 | 4 531 | **4 503** | −28 |
| `SchemaSize`, `--release`, raw | 12 760 | 12 652 | −108 |
| application, parse flat × 300 000 (ms, median of 7) | 358 | **351** | 0.98× |
| application, decode flat × 300 000 | 162 | **158** | 0.98× |
| application, print flat × 300 000 | 466 | 469 | 1.01× |
| `--library` bench, parse flat valid (ns) | 1 166 | 1 340 | 1.15× |
| `--library` bench, read flat valid | 402 | 501 | 1.25× |
| `--library` bench, parse flat unknown_key | 1 391 | 1 693 | 1.22× |
| `--library` bench, parse list valid | 920 µs | 1 052 µs | 1.14× |
| `--library` bench, decode flat | 320 | 442 | 1.38× |
| `--library` bench, print flat valid | 1 703 | 1 786 | 1.05× |
| `--library` bench, print list valid | 1 428 µs | 1 494 µs | 1.05× |

Both A/B, interleaved on one pinned core (`taskset -c 22`), Node 24.19, load 1.8–2.9: the
applications are a loop of 300 000 operations in `main`, built `--release` (whole-program
specialised; the same `SchemaBench` user and payload as `bench/schema-library`), timed as whole
`node` processes, start included; the library rows are
`bench/schema-library/run.mjs`'s own workloads, the two builds' modules imported into one process
and sampled alternately, 15 rounds.

### The wall: `--library` builds are not specialised

**The bar is met for size and for programs, and missed by `bench/schema-library/run.mjs`.** That
bench builds `SchemaBench` with `--library --release`, and a library build runs no whole-program
specialisation (`Emit.zig`: `specialise` only for an application), so beni-written core reaches
it as written — its identity casts, its constant sides and its small helpers uninlined — where the
hand-written engine had been specialised by hand. As an application the same engine is at parity.
The fix is the compiler's, not the engine's (`CLAUDE.md` rule 10): specialise a library build's
core modules (they are whole-program-known; only the library's own exports are open), or inline
small top-level functions in the per-module optimiser. Until then this step's library-mode figures
stand as the measured cost.

**Test cost.** Every test is inside its budget. A Schema program costs more to build:
`run/SchemaFailures` 413 → 596 M instructions in development and 1 229 → 2 078 M under
`--release` (the specialiser working through the engine), on the ReleaseSafe compiler.

### Landed (2026-10-02): the wall moved into the compiler, and what is left of it

The engine stayed beni (`CLAUDE.md` rule 10); the compiler changed, in three pieces, each measured
with `bench/schema-library/run.mjs` against the JavaScript engine (the compiler before this step),
4 alternating runs, `taskset -c 22`, load 1.3–1.7, medians:

1. **A `--library` build is specialised** (`backend.md` §9, *Whole-program specialisation*,
   amended): `Emit.specialise` runs for a library too, every name a root-package module exports in
   `Input.escaping`. `read` 1.27 → 1.14×, `decode` 1.30 → 1.15×, the rest 1.02–1.16×. Four
   `emit/release/` fixtures — built `--library` — were given inputs a library's caller supplies so
   that what each pins is not folded first (`ReleaseInline`'s `held`, `CompactIf`'s `classify`,
   `InlineOnce`'s `twice` and `answer`, `StatementShapes`'s `start`); the six others' new goldens
   are the specialised output with their claims intact.
2. **A self-call on the right of `||` or `&&` in tail position is a tail call** (`backend.md` §8,
   amended; `run/TailCallLogical`, red before: `RangeError`). The engine's key searches —
   `claims`, `fieldOn` — were a frame per field; `unknown_key` 1.16 → 1.07×. It is the language's,
   not the engine's: `run/OperatorSectionApplied` is 427 brotli bytes smaller for it.
3. **The record loop writes `Object.hasOwn` and `push` out** (`fieldsFrom`, `listItems`,
   `collect`, `failAt`), as step 1 wrote `charCodeAt` out in `compare`: profiled in a process that
   runs every workload, as the bench does, V8 inlined neither helper into the loop (5 % of the
   samples between them) where it inlined everything into the hand-written engine's `recordOf`.

| workload | JavaScript engine | beni engine | |
|---|--:|--:|--:|
| parse flat valid | 1 213 ns | 1 241 | 1.02× |
| read flat valid | 446 | 458 | 1.03× |
| parse flat wrong_type | 1 115 | 1 162 | 1.04× |
| parse flat missing_key | 980 | 1 035 | 1.06× |
| parse flat unknown_key | 1 355 | 1 406 | 1.04× |
| parse list valid | 845 µs | 861 µs | 1.02× |
| decode flat | 366 | 370 | 1.01× |
| print flat valid | 1 638 | 1 670 | 1.02× |
| print list valid | 1 302 µs | 1 322 µs | 1.02× |

**What is left, the wall as it stands.** The valid paths are within 1–3 %; the three failure paths
are 4–6 % slower, reproducibly (1.04–1.06× in each of three runs). Each failure builds the same
issue, path array and record the hand-written `failAt` built, so what differs is the shape V8 sees,
and no compiler change found here moves it. Tried and not kept: letting slice 8 write in a small
function at every call when the whole is no larger than the declaration (`a.length`, `push`,
`Object.hasOwn` wrappers): no measurable change on this bench. **And the bytes**: `SchemaSize`'s
release brotli is 4 531 → **4 489**, but the corpus's schema programs, which reach more of the engine
than a small schema does, are larger — `bench/size.mjs` release brotli, the JavaScript engine against
this: `run/SchemaFailures` 5 712 → 6 198 (+8.5 %), `SchemaDescribe` 3 650 → 4 039, `SchemaTagged`
+248, `SchemaConstruction` +247, `SchemaDepth` +132, `SchemaDirections` +127, three others within
±17. The engine as the other step left it measured the same (+505 on `SchemaFailures`); it is the
engine's beni, specialised, against hand-minified JavaScript, and it is the next thing to measure
with `hand-minify`'s method.

`bench/size.mjs` over all 349 programs, before this step and after: release brotli 381 023 →
382 038 (+0.27 %), all of it the schema programs above; `bench/corpus` −194, the pages unchanged.

### The two gaps, taken to the compiler (2026-10-03)

**The failure paths: a top-level `let` was the cost.** Profiled in V8 against the JavaScript engine
(CPU profiles, `--trace-turbo-inlining`, `--trace-deopt`, and instructions per operation counted
with `perf_event_open` — `(I(N) − I(0)) / N` per workload, every workload warmed first as the bench
does, five processes each — because wall time on this machine moved ±5 % with other agents' load
and instructions did not), the two engines allocate alike (beni 10 % less) and deoptimise alike; what
differed was the release printer's `const` → `let`. V8 folds a module-level `const` into the code
that reads it and loads and checks a `let` on every read, and the engine's top-level functions are
read at every call: a loop over a two-line top-level function ran 2.5× slower with it written `let`.
Split by kind, only function-valued bindings mattered. The fix is the compiler's
(`backend.md` §9, *Compact statements*, amended 2026-10-03; `emit/release/app/TopLevelConst`): a
top-level `const` stays `const`, emitted and hand-written alike. Instructions per operation against
the JavaScript engine, `--library --release`, before and after:

| workload | before | after |
|---|--:|--:|
| parse flat valid | 1.004 | 0.983 |
| read flat valid | 1.012 | 0.964 |
| parse flat wrong_type | 1.037 | 1.021 |
| parse flat missing_key | 1.012 | 0.999 |
| parse flat unknown_key | 1.046 | 1.014 |
| read flat wrong_type (not in the bench) | 1.073 | 1.017 |
| read flat missing_key (not in the bench) | 1.053 | 1.016 |
| parse list valid | 1.023 | 1.000 |
| decode flat | 0.989 | 0.939 |
| print flat valid | 1.008 | 0.986 |
| print list valid | 1.008 | 0.996 |

Repeated runs of the same build move these by ±1.5 %. Wall time, the bench's own workloads sampled
in alternating processes on one pinned core (`taskset -c 11`, load 4–5, ten processes each, medians):
parse `wrong_type` 1.039 → 1.022, `missing_key` 1.052 → 1.027, `unknown_key` 1.036 → 1.002, the
valid paths 0.94–1.01; a second run at load 13–30 gave 1.011, 1.047 and 1.029. The two reads of a
failing value, which the bench does not time, stay 4–5 % slower in wall time at 1.6 % more
instructions; nothing measured here explains the difference. Not kept, each measured: writing
`parseWith`'s `Ok` wrapper out (no change), splitting `prim` back out of `run` (slower), and
writing the record loop in place in `recordOf` (−1.6 % instructions on valid reads, nothing on
failures; the compiler's *A function called once* does not yet take a loop tested by an `if`).

**The bytes: the engine pinned `Issue`.** Taken apart per top-level unit (leave-one-out brotli), most
of the schema programs' growth was not the engine's code but its names: every schema program kept
`Issue`'s field names and the string tags of `Direction`, `Endpoint`, `IssueCode`, `PathSegment`,
`Maybe` and `Result`. The boundary (`backend.md` §9, *Item 4, taken up*) was right to keep them:
`conversion`, `mapping`, `injection` and `recursive` handed their functions to the host with
`Js.from` at the functions' own types — `b -> Result (List Issue) a` — which says JavaScript may
call them. Nothing does; the engine parks them and calls them from beni, so they now cross at a type
variable like every other value the engine parks (`toHost`), which is the engine's own rule for its
records (above). Red before: `build_test`'s *a schema program's issues get short fields and integer
tags under --release*. `bench/size.mjs`, release brotli, master before these two changes → after,
and the JavaScript engine for reference:

| program | JavaScript engine | before | after |
|---|--:|--:|--:|
| `run/SchemaFailures` | 5 712 | 6 198 | 6 207 |
| `run/SchemaDescribe` | 3 650 | 4 039 | 4 024 |
| `run/SchemaTagged` | 5 449 | 5 697 | **5 520** |
| `run/SchemaConstruction` | 5 902 | 6 149 | **5 957** |
| `run/SchemaDepth` | 5 338 | 5 470 | 5 438 |
| `run/SchemaDirections` | 5 402 | 5 529 | **5 353** |
| `run/SchemaJson` | 4 975 | 4 958 | 4 936 |
| `run/SchemaPresence` | 5 156 | 5 167 | 5 134 |
| `run/SchemaProtoKeys` | 5 019 | 5 032 | 5 033 |
| `SchemaSize` (`bench/schema-library`) | 4 531 | 4 489 | 4 487 |
| the release total, 351 programs | | 372 717 | 372 759 |

The total is +620 from the `const`s and −578 from the schema programs; `bench/ui`'s app 5 675 →
5 669, the empty pages +3, `browser-tea` random +31.

**What is left, the wall.** `SchemaFailures` and `SchemaDescribe` reach `Debug.log`, so
`bench/size.mjs` builds them with the harness-only `--allow-debug`, which turns field renaming and
integer tags off for the whole build; a shipping release build refuses them. With the `Debug.log`
calls taken out they are 5 414 → **5 433** and 3 328 → **3 441** against the JavaScript engine. A
`Debug` use instantiated at a type could be a door of the boundary like `Js.from`, so that only the
types `Debug` prints keep their names; that is a checker artifact, for the harness only. The rest,
`SchemaDescribe` +113, `SchemaDepth` +100, `SchemaTagged` +71, `SchemaConstruction` +55, is the
engine's cold code: the hand-written engine walked a schema with `some`, `find`, `map` and `for … of`
inline, and the beni engine has a loop helper for each (`problemInFields`, `opaqueVariant`,
`collectVariants`, `tagList`, …) and `kindOf`, a seven-arm `switch` from an `Int` to the integer
tag it already is — about 1 000 raw bytes of `analyse` and the builders. Compiler rewrites priced
on the six programs with `hand-minify`'s method, each alone: a helper loop written in place in its
looping caller +7 brotli, merged identical `case` arms +15, `case` bodies without braces −30, copy
propagation of `let d=a` −20, folding a test of a known constant −18 — noise, as the skill predicts
for rewrites that do not remove distinct text. What would remove it is the engine's cold paths
written with fewer walks, which is a change to `core/Schema.beni`'s shape and so the owner's call
(`CLAUDE.md` rule 10), not something this step did.

*2026-10-02.* `SchemaFailures` and `SchemaDescribe` reach no `Debug` any more: what their
`Debug.log` showed — a lazy traversal, a whole-record conversion waiting, describing running no
conversion — is `run/SchemaLaziness`'s, so `bench/size.mjs` measures the two as a release build
ships them, field renaming and integer tags on. Release brotli, the same compiler before and
after: `SchemaFailures` 6 219 → **5 282** (the laziness cases left with the instrument),
`SchemaDescribe` 4 036 → **3 441**.

*2026-10-02, the cold paths rewritten (the owner's approval of that day).* Still beni over `Js`,
no `foreign`. Kept, each priced alone over every `bench/size.mjs` line: a primitive node holds
its `PrimitiveKind`, so `kindOf` is gone (−61 total); `describe` maps fields and variants with
`List.map` (−200); `duplicateIn` is the host's `map`, `find` and `indexOf` (−80); the
discriminator clash is `find` and `some` (−120); a variant carries its own construction problem,
so `tagged` keeps the array it is given and `collectVariants` is gone (−70); a conversion's
issues are moved with `Js.each` (−534); and a compiled failure reads its `IssueCode` from an array
instead of a twelve-arm `case` (−197). Tried and dropped, each larger in total: `problemIn` and
`opaqueIn` through `List.any`, a shared `firstJust`, or the host's `some` (+70 to +476 — the
four sibling loops compress against each other, and one closure each does not); `call` through
`conversionAnswer` (−2, an extra frame on a hot path for nothing); and `tagList` as `map` and
`join` (−233, but the unknown-tag failure retired 19 % more instructions, so it stays a loop).
`run/SchemaConstruction` gained the precedence cases the rewrite had to keep (first name that
occurs again, a broken variant before a duplicate tag, tags before names).

Release brotli, master before → after, and the JavaScript engine where the program is the one it
was measured on:

| program | JavaScript engine | before | after |
|---|--:|--:|--:|
| `run/SchemaDescribe` | 3 328 | 3 419 | **3 256** |
| `run/SchemaTagged` | 5 449 | 5 524 | 5 475 |
| `run/SchemaConstruction` | 5 902 | 5 960 | **5 809** |
| `run/SchemaDepth` | 5 338 | 5 444 | 5 367 |
| `run/SchemaDirections` | 5 402 | 5 360 | **5 327** |
| `run/SchemaFailures` | — | 5 271 | 5 237 |
| `run/SchemaJson` | 4 975 | 4 943 | **4 918** |
| `run/SchemaPresence` | 5 156 | 5 173 | **5 149** |
| `run/SchemaProtoKeys` | 5 019 | 5 024 | **5 004** |
| `run/SchemaLaziness` | — | 5 976 | 5 856 |
| `run/SchemaDecl*`, seven programs | — | 45 661 | 45 245 |
| `SchemaSize` (`bench/schema-library`) | 4 531 | 4 482 | **4 459** |
| the release total, 363 programs | | 429 717 | 428 605 |

No other program moved. Speed, in instructions per operation, `(I(N) − I(0)) / N` over whole
processes, every workload warmed first, three to five processes a side (wall time on this
machine moved by up to 1.5× with other agents' load; instructions repeat within ±2 %): every
`bench/schema-library/run.mjs` workload, every `bench/schema-libraries/quick.mjs` cell of the
`beni` and `beni-library` rows (failure paths included), and a probe of the paths rewritten — an
unknown tag, a conversion that fails through the library and through a declaration, a compiled
wrong type — are within that noise; the largest median differences, +2 and +3 % on two library
cells, came back at +0.75 and +0.5 % when repeated. One thing to know: a `--library` build keeps
string tags, so in those benches `prim` now switches on `"StringKind"`… rather than on `0`…; a
shipped program's tags are integers, and the instruction counts show no cost either way.

## Step 2 — the fiber runtime: the plan (2026-10-02)

**Studied, not landed.** [Research 49](../docs/design/research/49-task-kernel-in-beni.md) built
`core/Task.js` (as it stood at `84a49831`, before the defect teardown) in beni on a scratch branch
and measured it. The answer to the step's question — can the kernel be written in the language
whose suspension it implements — is yes: the compiler's suspendable-form lowering touches only
calls whose callee may suspend, so the kernel's state machinery compiles as plain code and the few
functions that compose suspending kernel functions get the protocol written for them. What it
needs is **one intrinsic, `Js.suspending`** (the body's value, with a `suspends` rung: how `park`
returns the sentinel), and **a one-line fix in `Reach`** (keep `Task.andThen`/`Task.isWaiting` for
any declaration kind). With them the prototype passes `test-blackbox` but the module-graph golden,
makes every fiber program 182–279 brotli bytes smaller (total −4 161, none larger) and matches the
sibling within ±2 % of instructions on every kernel workload (single-threaded V8; research 49 §4).

**After the defect teardown.** The teardown of `boundary.md` §9.8.14 has landed in `Task.js`
(`8063245c`, `12c4333c`, `d6cb1a73`), so the port is of the 790-line file, not the 526 the
prototype ported; research 49 §5 reads each teardown piece into `Js` and finds nothing beyond the
intrinsic. Each slice is specified before it is built (rule 1), red first (rule 3), and passes
`zig build gates` before it lands.

| # | Slice | What | Done when |
|---|---|---|---|
| K1 | **`Js.suspending` and the `Reach` edge** | `boundary.md` §4.2 and `backend.md` §4 (*`Js.suspending` is its body*) as research 49 §3.1 drafts them; `transparent-effects-proposal.md` §16.1's sentence; `JsIntrinsic.suspending`, `Lower` (tail, value **and discarded** positions — the prototype did the first two), `core/Js.beni` and `Js.js`; `Reach.effectEdges` without its `foreign_value` test | `emit/core/JsSuspending` (a park in tail, value and discarded position, both builds); a `--core-root` `check_test` whose `Task` writes `andThen` in beni and whose user module only `yieldNow`s — red before the `Reach` fix (`andThen` dropped) |
| K2 | **The kernel's own defect first** | `run/` fixture: a fiber whose `bracket` release spawns a child, cancelled; the child must not outlive it (research 49 §6 item 1). Fixed in `Task.js` as it stands — `ended` and `finished` cancel and wait for children that appeared after `stopChildren` — so the port starts from a kernel without it | the fixture red on master, green after, both builds |

*K2 as built (2026-10-02, `7bcb1721`):* `run/ReleaseSpawnCancelled` and `run/ScopeReleaseSpawnIn`, both red on the previous `Task.js` in both builds. A spawn from an unwinding parent swaps its `ended` for `reap`, which cancels and awaits the remaining children before ending (Effect's `interruptChildren` after the stack unwinds); `closeScope` and the scope finaliser share `shut`, which marks the scope closed (a later `spawnIn` is cancelled before it runs) and drains it. Release output is unchanged for programs that never spawn; spawning programs grow 40–90 B brotli; `bench/fiber` within noise.
| K3 | **The port** | `core/Task.beni` holds the whole kernel over `Js`, teardown included; `core/Task.js` deleted. The prototype's disciplines: records as `Js.Value`s read by name, one literal each; every beni function the kernel runs held as a `Js.Value` and called with `Js.apply` (no `$s` twin of any kernel function — check the dump); `Exit` crossing at a type variable; `Task.js`'s hand-written elimination (`failure`/`closing` bound in `newFiber`) as `Js.Ref`s written there | gates green but the graph golden, re-blessed (`core:Task -> core:Js`); `test-run-hashes` recorded; `emit/` goldens that show `Task`'s output re-blessed with a side-by-side note |
| K4 | **The bar, measured** | `bench/size.mjs` both ways (no program larger, research 49 §4.2's twenty smaller); the kernel workloads of research 49 §7 in instructions, single-threaded and with threads, and in wall time on a quiet machine (load under 2), the scope workload re-run before anything is concluded from it; `bench/fiber`'s research 44 workloads | every workload within noise or better; a reproducible loss is a wall reported to the owner (rule 10), never a reason to bring JavaScript back |
| K5 | **What the beni kernel makes cheap** (research 48's kernel list, each specified in `transparent-effects-proposal.md` first) | `Task.resume`; `Task.interruptible` inside a masked region; `spawnDetached` (a root in the registry); `poll`; `waitAny` and `race` over the private observers; the fiber slots (clock, log context, seed) as fields of the one literal, copied in `fork`; a development-only spawn site for logical stack traces (`Js.development`) | each with its `run/` fixture, written in `Task.beni` with no new `foreign` |

*K5, specified 2026-10-02* (`docs/design/transparent-effects-proposal.md` §17, the owner having
taken research 48's decisions): the kernel additions are §17.3's `resume`, `poll`, `spawnDetached`,
`uninterruptibleMask`/`restore` with a `Restore` token (decision 12, in place of the
`Task.interruptible` above) and `defer`; §17.5's **four** slots — clock, scheduler, log context,
random seed — copied by reference in `fork`; and §17.6's `Task.sleep` over the clock slot.
`waitAny`/`race` are no longer kernel work: §17.7's combinators are library beni over `scope`,
`spawnIn`, `wait`, `cancel` and `Deferred`. The development-only spawn site stays with P6.

**Not required by the step, and kept out of it** (research 49 §3.3, §3.4): a lowering that writes a
small non-tail continuation twice so the fast path allocates nothing, and `Opt` dropping the dead
branch behind a `Js.Ref` specialisation folded. Either is a general compiler change, priced on its
own when someone wants it.

## Step 3 — the list runtime: the plan (2026-10-02)

**Studied, not landed.** [Research 50](../docs/design/research/50-list-in-beni.md) wrote all of
`core/List.js` — the views, the E1tp trie and its claims, the readers and writers, `eq`,
`compare`, `concat` — in beni on a scratch branch (`list-in-beni-prototype`, `ab729385`) and
measured it. What it needs is **two intrinsics**, `Js.object` (an object literal whose keys are
written as written: the header, view and tree shapes, `$plain` included) and `Js.method` (a
`function` that reads `this`: the two `$plain` methods), and **two one-line `Lower` fixes** (export,
and treat as observed, the core-private `List` values the emitter calls when they are beni and not
`foreign`). No class form, getter, `Js.Ref` field or integer loop type is needed. With them the
emitted runtime has the sibling's shapes field for field; every `run/` program prints its
`.expected` in both builds and the claim sweep's 3.03 million checks hold; every measured operation
ties the sibling in steady-state wall time except `compare`, 1.16–1.19× — the tail-call loop's
printed exit, not the runtime (research 50 §5.3); release brotli is 1 408 bytes smaller in total,
44 programs grow by 1–83 bytes and the `effects` page by 28; and `abuse_wide_test`'s release case
goes over its budget (4 771 against 4 300 million instructions), the wall the port waits on.

Each slice is specified before it is built (rule 1), red first (rule 3), and passes
`zig build gates` before it lands. The `.beni` the prototype wrote predates the Unicode notation:
`beni fmt --migrate-unicode` it before reuse.

| # | Slice | What | Done when |
|---|---|---|---|
| L1 | **The two `Lower` fixes** | `backend.md` §4's *The emitter's imports of the core-private exports* amended: exported and observed whether `foreign` or beni. `Lower.exports` tests `isValue()` for `List` as for `Schema`; the unobserved-result rule marks `unsafeGet`, `view`, `base`, `offset`, `close` dispatched | a `--core-root` `build_test` whose `List` writes `close` in beni: red before (the import fails to load, then `close` returns `undefined`), green after |
| L2 | **`Js.object`** | research 50 §3.1's text in `boundary.md` §4.2 and `backend.md` §4; `JsIntrinsic.object`, the checker's pair typing, the graph exemption for the keys, `Lower.objectLiteral`, a code of its own for a malformed pair; `Js.beni`/`Js.js` | `emit/core/JsObject` and its release twin (key order kept, keys never renamed, values in written order); `check/bad/core/JsObjectKey`; a `check_test` that a module below `String` writes one |
| L3 | **`Js.method`** | research 50 §3.2's text; JsIr `this_lit` and `arrow_method`, printed as `function(){…}` with a block body in both printers; `Lower.methodFunc` | `emit/core/JsMethod` (both builds); a `run/` program whose method reads its receiver through a nested arrow |
| L4 | **The loop exit** | `backend.md` §8: a tail-call loop whose body begins `if (!c) return x` prints as `while (c) {…} return x` (or a `for` with the update in its head) | `emit/release/` golden of `List.compare`'s shape; `compare` within noise of the sibling on research 50's `steadyall.mjs`, quiet machine |
| L5 | **The budget** | find what `abuse_wide_test`'s *16 400 literal branches … under `--release`* spends on a beni `List` (profile first; the guess is the release passes over the runtime in every program) and fix it in the compiler | the case under 4 300 million with the prototype's `List` in core |
| L6 | **The port** | `core/List.beni` holds the runtime, the sibling only `length`, `at`, `put`, `identical`, `kept`, `half` for a value of one; `backend.md` §4 *The runtime: `core/List.js`* rewritten to name `List.beni` | gates green; goldens re-blessed with a note each (`SuspendShapes`' `d(i)`, the graph's `core:List -> core:Js`, `build_test`'s sibling file); `test-run-hashes` recorded; the claim sweep against the compiled core added to `bench/arrays/lists/` |
| L7 | **The bar** | `bench/size.mjs` both ways: no program larger, or the owner's call on the residue (research 50 §7 item 5) after `hand-minify` on `concat` and the evidence loops; research 50's speed table re-run on a quiet machine; the `bench/ui` app against Solid 1 and 2 | every row within noise or better; a reproducible loss is reported, never answered with JavaScript |
