# The browser runtime, moved to beni one piece at a time

*Started 2026-10-02.* The owner's decisions R47-1..3 (`plans/browser-decisions.md`, *The runtime in
beni*): the DOM runtime (`platforms/browser/runtime.js`) is rewritten in beni now, gradually, and
**each step lands only if, for the piece it moves, the generated JavaScript is no larger** (release
brotli: the empty page, the `bench/ui` app, and a page that uses the piece), **no slower** (`bench/ui`
per-operation script medians against the hand-written build and Solid 1, in one batch) **and
equivalent in shape** (a side-by-side listing in the step's report). A piece that cannot meet the
bar stays hand-written until the compiler feature it needs lands, and the step builds that feature
first. The mechanism is `boundary.md` §9.2's runtime module (`"markup": { …, "module": "Rt" }`) and
`backend.md` §15.1: the module's `pub` values stand in for runtime exports of their names, the file
imports the rest from `beni:Rt`, and both are compiled with the program, so `--release` specialises
the runtime to the page (§9, *Whole-program specialisation*).

## The steps

| # | Piece | State |
|---|---|---|
| 1 | **Slot and mount**: an instance's nodes (`first`, `last`, `put`, `drop`, `swap`), `template`, `slot`, `parentOf`, `unit`, `patch`, `place`, `childHtml`, the render queue, `flush`, `run` and the mount | **landed 2026-10-02**, below |
| 2 | **Templates and holes**: `childMaybe`, `childList`, `insertText`, `attr`, `attrNS`, `rawHtml`, `safeUrl`, the text and map kinds (`text`, `map`) | **landed 2026-10-02**, below; `childList` moves with step 4, `safeUrl` stays |
| 3 | **Render loop, events and host**: `fire`, `delegated`, `delegate`, `start`, `listen`, `identity`; `Browser.program`/`hosted` and the hosted loop of `Browser.js` | **landed 2026-10-02**, below, with the two features `Browser.program` needed; `hosted` and its loop with `Js.finally`, below |
| 4 | **Keyed lists**: `forKeyed`, `forPosition`, `trimmed`, `reconcile`, `park`, `mountRow`, `patchRow`, `show`, `hide`, `fallback`, and `childList` and `Elements` with them | **landed 2026-10-02**, below, with the compiler features it needed |
| 5 | **Class and style helpers**: `classes`, `styles`, `classSet`, `styleMap` | **landed 2026-10-02**, below; `safeUrl` stays |

## Step 1 — slot and mount (2026-10-02)

**What moved.** `platforms/browser/Rt.beni` (the port research 47 made in
`tests/platforms/beni-runtime`, now the real platform's; the test platform, its `-tea` twin and
`browser/split/`'s two duplicate pages are gone, and `emit/release/split/EmptyPage` is built for
`browser`). `runtime.js` lost those functions and imports them. The lowering is unchanged.

**What changed besides.** A `--library` build roots the module's `run`, `start` and `flush`, since
the page's own entry calls them (`backend.md` §15.1); `bench/ui`'s micro page and `browser_test`'s
library page read them from `_platform/_browser/Rt.mjs`. `Minify`'s test that every shipped file
scope-hoists reads the manifest's `"module"`; the oracle extractor accepts `Rt$template`.

**Sizes** (release, brotli, the whole bundle; `bench/size.mjs`'s pages plus the `bench/ui` app and
four `browser/dom/` pages; `--allow-debug` where a page logs):

| page | hand-written | beni | |
|---|--:|--:|--:|
| empty `browser` | 978 | **838** | −140 |
| empty `Tea.sandbox` | 986 | **844** | −142 |
| empty `Tea.element` | 1 724 | **1 601** | −123 |
| `Tea.element` with effects | 5 968 | **5 832** | −136 |
| `bench/ui` app | 6 139 | **6 084** | −55 |
| `dom/Keyed` | 5 322 | 5 227 | −95 |
| `dom/KeyedMoves` | 5 025 | 4 944 | −81 |
| `dom/RenderLoop` | 3 822 | 3 743 | −79 |
| `dom/ShowAndBranches` | 2 091 | 1 993 | −98 |
| `dom/Events` | 5 007 | 4 918 | −89 |
| `tea/AfterRenderFocus` | 4 390 | 4 285 | −105 |

Development builds fall 125–190 brotli bytes each (the module is written as a module of its own and
only what is reached).

**Speed.** `bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, n = 8, 1-minute load 0.9–2.8,
release builds of the same app with the compiler before and after, and Solid 1, one batch per
group; script median ms:

| | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| hand-written | 4.96 | 10.7 | 1.45 | 1.38 | 1.14 | 0.51 | 54.4 | 5.34 | 21.9 |
| beni | 4.97 | 10.7 | 1.65 | 1.23 | 1.00 | 0.50 | 53.3 | 5.32 | 22.1 |
| Solid 1 | 4.92 | 11.7 | 1.50 | 1.53 | 1.54 | 0.56 | 56.8 | 5.25 | 22.8 |

`update10th` and `select`, re-run at n = 16 (load 0.8): hand-written 1.65 / 1.20, beni 1.33 /
1.38, Solid 1 1.85 / 1.50 — each flips between the two runs, so both are noise. No operation is
slower.

**Shape.** Every function is the hand-written one; on the `bench/ui` app `template` is specialised
to the one flag value the app passes (`e=(a)=>{let b=null;return()=>{…b=d.content;b=b.firstChild}
return b.cloneNode(true)}}` against the hand-written three flag tests), and a slot on the empty page
has no list fields. `emit/release/split/EmptyPage` is the listing.

**What is still paid, and why `Browser.program` stayed.** A plain page keeps the hosted branch of
`run` and the after-render phase (`backend.md` §15.11: 26 bytes). Writing `Browser.program` in beni
would let fact 3 fold `m.h === undefined` and drop both — measured by hand on the empty page,
**838 → 816** — but it needs two things the compiler lacks:

1. **`sync` on an ordinary declaration's signature.** `program`'s signature demands that `update`
   and `view` do not suspend; only a `foreign` signature may write `sync` (`language.md` §5.4,
   `misplaced_sync`), and without it a program whose `update` suspends would build and misbehave.
   A language change, so the owner's.
2. **The entry file's `run(main)` seen as a call.** `Emit` lists `run` and `main` as escaping
   (`Spec.Input.escaping`), so `main`'s mount object escapes and its `h` never folds, even with
   `program` in beni (tried: the branch stays). The entry is the compiler's own output; the pass
   could model it as one call of `run` with `main`.

Both belong to step 3, and landed with it.

## Step 2 — templates and holes (2026-10-02)

**What moved.** `Rt.beni` now holds `childMaybe`, `insertText`, `attr`, `attrNS`, `rawHtml`, and
the two markup primitives with their kinds, `text` and `map`; `runtime.js` lost them and no longer
imports `slot` or `childHtml`. The lowering is unchanged.

**The compiler feature it needed.** A markup primitive was always the file's (`boundary.md` §9.2),
so `text` and `map` could not move. Now the runtime module supplies a primitive as it supplies any
other name, and a use of it reads the module's declaration (`Lower.primitiveName` goes through
`suppliedName`, as `markupRuntime` does; `Emit.takeSupplied` no longer skips primitives).
`boundary.md` §9.2 and `backend.md` §15.1 are amended. Red first: with the compiler as it was and
`Rt` declaring `text` and `map`, every browser build fails with `foreign_export_mismatch` ("the
markup runtime does not export `text`"). Goldens: `emit/dom/DomChildren` (`Rt$text`, `Rt$map`),
and a new `emit/release/split/HolesPage`, where `text` is called with one string and specialises to
a function of nothing (`A=()=>({t:z,v:"count"})`). New page: `browser/dom/Holes` — a `Maybe Html`
hole emptied and refilled, a `List Html` hole grown and shrunk, text holes beside other nodes,
`Html.text`, `Html.map` whose function a render replaces, a `Bool` attribute set and removed, a
namespaced one, and a `javascript:` URL written as nothing — under happy-dom and headless Chrome.
`rawHtml` has a page of its own, `browser/dom/RawHtml`, whose `innerHTML` is written in a platform
package of the project's (`innerHTML` in the root package is a warning, and a page must build
clean); no test ran it before (release: 1 344 → 1 334 brotli, `(a,b)=>{a.innerHTML=b}` against
`(T,V)=>{T.innerHTML=V}`).

**What stayed, and why.**

- **`childList`**: written in beni it was smaller alone (`dom/Holes` −19 against the hand-written
  one), but `dom/Blocks`, which also has a positional `For`, went from 3 689 to 3 732 brotli: the
  hand-written `childList` and `forPosition` share their loop text, and brotli pays for it once.
  It moves with `forPosition` in step 4. That version needed an index write (`o[k] = v`), which `Js`
  lacks; a `Js.setAt` was built and tested for it and taken out again with `childList`, so step 4
  starts by adding it.
- **`safeUrl`**: `Js` writes no regular expression literal (`new RegExp("…")` would spell every
  backslash twice), and the function has nothing a page could specialise, so moving it could only
  cost bytes.
- **`Elements`** stays with the list code that reads it.

**Sizes** (release, brotli, the whole bundle; the step 1 table's pages plus every other
`browser/` page; `--allow-debug` where a page logs). "raw =" marks a page whose JavaScript is
byte-for-byte the same length and the same text up to which one-letter names the declarations get
— the pages that reach nothing that moved; their brotli moves by the letters alone.

| page | step 1 | step 2 | |
|---|--:|--:|--:|
| empty `browser` | 838 | **834** | −4 (raw =) |
| empty `Tea.sandbox` | 844 | **843** | −1 (raw =) |
| empty `Tea.element` | 1 601 | 1 601 | 0 (raw =) |
| `Tea.element` with effects | 5 832 | **5 829** | −3 (raw =) |
| `bench/ui` app | 6 084 | **6 050** | −34 (names only: raw −30) |
| `dom/Holes` (new) | 3 366 | **3 340** | −26 |
| `dom/Blocks` | 3 720 | **3 692** | −28 |
| `dom/Events` | 4 918 | **4 868** | −50 |
| `dom/Keyed` | 5 227 | **5 179** | −48 |
| `dom/KeyedEnds` | 6 047 | **5 957** | −90 |
| `dom/KeyedInPlace` | 5 097 | **5 066** | −31 |
| `dom/KeyedMoves` | 4 944 | **4 902** | −42 |
| `dom/KeyedReplace` | 4 955 | **4 923** | −32 |
| `dom/RenderLoop` | 3 743 | **3 697** | −46 |
| `dom/RowItemOnly` | 3 939 | **3 910** | −29 |
| `dom/RowMountOrder` | 4 994 | **4 975** | −19 |
| `dom/Selector` | 4 482 | **4 473** | −9 |
| `dom/ShowAndBranches` | 1 993 | **1 971** | −22 |
| `dom/HelperSkip` | 1 987 | 1 993 | +6 (raw =) |
| `dom/NullaryHelperSkip` | 1 856 | 1 862 | +6 (raw =) |
| `tea/AfterRenderFocus` | 4 285 | 4 290 | +5 (raw =) |
| `tea/FlushLatched` | 3 667 | 3 681 | +14 (raw =) |
| `tea/Counters` | 2 047 | **2 024** | −23 |
| `tea/TypedInput` | 2 559 | **2 544** | −15 |
| `tea/LatestTagger` | 6 487 | **6 472** | −15 |
| `tea/HttpResults` | 5 671 | **5 657** | −14 |
| `tea/TwoPrograms` | 2 004 | **1 994** | −10 |
| other `tea/` pages (7) | | | −1 to −7 |

Every page that uses a moved function is smaller. The four that grew reach none of them; their
text is unchanged and the global names were handed out in a different order (`first` is `c`
where it was `l`), which is the renamer's emission order meeting a smaller import list, not code.

**Speed.** `bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, n = 8, 1-minute load
0.6–4.2, release builds of the same app with the step 1 compiler ("step 1") and this one, and
Solid 1, one batch per group of three; script median ms. The app reaches nothing that moved: its
two builds differ only in identifier names (the same text once every name is masked).

| | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| step 1 | 4.94 | 10.6 | 1.69 | 1.04 | 1.04 | 0.51 | 53.3 | 5.28 | 22.3 |
| step 2 | 5.06 | 10.7 | 1.29 | 1.26 | 0.93 | 0.51 | 52.8 | 5.32 | 22.1 |
| Solid 1 | 4.98 | 11.7 | 1.86 | 1.69 | 1.34 | 0.56 | 56.6 | 5.21 | 22.4 |

`run1k`, `select` and `append1k`, re-run at n = 16 (load 0.7–2.2): step 1 5.00 / 1.34 / 5.35,
step 2 4.99 / 1.12 / 5.35, Solid 1 4.94 / 1.54 / 5.28 — `select` flips and the others tie, so all
three were noise. No operation is slower.

**Shape**, the hand-written function against the beni one, from `dom/Holes`'s release file:

```js
// childMaybe
(s,T)=>{if(T!==null)z(s,T);else if(s.i!==null){k(s.i);s.i=null}}
(a,b)=>{if(b===null){if(a.i!==null){i(a.i);a.i=null}}else m(a,b)}
// insertText
(parent,ja,M)=>parent.insertBefore(globalThis.document.createTextNode(M),ja)
(a,b,c)=>a.insertBefore(document.createTextNode(c),b)
// attr (attrNS alike)
(P,name,M)=>{if(M===null)P.removeAttribute(name);else P.setAttribute(name,M)}
(a,b,c)=>c===null?a.removeAttribute(b):a.setAttribute(b,c)
// the text kind and `text`
{m:v=>{const U=globalThis.document.createTextNode(v);return{s:U,q:null,e:U,d:v}},p:(A,v)=>{if(v!==A.d){A.d=v;A.s.data=v}},}
{m:(a)=>{const b=document.createTextNode(a);return{d:a,e:b,q:null,s:b}},p:(c,d)=>{if(d!==c.d){c.d=d;c.s.data=d}}}
s=>({t:ea,v:s})
(a)=>({t:z,v:a})          // and on dom/Blocks, called with one string: ()=>({t:z,v:"text"})
// the map kind
{m:(v,ha)=>{const c={f:v[1],up:ha};const V=l(null,null,c);V.i=u(v[0],c);return{s:null,q:V,e:null,c}},p:(A,v)=>{A.c.f=v[1];A.q.i=w(A.q.i,v[0],A.c)},}
{m:(a,b)=>{const c={f:a[1],up:b},d=j(null,null,c);d.i=l(a[0],c);return{c:c,e:null,q:d,s:null}},p:(e,f)=>{e.c.f=f[1];e.q.i=q(e.q.i,f[0],e.c)}}
```

