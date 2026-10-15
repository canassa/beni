# 102 — Where beni's output bytes go, and what would shrink them

*2026-10-15. Research only. Beni master `d10749f70a2060230c99cd196d70c15c2666eb9b`;
Node 24.19.0, Terser 5.51.2, esbuild 0.28.2; x86-64 Linux, pinned to cores
8–23; azathoth was not used. Read after [97](97-conduit-dispatch-profiles.md),
[99](99-direct-bytes.md) and [101](101-conduit-byte-floor.md). 100 is reserved
for S8 and 101 is taken; master and the three open PRs were checked before
choosing 102. Measurements and scripts: [`bench/output-size/`](../../../bench/output-size/README.md).*

## 0. Answer

**The gap to Solid is real code, not minification.** Terser (compress +
mangle, module mode, `passes: 2`) takes **1,298 B (4.1%)** off tea and
**2,947 B (7.7%)** off direct. Against the adjusted single-chunk Solid
RealWorld (13,085 B), that is 7% of tea's 18,660 B gap and 12% of direct's
25,158 B. Terser's output runs Conduit's three corpus scripts identically.
Most of direct's Terser win is one transform beni lacks: inlining a
top-level binding read once. Direct's template protocol makes 511 of those.

Master's bundles are tea **31,745 B** and direct **38,243 B** brotli (101
measured 31,389 and 37,970 on an older master). By origin, in the ordered
account (§2):

| | tea | direct |
|---|---:|---:|
| core (Task, List, Dict, Schema, Url, Basics…) | 8,024 | 8,062 |
| platform runtime (Rt, Http, Navigation, Hosted…, Tea, Direct) + JS siblings | 8,120 | 9,354 |
| app: schemas (generated readers, printers, descriptions) | 2,171 | 2,197 |
| app: markup (templates, mount factories, patches, direct protocol) | 7,417 | 12,398 |
| app: update/init, view functions, requests/routes/helpers | 5,027 | 5,070 |
| residual (keywords, separators, compression interactions) | 986 | 1,162 |
| **total** | **31,745** | **38,243** |

The single largest avoidable cost is **not a minifier problem**. Every
request body goes through `Http.jsonBody`, which takes a `Schema` value. A
`Schema` value means the library interpreter, so the interpreter and five
schema descriptions ship. Each declared schema already has a compiled `print`. Routing
the five bodies through those compiled `print`s (a source edit of Conduit, §5)
saves **2,223 B tea / 2,188 B direct**. The edited build sends byte-identical
requests in all six corpus runs.

**The guarantees cost about 6 kB of tea** (§3): response validation with typed
issues (about 2.5 kB once the interpreter is gone), the fiber runtime
(1.5 kB), typed HTTP and the checks that keep `fetch` from throwing (about
1.0 kB), request printing (0.6 kB) and defect teardown (0.4 kB). Solid's app
pays nothing for these. Its agent is `await fetch(…).json()` inside a catch
that returns whatever was thrown. **Its UI runtime and beni's are the same size.**
Solid's `solid.js`+`web.js`+`store.js` is 5.4 kB alone, and beni's Rt, Tea and
browser glue together are about 5.5 kB. The rest of the excess is code Solid also needs
but beni encodes larger. TEA view patching is 3.9 kB of patch functions Solid's
run-once components do not have. Then come the richer libraries (array-trie
`List`, red-black `Dict`, a real URL parser and History navigation against a
hash router) and the request/update code.

Ranked opportunities (§6), measured on executable variants unless marked:

| # | Change | tea | direct | Guarantee | Risk |
|---|---|---:|---:|---|---|
| 1 | Request bodies through the schema's compiled `print` | **−2,223** | **−2,188** | kept | low; faster |
| 2 | Inline top-level bindings read once at module initialisation | −180 | **−1,577** | kept | none at run time |
| 3 | One shared field reader for compiled schemas | −972 | −799 | kept | parse speed to measure |
| 4 | Terser-class local passes and name assignment (estimate on 1+2) | ≈ −1,100 | ≈ −1,400 | kept | per transform |
| 5 | Pay for `Http.track`'s streamed body only when reachable (alone, estimate) | ≤ −464 | ≤ −436 | kept | low |
| 6 | Constructor tags stay strings for types crossing `Tea.application` | — | −203 | kept | boundary rule |
| 7 | Drop the emitted `&&true` in schema readers | −138 | −31 | kept | none |
| 8 | Pick the quote that needs fewer escapes, per file | −123 | (+18) | kept | none |

