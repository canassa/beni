# 101 — Conduit's practical byte floor and direct's representation

*2026-10-15. Research only. Beni master `2c4e2aee0a5be57606da36ee7c667ca46c6de427`;
Node 24.19.0, npm 11.17.0, zorg 0.17.1+zorg.1, Apple M2 Pro / macOS.
All builds and byte measurements ran locally; azathoth was not used.
Read after [97](97-conduit-dispatch-profiles.md),
[98](98-browser-app-ownership.md) and PR #134's
[99](99-direct-bytes.md). Number 101 leaves 100 for S8; master and the open
PR file lists were checked before choosing it.*

## 0. Answer

There is an **observed small-app reference band, not a proved minimum for the
complete beni feature set**. An established Solid Conduit is **23,902 B** brotli
in its stock production build. Making its article body match beni's paragraph
renderer and fixing its broken favorite callback gives **16,270 B** over all
nine production chunks, or **13,085 B** in a real one-chunk production build.
Modern-browser, paragraph-only vanilla Web Components is **11,684 B**, but
lacks several features beni implements. It is useful context, not a full-parity
floor. The source audit below is essential to interpreting these numbers.

Beni tea is **31,389 B**, direct **37,970 B**. Direct's same-app excess is
**6,581 B / 20.97%**. Relative to the adjusted single-chunk Solid reference,
direct carries **24,885 B** more and tea **18,304 B** more, before pricing
remaining feature/guarantee differences. Those are download differences, not
optimisation budgets. Removing direct's entire tea-relative excess would still
leave a much larger bundle than the reference.

**The 20% is not an inherent price of precise static updates. It is a price of
this workload and this representation.** Report 99's table app is smaller under
direct than tea. But the new evidence also rejects a tempting simplification:
deleting all recognized patch-entry environment prologues saves only **90 B**.
Replacing array loads with human-looking lexical names cannot explain or recover
6.6 kB by itself.

The evidence points to **shared lexical template factories plus precomputed,
shared ordered operation selections**, retaining captures, restates, row
ownership and a fallback. A **1–3 kB net saving is a planning hypothesis** for
that redesign, not a measured executable result or acceptance promise. A
measured deletion of matrix, descriptors, selection runtime and prologues
together frees only **2,600 B before replacement code**. Getting another large
saving would require changing the patch bodies, preparation and instance
representation too. There is no evidence here for recovering all 6,581 B,
or reaching 13 kB while retaining beni's current guarantees.

## 1. Reference builds and parity

The references are established implementations, not new golfed demonstrations:

- [Solid RealWorld](https://github.com/solidjs/solid-realworld/tree/f6e77ecd652bf32f0dc9238f291313fd1af7e98b),
  `f6e77ecd652bf32f0dc9238f291313fd1af7e98b` (2022-04-24).
  Its [readme](https://github.com/solidjs/solid-realworld/blob/f6e77ecd652bf32f0dc9238f291313fd1af7e98b/readme.md)
  says `npm install`, then `npm run build`. The heading says production;
  the following sentence calls it development, but the actual command is
  `rollup -c --environment production` and enables Terser. We ran that command
  with its upstream npm lock (line endings normalized to LF), resolving Solid **1.3.3** and its matching JSX
  compiler. This is **not Solid 2**, the separate speed reference in this repo.
- [Vanilla JS Web Components RealWorld](https://github.com/gothinkster/web-components-realworld-example-app/tree/8408c72d1d62c4d67416b1d6b28d1deb6c521af9),
  `8408c72d1d62c4d67416b1d6b28d1deb6c521af9` (2021-11-13), from
  the RealWorld project's own organization. Its readme documents yarn/start;
  its package's production script is `npm run build`, invoking
  `webpack --config webpack.config.prod.js` with `mode: 'production'`.
  We used that script. Its upstream yarn lock and the npm lock actually used
  are committed under `bench/conduit-floor/references/vanilla/`.

Vanilla's Git dependency is fetched over HTTPS as an archive of the **same
`004aaac0ee1d5908168825a6175d823ed3667067` commit in its yarn lock**.
The npm lock pins the resolved upstream dependency ranges. It is not a claim
to reproduce every resolution in the old yarn lock. Webpack 4 also needs
Node's OpenSSL legacy-provider switch. These are recorded build adaptations;
the stock app and production configuration are otherwise unchanged.

Both references have home/global and personal feeds, tag filtering,
login/register, settings/logout, article viewing, article create/edit,
profiles/authored/favorited lists, and comment creation. That is substantially
more than TodoMVC. It is not proof of feature equality:

| Feature / behavior | Beni `examples/conduit` | Solid reference | Vanilla reference |
|---|---|---|---|
| Article body | Safe text paragraphs split on blank lines | `marked` Markdown, sanitization option | `markdown.toHTML`, HTML insertion |
| Feed favorite | Implemented with typed failure handling | UI present; callback references undefined `slug` | Implemented; fixture click sends favorite request |
| Article follow/favorite | Both controls | Article actions area empty; absent | Both controls |
| Article edit/delete | Both | Both | Edit; no delete control/request |
| Comment create/delete | Both | Both | Create; no delete control/request |
| Home pagination | Global, personal and tag feeds | UI; personal-feed agent hardcodes offset 0 | UI and offset handling |
| Profile pagination | Authored and favorited | UI present; different page limits from beni | No pagination |
| Profile follow | Implemented | Implemented | Implemented |
| Editor text updates | Input messages on each change | Text fields use `onChange`, tag keys differ | Handwritten DOM/key handlers |
| API response validation | Specialized schemas, typed bad-body and host failures | Untyped JSON/property access | Untyped JSON/property access |
| Navigation/lifecycle | Browser application/navigation, managed commands | Hash router, resources/store, lazy pages | Navigo hash router, custom-element callbacks |

Source evidence: Solid's `src/pages/Article/Article.js`,
`src/components/ArticleList.js`, `src/store/createAgent.js`, and editor/profile
pages; vanilla's `app/pages/{home,profile,editor,article-preview}.comp.js`,
`app/components/article-preview-banner.js`,
`app/components/comment-preview.comp.js`, and `app/http/http.js`; beni's `Article`,
`ArticlePage`, `Feed`, `ProfilePage`, `Editor` and `Api` modules. See the pinned
trees above and the emitted code in `results/excerpts.json`.

The adjusted Solid builds replace Markdown with the same blank-line paragraph
behavior and change `makeFavorite(slug)` / `unmakeFavorite(slug)` to
`makeFavorite(article.slug)` / `unmakeFavorite(article.slug)`. The second change
restores an intended feature rather than deleting it. The exact two source edits
are in `references.json`; the stock result preserves the bug. Against the
paragraph-only trial before that fix, the fix costs 35 B across chunks / 21 B
in one chunk. We do **not** silently fix its feed pagination or add article
actions, and do not claim its other workflows have been fully verified.

Vanilla's adjusted build removes the always-bundled fetch/Web Components
polyfills, targets Chrome 120 in its existing Babel preset, and constructs safe
paragraph nodes instead of importing Markdown. Native browser APIs replace
the compatibility layer. This is an explicitly different browser-support target,
not the stock result. The small number must not be used to price a complete
Conduit with article deletion, comment deletion and profile pagination.

Therefore **only the tea/direct comparison is strictly like for like**. The
adjusted references align the largest optional content/browser-support costs;
the table retains the remaining differences rather than subtracting guessed
byte allowances. No fully feature-and-guarantee-equivalent reference floor
was established. In particular, 11.7 kB is not a defensible target for the full
beni app on this evidence alone.

## 2. Shipped bytes and attribution

The requested research 98 is the ownership audit and specifies no byte protocol.
We use research 97/99's actual protocol: production JS, Node zlib brotli quality
11 with input-size hint, gzip 9, no extra minifier for beni. Every route's JS is
included once. CSS, HTML, fonts, images, maps and the unloaded direct plan are
excluded. Vanilla's emitted map-trailer comment remains part of its JS response.

Each HTTP response is compressed **separately**, then summed. Cross-file
compression is not available to a browser. All beni releases here have one
file. For transparency, the last column also gives research harnesses'
concatenated-input diagnostic for the split references; it is not a download.

| Production build | JS files | Raw | Gzip 9 | Brotli 11 transfer | Concatenated br diagnostic |
|---|---:|---:|---:|---:|---:|
| Solid stock | 9 | 73,714 | 26,702 | **23,902** | 21,409 |
| Solid paragraphs + favorite fix | 9 | 48,661 | 18,423 | **16,270** | 13,833 |
| Same Solid, Rollup single chunk | 1 | 48,078 | 14,534 | **13,085** | 13,085 |
| Vanilla stock | 3 | 225,131 | 55,120 | **47,485** | 45,796 |
| Vanilla modern / paragraphs | 2 | 60,280 | 13,384 | **11,684** | 11,323 |
| Beni tea | 1 | 125,961 | 36,836 | **31,389** | 31,389 |
| Beni direct | 1 | 210,016 | 45,678 | **37,970** | 37,970 |

The single-chunk Solid variant is a real Rollup build with
`--inlineDynamicImports`, not concatenated module text. It gives up lazy page
loading; the all-route byte saving is not a first-page latency recommendation.
Both reference build scripts still perform their own production minification.

Runtime/application splitting follows research 97's **ordered removal
accounting**, not independent compressed component sizes. Using source maps,
we replace complete AST initializers, function bodies or expression statements
whose mapped provenance is uniformly runtime with `0`, `{}` or `0;`. We then
do the same for Markdown. Every intermediate parses; no DCE follows. The
successive whole-response brotli deltas are the charges; the residual is
application, startup, stub syntax and unassigned compression interactions.
`sizes.json` records every exact span and source. These are nonexecutable
attribution variants, not equivalent apps or potential savings.

Runtime means external framework/router/polyfill/Babel code and webpack
bootstrap for the references, **all reachable core and platform code for beni**.
App-owned routers/helpers are app code. Beni's generated schema parsers and DOM
factories are charged to app sources. This is broader than "rendering runtime"
and cannot be read as a comparison of UI runtimes alone.

| Build | Runtime charge | Markdown charge | App/startup residual | Total br |
|---|---:|---:|---:|---:|
| Solid stock | 5,698 | 7,357 | 10,847 | 23,902 |
| Solid paragraphs + favorite fix | 5,718 | 0 | 10,552 | 16,270 |
| Solid same, single chunk | 5,698 | 0 | 7,387 | 13,085 |
| Vanilla stock | 30,308 | 5,361 | 11,816 | 47,485 |
| Vanilla modern / paragraphs | 3,203 | 0 | 8,481 | 11,684 |
| Beni tea | 15,509 | 0 | 15,880 | 31,389 |
| Beni direct | 16,748 | 0 | 21,222 | 37,970 |

The **6,581 B tea/direct difference** charges **1,239 B to runtime** and
**5,342 B to app/startup** in this convention. Most of the difference lives
in generated representation, not a larger fixed rendering library. However,
beni's common core/effects/platform/API surface is already much bigger than
Solid's dependency surface. A direct-only template redesign cannot close that
whole cross-language gap. The attribution order and residual prohibit treating
these charges as isolated removable library downloads.

Research 99 measured direct at 209,384 raw / 37,768 br. Current master adds
retained-value fallback/restate handling in `Direct.beni`, plus its lowering
changes: **+632 raw / +202 br**, while tea is byte-identical. These new results
do not silently substitute the older compiler. The compiler hash and every
response hash are archived in `manifest.json` / `sizes.json`.

## 3. What Solid actually emits

The production output, not just its JSX or the current Solid 2 source, supplies
the comparison. `excerpts.json` preserves the complete prettified ArticleList
chunk from each Solid build. For the preview's favorite button, the emitted
operations include:

```js
r.$$click = s;
r.$$clickData = n;
e(r, () => n.favoritesCount, null);
l(() => r.className = n.favorited
  ? "btn btn-sm btn-primary"
  : "btn btn-sm btn-outline-primary");
```

Here `r` is the button node and `n` its article, closed over by the callbacks;
the imported aliases `e` and `l` are Solid's insertion/effect operations.
The enclosing preview function clones its static template and keeps
`firstChild` references in ordinary locals. Titles, descriptions, dates and
tags destructured from the article use direct insertion/text assignments;
the mutable favorite fields use accessors and a reactive effect. Pagination
similarly closes over its `<li>` and toggles its class in an effect.

So this is **straight-line mount code plus small lexical reactive callbacks**,
not a single straight-line update function with no runtime. Static HTML is
hoisted into shared `template(...)` constants, cloned per instance. Component
functions/template constants are reused across calls; template strings are
not deduplicated into one whole-application super-template. The runtime pays
for signals/store proxies, subscriptions, ownership/disposal, resources,
control flow and insertion/list reconciliation. Its dependency charge is about
5.7 kB here, not zero. Conduit's handwritten hash router is app-owned code.

Direct's corresponding generated entry is, for example:

```js
sj = (a, b) => {
  let c = b[0];
  {
    let b = c;
    if (b !== a.g0_0) {
      a.g0_0 = b;
      a.w0.setAttribute("class", b);
    }
  }
};
```

Its reusable entry gets an instance and prepared positional arguments,
compares cached inputs, and reaches its DOM node through instance fields.
Other entries compute route strings and conditionally patch more than one
hole. Direct is **not** cloning the entire source component per live call:
this bundle has **146 shared patch definitions / group descriptors**, and
120 recognized leading environment prologues loading **155 slots**. Its
call-path-sensitive matrix has 331 source/mask entries (research 99's protocol).
Runtime instances and selections are distinct from those emitted definitions.

Direct spends bytes absent from this Solid output on:

1. **Message/call-path × consumer masks and descriptor facts.** They permit
   static skipping before ordinary value guards. Solid instead allocates a
   reactive dependency graph while the component executes; it needs no message
   constructor table or source-path string matrix.
2. **Entry wiring and a generic environment/instance ABI.** Direct's reusable
   patch functions, prepare functions, instance cache/node properties and
   group attachment calls must agree. Solid's callback closes over lexical
   nodes and accessors. Solid still pays callback definitions, captures,
   graph nodes and list/component plumbing.
3. **Selection/cache/context machinery.** Direct constructs ordered lists of
   selected operations on first use, retains them, tracks call/row ownership
   and restores ambient context. Solid uses subscriber links, owners and its
   scheduler. This is a different selection representation, not eliminated work.
4. **Restate/capture refresh and value-root fallback.** Beni's every-render
   and escaped/nested markup semantics need these even when ordinary reads do
   not select a group. Reactive accessor ownership is Solid's counterpart;
   deleting restatement is not a lexical encoding optimization.

Neither the shared HTML strings nor the initial DOM walk explains the whole
gap: both systems use them. Neither does the environment-load syntax alone.
Nor can Solid's graph simply be declared "free" because it has no mask literals.

## 4. Measure the representation opportunities

These current-master probes each start from the unchanged direct bundle.
They parse after editing but **do not run**. A deletion identifies compressed
cost in context, not a valid representation or an achievable saving.

| Independent deletion | Count | Br bytes removed |
|---|---:|---:|
| Leading positional environment declarations | 120 functions | **90** |
| Consumer matrix | 1 | **1,545** |
| Group descriptor initializers | 146 | **572** |
| Selection-runtime initializers | 4 retained declarations | **404** |
| Entire patch-entry initializers | 146 | **3,507** |
| Matrix + descriptors + selection + prologues, together | 271 edits | **2,600** |

The entire patch body includes real computations, identity checks and DOM
writes that must survive any representation. Its 3,507 B is not overhead.
The isolated deltas cannot be added: the combined 2,600 B is recompressed,
not their sum. Research 99's executable short-ID and complete-group-record
trials saved 589 and 233 B on its older baseline; those historical savings
must not be added to these deletions or promised on current master.

The 90 B prologue result is particularly useful. There are only 1,565 raw
bytes in those statements, and their repeated shape already compresses well.
The expensive distinction is how groups are selected, shared and connected
to live state, not whether the local code looks human-written.

## 5. The representation worth prototyping

Keep static precision, but lower a known template/call pattern into a **shared
factory with lexical node references and an explicit ordered update interface**.
In schematic readable JavaScript:

```js
function preview(initial) {
  const node = clonePreview(), button = /* static walk */ node.firstChild;
  let current = initial, previousClass;
  const favorite = () => {
    const next = current.favorited ? activeClass : inactiveClass;
    if (next !== previousClass) {
      previousClass = next;
      button.className = next;
    }
  };
  return { node, setInput(value) { current = value; }, favorite };
}
// Separate generated call-site selection calls only its ordered operations.
// Capture refresh, restates and structural/row work retain their own entries.
```

This sketch is not a runnable replacement: it omits count text, event handling,
mount/row paths and fallback code. It makes the environment choice explicit.
Factories stay shared at definition sites; whole views are not duplicated
into every message handler. Known call paths select interned ordered operation
lists compiled ahead of time, with equal selections shared. Sparse message
dispatch should reach these entries directly rather than reconstructing the
same source-string/call-path selection and scanning group descriptors on first
use. Unknown value roots retain the current conservative path.

**Estimate:** budget **1–3 kB net** (about 3–8% of direct's current bundle)
for an initial successful redesign, leaving roughly **35–37 kB**. The lower
portion assumes some of the 2.6 kB combined protocol deletion can be replaced
with a smaller static dispatch/list representation. The upper portion also
assumes useful reductions in entry wiring, instance fields and preparation;
it is much less supported. This range is an engineering target inferred from
measured costs, **not a measured candidate or a statistical confidence interval**.
It is falsified if the necessary lists, factories and fallback retain those
bytes. A lexical rewrite alone earns no forecast beyond the 90 B probe.

Costs and conditions:

- Lexical group closures allocate per live template instance, where today's
  patch definitions are shared and receive state as arguments. That may cost
  mount time, memory, GC and JIT work, especially for rows. It could also save
  repeated instance/argument loads. Neither direction has been timed here.
- AOT selections can remove cold mask scanning/cache construction without
  adding a graph. They can also create more literals and indirections than the
  compressed bit strings cost. Deduplication and a bound on specialization
  are required; blindly emitting every key × call-path × group combination
  could worsen bytes and compile time.
- The compiler needs call/escape/row ownership analysis, deterministic
  specialization keys, lexical environment lifetime handling and sharing of
  identical selection bodies. This belongs in lowering/whole-program IR,
  not token minification. Keep the generic value-root fallback and avoid
  copying unspecialized updates into per-message handlers (research 97).
- Preserve immutable field identity, operation order, input refresh, captures,
  every-render restates, lifecycle/command ordering and the independent visit
  oracle. Do not pay for fewer bytes by visiting every group or dropping a
  restate. This is a representation research direction, not a changed contract.

Before adopting it, validate paired transcripts/value fuzz/visit precision and
measure mount, first-key compilation, warmed dispatch, row churn and allocation
against Solid 2 using the existing UI harness. Report 97's three Conduit
message medians have overlapping tea/direct IQRs; they do not establish a
20% speed benefit that justifies every byte here. No new speed claim follows
from the byte measurements or the small Solid 1 build.

## 6. Validation and reproduction

[`bench/conduit-floor/README.md`](../../../bench/conduit-floor/README.md)
gives the commands, lockfile policy and archive format. `build.mjs` checks out
the pinned references and executes their production scripts. `measure.mjs`
builds unchanged beni tea/direct with and without maps, requires mapped
executable text to equal plain text after removing the map trailer, archives
the JS/maps, and prices each response. The same invariant holds for Solid's
mapped/plain builds. The sources/maps, hashes, attribution spans, probes and
emitted excerpts are committed. `--archive` reprices without rebuilding.

The offline Chrome 155.0.8059.80 smoke campaign starts the measured reference
bundles with fixture responses and no CSS: home, article, authenticated editor
and a feed-favorite click, five variants / 20 cells. Storage is cleared before
each mount; no public API or backend availability affects the result. The
fixture normalizes duplicate slashes when selecting a response, while keeping
the original request URL in its log. All route-startup cells render the
expected content. Stock Solid's favorite click records the undefined-`slug`
error; both adjusted Solid variants and both vanilla variants send the request
without that error. This is **not** a full authentication/CRUD/pagination/error
conformance test or a new cross-framework speed run.

Local `zorg build test test-blackbox fmt-check beni-fmt-check` completed with
**1,329 passed, 15 skipped and the two documented macOS case-folding failures**
in `build_test`. The hardware-budget gate remains owed on supported x86-64
Linux; macOS cannot issue that verdict. No compiler, core, platform, application,
test-budget or run-hash file was changed. The new JS research scripts also pass
Node syntax checks. These observations do not waive the known host failures.