One difference that is not bytes: a beni record's keys are written sorted, so a text instance is
`{d,e,q,s}` where the hand-written one was `{s,q,e,d}`. Both are shapes of their own beside the
compiled kinds' `{s,q,e,…}`, so no inline cache that was monomorphic becomes polymorphic; `bench/ui`
does not reach it. `{ c }` is written `{c:c}`: the printer has no shorthand property.

## Step 3 — events, `Browser.program`, and the two features it needed (2026-10-02)

**The two compiler features first**, each specified and red first:

1. **`sync` in a platform's ordinary signatures** (R47-4; `transparent-effects-proposal.md` §15.2
   item 1, `checker-v2.md` §27, `language.md` §5.4, `boundary.md` §4, all amended). The parser reads
   `sync (…)` in every top-level annotation; lowering refuses it (`misplaced_sync`, *"Only a platform
   package may write `sync`"*) outside core and platform packages; a mark on an ordinary
   declaration is a demand in its own graph, so its summary publishes the class `sync` whatever the
   body does (`!sync` in the interface) and a body that makes the class suspend is `sync_boundary`
   at the word. One spelling changed meaning: a type variable named `sync` directly before a
   parenthesised argument in a top-level annotation (`Pair sync (Int)`); in a `let` annotation it is
   two arguments still (`parse/good/ForeignSync`). A `sync_boundary` whose callee is a platform
   package's beni function says the platform calls it, as for a `foreign`. Fixtures, red before the
   change (`sync (` was a parse error outside a `foreign`): `check/bad/SyncOutsidePlatform`,
   `check/bad/core/SyncOrdinary/` (`Main` hands `Plat.program` a suspending `view` across the module
   boundary, directly and through `Lib`; `Plat.race` makes its own marked parameter suspend),
   `check/good/core/SyncOrdinary` (the interface).
2. **The entry's `run(main)` is a call** (`backend.md` §9, *The entry's call is a call*): `Spec.Input`
   takes the entry call (`Entry`, the callee's and arguments' whole-program names) instead of listing
   `run` and `main` as escaping; fact 3 joins `main`'s objects into `run`'s parameter, facts 1–2 and
   `prune` treat both names as before. Red first: with `Browser.program` in beni and `Spec` as it was,
   `emit/release/split/EmptyPage`'s new golden (no `b.h===undefined`, no phase) failed.

**What moved.** `Browser.program` is a beni declaration of `Browser.beni` (`Js.to (Js.array [ Js.from
{ a = p, n = Js.null } ])`, the hand-written `[{a:p,n:null}]`), with `sync` on `update` and `view`;
`Rt.beni` holds the events — `fire` (with `through` and `mountAbove`, its two loops), the delegated
listener (`delegated`, `bubble`), `registered`, `delegate`, `start`, `listen` and `identity`;
`runtime.js` lost them. One change of form: `fire` takes a node's flag word as it is — the
listener's `?? 0` is gone, because `undefined & k` is `0`.

**What stayed, and why.**

- **`Browser.hosted` and its loop** (`Host`, the after-render phase, `flush`, `onRendered`): each of its
  three guards — a message's `update`, a render, the after-render phase — is a `try … finally`, so
  that an exception thrown there (a stack overflow, a host error, `Debug.todo` in a development
  build) leaves the loop able to run the next message. Beni writes no `try`: without it the port
  would leave `Dispatching` or `Busy` set after such a throw and the page would stop handling
  messages, which is a behaviour change. The feature it needs is a `Js.finally` intrinsic and a
  `try` statement in `JsIr`, which every IR walk (`Opt`, `Spec`, `Print`, `Rename`, `Suspend`) would
  learn; a sibling-function version (`finally(f, g)`) needs no compiler change but allocates two
  closures per message. Neither was built: the loop is on no page `bench/ui` times (the app is a
  `Tea.sandbox`, which is `Browser.program`), and nothing of it is specialisable beyond what
  `Minify`'s export cut does already — a page reaches `onRendered` or not, and that is an export.
- **`mountAt` and `programs`** were not in the step's list; both hand a description to `.map` or a
  loop over a `List`, where fact 3 would see it escape anyway.

**Sizes** (release, brotli, the whole bundle; the step 2 table's pages plus the rest of `browser/`;
`--allow-debug` where a page logs). "names only" marks a page whose JavaScript is the same text
once every identifier is masked.

