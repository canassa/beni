# 75 — Datastar: what the hypermedia framework is, what its speed claims rest on, and what beni can use

*2026-10-12. A research report for the owner's question: what is Datastar (data-star.dev,
`starfederation/datastar`, Delaney Gillilan and contributors) — its ideas, its philosophy, and
what it actually is under the hood — and does the performance its authors and community talk
about hold? Read from a shallow clone of `starfederation/datastar` taken today, branch `develop`
at `1efcdc3` (the v1.0.4 release, 2026-09-21), from the project's site, essays and release
notes, and from practitioners. Claims are marked **[source]** (read in that code, file named),
**[doc]** (the project's own site, essays or release notes), **[reported]** (a practitioner,
linked), **[measured]** (by the scripts in §9, on this machine), **[estimate]** (my reasoning).
Nothing was implemented in beni and no code outside this report changed.*

---

## 0. The answer in eight points

1. **Datastar is a ≈ 12 kB runtime interpreter for HTML attributes, plus a wire protocol.** The
   page's `data-*` attributes hold JavaScript snippets that are regex-rewritten and compiled with
   `Function()` in the browser (§2.1); a small signal store, a copy of alien-signals' push-pull
   graph, makes them reactive (§2.2); and a server answers any request with a stream of
   Server-Sent Events, each either an HTML fragment to **morph** into the page (an idiomorph
   port, §2.3) or a JSON merge patch for the signals (§2.4). Backend SDKs in a dozen languages do
   nothing but format those events (§2.5). There is no compiler, no component model in the core,
   no virtual DOM, and no types.
2. **Its philosophy is "the backend is the source of truth"** (*The Tao of Datastar*): keep state
   on the server, re-render HTML there with whatever templating you have, push it down a
   long-lived SSE stream ("CQRS": one read stream, many short write requests), let the morph keep
   focus and DOM state, use client signals sparingly, and never update optimistically (§3). It is
   htmx's hypermedia argument with Alpine's attributes folded in and LiveView's server push
   added, minus LiveView's server-side diffing.
3. **The size claim holds exactly**: the README's "11.89 KiB" is the brotli size of
   `bundles/datastar.js` — **12 183 B** brotli-11 [measured], 33 553 B minified; the core without
   plugins is 4 444 B; with Rocket (web components) 21 280 B (§4.1).
4. **The wire-size claim holds, with a condition**: re-sending a whole 1 000-row table (218 kB of
   HTML) as a second SSE event costs **38 bytes** after brotli when one class changed, and 688 B
   when every tenth label changed — because one brotli stream with a 4 MiB window spans the
   connection [measured, §4.2]. With gzip's 32 KiB window the same event is **7 972 B**: the "200:1"
   claim is brotli-or-zstd-on-a-long-lived-stream, not compression in general.
5. **The client-CPU claim does not hold as a general one** — and Datastar mostly does not make it
   with numbers. Morphing a 1 000-row table in headless Chrome [measured, §4.3]: a patch that
   changes nothing costs **15 ms** of script (parse 218 kB, walk every node), selecting one
   row 24 ms against vanilla's 0.2 ms, updating every tenth row 33 ms against 2 ms (n = 10
   medians); and **a patch that replaces every keyed row is quadratic** — 715 ms at 1 000 rows
   in the n = 10 table, and in a separate scaling batch 56 ms at 250, 452 ms at 1 000, **1.9 s at
   2 000** (×4.3 for ×2 rows) — in the idiomorph matching loop (§2.3). No benchmark of Datastar's own was found in
   its repository or on its site; its demos (DBmon, Bad Apple, TodoMVC) show a frame rate, not a
   method (§5).