Items 1 and 2 together are measured at **29,369 B tea / 34,509 B direct**
(−7.5% / −9.8%), and all six corpus runs pass. Adding 3–8 by estimate gives
**about 27 kB tea and 32 kB direct**, still about twice Solid. Closing more
needs representation work (§6.3) or **weakening a guarantee, which is the owner's
decision and is not recommended here** (§6.4).

## 1. Method

`build.mjs` builds `examples/conduit/src` with `--release --no-cache`, plain
and with `--source-maps`. It requires the mapped JavaScript, without its
trailer, to equal the plain build, and archives both. The compiler was a
ReleaseFast build of this commit, whose output is the safe build's (rule 5).
Sizes follow research 97/99/101: the one `_main.mjs`, brotli 11 with the size hint.

**Attribution** (§2) uses research 99's two accounts on research 101's units.
A unit is a top-level declarator, function or statement. Its group is the
source owning most of its mapped raw bytes; every unit in both bundles is at
least 90% one source, and most are 100%. The release map also carries the
original beni name at each binding. That is how app code is split by kind:
`X$$read`/`$$write`/`$$description` are schemas, `tN`/`kN`/`pN`/`bN` and direct's
`dgN_M`/`dpN_M`/`drN_M` are markup, and the rest goes by declaration name. *Alone*
stubs one group in the original (initialiser → `0`, body → `{}`, statement →
`0;`) and recompresses. *Ordered* stubs the groups cumulatively in table
order, so the residual closes the account exactly. Stubbed files are
syntax checked and never run. They locate a cost; they are not savings, and
alone deltas do not add up.

**Prototypes** (§5) are executable. `verify.mjs` runs `ConduitEditor`,
`ConduitReader` and `ConduitTour` through the gates' own `tests/browser/driver.mjs`
under happy-dom. Direct runs with `--no-comments`, as the corpus walker
runs it. Each transcript must equal both the corpus golden and the unchanged
bundle's transcript. Transcripts record every request's method, URL, headers
and body, so a changed request body would fail.

## 2. Every byte by origin

Brotli bytes; raw is the units' UTF-8 bytes. Order is the table's.

| Group (tea) | Units | Raw | Alone | Ordered |
|---|---:|---:|---:|---:|
| core/Task | 72 | 4,638 | 1,661 | 1,661 |
| core/List | 58 | 4,730 | 1,605 | 1,414 |
| core/Dict | 20 | 3,398 | 883 | 804 |
| core/Schema | 75 | 10,148 | 3,129 | 2,991 |
| core: Basics, Maybe, Result, String | 23 | 1,008 | 418 | 417 |
| core: Url, Url.Parser, Url.Builder | 25 | 2,381 | 792 | 737 |
| unmapped (JS siblings, shared constant constructors) | 104 | 2,215 | 473 | 420 |
| platforms/browser/Rt | 67 | 9,568 | 3,489 | 3,523 |
| platforms/browser/Http | 31 | 4,399 | 1,537 | 1,475 |
| platforms/browser/Browser/Navigation | 16 | 1,688 | 526 | 541 |
| platforms/browser: Hosted, Cmd, Sub, Listen, Storage, Browser, Html | 46 | 2,944 | 998 | 1,081 |
| platforms/browser-tea/Tea | 23 | 3,192 | 1,024 | 1,080 |
| app: schemas | 32 | 18,654 | 2,217 | 2,171 |
| app: markup | 219 | 39,420 | 7,346 | 7,394 |
| app: `main` | 1 | 69 | 120 | 23 |
| app: update / init | 30 | 11,902 | 2,396 | 2,321 |
| app: view functions | 41 | 3,290 | 963 | 1,024 |
| app: requests, routes, helpers | 50 | 4,779 | 1,277 | 1,682 |
| residual | — | 1,355 | — | 986 |