| page | step 2 | step 3 | |
|---|--:|--:|--:|
| empty `browser` | 834 | **802** | −32 (`program` and the entry call alone: 796; the events' move then +6, names only) |
| empty `Tea.sandbox` | 843 | **809** | −34 |
| empty `Tea.element` | 1 601 | **1 599** | −2 (names only) |
| `Tea.element` with effects | 5 829 | 5 839 | +10 (names only) |
| `bench/ui` app | 6 050 | **5 998** | −52 |
| `dom/Events` | 4 868 | **4 806** | −62 |
| `dom/Keyed` | 5 179 | **5 100** | −79 |
| `dom/KeyedMoves` | 4 902 | **4 811** | −91 |
| `dom/KeyedReplace` | 4 923 | **4 838** | −85 |
| `dom/KeyedInPlace` | 5 066 | **4 993** | −73 |
| `dom/RowMountOrder` | 4 975 | **4 905** | −70 |
| `dom/Selector` | 4 473 | **4 407** | −66 |
| `dom/Blocks` | 3 692 | **3 628** | −64 |
| `dom/NullaryHelperSkip` | 1 862 | **1 799** | −63 |
| `dom/RowItemOnly` | 3 910 | **3 849** | −61 |
| `dom/HelperSkip` | 1 993 | **1 935** | −58 |
| `dom/Holes` | 3 340 | **3 291** | −49 |
| `dom/RenderLoop` | 3 697 | **3 649** | −48 |
| `dom/RawHtml` | 1 334 | **1 287** | −47 |
| `dom/ShowAndBranches` | 1 971 | **1 936** | −35 |
| `dom/KeyedEnds` | 5 957 | **5 936** | −21 |
| `tea/Counters` | 2 024 | **1 963** | −61 |
| `tea/LatestTagger` | 6 472 | **6 427** | −45 |
| `tea/TypedInput` | 2 544 | **2 505** | −39 |
| `tea/TwoPrograms` | 1 994 | **1 971** | −23 |
| other `tea/` pages (11) | | | −9 to −27 |

Every page that reaches a moved piece is smaller. The two that grew reach none of them (a hosted
program with no handler): their text is unchanged and only the global names were handed out in
another order, as in step 2.

**Speed.** `bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, n = 8, release builds of the
same app with the step 2 compiler ("step 2") and this one, and Solid 1, one batch per group (each
under 5 minutes); 1-minute load 17.5 / 10.4 / 6.7 at the first three operations (another build was
running), 0.6–4.5 for the rest; script median ms:

| | run1k | replace1k | update10th | select | swap | remove | create10k | append1k | clear |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| step 2 | 5.63 | 10.7 | 1.29 | 1.40 | 0.98 | 0.51 | 53.0 | 5.31 | 22.3 |
| step 3 | 5.78 | 10.7 | 1.64 | 1.23 | 1.20 | 0.51 | 54.2 | 5.30 | 22.0 |
| Solid 1 | 5.46 | 11.9 | 1.67 | 1.54 | 1.86 | 0.55 | 57.3 | 5.29 | 23.3 |

Re-run, load 0.5–1.3: `run1k`, `update10th`, `swap` at n = 16 — step 2 4.96 / 1.68 / 1.04, step 3
4.93 / 1.43 / 1.11, Solid 1 4.96 / 1.73 / 1.46; `create10k` and `swap` at n = 12 — step 2 53.5 / 1.00,
step 3 53.7 / 1.21; `swap` and `select` at n = 24 (load 10–16) — step 2 1.08 / 1.25, step 3 1.06 /
1.42. `update10th`, `select` and `swap` flip between runs and every interquartile range overlaps;
`run1k` and `create10k` tie. No operation is slower.

**Shape**, the hand-written function against the beni one, from `dom/Events`'s release file:

```js
// fire (its two loops, through the `Html.map` contexts and up to the mount node, are functions of their own)
(z,event,A,C)=>{if(C&1)event.preventDefault();let F=z[`${A}X`];let E=F===undefined?z[A]:z[A](F(event));for(let D=z.$$cx;D!=null;D=D.up)E=D.f(E);let B=z.parentNode;while(B!==null&&B.$$root===undefined)B=B.parentNode;if(B!==null)B.$$root(E);if(C&2)event.stopPropagation()}
(a,b,c,d)=>{if((d&1)!==0)b.preventDefault();const e=a[`${c}X`],f=w(a.$$cx,e===undefined?a[c]:a[c](e(b))),g=x(a.parentNode);if(g!==null)g.$$root(f);if(d&2)b.stopPropagation()}
w=(a,b)=>{for(;;){if(a==null)return b;const c=a.up;b=a.f(b);a=c}}
x=(a)=>{for(;;){if(a===null||a.$$root!==undefined)return a;a=a.parentNode}}
// the delegated listener
event=>{const x=`$$${event.type}`;for(let y=event.target;y!==null;y=y.parentNode){if(y[x]!==undefined&&!y.disabled){const R=y[`${x}F`]??0;ga(y,event,x,R);if(R&2)return}}}
(a)=>{const b=a.type,c=`$$${b}`;let d=a.target;while(d!==null)if(d[c]!==undefined&&!d.disabled){const e=d[`${c}F`];y(d,a,c,e);if(e&2)return;d=d.parentNode}else d=d.parentNode}
// delegate, start
Ma=>{for(const name of Ma){if(ia.has(name))continue;ia.add(name);globalThis.document.addEventListener(name,ha)}}
(a)=>{for(const b of a)if(!A.has(b)){A.add(b);document.addEventListener(b,z)}}
Ha=>{if(Ha.delegate!==undefined)ja(Ha.delegate)}
(a)=>{if(a.delegate!==undefined)B(a.delegate)}
// listen, which this page calls with flags 0 only
(xa,name,R)=>{const x=`$$${name}`;xa.addEventListener(name,event=>{if(xa[x]!==undefined)ga(xa,event,x,R)})}
(a,b)=>{const c=`$$${b}`;a.addEventListener(b,(d)=>{if(a[c]!==undefined)y(a,d,c,0)})}
// Browser.program
b=>[{a:b,n:null}]
(a)=>[{a:a,n:null}]
```

And what the entry call removes from every `Browser.program` page (`emit/release/split/EmptyPage`):
`if(b.h===undefined)n(b.a,d);else n(b.h(d,m,(f)=>{k=f;return j}),d)` is `m(b.a,d)`, the `let k=null`
phase is gone, and `flush` ends at its render loop (`…for(const b of a)b()` where it was `…b();k?.()`).

Two bytes a later pass could take: `(d&1)!==0` in `fire`'s first test is not the flag peephole's
`d&1` (the development build writes the same `if`, so `Spec.peephole` declines it for a reason not
yet looked into — its test for a comparison referenced once is the likely one), and `b.n===null` in `run` reads a key every description writes as
`null` — a "constant property" fact beside fact 3 would fold it, and the mount's error message with
it.

## Step 4 — keyed and positional lists (2026-10-02)

**What moved.** `Rt.beni` now holds the whole of `backend.md` §15.5's runtime: `forKeyed` (its full
pass, the key map with its rank chains, the selector's two probes), `trimmed` (the ends first, the
crossed pairs, the key lookups that hand over on a duplicate key, the replacement that empties the
parent), `reconcile` (udomdiff over instances, `park`), `forPosition`, `childList`, `show`,
`hide`, `mountRow`, `patchRow`, `sameInputs`/`sameInputsBut`, `reselect`, and `elements` (the
list protocol's reader, `pub` for `runtime.js`'s class and style lists, which stay for step 5).
`fallback` is `childMaybe s (if empty then f else null)`, which is what it was. `runtime.js` is the
class and style diffs and `safeUrl`. Every loop is a tail-recursive function called once; the
mutable locals the JavaScript reassigns are its variables; `keyAt` and `hit` are the closures they
were, passed to the loops as `sync` parameters (a call of an unknown function would otherwise make
the loop one that may suspend, which is never written in place).

**The compiler features it needed** (`backend.md` §9, three amendments of 2026-10-02):

1. **A loop whose value is bound or discarded is written in place** (*A function called once is
   written where it is called*): `x = loop …`, `( a, b ) = loop …` (each exit's tuple written into
   the names, no tuple built), `_ = loop …`. Exits `break`; a name every exit gives from one
   variable the loop reassigns becomes that variable. Without it every inner loop of `reconcile`
   and `trimmed` was a call, and `trimmed`'s crossed-pair loop returned an object. Red first:
   `emit/release/core/BoundLoops` against the compiler before keeps each call and the tuple
   `{a:b,b:c}`. With it, three `Lower` rules that drop a copy the hand-written code never makes: a
   bound `case` writes its binding, a leaf `case` and a leaf `let … in x` write the tree's
   temporary, a binding of an unreassigned name is that name.
2. **`Js.setAt`**, `o[k] = v` (`core/Js.beni`), which step 2 built and took out again.
3. **Short names reused across scopes** (*Item 2*, amended): the flat per-declaration alphabet
   gave `trimmed`'s fiftieth local a two-letter name and every loop body names of its own; the
   keyed code written in beni was 469 raw bytes *smaller* than the hand-written and still 31
   brotli bytes larger on `bench/ui`, and this was most of the difference. It is a renamer change,
   so every page moved: 7–118 brotli bytes smaller on every `browser/` page.
4. **The loops print as a hand minifier writes them** (*Compact statements*, amended):
   `while(c){…}` for an exit `break`, `for(let i=a;c;i++)` when the variable is declared just
   before and updated last, `i++`, `a!=b`.

**Sizes** (release, brotli, the whole bundle; master at `a9ee5efb` against this step, built from
the same pages; `--allow-debug` where a page logs). Every page is smaller:

| page | master | step 4 | |
|---|--:|--:|--:|
| empty `browser` | 615 | **605** | −10 |
| empty `Tea.sandbox` | 615 | **605** | −10 |
| empty `Tea.element` | 1 501 | **1 475** | −26 |
| `Tea.element` with effects | 5 651 | **5 590** | −61 |
| `bench/ui` app | 5 868 | **5 850** | −18 |
| `dom/Keyed` | 5 011 | **5 004** | −7 |
| `dom/KeyedEnds` | 5 850 | **5 771** | −79 |
| `dom/KeyedInPlace` | 4 913 | **4 879** | −34 |
| `dom/KeyedMoves` | 4 712 | **4 706** | −6 |
| `dom/KeyedReplace` | 4 728 | **4 711** | −17 |
| `dom/Selector` | 4 312 | **4 241** | −71 |
| `dom/RowItemOnly` | 3 783 | **3 770** | −13 |
| `dom/RowMountOrder` | 4 787 | **4 706** | −81 |
| `dom/ForAtEnds` | 4 307 | **4 281** | −26 |
| `dom/Blocks` | 3 521 | **3 440** | −81 |
| `dom/Holes` | 3 174 | **3 114** | −60 |
| `dom/Events` | 4 692 | **4 670** | −22 |
| `dom/RenderLoop` | 3 566 | **3 540** | −26 |
| `dom/HelperSkip`, `NullaryHelperSkip`, `ShowAndBranches` | | | −51, −31, −27 |
| `tea/` pages (15) | | | −14 to −118 |

The list code alone, on `bench/ui` (the region from `elements` to the end of `forKeyed`): 5 078 raw
and 1 929 brotli hand-written, 4 552 and 1 929 in beni. The order of the work mattered: with the
bound loops and the printing alone the keyed pages were 150–220 bytes *larger*; the renamer took
them to −24…+45, and the `for` head and a loop's variable kept off its surrounding scope's
spellings to the table above.

**Speed.** `bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, release builds of the same app
by master ("before") and this step, and Solid 1, three batches of three operations (each under 5
minutes), n = 12; script median ms [IQR]:

| | before | step 4 | Solid 1 | load |
|---|--:|--:|--:|--:|
| run1k | 4.75 [4.71–4.81] | 4.77 [4.73–4.79] | 4.94 | 0.5–0.8 |
| replace1k | 10.39 [10.33–10.58] | 10.36 [10.31–10.40] | 11.79 | 0.4–0.9 |
| update10th | 1.50 [1.35–1.60] | 1.48 [1.15–1.52] | 1.48 | 0.9 |
| select | 1.22 [1.05–1.30] | 1.24 [1.04–1.40] | 1.59 | 0.7–0.9 |
| swap | 0.98 [0.82–1.02] | 0.86 [0.79–1.02] | 1.54 | 0.9 |
| remove | 0.50 [0.50–0.51] | 0.50 [0.48–0.50] | 0.56 | 0.8–0.9 |
| create10k | 52.67 [52.14–53.07] | 52.21 [51.64–52.57] | 56.13 | 0.4–0.8 |
| append1k | 5.39 [5.38–5.43] | 5.45 [5.42–5.50] | 5.25 | 0.5–0.6 |
| clear | 22.01 [21.03–22.17] | 22.00 [21.69–22.28] | 22.79 | 0.5–0.8 |

Re-run: `append1k`, `select`, `run1k` at n = 16 (load 0.4–0.8) — before 5.36 / 1.26 / 4.80, step 4
5.43 / 1.15 / 4.75, Solid 1 5.23 / 1.63 / 4.94; `append1k` again at n = 30 (load 0.6–1.3) — before
5.43 [5.38–5.51], step 4 5.45 [5.40–5.49], Solid 1 5.27. Every range overlaps; `append1k` ties at
n = 30 and `select` flips. No operation is slower. Against Solid 1, as before: ahead on all but
append, which both builds trail by ~3 %.

**Shape**, the hand-written loop against the beni one, from `bench/ui`'s release file:

```js
// trimmed: the start
for(;s<h.length&&s<K;s++){let a=i[s];const r=h[s];if(a.x!==r){if(a.k!==(E===null?r:E(r)))break}else if(F&&a.k!==G&&a.k!==H){a.kv=y;continue}const t=Aa(n,a,r,s,c.cx);if(t!==a){i[s]=t;c.x.set(t.k,t);t.y=s;a=t}a.x=r;a.kv=y}
while(p<o.length&&p<m){let c=l[p],q=o[p],r=c.x===q;if(!r&&c.k!==(f===null?q:f(q)))break;if(r&&h&&c.k!==i&&c.k!==k){c.kv=n;p++}else{let s=w(g,c,q,p,a.cx);if(s!==c){l[p]=s;a.x.set(s.k,s);s.y=p}s.x=q;s.kv=n;p++}}
// trimmed: the end, and the crossed pairs with their two inner loops
while(q<v&&p<o){const a=i[v-1];if(a.x!==I[o-1-s]&&a.k!==S(o-1))break;a.kv=y;w[--o]=a;v--}…while(v-q>1&&o-p>1&&$(i[q],o-1)&&$(i[v-1],p)){_=true;const a=i[q++];const fa=i[--v];a.kv=y;fa.kv=y;w[--o]=a;w[p++]=fa;while(q<v&&p<o){const x=i[q];if(x.x!==I[p-s]&&x.k!==S(p))break;x.kv=y;w[p++]=x;q++}while(q<v&&p<o&&$(i[v-1],o-1)){const x=i[--v];x.kv=y;w[--o]=x}}
while(p<z&&p<A){let a=l[z-1];if(a.x!==q[A-1-p]&&a.k!==t(A-1))break;a.kv=n;y[A-1]=a;z--;A--}let F=p,G=z,H=A;while(G-F>1&&H-F>1&&x(l[F],H-1)&&x(l[G-1],F)){let a=l[F],c=l[G-1];a.kv=n;c.kv=n;y[H-1]=a;y[F]=c;let f=F+1,g=G-1,h=H-1;while(f<g&&f<h){let a=l[f];if(!x(a,f))break;a.kv=n;y[f]=a;f++}let i=G-1,k=H-1;while(f<i&&f<k&&x(l[i-1],k-1)){let a=l[i-1];a.kv=n;y[k-1]=a;i--;k--}F=f;G=i;H=k}
// reconcile: the end trim, a run put before a node, the index map
while(v>q&&o>p&&h[v-1]===g[o-1]){v--;o--} … while(p<o)e(parent,g[p++],O) … for(let a=p;a<o;a++)J.set(g[a],a)
let o=k,p=m;while(o>j&&p>l&&c[o-1]===g[p-1]){o--;p--} … for(let r=l;r<p;r++)e(a,g[r],q) … for(let v=l;v<p;v++)s.set(g[v],v)
// sameInputs
for(let x=0;x<h.length;x++)if(h[x]!==g[x])return false;return true
let c=0;while(c<a.length&&a[c]===b[c])c++;return c===a.length
```

Every loop is a JavaScript loop in its function, with no call and no allocation the hand-written
one does not make; the loop variables are `let`s, the crossed pairs' three results are three
variables, and every early exit is a `break` or a `return`. Three differences that are not bytes:
the crossed-pair loop's `crossed` flag is `aStart !== p` (it moved iff the start did); the two
starts move together, so one variable is both, where the JavaScript kept `q` and `p` equal by hand;
and `patchRows` re-reads `next[b]` for the row it shows instead of a variable each branch assigns.

**What stayed, and why.** The class and style lists (`classes`, `styles`, `classSet`, `styleMap`)
are step 5's; `safeUrl`, for step 2's reason. The `For`'s `Js.each` over the rows to insert is a
`for…of`, as in the JavaScript.

## Step 3, finished — the hosted loop (2026-10-02)

**The compiler feature first.** `Js.finally : sync (() -> a), sync (() -> ()) -> a`, the statement
`try { … } finally { … }` (`boundary.md` §4.2; `backend.md` §4, *`Js.finally` is `try …
finally`*): JsIr's `try_stmt`, walked by every pass — `Opt` folds nothing across it, `Spec` walks
both blocks (fact 3's guards die at it, `inlineOnce` copies it and writes a call found in either
block into that block), `Rename` scopes each block, `Print` braces both, `Suspend` refuses a
marker inside one. Called with lambdas, each lambda's body is its block and no closure is made;
discarded it is the bare statement, in tail position the body's `return`s are inside the guard,
anywhere else a `let` the body assigns. A body or cleanup that may suspend is `sync_boundary` at
the argument: a fiber that parked inside the guard would run the cleanup at the park and the rest
outside it. Red first: `emit/release/core/JsFinally`, `run/JsFinally` (cleanup on return and on
`Js.throw`, bound, discarded, in tail position, nested, at the end of a loop, with arguments that
are not lambdas — made first, in order — as a value, and written by `inlineOnce` into another
module), `check/bad/core/FinallySuspends`; with the core before, `Js does not expose finally`.

**What moved.** `Browser.hosted`, its mount record (`Host`), the after-render phase, the inbox and
`flush`'s latches, `Browser.flush` and `Browser.onRendered` are declarations of `Browser.beni`,
each of the three guards a `Js.finally`; `Browser.js` keeps `mountAt` and `programs`. The protocol
with `Rt` is the same (`{ h, n }`, `h(root, flush, setPhase)`), and so is the behaviour: every
`browser/tea/` page passes unchanged in both builds, and a new one, `tea/ThrowRecovers`, throws
from `update`, from a render and from after-render work and shows the next message applied and
`Browser.flush` rendering at once after each. Its transcript is the hand-written loop's
byte for byte (built by the compiler before, under happy-dom, both builds); with the three guards
written as plain calls instead, it fails at its second step (the dispatch latch stays set and
`inc` is never applied). It needed one driver feature: a `throws <step>` line records each
uncaught exception as `(threw: …)` instead of ending the run (`tests/corpus/README.md`).

Two compiler rules came with it, both for the shape: a `Js.finally` whose body is a lambda is
unit-valued when that body is (`Lower.unitValued`), and the end of a function whose result nothing
reads is followed into a `try`'s guarded block (never its cleanup), so the phase's
`try{…;return}finally{…}` is `try{…}finally{…}`. In the beni, the inbox's push is a `let _ =`
(the hand-written `update` returned `null` there too), the drain loop is bound, so it prints as the
hand-written `for`, and `send` is unit-valued.

**Sizes** (release, brotli, the whole bundle; the compiler before this step against this one, the
same pages; `--allow-debug` where a page logs):

| page | before | after | |
|---|--:|--:|--:|
| empty `browser` | 605 | 605 | 0 (identical) |
| empty `Tea.sandbox` | 605 | 605 | 0 (identical) |
| empty `Tea.element` | 1 475 | **1 261** | −214 |
| `Tea.element` with effects | 5 590 | **5 412** | −178 |
| `bench/ui` app | 5 850 | 5 850 | 0 (identical) |
| `tea/ReentrantSend` | 3 769 | **3 573** | −196 |
| `tea/FlushLatched` | 3 528 | **3 338** | −190 |
| `tea/OwnedByProgram` | 5 571 | **5 387** | −184 |
| `tea/Policies` | 6 257 | **6 080** | −177 |
| `tea/ThrowRecovers` (new) | 3 898 | **3 726** | −172 |
| `tea/WindowEvents` | 5 627 | **5 459** | −168 |
| `tea/ClockStops` | 5 093 | **4 929** | −164 |
| `tea/TupleKeyRestart` | 5 113 | **4 954** | −159 |
| `tea/HttpResults` | 5 457 | **5 331** | −126 |
| `tea/AfterRenderFocus` (`Dom.rendered`) | 4 164 | **4 052** | −112 |
| `tea/LatestTagger` | 6 217 | **6 110** | −107 |
| `tea/DebouncedSearch` | 5 989 | **5 912** | −77 |
| `tea/TwoPrograms` | 1 862 | 1 865 | +3 (names only) |
| `tea/Counters`, `tea/TypedInput`, every `dom/` page | | | 0 |

Every page that reaches the loop is smaller. `TwoPrograms` (two `Tea.sandbox`es) reaches none of
it; its text is the same once every identifier is masked.

**Speed.** The `bench/ui` app is a `Tea.sandbox` and its release file is byte-identical before
and after, so its medians cannot move. A `Tea.element` counter page (release, happy-dom in Node
24, pinned to one core, 1-minute load 2.7–3.1; 41 rounds each, three interleaved runs per build),
median [IQR] of one round:

| | before | after |
|---|--:|--:|
| `send` alone (20 000 per task, one render after) | 33.7 [31.4–37.2], 32.3 [31.1–37.5], 36.8 [31.4–41.1] ns | 36.1 [31.3–37.3], 36.8 [31.5–41.6], 36.4 [31.2–38.1] ns |
| `send` and its render (2 000, one per task) | 772 [643–1135], 771 [637–1132], 769 [638–973] ns | 782 [654–990], 753 [621–987], 764 [631–1037] ns |

Every range overlaps and the medians flip between runs: no slowdown.

**Shape**, from `tea/AfterRenderFocus`'s release file (the hand-written loop as `Minify` left it,
then the beni):

