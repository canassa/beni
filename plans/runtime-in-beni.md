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
| 3 | **Render loop, events and host**: `fire`, `delegated`, `delegate`, `start`, `listen`, `identity`; `Browser.program`/`hosted` and the hosted loop of `Browser.js` | **landed 2026-10-02**, below, with the two features `Browser.program` needed; `hosted` and its loop stay |
| 4 | **Keyed lists**: `forKeyed`, `forPosition`, `trimmed`, `reconcile`, `park`, `mountRow`, `patchRow`, `show`, `hide`, `fallback` | open |
| 5 | **Class and style helpers**: `classes`, `styles`, `classSet`, `styleMap` | open |

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