| Group (direct) | Units | Raw | Alone | Ordered |
|---|---:|---:|---:|---:|
| core/Task | 70 | 4,606 | 1,494 | 1,494 |
| core/List | 58 | 4,735 | 1,468 | 1,558 |
| core/Dict | 20 | 3,961 | 812 | 715 |
| core/Schema | 75 | 10,401 | 3,094 | 3,156 |
| core: Basics, Maybe, Result, String | 23 | 1,033 | 329 | 370 |
| core: Url, Url.Parser, Url.Builder | 25 | 2,524 | 697 | 769 |
| unmapped (JS siblings, shared constant constructors) | 104 | 2,326 | 453 | 437 |
| platforms/browser/Rt | 36 | 6,730 | 2,435 | 2,415 |
| platforms/browser/Http | 31 | 4,449 | 1,394 | 1,438 |
| platforms/browser/Browser/Navigation | 16 | 1,750 | 537 | 552 |
| platforms/browser: Hosted, Cmd, Sub, Listen, Storage, Browser, Html | 39 | 2,616 | 725 | 810 |
| platforms/browser-direct/Tea | 19 | 2,892 | 791 | 931 |
| platforms/browser-direct/Direct | 73 | 7,401 | 2,513 | 2,771 |
| app: schemas | 32 | 18,654 | 2,129 | 2,197 |
| app: markup | 588 | 54,248 | 9,488 | 9,560 |
| app: `main` (the mounted program and consumer matrix) | 1 | 64,467 | 2,749 | 2,838 |
| app: update / init | 30 | 11,951 | 2,363 | 2,383 |
| app: view functions | 37 | 2,765 | 724 | 932 |
| app: requests, routes, helpers | 50 | 4,914 | 1,274 | 1,755 |
| residual | — | 1,776 | — | 1,162 |

Per app module, alone (tea): ArticlePage 2,256, Article 1,428, Editor 1,142,
Feed 991, Page 949, Api 905, Settings 896, ProfilePage 795, Home 742, Main
704, Author 667, Login 384, Register 379, Comment 349, Route 336, Session
169. Direct's order is the same except Main (3,239, the matrix) leads it.

**Markup by generated kind** (`markup.json`):

| Kind | tea units / raw / alone | direct units / raw / alone |
|---|---|---|
| `t` HTML templates | 79 / 6,857 / 1,462 | 79 / 6,857 / 1,403 |
| `k` mount factories (clone, walk, wire, slots) | 69 / 12,647 / 1,989 | 79 / 14,542 / 2,117 |
| `p` patch functions | 45 / 19,500 / **3,881** | 55 / 5,582 / 998 |
| `dg` / `dp` / `dr` (direct protocol) | — | 147 / 4,857 / 548; 147 / 21,042 / **3,508**; 57 / 984 / 66 |

The HTML itself is not the difference: beni's 79 template strings are 6,146
raw bytes, Solid's 47 are 5,840. Patching is: a TEA view runs again on every
message, so every dynamic hole needs a cached-value guard and a write. The
Solid components in this reference run once; only accessor-wrapped holes re-run.
Two smaller findings sit inside this row. The `k` factories initialise every
slot (`a0:undefined,…,g3_3:NaN`), **287 entries, 3,229 raw, 552 B** to delete
in tea (444 direct). That is hidden-class and first-compare work, not dead weight.
And seven conditional text holes patch a constant (`if(" Edit Article"!==a.a1)…`), about 450 raw.

**Within the runtime** (`price.json`, alone, tea / direct):

| Part | tea | direct |
|---|---:|---:|
| core/Schema's library interpreter (absent once bodies use compiled `print`) | 2,267 | 2,243 |
| Rt's row reconciliation (`forKeyed`, `trimmed`, `reconcile`, `forPosition`, row mount/patch) | 2,012 | 1,643 |
| core/List's trie (`trie*`, leaves, claimable tail) | 672 | 565 |
| core/Dict's removal path (`remove`, `moveRed*`, `removeMin`…) | 452 | 398 |
| Http's streamed body with progress (`chunks`, `tracked`, …) | 464 | 436 |

`Dict` is reached by the platform, not by Conduit: Tea's keyed commands
and subscriptions insert and remove, Http joins headers, and `Url.Parser`
collects query parameters.

## 3. What the guarantees cost

Alone, after the interpreter is gone (the `jsonbody` prototype of §5, whose
schema code is only compiled readers, compiled printers and the compiled path's
support). Groups overlap in context, so the column is not a sum.