```js
// hosted, Host, the phase
w=b=>[{n:null,h:(g,mb,i)=>lb(b,g,mb,i)}]
M=(a)=>[{h:(b,c,d)=>{C=c;D=d;d(H);…}}]   // `Host` is written into `hosted`'s mount
const kb=()=>{const t=gb;const u=fb;gb=[];fb=[];hb=true;try{for(const f of t)f(null);for(const l of u)l()}finally{hb=false}}
H=()=>{let a=E,b=F;E=[];F=[];G=true;try{for(let b of a)b(null);for(let a of b)a()}finally{G=false}}
// the host and its record
const q=()=>g.$$root(eb);db=q;…const j={send:d=>g.$$root(d),after:l=>{fb.push(l);q()},};const s=d=>{o=true;c=b.update(j,d,c)}
let e=(a)=>{b.$$root(a)};I=()=>e(J);…j={after:(a)=>{F.push(a);return e(J)},send:e},k=(b)=>{h=true;f=a.update(j,b,f)}
// update: the dispatcher
update:d=>{if(d===eb)return null;if(ib){jb.push(s,d);return null}ib=true;try{s(d);for(let e=0;e<jb.length;e+=2)jb[e](jb[e+1])}finally{jb=[];ib=false}return null}
update:(a)=>{if(a!==J)if(K)L.push(k,a);else{K=true;try{k(a);for(let b=0;b<L.length;b+=2)L[b](L[b+1])}finally{L=[];K=false}}}
// view
view:()=>{if(!r){r=true;c=b.settle(j,b.init(j));return(p=b.view(c))}if(!o)return p;o=false;hb=true;try{c=b.settle(j,c);return(p=b.view(c))}finally{hb=false}}
view:()=>{if(!g){g=true;f=a.settle(j,a.init(j));i=a.view(f);return i}if(!h)return i;h=false;G=true;try{f=a.settle(j,f);i=a.view(f);return i}finally{G=false}}
// onRendered
D=f=>{if(bb===null||(!cb(kb)&&fb.length===0)){f(null);return null}gb.push(f);db();return()=>{const e=gb.indexOf(f);if(e>=0)gb.splice(e,1);return null}}
N=(a)=>{if(C===null||!D(H)&&F.length===0){a(null);return null}E.push(a);I();return()=>{let b=E.indexOf(a);return b>=0?E.splice(b,1):null}}
```