6. **What is genuinely new is small**: the event protocol (patch-elements / patch-signals over
   SSE for *any* HTTP method, §2.4), and the packaging — server push + morph + signals + one
   attribute language in one 12 kB file. The parts are repackaged: idiomorph (htmx's morph),
   alien-signals (Johnson Chu's, also the lineage of Solid 2's graph, research 27 §1.2), Azure's
   `fetch-event-source`, Alpine-style expression attributes.
7. **For beni, three ideas are worth adapting and the rest conflicts** (§8): a
   **server-driven platform** where the server runs TEA and pushes typed patches over SSE —
   adapt, but with compile-time patches (the server knows the write set, so it can send the
   holes that changed, not HTML to morph); the **brotli-over-a-long-lived-stream** observation —
   adopt as a measured fact for any beni streaming protocol; and **SSE for every HTTP method with
   reconnect and `Last-Event-ID`** — adapt into the `Http`/`browser-tea` effect library as a
   typed stream. **Reject** the attribute expression language (`Function()`, untyped strings, a
   runtime parser), the morph as a rendering strategy (it is research 29's "virtual DOM over the
   real DOM", and slower), the client signal store, and the error model (§7).
8. **The signal core is not prior art against write sets**: it is the same run-time read-tracking
   graph Solid 2 uses, at an older alien-signals revision (it still has the `isValidLink` walk
   Solid 2 removed); write sets are the compile-time thing it does not have.

---

## 1. What Datastar is, layer by layer

| layer | what it is | where [source] |
|---|---|---|
| engine | scans the DOM for `data-*` attributes, dispatches each to a plugin by name, watches the page with one `MutationObserver` | `library/src/engine/engine.ts` |
| expressions | an attribute value → regex rewrite (`$x` → `$['x']`, `@get(` → `__action("get",evt,`) → `Function(...)` | `engine.ts` `genRx`, `engine/csp.ts` |
| signals | alien-signals' graph (linked `Link`s, flags, push-dirty/pull-check) behind a deep `Proxy` store; JSON Merge Patch in and out | `engine/signals.ts` |
| attribute plugins | `bind`, `text`, `show`, `class`, `attr`, `style`, `on`, `signals`, `computed`, `effect`, `init`, `indicator`, `ref`, `on-intersect`, `on-interval`, `on-signal-patch`, `json-signals` | `plugins/attributes/*.ts` |
| actions | `@get/@post/@put/@patch/@delete/@query` (SSE fetch with retry), `@peek`, `@setAll`, `@toggleAll` | `plugins/actions/*.ts` |
| watchers | `datastar-patch-elements` (parse + morph or insert), `datastar-patch-signals` (merge patch) | `plugins/watchers/*.ts` |
| Rocket | web components whose `render` builds a tagged-template fragment and **morphs** it into the host | `library/src/rocket/` (≈ 3 450 lines) |
| SDKs | Go, Python, TypeScript, PHP, Ruby, Rust, Java, .NET, Clojure, Haskell, Zig… — an SSE writer and a signals reader each | `sdk/ADR.md`, separate repositories |

The whole client is ≈ 8 000 lines of TypeScript, of which Rocket is 43 % and the default bundle's
part ≈ 4 600. Everything is a plugin registered into three maps; the default bundle registers all
of them, so tree shaking is by hand-picking imports (`bundles/datastar-core.ts` registers none).

A program looks like this [doc, README]:

```html
<input data-bind:title />
<div data-text="$title.toUpperCase()"></div>
<button data-on:click="@post('/endpoint')">Save</button>
```

and the server answers `POST /endpoint` with `Content-Type: text/event-stream`:

```
event: datastar-patch-elements
data: elements <div id="feed"><span>1</span></div>

event: datastar-patch-signals
data: signals {"title": ""}

```

---

## 2. Under the hood

### 2.1 Attributes: a regex rewriter and `Function()`

**Parsing a key** [source, `engine.ts` `parseAttributeKey`]: `data-on:click__debounce.200ms`
splits on `__` into modifiers, on the first `:` into plugin name and key. Since v1.0.0-RC.6
(2025-10-21) the delimiter is `:`; before it was `-` (`data-on-click`) [doc, release notes].

**Compiling a value** [source, `engine.ts` `genRx`, lines 385–524]: for a plugin that returns a
value, the string is split into statements by a regex that knows strings, regex literals,
template literals and *a limited IIFE* ("no nested IIFEs"), the last statement gets
`return (…)`; then a second regex rewrites signal references (`$foo.bar-baz` →
`$['foo']['bar-baz']`) and action calls (`@get(` → `__action("get",evt,`), skipping string
literals and rewriting `${…}` only "when braces are non-nested". The result goes to
`compileExpression(['el','$','__action','evt',…], expr)` which is **`Function(...argNames,
expression)`** (`engine/csp.ts`). There is no tokenizer and no AST: what the regexes misjudge
(a `$` inside a nested template interpolation, a `;` inside a nested IIFE) is a run-time
`GenerateExpression` or `ExecuteExpression` error, reported with a link to
`data-star.dev/errors/…` (`engine/errors.ts`).

- **Compilation is lazy and per attribute instance**: `ctx.rx` compiles on first call and caches
  in a closure; outside CSP mode there is **no cache by source**, so 1 000 rows each carrying
  `data-on:click="@post('/x')"` compile 1 000 functions [source].
- **CSP**: `Function()` needs `unsafe-eval`. With `data-nonce` on `<html>`, CSP mode instead
  wraps each expression in a `<script nonce=…>` element appended to `<head>`, reads the function
  back from `document.currentScript.x`, and caches by source. The docs are explicit that this
  "does not make Datastar expressions safe to use with untrusted content. Datastar does not
  examine or sanitize expressions" [doc, *Security*] — any server template that interpolates
  user text into a `data-*` attribute is a script injection, and escaping it is the template's
  job.
- **Scope**: an expression sees `el`, `$` (the global signal root), `__action`, `evt` and the
  plugin's argument names — and, through `Function`, every global. Signals are one page-global
  namespace; there are no components and no lexical scope in the core.

### 2.2 Signals: alien-signals behind a deep Proxy

`engine/signals.ts` [source] is a port of **alien-signals**' algorithm, kept recognisable by its
identifiers (`AlienSignal`, `AlienComputed`, `AlienEffect`, `ReactiveFlags.RecursedCheck`):

- **Graph**: one `Link` per (dependency, subscriber) pair threaded into two intrusive doubly
  linked lists, with a version stamp; `link()` has the same three early exits research 27 §1.2
  read in Solid 2's `graph.ts`, which cites the same source. **It still has `isValidLink`**, the
  backwards walk over the subscriber's dependency list that Solid 2's comment calls "O(n²) when a
  computation re-reads earlier deps non-consecutively" and replaced with a generation check.
- **Propagation**: push-pull. A write marks direct subscribers `Dirty` and transitive ones
  `Pending` (`propagate`, iterative with an explicit stack), queues effects; a read of a
  `Pending` computed walks its dependencies (`checkDirty`) and recomputes only if one really
  changed. Equality is `!==`. Effects flush synchronously at the end of the outermost batch;
  every `data-on` handler runs inside `beginBatch/endBatch`.
- **The store** (`deep`, lines 565–678) wraps every object and array in a `Proxy` whose leaves
  are signals; reading a missing path **creates** it as `''` and dispatches a patch event;
  setting a property to `null` deletes it; array methods subscribe to a `keys` signal. Every
  change is collected as a `[path, value]` pair and dispatched as a `datastar-signal-patch`
  event (a JSON merge patch) at the end of the batch, which `data-on-signal-patch` listens to.
- **Wire semantics**: `mergePatch` is RFC 7386 JSON Merge Patch (`null` deletes). When an action
  fetches, the **whole store** is serialised as JSON and sent — in the body, or as
  `?datastar=` for `GET` — minus paths matching `/(^|\.)_/` (`fetch.ts`, `filterSignals`
  default) [source]. A signal whose name starts with `_` is client-only; everything else is a
  request parameter on every request.

**Against Solid and Preact** [estimate]: the graph is the same family as Solid 2's (both from
alien-signals) and Preact's (versioned push-pull); what differs is the surface — Datastar's
signals are created and named by attributes and server patches, read by string expressions, and
global. It is a reasonable signal core, not a new one.

### 2.3 The morph: idiomorph, ported

`plugins/watchers/patchElements.ts` [source] parses the fragment with
`DOMParser().parseFromString('<body><template>…</template></body>')` and, for modes `outer` and
`inner`, morphs it into the target. The algorithm is idiomorph's — the vocabulary is the same
(*id sets*, *soft match*, *pantry*, *persistent ids*, `moveBefore`), and the comments cite
morphdom and nanomorph for the input special cases:

1. Collect the ids under the old and new trees; an id is **persistent** if it occurs once in each
   with the same tag. Give every ancestor of a persistent element the set of persistent ids
   below it.
2. For each new child, scan forward over the old siblings (`findBestMatch`): an old node with an
   intersecting id set is a hard match; otherwise remember the first **soft match** (same node
   type and tag, and either no id or the same id); stop early if two later new siblings would
   soft-match first (a prepend heuristic) or if scanning would displace more persistent ids
   than the node holds.
3. A match is morphed in place (attributes synced, text set, children recursed unless
   `isEqualNode`); a persistent element found elsewhere is moved with `moveBefore` (state-keeping
   where the browser has it); nodes skipped over go to a hidden "pantry" if they will be matched
   later, otherwise are removed; an unmatched new node is `importNode`d.

**The quadratic case** [source + measured]: when the new rows all carry ids the old ones do not
(a replaced list), no node is persistent, no id-set match exists, and a soft match is refused
because "oldElt has an `id` … and it doesn't match" — so `findBestMatch` scans **every remaining
old sibling for every new one** and finds nothing. §4.3 measures it: in one scaling batch, 1 000 → 2 000 rows
is 452 → 1 939 ms, ×4.3 (the n = 10 table's median at 1 000 is 715 ms; the absolute values move
with the machine's load, the ratio is the claim). Unkeyed rows are linear (the first sibling soft-matches).

**What a morph costs even when nothing changed** [source]: the server's HTML is parsed into a
fresh DOM; every new node is compared with an old one (attribute by attribute, both directions);
`isEqualNode` is called on every matched element before recursing, which itself walks the
subtree. So the floor of every patch is proportional to the size of the *patch*, not of the
change — research 29 §6's verdict on the virtual DOM, with the browser's HTML parser and real
DOM nodes standing in for `h()` and vnodes.

After a morph, the engine's `MutationObserver` (`engine.ts` `observe`) sees added nodes and
scans each one and its descendants for `data-*` attributes, applying plugins and running
cleanups for removed ones; an attribute change on a `data-*` attribute re-applies that one
plugin. **This observer is the component lifecycle**: Datastar has no other.

### 2.4 Transport: SSE for every method

`plugins/actions/fetch.ts` [source] embeds a rewrite of Azure's `fetch-event-source` (the
licence note is in the file): `fetch()` with any method and a JSON or form body, the response
body read as a byte stream, split into SSE lines and events by hand, `Last-Event-ID` resent on
reconnect, `retry:` honoured, exponential back-off (1 s × 2 up to 30 s, 10 attempts), the
stream closed when the tab is hidden and reopened when visible (`openWhenHidden`, default
false for `GET`), and a new request on the same method and URL aborts the previous one
(`requestCancellation: 'auto'`). The response's `Content-Type` decides what happens:
`text/event-stream` → each `datastar-*` event becomes a `datastar-fetch` DOM event dispatched to
the matching watcher; `text/html` → one patch-elements with options from `datastar-*` response
headers; `application/json` → one patch-signals; `text/javascript` → a script executed.

The two events [doc, `sdk/ADR.md`]: `datastar-patch-elements` (data lines `selector`, `mode` ∈
outer/inner/replace/prepend/append/before/after/remove, `namespace` html/svg/mathml,
`useViewTransition`, then `elements …` lines) and `datastar-patch-signals` (`onlyIfMissing`,
`signals …`). v1.0.0-RC.1 renamed *merge* to *patch* and *fragments* to *elements* — "to better
reflect the non-idempotent nature of these operations" [doc, ADR]. Script execution, once a
third event, is now a `<script>` patched in as an element.

### 2.5 The SDKs

Each SDK is a `ServerSentEventGenerator` that sets the SSE headers, writes the events above in a
fixed field order and flushes, plus `ReadSignals(request)` that reads the JSON from the body or
the `datastar` query parameter [doc, `sdk/ADR.md`]; `sdk/tests` is a shared conformance suite.
They are thin by design. The server's real work — keeping state, re-rendering, fanning out to
streams (the docs' recommended pattern is a message bus such as NATS feeding each open stream)
— is the application's, in whatever language it is written.

### 2.6 What is not in the core

No templates on the client (the server renders), no list primitive (a list is HTML the server
re-sends; Rocket has a `for`), no routing, no component scoping (Rocket's web components add
it), no type checking of expressions or of the signal store, no hydration step (the page is
already HTML; the engine scans it). **Datastar Pro**, a paid commercial licence introduced with
v1.0.0-RC.1 (2025-07-10), holds further plugins — `data-persist`, `data-query-string`,
`data-on-resize`, `data-replace-url`, animation helpers and the like [doc, release notes]; Rocket
was Pro and became MIT with v1.0 ("There's no such thing as a Free Launch") [doc].

---

## 3. The philosophy, from its own documents

*The Tao of Datastar* [doc, `/guide/the_tao_of_datastar`], in its own words:

- "Most state should live in the backend. Since the frontend is exposed to the user, the backend
  should be the source of truth."
- "Since the backend is the source of truth, it should *drive* the frontend by **patching**
  (adding, updating and removing) HTML elements and signals."
- "Overusing signals typically indicates trying to manage state on the frontend."
- "In Morph We Trust": "only modified parts of the DOM are updated, preserving state and
  improving performance."
- "Compression ratios of 200:1 are not uncommon when compressing streams using Brotli."
- **CQRS**: "Commands (writes) and requests (reads) are segregated, making it possible to have a
  single long-lived request receive updates while making multiple short-lived write requests."
- "Rather than deceive the user with premature confirmations, use loading indicators and only
  confirm success from the backend" — no optimistic updates.

The **fat morph** is the pattern this adds up to [doc + reported]: on any change, the server
re-renders the whole page region (often `<main>` or `<body>`) and sends it all down the open
stream; the morph and the compression make the redundancy cheap. The essays argue the rest —
*Why another framework?* (htmx's and Alpine's plugins have no dependency management; in Datastar
"EVERYTHING is a plugin"), *Event streams all the way down* (SSE extended to every method),
*htmx sucks*, *Yes, you want a build step*, *Haikus*, *I'm a Teapot*, *Greedy Developer?* (the Pro
licence), *The Road to V1*, *V1 and Beyond* [doc, `/essays`]. None of the essays reached
contains a measurement.

**Version history** [doc, GitHub releases]: the repository dates from 2023-08-28 (it began as an
htmx-plus-Alpine replacement; *Why another framework?*); v0.19–v0.21 through late 2024;
v1.0.0-beta.1 (2025-01-02) brought back the `$signal` and `@action` sigils "honing our regex fu"
and replaced `@sse()` with per-method actions; RC.1 (2025-07-10) made objects in signals
reactive, introduced patch-elements/patch-signals and the Pro licence, and accepted
`text/html`/`application/json`/`text/javascript` responses; RC.6 (2025-10-21) changed the
attribute delimiter to `:` and renamed `data-on-load` to `data-init`; **v1.0.0 shipped
2026-04-16** ("We are done. Done like dinner") with Rocket rewritten as a JavaScript API; v1.0.4
on 2026-09-21. Six RCs over nine months, each with breaking changes, then a frozen core.

---

## 4. Measurements

All on an AMD Ryzen 9 5950X, Chrome 154 headless, Node 24, **unthrottled**, with a load average
of ≈ 22 on 32 threads from other work (so spreads are wide; medians only). Scripts in §9.

### 4.1 Bundle size [measured]

| bundle (`bundles/`, v1.0.4) | minified | gzip -9 | brotli -11 |
|---|---|---|---|
| `datastar-core.js` (engine + signals, no plugins) | 10 480 | 4 882 | **4 444** |
| `datastar.js` (the default) | 33 553 | 13 365 | **12 183** |
| `datastar-rocket.js` (+ web components) | 65 470 | 23 571 | **21 280** |

12 183 B = 11.90 KiB: the README's figure is brotli and is honest. For scale: research 73's
whole table app on `browser-direct --release` is 4 110 B brotli including its markup; the empty
mounted page on `browser` is 1.4 kB. Datastar is all-or-nothing per bundle: a page that uses one
attribute ships all 12 kB.

### 4.2 Wire bytes of a fat morph [measured]

One SSE stream, three `datastar-patch-elements` events each carrying the *whole* 1 000-row
js-framework-benchmark table as HTML (≈ 218 kB raw): the initial table, the same table with row
501 selected, then with every tenth label changed. Each event is flushed through one compressor
for the connection, as a compressing proxy or middleware does for SSE:

| compressor | event 1 | event 2 (select) | event 3 (update every 10th) |
|---|---|---|---|
| brotli q11, default 4 MiB window | 6 005 | **38** | **688** |
| brotli q5, 16 MiB window | 7 689 | 34 | 748 |
| gzip -9 (32 KiB window) | 8 318 | 7 972 | 8 247 |

For comparison, a targeted patch of just one row is 270 B raw, and the signals patch for "every
tenth label" is 2 492 B raw. **The claim is real and specific**: within a long-lived stream
compressed by a codec whose window holds the previous frame (brotli's default, zstd's with a
large window — the DBmon demo uses zstd), re-sending an unchanged page costs almost nothing on
the wire; 218 kB → 38 B is 5 700:1. It does not hold for gzip, nor across short-lived
responses (each restarts the window), nor for the server's CPU, which compresses 218 kB per
event (not measured here). And the bytes saved on the wire are paid for in the client (§4.3).

### 4.3 Client CPU of a morph, against vanilla [measured]

A page loading `datastar.js` v1.0.4; each operation is one `datastar-patch-elements` event of
the whole `<tbody id="tbody">` (rows keyed by `id="r…"`, js-framework-benchmark's markup),
dispatched in the page so no network is timed; *script* is from dispatch until the engine's
mutation-observer microtask has run, *+layout* adds a forced style and layout. Vanilla does the
same change by hand (`textContent`, `className`, two `insertBefore`, `remove`, `innerHTML` for
create/replace). Fresh page per sample, n = 10, median.

| operation | morph script | morph +layout | vanilla script | vanilla +layout |
|---|---|---|---|---|
| create 1 000 (into empty) | 67.6 | 135.8 | 45.5 | 106.7 |
| replace 1 000 (new ids) | **715.0** | 836.1 | 47.3 | 97.8 |
| update every 10th | 33.4 | 55.3 | 2.1 | 24.9 |
| select one row | 24.1 | 24.1 | 0.2 | 0.2 |
| swap rows 2 and 999 | 17.6 | 22.1 | 0.4 | 4.9 |
| remove one row | 15.6 | 19.6 | 0.3 | 5.2 |
| nothing changed | 15.2 | 15.2 | 0.0 | 0.1 |

All in ms; correctness was checked per sample (row count, the swapped ids, one `.danger` row,
first row kept by identity where it should be). A cleaner n = 3 batch earlier read replace 497
ms, update 22, select 20, nothing 14. Scaling of the replace and the floor, a **separate batch**
(n = 5 each, simpler two-cell rows, so its absolute values differ from the table above — 452 ms
against 715 for the keyed replace at 1 000, 11 ms against 15 for the floor; the ratios between
its own rows are what it shows):

| rows | replace, keyed (new ids) | same HTML again | replace, unkeyed |
|---|---|---|---|
| 250 | 56 | 9 | 14 |
| 500 | 156 | 13 | 60 |
| 1 000 | 452 | 11 | 100 |
| 2 000 | **1 939** | 25 | 181 |

And the client-reactive path, the one Datastar recommends using sparingly: 1 000 rows each
`<a data-text="$l.l42">`, then a `datastar-patch-signals` changing every tenth signal — **4.8 ms
script** (vanilla 2.1), but mounting those 1 000 bound rows costs **58 ms** of script, because
each `data-text` compiles its own `Function` and creates its own `MutationObserver` (to rewrite
text a third party changes; `plugins/attributes/text.ts`) [source].

**What this says** [estimate]: a fat morph puts a floor of ≈ 10–25 ms of main-thread script
under *every* update of a 1 000-row region, whatever changed, plus a quadratic cliff when a
keyed list is replaced. That is invisible at the scale of a form or a dashboard tile and decisive
at the scale of research 29's table. It is not "as fast as Solid" — research 29 measured Solid 2
and beni's compiled templates at a fraction of a millisecond of script for `select` — and
Datastar does not claim it is, in a number. Unthrottled; the official js-framework-benchmark
throttles some operations 4×.

---

## 5. The performance claims, sorted

Datastar's author posts as `sudodevnull` on HN and `u/opiniondevnull` on Reddit; its most
active outside advocate, Anders Murphy, is the source of most of the numbers. **Datastar has no
entry in js-framework-benchmark** (`frameworks/keyed` and `non-keyed` hold `alpine` and `solid`,
no `datastar` or `htmx`; no issue or PR there mentions it), and no third-party benchmark of its
client was found.

| claim | where | what it measures | verdict |
|---|---|---|---|
| "a single 11.90 KiB file" | home page, README | brotli bundle size | **holds** — 12 183 B (§4.1) |
| "The core is less than 250 lines"; "The core is < 4kb" | *V1 and Beyond*; [HN 45803358](https://news.ycombinator.com/item?id=45803358) | `engine.ts` | **dated** — `engine.ts` is 524 lines at v1.0.4; core bundle 4 444 B brotli (§4.1) |
| "40% smaller than htmx (when you include morphing)" | *V1 and Beyond*; [HN](https://news.ycombinator.com/item?id=45536000) | bundle size | plausible, not re-measured (htmx + idiomorph is a different feature set) |
| "Compression ratios of 200:1 are not uncommon … using Brotli" | *Tao of Datastar* | wire bytes of repeated HTML on one stream | **holds for brotli/zstd on a long-lived stream** — 5 700:1 on a repeat (§4.2); not for gzip |
| "one check is 13–20 bytes over the wire even though it's 140k of HTML" | Murphy, [HN 45544029](https://news.ycombinator.com/item?id=45544029), [45941631](https://news.ycombinator.com/item?id=45941631) | wire bytes | **holds** — same mechanism, 38 B here |
| "1000 concurrent users at 10 FPS on a 2 vCore shared VPS" | [Murphy, 2026-09-29](https://andersmurphy.com/2026/09/29/faster-streaming-html-with-batches-and-aggregates.html) | server throughput of one app | **reported**, one app, no client cost |
| "have the fastest signal implementation"; "BY FAR the fastest signal approach" | [HN 43657491](https://news.ycombinator.com/item?id=43657491), HN 45702558 | — | **rhetoric**: no benchmark published; the graph is alien-signals' (§2.2), so at best it equals alien-signals, which Solid 2 also builds on |
| "looking like over 2x faster than idiomorph" | [HN 43657491](https://news.ycombinator.com/item?id=43657491) | morph | **unbacked**; the v1.0.4 morph is idiomorph's algorithm (§2.3) and has its quadratic replace (§4.3) |
| "updates in microseconds above half RTT" | HN 45845582 | client apply time | **false at scale**: a 15 ms floor for a 1 000-row region (§4.3); true for a small fragment |
| "it can do ANYTHING that React, Vue, or Svelte can do, faster and with less code" | *The Road to V1* | — | **rhetoric**, no data |
| "In Morph We Trust … improving performance" | *Tao of Datastar* | — | **half**: a morph keeps DOM state; against a targeted write it is slower by 1–2 orders of magnitude (§4.3) |
| DBmon "10x the rows" works locally; Bad Apple at 30 fps | [examples](https://data-star.dev/examples/dbmon) | a frame rate on a demo | demos, no method |

**So**: the measured claims are about **bytes** — of the bundle and on the wire — and those hold.
The claims about **client speed** ("fastest signals", "faster than idiomorph", "microseconds",
"faster than React") come without a benchmark and the ones that can be tested here do not hold
in general. The architecture's real performance argument is different and is sound in its
domain: the server does the work once, the client applies a patch, and compression makes
redundancy free on the wire; for a page whose updates touch a few hundred nodes, a 10–20 ms
morph is below what a user perceives. The cost moves to the network round trip (every
interaction waits for the server, by design: no optimistic updates) and to the server's CPU.
The one counter-measurement in public — the site's TodoMVC "is slow and doesn't work correctly"
during the April 2025 HN surge ([HN 43656843](https://news.ycombinator.com/item?id=43656843)),
blamed by the author on a free Fly.io instance ([43657466](https://news.ycombinator.com/item?id=43657466))
— is that cost showing.

---

## 6. What practitioners say

Found through the `hackernews` skill (Algolia), Reddit archives and the posts they link. The two
big HN threads are Chris May's "Why I switched from htmx to Datastar" (2025-10-09, 315 points,
380 comments, [45536000](https://news.ycombinator.com/item?id=45536000)) and Chris Malek's first
impressions (April 2025, 255 points, [43655914](https://news.ycombinator.com/item?id=43655914)).

**Where it shines** [reported]:

- One library instead of htmx + Alpine: "With Datastar, I regularly use just one attribute"
  ([May](https://everydaysuperpowers.dev/articles/why-i-switched-from-htmx-to-datastar/)).
- The mental model for back-end developers: "re-render HTML on server, then just display it is
  refreshingly simple" ([Threadgold, coming from React](https://threadgold.nz/writing/datastar-coming-from-react));
  "I use it professionally for full stack go webapps. Absolutely rock solid"
  ([r/programming](https://www.reddit.com/r/programming/comments/1vagopa/)); David Nolen rebuilt
  Instabooks on it and calls it "the best tool that I've added to the web technology stuff that I
  do in at least 12 years" ([essay](https://data-star.dev/essays/datastar_its_pretty_good)).
- Real-time, multi-user pages from a plain server: Murphy's Game of Life and One Billion
  Checkboxes in Clojure with no ClojureScript
  ([post](https://andersmurphy.com/2025/04/07/clojure-realtime-collaborative-web-apps-without-clojurescript.html),
  [HN 43975375](https://news.ycombinator.com/item?id=43975375)).

**Criticism and failure stories** [reported]:

- **The Pro licence dominates every thread.** Features that had been free (`data-replace-url`,
  `data-scroll-into-view`, `data-persist`, `data-query-string`, the Inspector) moved behind a
  commercial licence at RC.1 — $349 solo, $1 299 for teams, "making the software available in a
  public repo … is strictly prohibited" ([Pro page](https://data-star.dev/reference/datastar_pro)).
  A clinic's developer whose site used two of them: "What the fuck", later "an emotional
  product" ([drshapeless](https://drshapeless.com/blog/posts/htmx,-datastar,-greedy-developer.html));
  Simon Willison: "it has a chilling effect on open source contributions"
  ([45538503](https://news.ycombinator.com/item?id=45538503)). The author: the plugins are
  "anti-patterns and support burdens" ([45540044](https://news.ycombinator.com/item?id=45540044));
  the reply: "Wait so you pay to use the anti patterns?"
  ([45543773](https://news.ycombinator.com/item?id=45543773)). The project's answer is *Greedy
  Developer?*.
- **Tone**: several commenters describe the author's replies as abrasive
  ([45537119](https://news.ycombinator.com/item?id=45537119),
  [45544782](https://news.ycombinator.com/item?id=45544782),
  [r/htmx](https://www.reddit.com/r/htmx/comments/1o4orwo/)); the author's own line: "We don't
  shy away from telling you your ideas are terrible"
  ([45539942](https://news.ycombinator.com/item?id=45539942)).
- **`unsafe-eval`**: "a gaping hole in one's Content-Security-Policy"
  ([43656944](https://news.ycombinator.com/item?id=43656944)), "the reason I didn't try out
  DataStar" ([43660084](https://news.ycombinator.com/item?id=43660084)); the author called CSP
  "mostly a red herring" ([43668413](https://news.ycombinator.com/item?id=43668413)); an opt-in
  nonce mode arrived in v1.0.3 (2026-08-27) — and still does not sanitise.
- **Latency**: "is this yet another framework where every click is a server round trip?"
  ([43659762](https://news.ycombinator.com/item?id=43659762)); bad connections give "a
  significantly more degraded user experience" ([45537330](https://news.ycombinator.com/item?id=45537330));
  no offline story ([45547465](https://news.ycombinator.com/item?id=45547465)). Murphy: "Try my
  demo on 3G slow. It works fine" ([45547477](https://news.ycombinator.com/item?id=45547477)).
- **Server cost and coupling**: hosting cost of server-side state
  ([45538014](https://news.ycombinator.com/item?id=45538014)); "having the backend aware of the
  IDs in the HTML leads to pain" ([45539073](https://news.ycombinator.com/item?id=45539073));
  the render function "needs to be fast since it's going to get called a bunch of times"
  ([Biff](https://biffweb.com/p/understanding-datastar/)).
- **Developer experience**: signal names with `.` or `/` break on the kebab/camel rules, an RC
  wire change was "quite a laborious update" ([45544553](https://news.ycombinator.com/item?id=45544553));
  testing without end-to-end tests is unclear ([43660562](https://news.ycombinator.com/item?id=43660562));
  SSE events apply one at a time, so a dashboard's cards arrive in order
  ([r/htmx](https://www.reddit.com/r/htmx/comments/1phpowr/)); HTTP/1.1's six connections per
  origin are handled by closing hidden tabs' streams, "you should really use http2"
  ([43651531](https://news.ycombinator.com/item?id=43651531)).

Nobody reported a production failure caused by the morph or the signals; the failures people
report are licensing, trust, CSP, round-trip latency, and breaking changes during the RCs.

---

## 7. Against htmx, Alpine, LiveView, Hotwire and Solid

| | where state lives | what the server sends | how the client applies it | client reactivity | transport |
|---|---|---|---|---|---|
| **htmx** | server | an HTML fragment per request | swap into a target (`innerHTML` etc.); morph by extension (idiomorph) | none (Alpine alongside) | request/response; SSE and WebSocket by extension |
| **Alpine** | client | — | — | `x-data` objects made reactive; expressions in attributes (`Function`, or a parser in its CSP build) | — |
| **Turbo / Hotwire** | server | pages, frames, and Turbo Stream actions (`append`, `replace`, …) | swap; Turbo 8 "page refresh with morphing" uses idiomorph | Stimulus controllers (hand-written JS) | request/response; streams over SSE or WebSocket |
| **Phoenix LiveView** | server, one process per connected page | only the **dynamic parts** that changed — HEEx compiles a template into statics and dynamics, and the server tracks changed assigns | morphdom over the reassembled HTML | `JS` commands, hooks | WebSocket |
| **Datastar** | server, by doctrine | whole HTML regions (the fat morph) or JSON merge patches of signals | idiomorph port; signal effects | global signal store, expressions in attributes (`Function`) | SSE over `fetch`, any method |
| **Solid 2** | client | — | compiled templates, per-hole effects | signals (alien-signals lineage) | — |

[doc + estimate. The LiveView row was checked for this report: its guide *Assigns and HEEx
templates* says a first render sends "all of the static and dynamic parts", later renders
"won't resend the static parts and it will only resend the dynamic part if it changes", and
"the tracking of changes is done via assigns"; its client imports `morphdom`
(`assets/js/phoenix_live_view/dom_patch.ts`, `main` at `a7f3538`). The htmx, Alpine and Turbo
rows are from those projects' documentation as remembered, not re-read.] Carson Gross, htmx's author: "data-star isn't a successor to htmx,
it's a pretty different take on hypermedia, using SSE for a streaming, dynamic hypermedia driven
system" ([HN 42312746](https://news.ycombinator.com/item?id=42312746)) and it "combines ideas of
htmx & solid (signals)" ([41734456](https://news.ycombinator.com/item?id=41734456)). Commenters
also name Meteor, RJS, ASP.NET WebForms and Seaside as precedents.

**What is new, and what is repackaged** [estimate]:

- **New**: treating SSE as the *universal* response format — any method, any number of events,
  `Content-Type` choosing between stream, fragment, JSON and script — with a two-event protocol
  small enough to implement in any language in an afternoon (the SDK conformance suite makes
  that real); and the **doctrine** that a long-lived compressed stream makes re-sending whole
  regions cheap, so the server needs no diffing. LiveView diffs on the server because its
  transport is not cheap for redundancy; Datastar moves the diff to the client (the morph) and
  lets brotli erase the redundancy on the wire. That trade is the one idea here that is
  Datastar's own, and §4 prices both sides of it.
- **Repackaged**: idiomorph (htmx's morph, also Turbo 8's), alien-signals, Azure's
  `fetch-event-source`, Alpine's expression attributes, htmx's hypermedia argument, LiveView's
  server push. Combining them in 12 kB with one attribute grammar is good engineering; it is not
  a new algorithm.
- **Against Solid**: Solid compiles JSX into templates and per-hole effects; Datastar interprets
  attribute strings at run time and re-parses server HTML. They share a signal graph and nothing
  else; "a lighter take on SolidJS with no build step", a home-page testimonial, is true only of
  the signals.

---

## 8. What it means for beni

beni is a typed language whose browser platforms compile `view` into templates (`browser`,
`browser-tea`) or compile the framework away using write sets (`browser-direct`), whose model
lives in the client under TEA, and which promises no runtime errors (CLAUDE.md rules 7–9).
Datastar is an untyped runtime whose model lives on the server. The overlap is therefore not
in the client runtime but in **the server–client boundary** — something beni has no platform for
today. Verdicts, most useful first.

### 8.1 A server-driven platform — **adapt**, with compile-time patches instead of a morph

**The idea**: the TEA loop runs on the server (beni's `node` platform already renders a view to
HTML with `Node.print (Ssr.render (view model))`, `backend.md` §15.6); the browser holds a thin
client that forwards events and applies patches pushed down one stream. That is Datastar's and
LiveView's architecture, and it is what a beni program would need for multi-user, real-time
pages with state the client must not hold.

**What beni would do differently, and why it would be better** [estimate]: Datastar re-sends
HTML and morphs because it knows nothing about what changed; LiveView knows which assigns
changed at run time and which template parts read them at compile time. **beni knows both at
compile time**: a message key's write set (`write-sets.md`) and each hole's read set
(`browser-direct.md` §1) are exactly the information that decides which holes a message can
change. So the server can send, per message, the *values of the holes that changed*, addressed
by slot number — `browser-direct`'s handler with its DOM writes replaced by "append (slot,
value) to the frame" — and the client applies them with `browser-direct`'s own writes, with no
parse, no morph and no quadratic case. The frame for "select one row" is a slot number and a
class string; Datastar's is 218 kB of HTML compressed to 38 B on the wire and 24 ms on the
client (§4). The wire would still go through brotli on one long-lived stream (§8.2), so small
frames get smaller still.

**What it conflicts with**: rule 9 and the "no runtime errors" promise must be carried across a
network — a dropped stream, a reconnect, a server restart, a patch for a page version the
client no longer shows are each a *typed* condition the program sees (as `Http`'s failures are),
not a retry loop that hides them. Datastar's `create` in `fetch.ts` (lines 683–692) ends in a
bare `catch {` that calls `retryRequest()` for **every exception that is not an abort** — a
`fetch` network `TypeError`, a stream read failure, a failure in `onopen` or in reading a
`text/html` or `application/json` body — without naming any of them. (A watcher's own errors do
not reach it: events are applied through `dispatchEvent`, which reports a listener's exception
as uncaught instead of throwing it to the dispatcher.) HTTP statuses are handled before it, not
by it. That is the shape rule 9 forbids: a catch that names nothing and keeps going, so an
unanticipated failure becomes a silent reconnect, up to ten times. Every interaction pays a round trip, which is the
opposite of "browser first" for interactive pages; Datastar's own answer — "no optimistic
updates" — is a choice beni need not inherit, since a split platform could run some keys on the
client (the keys whose write sets touch only client-owned paths) and the rest on the server.

**Recommendation**: not now. It is a new platform (rule 6: platforms own lowering), larger than
`browser-direct`, for a use beni has no user asking for yet. If the owner wants server-driven
pages, the design to specify is "write-set frames over SSE", not "HTML + morph", and the first
measurement is §4.3's table with the frame-applying client against Datastar and LiveView.

### 8.2 One compressed long-lived stream — **adopt as a note**: a measured fact, no design change

Any beni protocol that streams updates — a server platform (§8.1), an `Http` streaming
subscription, a dev server pushing rebuilt modules — should keep **one connection with one
compression context** (brotli or zstd with a window larger than a frame) rather than many short
responses. §4.2 measured why: repeated content costs bytes only once per connection. It also
argues against inventing a binary delta format before measuring plain text through brotli. No
design change; a line for whoever specifies such a protocol.

### 8.3 SSE over `fetch` for any method — **adapt** into the effect library, typed

The `browser-tea` platform has `Http`, `Time`, `Dom` and window events (`boundary.md` §9.1,
§9.8). A typed event-stream subscription — `fetch` with any method and body, the response read as
SSE, `Last-Event-ID` on reconnect, the server's `retry:`, closing while the page is hidden — is a
capability users of a browser language will want, and Datastar's `fetch.ts` is a compact
checklist of what it must handle. What beni must do differently is rule 9: each documented
failure (`TypeError` from `fetch` for a network error, an `AbortError`, a non-2xx status, a wrong
`Content-Type`, a malformed event) becomes its own constructor of a typed error delivered as a
message, and reconnection is a policy the program chooses, not a hidden catch-all retry. The
messages a stream delivers are decoded with a `schema` (`schema.md`), so a malformed server
payload is a typed failure, never an `undefined` in the model. **Adapt**, as a `browser-tea`
subscription; priority low until a program asks for it.

### 8.4 Server HTML as the page, with no hydration step — **confirms** a direction, nothing to take

Datastar never hydrates: the server's HTML is the page, and the engine scans it for attributes.
beni's open question W22 (hydration) and `browser-direct`'s "page is one HTML string per mount,
holes reached once at mount" are already the compiled form of that: research 73 measured the
table app with its markup in the HTML at 3 898 B. Datastar's scan of every element for
`data-*` attributes at load and on every mutation is the run-time price beni's compiler avoids
by knowing the holes' paths. Nothing to adopt; a data point that "the server's HTML is the page"
works for real applications.

### 8.5 The signal core — **reject** as prior art; it is Solid 2's graph at an older revision

§2.2: alien-signals' push-pull graph, with the `isValidLink` walk Solid 2 replaced. Research 27
and 29 already priced this family (≈ 20 ns per tracked read, of which ≈ 7 ns bookkeeping) and
research 58–73 replaced it with write sets, which know at compile time what a message writes —
the one fact a run-time read graph can never have. Datastar adds a global, string-addressed
store and JSON-merge-patch semantics, which beni's typed model does not want.

### 8.6 The morph — **reject** as a rendering strategy

It is research 29 §6's virtual DOM with the browser's parser in place of `h()`: cost proportional
to the patch, not the change (15 ms for a 1 000-row region that did not change), and
quadratic when keyed rows are replaced (§4.3). beni's lists have keys and edit tags
(`browser-direct.md` §6), so the id-set heuristics solve a problem beni does not have. If beni
ever needs to patch foreign server HTML into a page (an interop corner), a morph would be a
library inside the wall, not a platform's rendering.

### 8.7 The attribute expression language — **reject**

JavaScript in strings, rewritten by regexes and compiled with `Function()` at run time, against
one global untyped store: it conflicts with every beni guarantee — types, exhaustiveness,
`foreign` as the only door to JavaScript (rule 6), a strict CSP by default, and no runtime
errors (a mistyped `$sigal` silently creates `''`, §2.2). beni's JSX is checked and compiled;
nothing here improves it.

### 8.8 Doctrine worth quoting, not adopting

"The backend is the source of truth", "no optimistic updates", CQRS with one read stream: each is
a sound default for the apps Datastar targets and none is a language question. A beni program
on a server platform could follow them; a beni program on `browser-tea` keeps its model in the
client by design. Nothing to decide.

---

## 9. Method and scripts

The scripts lived in a scratch directory and are not committed (the brief: no code outside this
report); what they do is stated here precisely enough to rebuild them.

- **Sizes** (§4.1): Node's `zlib` on the release files in `bundles/` at `1efcdc3` —
  `gzipSync(level 9)`, `brotliCompressSync(quality 11)`, default window.
- **Wire** (§4.2): the js-framework-benchmark row markup (`<tr id="r…"><td class="col-md-1">…`,
  its label generator with a fixed seed), wrapped as `event: datastar-patch-elements\ndata:
  elements <tbody id="tbody">…</tbody>\n\n`; three events written to one
  `zlib.createBrotliCompress` (or `createGzip`) stream, each followed by a flush, and the bytes
  emitted per event counted.
- **Client** (§4.3): a page serving `bundles/datastar.js` as a module from a local HTTP server,
  driven by `bench/ui/lib/cdp.mjs`'s `launch` and `newPage` (used read-only; the harness's
  subjects were not touched), Chrome 154 with the harness's official flags, unthrottled, a fresh
  page per sample. Each sample first patches the initial table and waits a timer tick (so
  plugins and the mutation observer are idle), then times
  ```js
  const t0 = performance.now();
  document.dispatchEvent(new CustomEvent("datastar-fetch", { detail: {
    type: "datastar-patch-elements", el: document.body, argsRaw: { elements: html } } }));
  await Promise.resolve();                 // the engine's MutationObserver callback has run
  const script = performance.now() - t0;
  document.body.offsetHeight;              // forced style + layout
  const total = performance.now() - t0;
  ```
  which is exactly what `fetch.ts` does for each SSE event after parsing it. Vanilla's
  operations are timed the same way. The signals case patches `{l: {l1: …, …}}` into the store,
  morphs in 1 000 rows of `<a data-text="$l.l…">`, then times one `datastar-patch-signals`.
  Correctness: row counts, the swapped rows' ids, the single `.danger` row and the first row's
  identity were returned with every sample and checked.
- **What this is not**: not js-framework-benchmark's click-to-paint trace (research 29 §1), not
  throttled, and taken on a loaded machine (load average ≈ 22 on 32 threads), so the spreads are
  wide — `replace` 456–1 058 ms at n = 10. Medians and the scaling ratio (×4.3 for ×2 rows) are
  the claims; a single number is not. It took ≈ 6 minutes in all.

---

## Sources

Code (shallow clone, `starfederation/datastar`, branch `develop`, commit
`1efcdc3cb336ec3e9139491604e770e0329657bc` = v1.0.4):

- `library/src/engine/engine.ts` (plugin registry, `MutationObserver`, `parseAttributeKey`,
  `genRx`) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/engine/engine.ts
- `library/src/engine/csp.ts` (`Function()`, the nonce mode) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/engine/csp.ts
- `library/src/engine/signals.ts` (alien-signals graph, `deep` Proxy store, merge patch, `filtered`) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/engine/signals.ts
- `library/src/plugins/watchers/patchElements.ts` (patch modes, the morph) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/plugins/watchers/patchElements.ts
- `library/src/plugins/watchers/patchSignals.ts` — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/plugins/watchers/patchSignals.ts
- `library/src/plugins/actions/fetch.ts` (SSE over `fetch`, retry, content types) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/plugins/actions/fetch.ts
- `library/src/plugins/attributes/text.ts`, `on.ts`, `signals.ts`, `computed.ts` — https://github.com/starfederation/datastar/tree/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/plugins/attributes
- `library/src/rocket/` (web components; `runtime.ts` morphs each render) — https://github.com/starfederation/datastar/tree/1efcdc3cb336ec3e9139491604e770e0329657bc/library/src/rocket
- `bundles/` (the measured release files) and `sdk/ADR.md` (the SDK specification) — https://github.com/starfederation/datastar/blob/1efcdc3cb336ec3e9139491604e770e0329657bc/sdk/ADR.md
- Release notes, v0.19 – v1.0.4 (`gh api repos/starfederation/datastar/releases`) — https://github.com/starfederation/datastar/releases
  (v1.0.0-beta.1, RC.1, RC.6, v1.0.0 quoted)

The project's site:

- *The Tao of Datastar* — https://data-star.dev/guide/the_tao_of_datastar
- *Security* — https://data-star.dev/reference/security
- *Datastar Pro* — https://data-star.dev/reference/datastar_pro
- Essays index — https://data-star.dev/essays ; *Why another framework?* —
  https://data-star.dev/essays/why_another_framework ; *Event streams all the way down* —
  https://data-star.dev/essays/event_streams_all_the_way_down ; *The Road to V1* —
  https://data-star.dev/essays/the_road_to_v1 ; *V1 and Beyond* —
  https://data-star.dev/essays/v1_and_beyond ; *Greedy Developer?* —
  https://data-star.dev/essays/greedy_developer ; *There's no such thing as a Free Launch* —
  https://data-star.dev/essays/theres_no_such_thing_as_a_free_launch ; *Datastar – It's Pretty
  Good* — https://data-star.dev/essays/datastar_its_pretty_good
- Examples — https://data-star.dev/examples/dbmon , https://data-star.dev/examples/bad_apple
- Delaney Gillilan, *Real-time Hypermedia*, Big Sky Dev Con, 2024-10-05 —
  https://www.youtube.com/watch?v=0K71AyAF6E4 ; *Put State in the Right Place*, 2026 —
  https://www.youtube.com/watch?v=W7Ki3aXgmZU ; v1.0 launch podcast —
  https://youtu.be/T6uwri94ylk (not transcribed for this report)

Practitioners:

- Anders Murphy, "Why you should use Brotli SSE", 2025-04-15 — https://andersmurphy.com/2025/04/15/why-you-should-use-brotli-sse.html
- Anders Murphy, "Clojure realtime collaborative web apps without ClojureScript", 2025-04-07 — https://andersmurphy.com/2025/04/07/clojure-realtime-collaborative-web-apps-without-clojurescript.html
- Anders Murphy, "Faster streaming HTML with batches and aggregates", 2026-09-29 — https://andersmurphy.com/2026/09/29/faster-streaming-html-with-batches-and-aggregates.html
- Chris May, "Why I switched from htmx to Datastar", 2025-10-09 — https://everydaysuperpowers.dev/articles/why-i-switched-from-htmx-to-datastar/
- Chris Malek, "Datastar first impressions" — https://chrismalek.me/posts/data-star-first-impressions/
- Thomas Threadgold, "Datastar, coming from React", 2025-11-03 — https://threadgold.nz/writing/datastar-coming-from-react
- Jacob O'Bryant, "Understanding Datastar", 2026-10-01 — https://biffweb.com/p/understanding-datastar/
- drshapeless, "htmx, datastar, greedy developer" — https://drshapeless.com/blog/posts/htmx,-datastar,-greedy-developer.html

Hacker News (via the `hackernews` skill): stories
[45536000](https://news.ycombinator.com/item?id=45536000),
[43655914](https://news.ycombinator.com/item?id=43655914),
[47801419](https://news.ycombinator.com/item?id=47801419),
[45553033](https://news.ycombinator.com/item?id=45553033); comments
[41734456](https://news.ycombinator.com/item?id=41734456),
[42312746](https://news.ycombinator.com/item?id=42312746),
[43651531](https://news.ycombinator.com/item?id=43651531),
[43656843](https://news.ycombinator.com/item?id=43656843),
[43656944](https://news.ycombinator.com/item?id=43656944),
[43657466](https://news.ycombinator.com/item?id=43657466),
[43657491](https://news.ycombinator.com/item?id=43657491),
[43659762](https://news.ycombinator.com/item?id=43659762),
[43660084](https://news.ycombinator.com/item?id=43660084),
[43660562](https://news.ycombinator.com/item?id=43660562),
[43668413](https://news.ycombinator.com/item?id=43668413),
[43975375](https://news.ycombinator.com/item?id=43975375),
[45537119](https://news.ycombinator.com/item?id=45537119),
[45537330](https://news.ycombinator.com/item?id=45537330),
[45538014](https://news.ycombinator.com/item?id=45538014),
[45538503](https://news.ycombinator.com/item?id=45538503),
[45539073](https://news.ycombinator.com/item?id=45539073),
[45539942](https://news.ycombinator.com/item?id=45539942),
[45540044](https://news.ycombinator.com/item?id=45540044),
[45543773](https://news.ycombinator.com/item?id=45543773),
[45544029](https://news.ycombinator.com/item?id=45544029),
[45544553](https://news.ycombinator.com/item?id=45544553),
[45544782](https://news.ycombinator.com/item?id=45544782),
[45547465](https://news.ycombinator.com/item?id=45547465),
[45547477](https://news.ycombinator.com/item?id=45547477),
[45941631](https://news.ycombinator.com/item?id=45941631).

Reddit: https://www.reddit.com/r/htmx/comments/1o4orwo/ ,
https://www.reddit.com/r/htmx/comments/1phpowr/ ,
https://www.reddit.com/r/programming/comments/1vagopa/ ,
https://www.reddit.com/r/datastardev/comments/1lxhdp9/ .

Measurement: js-framework-benchmark's `frameworks/keyed` and `frameworks/non-keyed` (no
Datastar entry) — https://github.com/krausest/js-framework-benchmark

In this repository: research 27 §1.2 (alien-signals in Solid 2), 29 §6 (the virtual DOM priced),
58–73 (write sets and `browser-direct`), `browser-direct.md` §1, §6; `write-sets.md`;
`backend.md` §15.6 (the `ssr` lowering); `boundary.md` §9.1, §9.8; `schema.md`;
`plans/browser-decisions.md` W22.

Not reached: transcripts of Gillilan's talks and the v1.0 podcast; htmx's, Alpine's and Turbo's
sources (§7's rows for them are from their documentation as remembered; LiveView's row was checked); the
server-side CPU of compressing a fat morph.