| Guarantee | What ships | tea | direct | Solid's app instead |
|---|---|---:|---:|---|
| A response is validated, failures are typed issues with a path | 17 compiled readers + core/Schema's compiled support | 1,490 + 964 | ≈ same | `await e.json()`, property access; nothing checked |
| A request body is printed by its schema; an unprintable body is an error | 13 compiled printers (the interpreter and 5 descriptions today) | 601 (2,267 + 415 today) | ≈ same | `JSON.stringify(o)` |
| `fetch` never throws a `TypeError`: method and headers checked first (rule 9) | `problemOf`, `isToken`, `headerProblem`, forbidden lists | 402 | 398 | none |
| HTTP failures are typed (`BadStatus`, `BadBody`, network, timeout…) and wrapped precisely (rule 9) | the rest of Http | ≈ 560 | ≈ 580 | one broad `catch(e){… return e}` |
| Managed effects: fibers, interruption, scopes, keyed command policies | core/Task | 1,540 | 1,475 | promises and `async` functions; resources in `solid.js` |
| A defect stops the page and runs every cleanup (§9.8.14) | Task teardown + Rt `stop` | 412 | 320 | nothing; an exception escapes |

Today, before the §5 fix, the validation and printing rows cost 1,778 + 3,129 +
415 + 156 B in tea. **Roughly 6 kB of tea buys guarantees Solid lacks**, and
that is a floor for any equivalent beni app. It shrinks with encoding
(§6.1 item 3), never to zero.