The same statements, the same latches and the same order; the mount's unread `init:null` key is
gone (fact 3), `hosted` is written into `main`, and a page that never calls `Browser.flush` (this
one) ships no `flush`. Three differences that are not bytes: `skip` is `[]` where `Skip` was `{}`
(only its identity is read); `after` returns what `send` returns, and the waiter's canceller what
`splice` returns, both of which their callers discard; and `view` assigns `shown` and returns it
where the hand-written wrote `return(p=…)`, since beni writes no assignment expression.

**What is left of the hand-written browser runtime**: `mountAt` and `programs` (`Browser.js`),
`Hosted.js`'s keys, outlets, after-render work, taps and relays, and `runtime.js`'s class and
style lists (step 5) and `safeUrl`.

## Step 5 — class and style lists (2026-10-02)

**What moved.** `Rt.beni` now holds `classes`, `styles`, `classSet` and `styleMap`, the runtime's
diff of a class or style list that is not written in place (`backend.md` §15.3); `elements` is no
longer `pub`. `runtime.js` is `safeUrl` alone and imports nothing. The lowering is unchanged.

**What it needed besides.** No compiler feature. Two printer details the port made visible, each
a rule for every file: `RegExp` is one of the host globals a release build writes bare
(`Rename.bare_globals`; it was `new globalThis.RegExp(…)`), and a string literal writes a form
feed, backspace and vertical tab as `\f`, `\b`, `\v` instead of `\u000c` (`Print.quoted`, its unit
test). The class splitter is `new RegExp("[\t\n\f\r ]+")`, a top-level value made once, against
the hand-written literal `/[\t\n\f\r ]+/`: `Js` writes no regular expression literal.

