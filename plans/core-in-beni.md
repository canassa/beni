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
| 2 | **`core/Task.js`**: the fiber runtime | to come |
| 3 | **`core/List.js`**: the array-backed list and its views | to come; needs `Js`'s list positions loosened as step 1 loosened its names (*What step 1 leaves*) |
| 4 | **The rest**: `Char.js` (**gone 2026-10-02**), `Basics.js` (**all but the operators, `append` and `eq`, 2026-10-02**), `Debug.js`, `Js.js`'s value-passing half, the browser platform's `Hosted.js`, `Browser.js`, `Dom.js`, `runtime.js`'s `safeUrl`, `html`'s `Html.js`, and the `node` platform | to come |

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