**Bytes Solid also needs, encoded smaller** (Solid: `solid.json`, the same
unit and stub method on research 101's single-chunk build; alone):

| Job | beni tea | Solid |
|---|---:|---:|
| UI runtime: DOM, templates, delegation, rows, scheduling, state | Rt 3,489 + Tea 1,024 + Hosted/Cmd/Sub/Listen/Storage/Browser 998 | `solid.js` 3,484 + `web.js` 1,197 + `store.js` 759 |
| List rows | Rt reconciliation 2,012 | inside `web.js` (1,197 for all of it) |
| Views and their event wiring | markup 7,346 + view functions 963 | pages and components 4,536 |
| State updates | update/init 2,396 | store actions, in "stores, router, startup" 813 |
| Requests, routes | requests/routes/helpers 1,277 + Url 792 + Navigation 526 | HTTP agent 1,041 (with its endpoints); hash router in the 813 |
| Collections | List 1,605 + Dict 883 | native arrays and objects |

Read side by side, the UI runtimes match, with one exception: beni's row reconciliation
alone is larger than all of Solid's `web.js`. Rule 8 says to read Solid's
`reconcileArrays` before accepting that. The views cost 1.8× because of TEA
patching, which is the architecture rule 8 chose for speed, not an encoding
accident. Navigation is a feature difference: History API and real URL
parsing against `#/` routes.

## 4. What Terser takes, and why

| Variant | tea raw / br | Δ br | direct raw / br | Δ br |
|---|---|---:|---|---:|
| beni `--release` | 129,778 / 31,745 | — | 214,199 / 38,243 | — |
| Terser whitespace only | 129,287 / 31,599 | −146 | 213,706 / 38,203 | −40 |
| Terser mangle only | 129,457 / 31,085 | −660 | 213,992 / 37,906 | −337 |
| Terser compress only | 121,400 / 30,945 | −800 | 199,490 / 35,687 | −2,556 |
| **Terser compress + mangle** | 121,551 / **30,447** | **−1,298** | 199,654 / **35,296** | **−2,947** |
| Terser `unsafe`, 3 passes (not run) | 120,639 / 30,319 | −1,426 | 198,089 / 35,126 | −3,117 |
| esbuild `--minify` | 123,527 / 32,084 | +339 | 204,754 / 38,594 | +351 |

Terser's default output was run through all six corpus runs and passes. The
`unsafe` variant was not run. A property-mangling variant (not executable: it
renames DOM properties too) is only 160 B under the default in tea and 123 B in
direct. **Long property names are not where the bytes are.** The 1,894 property
names of three or more letters in tea are cheap after brotli.

Which transforms buy it (`ablate.json`: each compress option switched off
from the full configuration; positive = that option was saving bytes):

| Option | tea | direct | What it does here |
|---|---:|---:|---|
| `unused` + `reduce_vars` (+ `reduce_funcs`) | 436 / 297 / 200 | 2,248 / 2,165 / 511 | inline single-use top-level bindings and drop them |
| `collapse_vars` | 139 | 261 | fold `let c=b[0];{let b=c.C;…}` chains Opt refuses |
| `conditionals` | 150 | 156 | `if(x)a=…;else a=…` → `a=x?…:…`, `if(c)f()` → `c&&f()` |
| `booleans` | 30 | 120 | `true`/`false` → `!0`/`!1`, `x&&true` |
| `sequences` | −114 | 31 | **hurts tea**: comma-joined statements compress worse |
| `loops` | −72 | 83 | mixed |

**Single-use top-level inlining.** Terser removes 511 of direct's 1,325 top-level
bindings (58 kB raw) and 154 of tea's 930. None is dead, because beni's `Reach` is
exact. All are read once. `src/js/Opt.zig` inlines single uses only
*inside* a function body, so a binding like direct's patch entry is
printed under a 2–3 character name and read once. Examples are `Wt=(a,b)=>…` read in
`_t=Uf(…,[Qf(Vt,Wt,null),…])`. Random short names are what brotli compresses
worst. §5's prototype does exactly the safe subset: a pure initialiser read
once by a later module-level initialiser, so evaluation count and identity are
unchanged.

**Naming.** Mangling alone is worth about 500 B in tea over whitespace (−660
against −146). `Rename.zig` assigns in emission order and records that this
compressed better than frequency order (§9 table F). Terser also ranks its alphabet
by the output's character frequency and reuses names across sibling scopes.
That claim deserves a re-measurement on Conduit. The whitespace-only 146 B
is almost entirely quoting: Terser prints `'…"…'` where beni escapes
`"…\"…"` in template HTML (item 8).

Terser on top of items 1 and 2 still takes **1,138 B tea / 1,368 B direct**.
That is item 4's estimate for the rest of what a minifier-class pass could do.

## 5. Executable prototypes

| Prototype | How | tea | direct | Corpus scripts |
|---|---|---:|---:|---|
| `jsonbody` | Conduit's five `Http.jsonBody (X.schema ⊤) v` become `Api.jsonText X.print v`, a four-line helper over `Http.stringBody` ([patch](../../../bench/output-size/results/jsonbody.patch)) | −2,223 | −2,188 | 6/6 match |
| `inline` | top-level single-use inlining at module initialisation (`inline-toplevel.mjs`; 41 / 395 bindings) | −180 | −1,577 | 6/6 match |
| `schema` | one shared per-field reader for compiled schemas (`schema-outline.mjs`; 41 field blocks) | −972 | −799 | 6/6 match |
| `andtrue` | delete `&&true)` (48 sites) | −138 | −31 | 6/6 match |
| `quotes` | fewer-escape quote per literal | −123 | +18 | 6/6 match |
| **`jsonbody` + `inline`** | both | **−2,376** | **−3,734** | 6/6 match |

`jsonbody` does not weaken anything Conduit relies on: each compiled `print`
still checks its value and returns `Result (List Issue) String`. The helper maps an
unprintable value to an empty body where `Http.jsonBody` keeps `Unprintable
issues`. A real change must keep that typed error. The bytes do not depend
on it: the interpreter, `run`, `recordOf`, `variantOf`, `fieldsFrom` and the
descriptions disappear because nothing reaches them. Two designs keep the API.
(a) `Http.jsonBody`'s release lowering specialises on a statically known
schema declaration, so `Schema.print (X.schema ⊤)` becomes `X.print`. The
release optimiser already has a `specialise` phase. (b) Http gains a body
from a compiled printer. Option (a) also fixes every other library-path use of
a declared schema, and the S4 measurements already say compiled is faster.

`schema` writes the per-field block once:

```js
// before, per field of every schema (tea):
let j,k=f["slug"];if(k!==undefined){if(i)j=pf(a,g,"slug","slug",5,"the depth limit is reached",k);
else if(typeof k!=="string")j=pf(a,g,"slug","slug",0,"expected a string",k);else j=k}
else j=pf(a,g,"slug","slug",1,"missing key \"slug\"",f);if(j===a.a&&true)return a.a;
// after:
let j=$$f(a,g,f,i,"slug",$$s);if(j===a.a)return a.a;
```

It keeps every check, issue code, message and order. As prototyped, it passes the
issue context eagerly where the compiler had inlined it lazily, and it calls
through a per-type checker. Both are speed questions: the lowering should hoist
the context once and call typed helpers directly. The change must be measured on
`bench/schema-libraries` before it is taken, because S4's claim is to be faster
than Valibot, Zod and Effect.

## 6. Opportunities, ranked

### 6.1 Keep every guarantee; recommended

1. **Request bodies through compiled printers: −2.2 kB, both platforms.** Low
   risk, faster at run time, no compile-time cost. Owner-visible only if
   option (b)'s API is chosen; (a) is a release-lowering change.
2. **Top-level single-use inlining at module initialisation: −1.6 kB direct,
   −0.2 kB tea.** No run-time cost by construction. The value is created
   once, by the same expression, before anything can observe it. It belongs in
   the release optimiser next to `Reach`, which already counts uses. Do not
   widen it to uses under a function: that would allocate per call and
   change identity (rule 8, field identity).
3. **Shared compiled-schema field readers: about −0.8 to −1.0 kB.** Needs a
   parse-speed measurement first.
4. **Minifier-class passes: about −1.1 kB tea, −1.4 kB direct on top of 1–2**
   (estimate). Collapse single-use local chains Opt refuses, `if`→`?:`/`&&`,
   `!0`/`!1`, and re-measure frequency-ranked naming. Leave `sequences` off.
   Price each change on its own with brotli, per the `hand-minify` skill. A
   change that slows code is not taken, even for bytes.
5. **`Http.track`'s streamed body only when `Http.track` is reachable: up to
   −0.46 kB.** Without it, read the response with `text()` and keep the
   same typed failures.
6. **Direct: tags of types that cross `Tea.application` stay strings: −0.2 kB
   direct.** `Maybe`, `Dict`, `Cmd` and 18 more keep `"Just"`/`"Nothing"`
   tags in direct but not in tea. The foreign only passes those values
   back, so `boundary.md` §4's "what JavaScript may read" is over-approximated
   here.
7. **`&&true` (−138 tea) and the quote choice (−123 tea, per file only when
   it wins).** Trivial printer fixes.

Items 1 and 2 are measured together at 29,369 / 34,509 B. With 3–7 by
estimate, **about 27 kB tea and 32 kB direct**: −15% and −16%, still about
2× and 2.4× the Solid reference.

### 6.2 Investigate (rule 8)

- **Row reconciliation (2.0 kB alone) against Solid's `reconcileArrays`.**
  Solid's whole `web.js` costs 1.2 kB alone. Read it and match it before
  accepting the difference.
- **Constant text holes** (seven sites): text that never changes belongs in
  the template.

### 6.3 Representation; bytes against speed

- **TEA patch functions (3.9 kB tea).** They are the price of a view
  that runs every render. Research 101's shared lexical factories are the
  direct-side version of this question. Neither is a minifier fix, and both must
  be timed against Solid 2 before they are proposed.
- **Slot initialisers (0.55 kB tea).** A per-template slot list or
  constructor would be shorter. Hidden-class stability and the `NaN` first-compare
  sentinel are why they exist, so no change without a mount benchmark.
- **`List`'s trie (0.67 kB) and `Dict` (0.88 kB).** These are representation
  decisions the owner took for O(1) access and push. A smaller internal map
  for platform bookkeeping (Tea's keyed jobs) would let `Dict` drop out of
  programs that never use it. That is worth pricing on a page without one.

### 6.4 Only by weakening a guarantee: the owner's decision, not recommended

| Weakening | Saves (tea, alone) | Guarantee lost |
|---|---:|---|
| Untyped JSON responses, as Solid | ≈ 2.4 kB after 6.1-1 (readers + compiled support) | no runtime error from a malformed response; typed, located issues |
| No method/header checks before `fetch` | ≈ 0.4 kB | `fetch` can throw `TypeError` (rule 9) |
| No defect teardown | ≈ 0.4–0.5 kB | cleanup on defect (`boundary.md` §9.8.14) |
| No fiber runtime | 1.5–1.7 kB | managed effects: interruption, scopes, command policies |

None of these is proposed. They are listed so the remaining distance to Solid
is not mistaken for waste.

## 7. Reproduction

[`bench/output-size/README.md`](../../../bench/output-size/README.md) lists the
commands. The archived bundles and maps reprice without a compiler.
`edits.mjs` re-runs every bundle-edit prototype and its corpus verdicts from
the archive, and `proto.mjs` rebuilds the source prototype. No compiler, core,
platform, application, test, budget or run-hash file changes, so the gates
are not affected by this branch beyond its new files.