**The page.** No `browser/` page reached the two functions: every class or style list on them is
written in place (a toggle or a `setProperty` per entry) or is a `String`, and so is `bench/ui`'s
row class. New: `browser/dom/ClassStyle` — a class list and a style list from the model, and the
same two as a pattern's `rest` (a view, read by the list protocol): a name holding whitespace
(tab and newline too) is several, a `False` entry and an empty name name nothing, a class both
lists name stays while one only the previous named goes, a property takes its last value, an
empty value removes it, and one only the previous list set is removed. It passes under
happy-dom and headless Chrome with the hand-written functions and with these.

**Sizes** (release, brotli, the whole bundle; master at `4c02d096` against this step):

| page | master | step 5 | |
|---|--:|--:|--:|
| `dom/ClassStyle` (new) | 2 471 | **2 454** | −17 (raw −113) |
| empty `browser`, `Tea.sandbox`, `Tea.element`, `bench/ui` app | | | byte-identical |
| `dom/Blocks`, `dom/Holes` | | | +2, +1 (raw =) |
| every other `browser/` page | | | names only, 0 |

`dom/Blocks` and `dom/Holes` reach `safeUrl` and nothing that moved: with no import left,
`runtime.js`'s two statements are written before the beni module instead of after it, the same
text in another place.

**Speed.** The `bench/ui` app's release file is byte-identical to master's, so its timings
cannot move. The two functions alone, hand-written against beni as the release files write them,
in Node 24 on mock elements (2 000 elements, a mount and 20 alternating patches of both lists
each; 41 runs, `taskset 8-15`, load 0.5): 33.18 ms [33.10–33.36] against 33.12 [32.96–33.34], a
tie.

**Shape**, from `dom/ClassStyle`'s release file:

```js
// classSet, classes
J=c=>{let h=new Set();let d=n(c);for(let a=0;a<d.length;a++){if(!d[a].b)continue;for(let name of d[a].a.split(/[\t\n\f\r ]+/))if(name!=="")h.add(name)}return h}
p=(a)=>{let b=new Set();for(let c of n(a))if(c.b){for(let a of c.a.split(o))if(a!=="")b.add(a)}return b}
z=(g,c,e)=>{let f=J(c);let b=e===null?null:J(e);if(b!==null)for(let name of b)if(!f.has(name))g.classList.remove(name);for(let name of f)if(b===null||!b.has(name))g.classList.add(name)}
q=(a,b,c)=>{let d=p(b),e=c===null?null:p(c);if(e!==null){for(let b of e)if(!d.has(b))a.classList.remove(b)}for(let b of d)if(e===null||!e.has(b))a.classList.add(b)}
// styleMap, styles
K=c=>{let i=new Map();let d=n(c);for(let a=0;a<d.length;a++)i.set(d[a].a,d[a].b);return i}
r=(a)=>{let b=new Map();for(let c of n(a))b.set(c.a,c.b);return b}
A=(g,c,e)=>{let f=K(c);let b=e===null?null:K(e);let j=g.style;if(b!==null)for(let name of b.keys())if(!f.has(name))j.removeProperty(name);for(let[name,value]of f)if(b===null||b.get(name)!==value)j.setProperty(name,value)}
s=(a,b,c)=>{let d=r(b),e=c===null?null:r(c),f=a.style;if(e!==null){for(let a of e.keys())if(!d.has(a))f.removeProperty(a)}for(let a of d)if(e===null||e.get(a[0])!==a[1])f.setProperty(a[0],a[1])}
```

The loops over the list are `for…of` where the JavaScript counted (`Js.each`), and a `Map`'s
entries are read as `a[0]`/`a[1]` where the JavaScript destructured them; `if(e!==null){…}` keeps
braces the hand-written code drops.

**What stayed.** `safeUrl`, for step 2's reason: its pattern written as a `RegExp` string would
spell each of its 28 backslashes twice. A `Js` intrinsic for a regular expression literal would
move it and leave `runtime.js` empty.

## Append against Solid 1 (2026-10-02)

Steps 1–4 left `append1k` the one table operation where beni trailed Solid 1, by about 3 % in both
the hand-written and the beni builds (step 4: 5.45 against 5.25 ms). **The runtime was not the
gap.** Split at the click (`bench/ui/halves.mjs`, n = 30): beni's listener half — the app's
`update`, building 1 000 rows and appending them — 0.74 ms, its render 4.55; Solid 1 does both in
the click, 5.12, of which its `buildData` is 0.29 (a timing stamp in a copy of its bundle). So
beni's render of the 1 000 new rows and the check of the 1 000 kept ones is *faster* than Solid's,
and its update slower: the rows took 0.61 ms to build (a stamp in a copy of the release file),
`model.rows ++ rows` 0.05.

**Why the build was slow, cold.** Hot, the same build is 0.18 ms (the V8 sampling profile of 300
appends in one page). On the benchmark's one append after its warm-up, V8's log (`--trace-deopt`)
shows the optimised `buildFrom` loop thrown away at its first iteration — *"not a Smi"* — and the
1 000 rows built in the baseline tier: the app's Park–Miller generator has modulus 2^31 − 1, so a
seed is past 2^30 about half the time, a heap number where the runs before had specialised the
loop to small integers. In the baseline tier every allocation costs: `pick` made a view
(`List.drop`) and a `Just` (`List.head`) per word, 6 000 per append. Solid's generator is
`Math.random` over arrays.

**What changed** — the app, not the compiler, runtime or core: the generator's modulus is the
largest prime below 2^30 (every seed a small integer; no deoptimisation in the click, by the same
log), and a word is read with `List.get`, which core has had since lists became arrays, instead
of `List.drop` then `List.head`. Each alone, on `append1k`'s script (n = 24–30): the modulus 5.41 →
5.33 ms, `List.get` without it −0.07 in the listener half only; together 5.01. The release bundle
is 5 850 → 5 723 brotli bytes (`List.drop`'s view is no longer reached).

**The table** (`bench/ui`, Chromium 153, Ryzen 9 5950X, `--taskset=8-15`, n = 16, load 0.6–1.3,
release builds of the app before and after with this compiler, and Solid 1; script median ms
[IQR]):

| | before | after | Solid 1 |
|---|--:|--:|--:|
| run1k | 4.84 [4.78–4.91] | **4.63** [4.58–4.68] | 4.94 |
| replace1k | 10.4 [10.3–10.4] | **10.2** [10.2–10.2] | 11.8 |
| update10th | 1.46 [1.38–1.90] | 1.50 [1.33–1.71] | 1.65 |
| select | 1.28 [1.06–1.46] | 1.06 [0.84–1.31] | 1.69 |
| swap | 1.08 [0.90–1.21] | 1.08 [1.01–1.35] | 1.56 |
| remove | 0.50 [0.49–0.50] | 0.51 [0.49–0.52] | 0.57 |
| create10k | 51.9 [51.4–52.5] | **50.0** [49.5–50.4] | 55.8 |
| append1k | 5.42 [5.40–5.44] | **5.00** [4.98–5.03] | 5.27 [5.22–5.32] |
| clear | 22.2 [22.0–22.4] | 22.3 [21.9–22.7] | 23.2 |

`append1k` again at n = 24: before 5.39, after 5.01, Solid 1 5.23, every range apart. Halves (n =
20): the listener half 0.71 → 0.40 ms, the render unchanged (4.54, 4.47). beni is now ahead of
Solid 1 on all nine operations' medians; `run1k`, `replace1k` and `create10k`, which build rows
too, moved with `append1k`.

**What stayed.** The view and the `Just` are still made by any page that reads a list as
`List.drop` then `List.head`, or `List.get` then `Maybe.withDefault`: in a loop V8 has optimised
they cost nothing (escape analysis), in one it has not they are most of the loop (removing both,
by hand in a copy of the release file, took the cold build from 0.61 to 0.40 ms while the
deoptimisation still happened). Writing them away is a whole-program optimiser's job — inlining a
small function at several call sites, then a tag test on a known constructor folded — which
`Spec` does not do yet. Nothing in `core/List.js`'s `append` or in `forKeyed`'s append path was
the gap, and neither changed.
