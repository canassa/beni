# 104 — Why Conduit's own code is big: views and update, construct by construct

*2026-10-15. Research only. Beni master `6508aeb3f0915dd48265d65e2190a7f2409d30d8`,
compiled ReleaseFast (output is the safe build's, rule 5); Node 24.19.0, Terser 5.51.2;
x86-64 Linux, heavy steps pinned to cores 8–23; azathoth was not used. Read after
[99](99-direct-bytes.md), [101](101-conduit-byte-floor.md) and
[102](102-beni-output-size.md). 100–102 exist and PR #153 claims 103.
Measurements and scripts: [`bench/app-code-size/`](../../../bench/app-code-size/README.md).
The Solid reference is research 101's adjusted single-chunk RealWorld build (Solid 1.3.3).*

## 0. Answer

**Beni's views are big because every view is written twice: once to build the
page and once to re-check it on every render, with the bookkeeping that
re-checking needs kept as fields of an instance record. Solid writes a
component once and lets a few accessor callbacks re-run.** The HTML is not the
problem (beni's strings cost 1.3 kB, Solid's 1.1 kB), nor are walks, writes
and events, which cost about what Solid's do. Calls of helpers and components
cost less in beni (485 B against 1,035, since a call has no prop getters), but
only because the kind each helper call makes is counted under scaffolding.
Two groups make the
whole tea gap: **re-render bookkeeping** (guards, kept values, restates, liveness)
and **kind scaffolding** (a mount function, a patch function and an instance record per
markup site). On direct, a third group comes on top and outweighs both: the
**parameterised-template protocol** (consumer masks, group descriptors, path IDs,
context capture, handlers and their dispatcher).

The account below deletes every byte of one construct from the shipped
response and recompresses; the rows of an area add up exactly to the area's
cost (§1). Schemas are left out, as asked. On this master the areas cost:

| Area (brotli, deletion account) | tea | direct | Solid |
|---|---:|---:|---:|
| views (markup; direct's `main`) | 7,602 | 12,798 | 4,825 |
| update / init / requests (and view wrappers) | 4,751 | 4,636 | 1,944 |
| **app without schemas, both areas deleted together** | **12,403** | **17,526** | **6,872** |

These are research 102's two areas on the current master, priced by deleting
bytes rather than stubbing units, which is why they differ slightly from 102's
7.4 / 12.4 kB and 5.1 kB (§1.2). The rows do not add up: each is priced with
everything else in place, and deleting both areas together costs 50 B more
than the sum on tea and 92 B more on direct (Solid: 103 B), which is
compression context, not a missing construct.

**The causes, ranked by bytes** (ordered account, §3–§4; "gap" is beni minus
Solid's equivalent construct):

| # | Cause | tea | direct | Solid's equivalent | gap (tea / direct) |
|---|---|---:|---:|---:|---:|
| 1 | Direct's parameterised-template protocol: consumer matrix, group descriptors, path IDs, context capture, entries, handlers, dispatcher, root selector, mount | — | 5,278 | none (a reactive graph at run time) | — / +5,278 |
| 2 | Re-render bookkeeping: group and hole guards, kept-value initialisers, restates, liveness, blocks and slot placements per render | 2,197 | 1,616 | render effects 417 | +1,780 / +1,199 |
| 3 | Kind scaffolding: mount and patch shells, instance records' node and slot fields, slot creation, static kinds, input prologues | 1,530 | 2,270 | `insert` calls 283 | +1,247 / +1,987 |
| 4 | Update's TEA plumbing: message constructors, dispatch on tags, commands, `Model × Cmd` pairs, record spreads | 1,674 | 1,543 | store setters and actions, inside 1,060 | ≈ +0.6 to +1.7 kB |
| 5 | The rest of update/init/requests: control flow, strings (typed error and validation messages), requests and routes | 3,077 | 3,093 | agent 514, router 370 | ≈ +2.2 kB |
| 6 | HTML template strings and their constants | 1,452 | 1,523 | 1,140 | +312 / +383 |
| — | At par or smaller in beni: walks (431 / 281 vs 437), values and writes (1,016 / 836 vs 966), helper/component calls and lists (485 / 513 vs 1,035), events and message values in views (491 / 481 vs 547) | | | | −562 / −874 |

Rows 4 and 5 are not a clean split of the same job: Solid's handlers live in its
components (its *views* row) and its pages do less (101 §1's feature table), so
the logic gap is a range, not a figure.

**Two things are not causes.** *Minification*: Terser takes 273 B from tea's
views and 210 B from its update/init/requests (about 4%); the suspected weaker
minification of update code is real but small (§5.2). *Repetition, as such*:
brotli prices a shape that the bundle repeats almost to nothing. Sharing every
identical template cloner and static kind saves 16 B alone (§6.1; 179 B once
the other kinds no longer share their shape, so what is cheap depends on what
else is there), and a view's own generated units cost little at the margin:
the feed preview's 2,549 raw bytes take only 298 B out of the response when
deleted alone (§6.3). The bytes are in
what *differs* from site to site: field names like `g3_2`, two- and three-letter
top-level names (975 references in tea's views cost 1,076 B, Solid's 420 cost
328 B), and per-site shapes (§5.1).

**What a Solid-like encoding would weigh.** Four uniform rewrites of the tea
bundle, each kept only if Conduit's three corpus scripts still produce the
golden transcript, were stacked (§6.1):

| Executable rewrite of every tea view | alone | its step in the stack | stacked | bundle |
|---|---:|---:|---:|---:|
| one test per hole (drop the hole test nested in a group test, and its field) | −208 | −208 | −208 | 31,401 |
| kept values, nodes and slots as closure locals, one shared `p` | −210 | −197 | −405 | 31,204 |
| one cloner per distinct template, one factory for static kinds | −16 | −179 | −584 | 31,025 |
| static liveness (Conduit has no live markup: no restates, no `l`) | −254 | −277 | −861 | 30,748 |
| … then Terser | | −662 | −1,523 | 30,086 |

That is **−0.86 kB, 11% of tea's views**, at the same semantics, plus Terser's
0.66 kB on top. It leaves tea's views near 6.7 kB against Solid's 4.8 kB. The
remaining 1.9 kB is the part of TEA a byte-level re-encoding cannot remove: a
view that runs again must test every input path it reads (Solid's components
read most props once and wrap only reactive reads), and every handler's
message is a value with a tag, built in the view and dispatched in `update`.
Closing that needs knowing, at compile time, which paths no message can write.
That is direct's write-set analysis, whose current encoding costs more than it
removes (§3.2). A one-off hand-written Solid-style preview, by contrast, made
the bundle **165 B larger** (§6.3). One rewrite proves little, but its
mechanism (a unique encoding pays its first-instance price) suggests pricing a
redesign applied to every view, not one view at a time.

## 1. Method

### 1.1 Builds and accounts

`bench/app-code-size/build.mjs` builds `examples/conduit/src` with
`--release --no-cache` on both platforms, plain and with `--source-maps`,
requires the mapped JavaScript minus its trailer to equal the plain build, and
archives both (tea 31,609 B, direct 38,175 B; 102 measured 31,745 / 38,243 on
`d10749f70`). Sizes follow research 97–102: the one `_main.mjs` response,
brotli 11 with the size hint.

**Painting.** `classify.mjs` gives every byte of the app's two areas a
construct. The areas are 102's: *views* are the generated markup units
(`tN`, `kN`, `pN`, `bN`, direct's `dgN_M`, `dpN_M`, `drN_M`) and direct's
`main`; *logic* is every other app unit outside the schemas (update and init,
view functions, requests, routes, helpers). Inside a unit, a byte belongs to the
innermost AST node a rule claims (a `template(…)` call, a `firstChild` chain, an
`if` whose test reads `a.g…`, an object literal starting `{$:`…), else to the
unit's default (its shell). Calls are resolved with scope, so a local `m` is
never taken for core/Task's top-level `m`. `show.mjs` prints any unit with its
bytes bracketed by construct; every class was checked that way on the views
quoted in §2.

**Pricing.** `account.mjs` deletes all bytes of one construct in one area from
the full response and recompresses (*alone*), and deletes the constructs
cumulatively in table order (*ordered*). The ordered rows of an area add up
exactly to the area's cost: the full response minus the response with every
byte of that area deleted, core, platform and schemas staying as context. The
deleted variants are not JavaScript; they locate a cost and never run, as 99's
and 102's stubs never did. Deleting bytes rather than stubbing whole units is
what lets the account go below the unit, into guards, fields and protocol
literals. `solid.mjs` paints and prices Solid's app code the same way, its views
being its pages and components and its logic the agent, stores, router and startup.

### 1.2 Reconciliation with research 102

102 stubbed whole units (initialiser → `0`) and kept a residual for keywords
and separators; here those bytes are deleted with their area. The figures move
accordingly: tea's markup 7,394 (102, ordered) against views 7,602 here; tea's
update/init + view functions + requests 2,321 + 1,024 + 1,682 = 5,027 against
4,751; direct's markup + `main` 9,560 + 2,838 = 12,398 against 12,798. Solid's
app is 6,872 here against 101's 7,387 app/startup residual (which carried
101's stub syntax and interactions). The picture the owner quoted holds without
the schemas: direct's app is 2.6× Solid's, tea's 1.8×.

## 2. Four views side by side

Each view's units were found through the release map (a unit belongs to the
view whose source lines hold its first mapped byte; markup units carry no beni
name), deleted alone, and priced (`views.mjs`; full code in
[`results/excerpts/`](../../../bench/app-code-size/results/excerpts/)). Helpers a
view calls are counted with it; direct's per-view figures leave out its shared
`main` (matrix, handlers), which §3.2 prices.

| View | tea units / raw / alone | direct units / raw / alone | Solid units / raw / alone |
|---|---|---|---|
| Feed list, article preview, pagination | 58 / 7,115 / **1,089** | 129 / 9,982 / **1,568** | 14 / 2,465 / **494** |
| Article page with comments | 60 / 11,652 / **2,019** | 146 / 14,776 / **2,581** | 20 / 5,305 / **949** |
| Editor form | 18 / 3,594 / **593** | 50 / 4,972 / **749** | 3 / 2,695 / **470** |
| Header, navigation (and footer, beni only) | 22 / 4,062 / **707** | 59 / 5,402 / **951** | 7 / 1,743 / **296** |

The code below is the shipped code, pretty-printed (`terser --beautify`, no
transform) and annotated; `…` marks a cut. Names are the release build's.

### 2.1 The article preview

The beni source (`Feed.viewPreview`, which calls `Author.avatar`,
`Author.link`, `Article.timestamp`, `Article.favoriteButton`, `Article.link` and
`Article.tagList`, each its own markup):

```elm
viewPreview maybeCred article =
    profile = Author.profile article.author
    summary = <><h1>{article.title}</h1><p>{article.description}</p><span>Read more...</span>
              {Article.tagList article.tags}</>
    <div class="article-preview">
        <div class="article-meta">
            <a href={Route.href (Route.Profile profile.username)}>{Author.avatar profile.image ""}</a>
            <div class="info">{Author.link article.author}{Article.timestamp article.createdAt}</div>
            {case maybeCred of
                Just cred → Article.favoriteButton article (ClickedFavorite cred article.slug)
                                (ClickedUnfavorite cred article.slug) "pull-xs-right"
                Nothing → <></>}
        </div>
        {Article.link article summary}
    </div>
```

**Tea** emits a template, a *kind* (mount function `m`, patch function `p`) and the patch
for this site, and the same three for each helper it calls:

```js
Vk = Ea("<div class=article-preview><div class=article-meta><a></a><div class=info><!><!>", 0);
Wk = { m: (a, b) => {                       // mount: clone, walk, make 5 slots, build the record
    let c = Vk(), d = c.firstChild, e = d.firstChild, f = e.nextSibling, g = f.firstChild, h = g.nextSibling,
        i = Fa(e, null, b), j = Fa(f, g, b), k = Fa(f, h, b), l = Fa(d, null, b), m = Fa(c, null, b),
        n = { s: c, q: null, e: c,                      // what the runtime reads
              w2: e, c1: i, c2: j, c3: k, c4: l, c5: m,  // node and slot references
              a0: undefined, a1_0: undefined, a2_0: undefined, a3_0: undefined, a5_0: undefined, a5_1: undefined,
              l0_0: NaN, d0: undefined, l1_0: NaN, l1_1: NaN, l1_2: NaN, d1: undefined,
              g0_0: NaN, g1_0: NaN, g2_0: NaN, g2_1: NaN, g3_0: NaN, g3_1: NaN, g3_2: NaN, g3_3: NaN };
                                                         // 22 kept values, each initialised (§3.1, cause 2)
    Uk(n, a); return n }, p: Uk, l: true };              // l: "may be live", so every slot is restated
Uk = (a, b) => {                                         // patch: runs on every render of the feed
  let c = b[0], d = b[1];                                 // inputs from the block's argument vector
  if (c.j !== a.l0_0) { a.l0_0 = c.j; a.d0 = Ji(c.j) }   // `profile =`: a let kept in the instance
  let f = a.d0;
  if (c.title !== a.l1_0 || c.D !== a.l1_1 || c.B !== a.l1_2) {  // `summary =`: a block kept too
    a.l1_0 = c.title; a.l1_1 = c.D; a.l1_2 = c.B; a.d1 = { t: Qk, v: [c] } }
  let h = a.d1, i = c.j;
  if (i !== a.g0_0) { a.g0_0 = i;                         // group test on the author …
    let j = li({ $: 7, a: f.username }), k = f.E, l = c.j;
    if (j !== a.a0) { a.w2.setAttribute("href", Cb(j)); a.a0 = j }        // … then a hole test
    if (k !== a.a1_0) { a.a1_0 = k; Qa(a.c1, Oi(k, "")) } else Ka(a.c1);   // helper call or restate
    if (l !== a.a2_0) { a.a2_0 = l; Qa(a.c2, Pi(l)) } else Ka(a.c2)
  } else { Ka(a.c1); Ka(a.c2) }                           // a skipped group restates its slots
  …                                                       // createdAt, the button, the link: same shape
  if (d !== a.g2_0 || c !== a.g2_1) { a.g2_0 = d; a.g2_1 = c;
    let o; if (d.$ === 0) { let p = d.a;
      o = Lj(c, { $: 1, a: p, b: c.A }, { $: 2, a: p, b: c.A }, "pull-xs-right") } else o = Tk;
    Qa(a.c4, o) } else Ka(a.c4);                          // both messages built on every run of this group
  …
  a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l };  // liveness, recomputed every render
// and per helper, e.g. Author.link:
ui = Ea("<a class=author> ", 0);
vi = { m: a => { let c = ui(), e = { s: c, q: null, e: c, w0: c, w1: c.firstChild,
                                     a0: undefined, a1: undefined, l0_0: NaN, d0: undefined, g0_0: NaN };
                 si(e, a); return e }, p: si };
si = (a, b) => { let c = b[0]; if (c !== a.l0_0) { a.l0_0 = c; a.d0 = ti(c) } let e = a.d0, f = c;
  if (f !== a.g0_0) { a.g0_0 = f; let g = li({ $: 7, a: e });
    if (g !== a.a0) { a.w0.setAttribute("href", Cb(g)); a.a0 = g }
    if (e !== a.a1) { a.a1 = e; a.w1.data = e } } };
Pi = a => ({ t: vi, v: [a] });                            // the helper itself returns a block
```

`Article.favoriteButton` is an `if` with two markups, so it is two kinds, two
patch functions and two copies of the same template string
(`"<button><i class=ion-heart>"`), differing only in a class literal.

**Direct** emits the same kind and template, but the patch is split into one
*entry* per group, each with a descriptor, and wrapped in the protocol:

```js
Un = [["7:434", "7:446", "7:467"], false, false, false];  // descriptor: the group's source holes (path IDs)
Vn = (a, b) => { let c = b[0], e = b[2];                   // entry: runs only when the masks select it
  { let b = c.n; { a.g0_0 = b;                              // the test is gone, the store is not (§3.2)
      let d = tj({ $: 7, a: e.username }), f = e.E, g = c.n;
      if (d !== a.a0) { a.w2.setAttribute("href", Re(d)); a.a0 = d }
      { a.a1_0 = f; Of("/7:446", () => Ve(a.c1, Nf("/7:446", () => ik(f, "")))) }   // place/value: context capture
      { a.a2_0 = g; Of("/7:467", () => Ve(a.c2, Nf("/7:467", () => jk(g)))) } } } };
Wn = a => { $e(a.c1); $e(a.c2) };                           // restate entry
…                                                           // three more descriptor/entry/restate triples
io = Uf((a, b) => { …the two lets, as tea… return [c, d, e, f] },     // prepare: inputs + derived values
        (a, b) => { …; a.l = a.c1.l || a.c2.l || a.c3.l || a.c4.l || a.c5.l },
        2, [Qf(Un, Vn, Wn), Qf(Xn, Yn, Zn), Qf(bo, co, eo), Qf(fo, go, ho)], false);
ko = { m: …the same mount as tea's Wk…, p: io, l: true };
```

and, in `main`, a row of the consumer matrix for every call path that reaches
it (`["$call/8:617/8:642/7:289", "0010000000…"]`, one bit per message key).

**Solid** (`ArticlePreview`, 1,043 B raw plus 8 templates) is one function that
clones one template, walks it, inserts components and text once, and wraps the
two reactive reads in an accessor and an effect:

```js
pt = ({ article: e, token: t, onClickFavorite: n }) => {
  const { title: r, description: o, slug: i, createdAt: l, tagList: s, author: { username: a, image: c } } = e;
  return (() => {
    const u = gt.cloneNode(!0), d = u.firstChild, f = d.firstChild, g = f.firstChild;
    return me(d, Z(Re, { href: `@${a}`, route: "profile",                 // a component call (NavLink)
                         get children() { const e = at.cloneNode(!0); return he(e, "src", c), e } }), f),
      me(f, Z(Re, { class: "author", href: `@${a}`, route: "profile", children: a }), g),
      g.textContent = new Date(l).toDateString(),                           // written once: no guard, no field
      me(d, t && (() => { const t = vt.cloneNode(!0), r = t.firstChild;
        return r.firstChild.nextSibling, r.$$click = n, r.$$clickData = e,  // the handler and its datum
          me(r, () => e.favoritesCount, null),                              // reactive: an accessor
          $(() => r.className = e.favorited ? "btn btn-sm btn-primary" : "btn btn-sm btn-outline-primary"), t })(), null),
      me(u, Z(Re, { href: `article/${i}`, route: "article", class: "preview-link",
                    get children() { return [ …h1, p, span, the tags written once… ] } }), null), u })() };
```

Title, description, date and tags are read once and written once. There is no
kept value for them, because the component is mounted per article object and
only the store's `favorited` and `favoritesCount` are reactive. In TEA the view
must handle any field of any article changing, so beni keeps and tests each.

### 2.2 The comment row (article page)

```elm
viewComment maybeCred slug comment =
    profile = Author.profile comment.author
    <div class="card">
        <div class="card-block"><p class="card-text">{comment.body}</p></div>
        <div class="card-footer">
            <a class="comment-author" href={Route.href (Route.Profile profile.username)}>
                {Author.avatar profile.image "comment-author-img"}</a>
            {" "}
            <a class="comment-author" href={Route.href (Route.Profile profile.username)}>{profile.username}</a>
            {Article.timestamp comment.createdAt}
            {case ( comment.author, maybeCred ) of
                ( Author.IsViewer _, Just cred ) →
                    <span class="mod-options"><i class="ion-trash-a" onClick={ClickedDeleteComment cred slug comment.id} /></span>
                _ → <></>}
        </div>
    </div>
```

**Tea** (patch `ro`, 897 B raw; mount `to`, 478 B; template 165 B; plus the delete
icon's kind and an empty kind):

```js
ro = (a, b) => { let c = b[0], d = b[1], e = b[2];
  if (c.j !== a.l0_0) { a.l0_0 = c.j; a.d0 = Ji(c.j) }  let g = a.d0, h = c.body;
  if (h !== a.g0_0) { a.g0_0 = h; a.w3.data = h }          // one path: one test, the right shape
  let i = c.j;
  if (i !== a.g1_0) { a.g1_0 = i;
    let j = li({ $: 7, a: g.username }), k = g.E, l = li({ $: 7, a: g.username }), m = g.username;  // href computed twice
    if (j !== a.a1) { a.w5.setAttribute("href", Cb(j)); a.a1 = j }
    if (k !== a.a2_0) { a.a2_0 = k; Qa(a.c2, Oi(k, "comment-author-img")) } else Ka(a.c2);
    if (l !== a.a4) { a.w6.setAttribute("href", Cb(l)); a.a4 = l }
    if (m !== a.a5) { a.a5 = m; a.w7.data = m } } else Ka(a.c2);
  if (a.g2 === undefined) { a.g2 = true; if (" " !== a.a3) { a.a3 = " "; a.x3.data = " " } }  // the constant {" "}
  …                                                          // timestamp slot, then the case:
  if (c.j !== a.g4_0 || d !== a.g4_1 || e !== a.g4_2 || c.T !== a.g4_3) { …4 stores…
    let p = c.j, q; r: { a: { if (p.$ === 0) if (d.$ === 0) { q = { t: no, v: [d.a, e, c] }; break r } else break a; break a } q = qo }
    Qa(a.c7, q) } else Ka(a.c7);
  a.l = a.c2.l || a.c6.l || a.c7.l };
```

**Direct** splits it into five descriptor/entry pairs (`Vu`…`nv`, 1,123 B raw with
the restates, against tea's one 897 B patch), an `Uf` entry, and the same mount.
The constant `" "` becomes a group of its own with a descriptor
(`[["2:1847"], false, false, true]`) and an entry that runs once.

**Solid** (`Comment`, 636 B raw):

```js
Ft = ({ comment: e, currentUser: t, onDelete: n }) => {
  const r = t && t.username === e.author.username, { id: o, body: i, author: { username: l, image: s }, createdAt: a } = e;
  return (() => { const e = Ut.cloneNode(!0), t = e.firstChild, c = t.firstChild, u = t.nextSibling, d = u.firstChild, f = d.nextSibling;
    return c.textContent = i,
      me(u, Z(Re, { href: `@${l}`, route: "profile", class: "comment-author",
                    get children() { const e = jt.cloneNode(!0); return he(e, "src", s), e } }), d),
      me(u, Z(Re, { href: `@${l}`, route: "profile", class: "comment-author", children: l }), f),
      me(f, () => new Date(a).toDateString()),
      me(u, r && (() => { const e = Dt.cloneNode(!0), t = e.firstChild; return t.$$click = n, t.$$clickData = o, e })(), null), e })() };
```

No guard at all: a comment never changes while its row lives, which Solid's
keyed `For` and store guarantee and beni's TEA view does not know.

### 2.3 The editor form

`Editor.viewForm` is one 613 B template (the `fieldset`s, inputs and button) on
both platforms; Solid's editor is one 790 B template that also holds the page
around the form. The HTML is comparable; the difference is around it:

```js
// tea, Po (1,020 B raw): eight path groups, each a test and a kept value …
  let m = f.title; if (m !== a.g3_0) { a.g3_0 = m; zb(a.w4, "value", f.title) }   // control(): stateful
  if (a.g4 === undefined) { a.g4 = true;                                          // once: the input handlers
    let o = a => ({ $: 4, a: a, b: null }), p = a => ({ $: 2, a: a, b: null }), … // constructors as functions
    if (o !== a.a4) { a.a4 = o; a.w4.$$input = o } … }
// … and Ro's mount wires the delegated events with their extractor and map context per node:
  h.$$inputX = Lk; if (b !== null) h.$$cx = b;  j.$$inputX = Lk; if (b !== null) j.$$cx = b; …
```

```js
// Solid, the same form: listeners attached once, one effect with nine tests for the reactive fields
pe(i, "change", l("title")), pe(f, "change", l("description")), …,
$(e => { const t = o.title, n = o.inProgress, …;
         return t !== e._v$ && (i.value = e._v$ = t), n !== e._v$2 && (i.disabled = e._v$2 = n), …, e },
  { _v$: void 0, _v$2: void 0, … })
```

Here the two encode the same job at similar cost (593 vs 470 B alone): the form
is fully dynamic in both, so Solid also keeps a previous value per hole. The
view that is mostly static (the preview, the comment) is where beni pays most.

### 2.4 The navigation link

```elm
navbarLink active page route label =
    <li class={[ ( "nav-item", True ), ( "active", active == page && page ≠ Other ) ]}>
        <a class="nav-link" href={Route.href route}>{label}</a></li>
```

```js
// tea: 49 + 162 + 308 B raw: a template, a kind and a patch of three groups, each test-then-test
Zj = (a, b) => { let c = b[0], d = b[1], e = b[2], f = b[3];
  if (c !== a.g0_0 || d !== a.g0_1) { a.g0_0 = c; a.g0_1 = d; let g = $j(c, d) && d.$ !== 0;
    if (g !== a.a0) { a.a0 = g; a.w0.classList.toggle("active", g) } }
  let h = e; if (h !== a.g1_0) { a.g1_0 = h; let i = li(e); if (i !== a.a1) { a.w1.setAttribute("href", Cb(i)); a.a1 = i } }
  let j = f; if (j !== a.g2_0) { a.g2_0 = j; a.w2.data = j } };
// direct: the same three groups as three descriptor/entry pairs and an Uf entry (525 B raw against tea's 308)
$l = [["11:357"], false, false, false];
_l = (a, b) => { let c = b[0], d = b[1]; { if (c !== a.g0_0 || d !== a.g0_1) { … } } };
fm = Uf((a, b) => b, (a, b) => {}, 4, [Qf($l, _l, null), Qf(bm, cm, null), Qf(dm, em, null)], false);
mm = (a, b, c, d) => ({ t: hm, v: Vf([a, b, c, d], Lf("", "11:355")) });   // the helper, with its call path
// Solid: NavLink is one component with one effect of three tests
Re = e => { const { getParams: t } = Ie(); return (() => { const n = Me.cloneNode(!0);
  return n.$$click = () => window.scrollTo(0, 0), me(n, () => e.children),
    $(r => { var o; const i = e.class, l = e.active || (null === (o = t()) || void 0 === o ? void 0 : o.routeName) === e.route, s = `#/${e.href || e.route}`;
      return i !== r._v$ && (n.className = r._v$ = i), l !== r._v$2 && n.classList.toggle("active", r._v$2 = l),
             s !== r._v$3 && he(n, "href", r._v$3 = s), r }, { _v$: void 0, _v$2: void 0, _v$3: void 0 }), n })() };
```

A link whose every hole is an input costs about the same in both (Solid's
`NavLink` keeps three previous values too). Beni's header costs more because it
is six such sites and each `{navbarLink …}` hole is a call, a block, a slot, a
placement and a restate (`Qa(a.c0, ck(c, Pj, Vj, "New Article"))` … `else Ka(a.c0)`),
and because each link's `href`, even the constant `Route.href Route.Home`, is
computed by `Route.href` and checked by `safeUrl` at run time on each mount.

## 3. Views: every byte by construct

### 3.1 Tea, against Solid

Brotli bytes; *raw* is the construct's UTF-8 bytes. Ordered in the table's order.

| Construct (tea) | raw | alone | ordered | Solid's equivalent (raw / ordered) |
|---|---:|---:|---:|---|
| HTML template strings | 6,146 | 1,335 | 1,335 | HTML 5,840 / 1,132 |
| `template(…, flags)` calls and bindings | 711 | 115 | 117 | 188 / 8 |
| clone and walk to holes | 2,625 | 368 | 431 | clone and walk 2,516 / 437 |
| slot and text-node creation at mount | 1,010 | 242 | 258 | `insert` calls 1,551 / 283 (all of mount-side composition) |
| instance record: node and slot references | 1,285 | 202 | 275 | none (closure locals) |
| instance record: initial values of kept fields | 3,046 | 384 | 386 | effects' `{_v$: void 0,…}` (inside effects) |
| kind objects `{m,p,l}`: mount shells | 2,872 | 375 | 549 | component function shells (inside *other*) |
| patch function shells and statement syntax | 532 | 58 | 85 | — |
| hoisted blocks `{t,v:null}` and static kinds | 1,736 | 217 | 239 | — |
| patch prologue `let c=b[0],…` | 612 | 52 | 109 | props destructuring (inside *other*) |
| group guards: path tests and kept-path stores | 4,654 | 657 | 747 | render effects and previous values 1,827 / 417 |
| view `let` cache in the instance | 387 | 98 | −18 | `createMemo` (none here) |
| hole guards: value tests and kept-value stores | 2,916 | 470 | 564 | (inside effects) |
| DOM writes | 1,785 | 301 | 371 | DOM writes 1,059 / 308 |
| value expressions (the view's computations) | 2,257 | 489 | 645 | *other* 2,168 / 658 (expressions, shells and handler logic) |
| slot placement `childHtml(…)` | 503 | 54 | 53 | — |
| restate calls and their `else` | 1,346 | 164 | 160 | — |
| liveness `a.l = …`, `l:true` | 912 | 33 | 195 | — |
| blocks built per render `{t,v:[…]}` | 196 | 14 | 110 | — |
| helper calls | 771 | 308 | 324 | component calls and prop getters 3,076 / 576 |
| message constructors in views | 628 | 89 | 136 | — (the handler is a function) |
| event wiring | 1,752 | 256 | 355 | event wiring and handlers 2,219 / 547 |
| list rows (`forKeyed`/`forPosition`, row objects, keys) | 736 | 62 | 107 | `For`/`Show`/`Suspense`/`Switch` 1,902 / 382 |
| `Html.map` | 20 | 5 | 54 | store/router access 256 / 77 |
| `main` | 51 | 44 | 15 | — |
| **total** | **39,489** | | **7,602** | **22,602 / 4,825** |

By cause (ordered): templates 1,452 against Solid's 1,140; walks 431 against
437; **scaffolding 1,530** (kind and patch shells, node and slot fields, slot
creation, static kinds, prologue, `main`) against `insert`'s 283; **re-render
bookkeeping 2,197** (both guards, initialisers, `let` cache, restates, liveness,
per-render blocks, placements) against effects' 417; values and writes 1,016
against 966; composition (helpers, rows, `Html.map`) 485 against 1,035; events
and messages 491 against 547. The gap of 2,777 B is +1,780 bookkeeping,
+1,247 scaffolding and +312 templates, less 562 where beni is smaller.

### 3.2 Direct

| Construct (direct) | raw | alone | ordered |
|---|---:|---:|---:|
| HTML template strings | 6,146 | 1,285 | 1,285 |
| `template(…)` calls and bindings | 711 | 117 | 238 |
| clone and walk | 2,625 | 250 | 281 |
| slot and text-node creation | 1,010 | 82 | 266 |
| instance record: references | 1,257 | 189 | 298 |
| instance record: initial values | 3,293 | 289 | 405 |
| kind objects: mount shells | 3,439 | 441 | 641 |
| patch/entry function shells and statement syntax | 1,923 | 474 | 502 |
| hoisted blocks and static kinds | 1,704 | 245 | 258 |
| prologue | 1,263 | 77 | 160 |
| group guards and kept-path stores | 3,590 | 372 | 325 |
| view `let` cache | 387 | 57 | 16 |
| hole guards and stores | 2,054 | 281 | 386 |
| DOM writes | 1,676 | 265 | 346 |
| value expressions | 3,167 | 358 | 490 |
| slot placement | 494 | −33 | 118 |
| restate calls and entries | 984 | 183 | 224 |
| liveness | 864 | 77 | 141 |
| blocks per render | 153 | −45 | 1 |
| helper calls | 815 | 284 | 339 |
| message constructors | 755 | 112 | 159 |
| event wiring | 2,068 | 184 | 322 |
| list rows | 710 | 55 | 221 |
| `Html.map` | 20 | −38 | −47 |
| **group descriptors and `templateGroup` attachment** | 5,587 | 1,028 | **1,126** |
| **`templatePatch` entries' shells** | 1,979 | 104 | 166 |
| **path IDs (`"7:446"`, `"$call/2:1016/2:1259"`…)** | 2,416 | 796 | **789** |
| **context capture: `templatePlace`/`Value`/`Inputs`/`Capture`** | 2,795 | 273 | **465** |
| **consumer matrix** | 41,293 | 1,526 | **1,545** |
| **per-key handlers** (98 near-identical closures) | 7,364 | 110 | 169 |
| **message dispatcher tree** | 3,157 | 376 | 376 |
| **root selector and document arms** | 620 | 79 | 191 |
| **program mount and host wiring** | 11,522 | 230 | 451 |
| redundant nested braces left by removed tests | 874 | −12 | 145 |
| **total** | **118,715** | | **12,798** |

By cause: templates 1,523; walks 281; scaffolding 2,270 (direct's entry shells
add 417 to tea's); bookkeeping 1,616 (fewer tests than tea, since a selected
entry skips its group test, but each entry still stores the kept path and
value); values and writes 836; composition 513; events and messages 481; and
**the parameterised-template protocol 5,278** (descriptors, entries, path IDs,
context capture, matrix: 4,091; handlers, dispatcher, root selector, mount:
1,187). That protocol is direct's whole excess over tea (12,798 − 7,602 =
5,196). Research 99 and 101 price its parts one by one and their re-encodings
(short path IDs −589 B on an older master; a redesign 0–2 kB net).

Two findings here are new. **Dead stores**: a selected entry has lost its test
but still writes the kept path (`a.g0_0 = b` in `Vn` above), and a hole whose
test went the same way still writes its kept value. Direct writes kept paths
158 times and tests one 72 times. Deleting the 64 stores (of either kind) whose
field name no code reads anywhere saves **106 B**, and the corpus runs
identically (`proto-dead-stores.mjs`). Field names repeat across kinds, so a
per-kind analysis would find more. **Handlers are
the shared update called 98 times**: direct now builds the message as a value,
walks a 3,157 B decision tree on its tags, and calls one of 98 closures that
differ only in the key index they pass (`Jf(k, 41)`) to look up the masks:

```js
p = a => { Df(null); let b = d, c = Bx(a, b); d = c.a; let e = Jf(k, 1);
           { let a = m(), b = a[0]; if (b !== j.k) Ue(j, b, a); else { if (j.i !== null) j.i.a = a;
             { if (j.k === 0) Ve(j.i.c, j.i.a[1].body) } } }
           Bc(j.i.a[1].title); wf(o, c.b); Kf(e) },
// … ×98, then:  if (a.$ === 2) { if (a.a.$ === 0) { Q(a); return } if (a.a.$ === 1) { R(a); return } …
```

Brotli makes the 98 copies nearly free (110 B alone); the dispatcher is not
(376 B). `browser-direct.md` §0 and §4.1 describe one function per message
key, taking the payload as parameters, with "no message object unless the
program makes a message a value". Conduit's views make every message a value
(page messages wrapped by `Html.map`, constructors passed to helpers), so all
its keys take the 2026-10-15 amendments' path instead: a message object, the
value-message dispatcher, and the shared `update`. That is tea's dispatch on
tags with a mask-key lookup added.

## 4. Update, init and requests: every byte by construct

| Construct | tea raw / alone / ordered | direct raw / alone / ordered |
|---|---|---|
| message dispatch: `switch` on tags, `.$===` tests | 1,888 / 322 / 322 | 1,804 / 220 / 220 |
| record updates `{...m, f: v}` | 1,008 / 160 / 152 | 1,011 / 154 / 207 |
| tuples and records built (`{a: model, b: cmd}`, new records) | 2,232 / 501 / 502 | 2,092 / 377 / 502 |
| message and constructor values `{$:…}` | 2,590 / 454 / 479 | 2,457 / 304 / 398 |
| commands: `Cmd.task`/`batch`/`map`/`none` and their thunks | 874 / 219 / 219 | 874 / 173 / 216 |
| requests: Api, Http, Url builders, Task chaining, routes | 1,221 / 293 / 389 | 1,221 / 240 / 458 |
| strings and string formatting | 1,837 / 550 / 589 | 2,187 / 568 / 655 |
| List, Maybe, Result calls | 598 / 113 / 197 | 584 / 130 / 227 |
| markup blocks and view wrappers `{t,v}` | 468 / 179 / 182 | 699 / 73 / 189 |
| bindings, parameters, `return` | 2,138 / 170 / 213 | 2,006 / 143 / 168 |
| other: control flow, operators, punctuation | 5,117 / 938 / 1,507 | 4,695 / 834 / 1,396 |
| **total** | **19,971 / — / 4,751** | **19,630 / — / 4,636** |

Solid's equivalent is 1,944 B: the agent (fetch wrapper and endpoint table) 514,
the stores and their actions 1,060, the hash router, lazy pages and startup 370.
Solid's event handlers (the `makeFavorite` call, the editor's submit with its
`.then`/`.catch`) sit in its views and are counted there.

The largest declarations (`logic-units.json`, alone): `ArticlePage.update`
360 B, `Settings.update` 258, `Main.changeRouteTo` 165, `Main.view` 143,
`Editor.update` 142, `Main.update` 139, `Article.list` 122, `Api.send` 117,
`ProfilePage.update` 85, `Api.errorMessages` 82. The shape repeats in every
page: an interaction is a constructor, an arm of `update` returning a pair, a
`Cmd.task` whose thunk calls a request and whose completion is another
constructor, and two more arms for `Ok` and `Err`:

```js
// Feed.update, tea (346 B raw; Elm: four arms over Msg)
rl = (a, b) => { let c = b; switch (a.$) {
  case 0: { return { a: { ...c, C: [] }, b: pd } }                               // dismiss errors
  case 1: { let b = a.a, d = a.b; return { a: c, b: wd(() => Aj(b, d), a => ({ $: 3, a: a, b: null })) } }   // favorite
  case 2: { let b = a.a, d = a.b; return { a: c, b: wd(() => Bj(b, d), a => ({ $: 3, a: a, b: null })) } }   // unfavorite
  default: { if (a.a.$ === 0) { let b = a.a.a; return { a: { ...c, O: Jc(c.O, a => b.A === a.A ? b : a) }, b: pd } }
             return { a: { ...c, C: oc(c.C, bh(a.a.a)) }, b: pd } } } };
```

```js
// Solid, the same job inside createArticles: an async action that edits the store in place
async makeFavorite(t) { const o = n.articles[t];
  if (o && !o.favorited) { r("articles", t, e => ({ favorited: !0, favoritesCount: e.favoritesCount + 1 }));
    try { await e.Articles.favorite(t) } catch (e) { throw r("articles", t, e => ({ favorited: !1, favoritesCount: e.favoritesCount - 1 })), e } } },
```

So the update gap is mostly the architecture, not the encoding: messages as
values with padded tags (`b: null`), a pair per arm, the nested pages' plumbing
(`updateWith`, `Cmd.map`, `toSession` over nine pages: `Main.changeRouteTo`
and `Main.update` alone cost 304 B), and features Solid's
reference lacks or does differently (typed and messaged HTTP failures,
`Api.errorMessages`; client-side validation messages in `Register`, `Settings`
and `Editor`; a real URL parser and `Url.Builder` against a hash router; 101 §1).
Padding is cheap: deleting the app's 81 `null` padding fields saves 97 B on tea and 35 B on direct (§6.1).

## 5. Names and minification

### 5.1 Names

Every identifier in the two areas by kind, deleted alone (`names.mjs`). These
cut across the construct rows; they are not added to them.

| Names | tea views | direct views | Solid views | tea logic | Solid logic |
|---|---|---|---|---|---|
| instance protocol fields (`g3_2`, `a1_0`, `w7`, `c4`, …) | 2,008 / 4,633 / **1,203** | 1,956 / 4,328 / **1,142** | — | — | — |
| record, constructor and DOM property names | 742 / 3,543 / 384 | 2,551 / 5,998 / 423 | 797 / 6,014 / **888** | 1,672 / 2,389 / 306 | 294 / 2,112 / 491 |
| references to top-level names | 975 / 1,920 / **1,076** | 2,950 / 5,861 / **2,702** | 420 / 760 / **328** | 834 / 1,605 / 739 | 85 / 135 / 51 |
| locals and parameters | 4,224 / 5,774 / **1,494** | 8,356 / 10,234 / 1,358 | 1,126 / 1,250 / 697 | 1,747 / 1,747 / 327 | 567 / 748 / 194 |

(count / raw / alone.) A top-level reference costs about a byte of brotli each:
two- and three-letter names drawn from a large set are what brotli compresses
worst (102 §4). Beni's views make 2.3× (tea) and 7× (direct) as many such
references as Solid's, because each site has its own template, kind, patch and,
on direct, descriptor and entry, all referenced by name; Solid's references are
mostly to a handful of runtime functions (`me`, `Z`, `$`, `he`). The protocol
field names are the same story inside a function: a positional code per group and
hole, which differs from site to site.

### 5.2 Minification

Terser (compress `passes: 2` + mangle, module, toplevel; 102's default), with the
release map as its input map so units keep their owners (`terser.mjs`):

| Area | tea before → after | direct before → after |
|---|---|---|
| views | 7,602 → 7,329 (**−273**) | 12,798 → 11,107 (**−1,691**) |
| update / init / requests | 4,751 → 4,541 (**−210**) | 4,636 → 4,393 (**−243**) |
| whole bundle | 31,609 → 30,447 | 38,175 → 35,296 |

The update code minifies like the rest: about 4%. On direct's views most of the
1.7 kB is 102's top-level single-use inlining (the descriptors and entries are
each read once), which PR #150 is building. Minification explains none of the
gap to Solid's update code.

## 6. What a Solid-like encoding would weigh

### 6.1 Uniform rewrites, executable

Each rewrite is a script over the shipped tea bundle, applied to every view;
each was run alone and stacked, and each result ran Conduit's three corpus
scripts (Editor, Reader, Tour, through the gates' driver under happy-dom) with
transcripts equal to the goldens and to the unchanged bundle's
(`prototypes.mjs`; every request's method, URL, headers and body are in the
transcripts). The tea rewrites also ran `feed-favorite.steps`, which
favourites and unfavourites an article from the feed list, something no
corpus script clicks, with a transcript equal to the unchanged bundle's
(`verify-favorite.mjs`).

| Rewrite | What it changes | alone | its step | stacked |
|---|---|---:|---:|---:|
| `proto-guards.mjs`: one test per hole | a hole test nested in a group test (`if (v !== a.a3) { a.a3 = v; w.data = v }`) becomes the write alone when its body is a text, `setAttribute` or class write; its kept field goes from the record. 50 tests, 36 fields. Slot placements keep their argument tests (a helper call is skipped, `language.md` §11.6) | −208 | −208 | −208 |
| `proto-closures.mjs`: closures instead of records | 44 kinds: kept values, node references and slots become locals of `m`; `p` becomes a closure `u` over them; the record keeps `s`, `q`, `e`; every kind's `p` is one shared `(a,b)=>a.u(a,b)`. The same tests and writes in the same order | −210 | −197 | −405 |
| `proto-static.mjs`: share what is static | 23 duplicate `template(…)` cloners bound once (§15.2 allows a shared string); 24 static kinds made by one factory, still one kind per site | −16 | −179 | −584 |
| `proto-live.mjs`: static liveness | Conduit has no live markup (no every-render value; a controlled input is not live since 2026-10-08), so 93 restate `else`s, 35 `a.l=` stores and 32 `l:true` go | −254 | −277 | **−861** |
| Terser on the stack | | | −662 | −1,523 |

**−861 B is 11% of tea's views**, and none of it changes what the page does.
The steps interact. Sharing static kinds saves 16 B alone but 179 B after the
closure rewrite: in the original bundle the static kinds repeat the shape of
the 45 kinds with a patch (`{m:…{…return{s:c,q:null,e:c…}}…}`), so brotli
already has them almost for free; once those kinds take the closure form, the
static kinds are the only ones left in the old shape and become expensive
until they are shared too. The same is true of liveness (−254 alone, −277
stacked). The order is the one a lowering would take; another order would
split the same total differently. The first and fourth are what a lowering with a little more knowledge would emit:
a write of an unchanged value is a no-op for these properties, and liveness is
a whole-program fact (`backend.md` §15.4 marks every kind whose slots may hold
an unknown kind as possibly live). The second is research 101's "shared lexical
template factories" applied to tea: it is cheaper than its reputation in bytes
(−210 B), and it allocates a closure per instance, so it needs rule 8's Solid 2
timing before anyone proposes it. The constructor-padding probe
(`proto-padding.mjs`, the app's `{$:…, b: null}` fields deleted) saves 97 B on
tea and 35 B on direct and runs identically, but padding is a shape decision for speed
(`backend.md` §4, correction 2), so it is a price, not a proposal.

### 6.2 What is left after the stack

After the four rewrites tea's views are near 6.7 kB against Solid's 4.8. The
rest is not re-encodable at the byte level:

- **Tests on paths that rarely change.** The preview tests `title`,
  `description`, `createdAt` and `tags` on every render, because in TEA a new
  article value may carry any change. Solid reads them once, relying on its
  store to merge the favourite's answer into the same article object, so that
  the row never sees a new title. In beni the answer replaces the article with
  a new value, so dropping a test needs a proof of which fields a write can
  change. That is `write-sets.md`'s analysis, which direct consumes; in
  Conduit's feed the write is the whole article, and direct spends its
  analysis on the protocol of §3.2 rather than on fewer tests.
- **Messages are values.** A view builds `{$:1, a:cred, b:slug}` and `update`
  dispatches on it; Solid's handler calls the action. This is the architecture
  (TEA), and §4 prices its plumbing at about 1.7 kB of the update code.
- **A kind per site and per branch.** `favoriteButton`'s two arms are two kinds
  with the same template string; `<></>` is a kind and a template per site.
  Kind identity per site is the guarantee that a branch change remounts
  (`backend.md` §15.2); sharing the *code* of two kinds that differ only in a
  literal is not forbidden by it and is unpriced here.
- **Names**: §5.1's references and field codes, which shrink with the
  scaffolding they name.

### 6.3 Why the one-view prototype got bigger

`proto-preview.mjs` rewrites the feed preview by hand, Solid-style: one
template with the helpers' markup inlined (comment markers kept, so the page's
transcript is byte-identical), nodes in closure locals, one test per input
path, no restates, the favourite button still remounted when its branch changes,
the tags through the runtime's positional list. The page runs identically
(the three corpus scripts and the feed favourite of §6.1). The
bundle grows from 31,609 to **31,774 B (+165)**, though its raw size falls by 932 B.

Deleted alone, the original preview's own units (2,549 raw bytes: the kind,
patch, template, summary fragment, empty kind and `Article.link`) cost **298 B**,
because they repeat shapes that the other 68 kinds already taught the compressor.
The hand rewrite's 1,625 raw bytes cost **522 B** alone, because nothing else
in the bundle looks like them. Solid's own `ArticlePreview` costs 257 B alone
in Solid's bundle. This is one rewrite of one view, but the mechanism it
shows (298 B against 522 B for the same job) suggests that a new encoding
priced one view at a time will look worse than it is, so it should be priced
applied to every view, as §6.1's rewrites are.

## 7. Why each construct is there, and what Solid does instead

| Construct | Why beni emits it | Guarantee or encoding? | Solid instead |
|---|---|---|---|
| Group guards and kept paths | A TEA view runs again on every render; `backend.md` §15.4 (*a root computes its own values*, 2026-10-04) tests each group's input paths so unchanged parts evaluate nothing | Needed for speed under TEA without write sets; which paths need a test is analysis | Accessors subscribe at run time; non-reactive reads run once |
| Hole guards nested in group guards | §15.4, *Within a group each op is written exactly as `p` wrote it before*: the old per-hole test survives inside the new group test | Encoding (§6.1: −208 B) | One test per effect expression |
| `NaN`/`undefined` initialisers | §15.4 *Mount through the patch*: every kept value starts unset so the first patch writes; `NaN` because a `⊤` may be `undefined` under `--release` (`dom.zig`); a full record keeps the hidden class stable (102 §6.3) | Encoding with a speed reason | `{_v$: void 0, …}` per effect, same idea, smaller scope |
| Restates and liveness | §15.4 *A skipped group restates its slots*: an every-render value nested below a skipped group must still re-run | The guarantee is real; emitting it where nothing can be live is conservatism (§6.1: −254 B) | Nested computations own their own subscriptions |
| Kinds `{m,p}`, records, slots, blocks | §15.3–§15.4: every `Html msg` is a block `{t,v}`, placed in a slot that patches when the kind is the same and remounts otherwise | Kind identity per site is a guarantee (§15.2); the record form is encoding (§6.1: −210 B) | `insert(parent, value, marker)`; components are plain function calls |
| A kind per helper call | §15.4 (2026-09-29): a helper call in a hole is skipped when its arguments are unchanged; inlining its markup is "later work" (research 39 §6.3 option 2) | Encoding; unpriced beyond §6.3 | Components are calls too, with prop getters; Solid pays more here (576 vs 324 B) |
| Event wiring `$$click`, `$$clickX`, `$$cx` | §15.3 *Events*: delegated handlers on node properties; the extractor for payloads; the map context per event node so `Html.map` composes at the listener | Guarantee of `Html.map`'s order (Elm's tagger chain) | `$$click` and `$$clickData`; no map, no context |
| Message constructors | TEA; constructors padded to one shape per type (`backend.md` §4, correction 2) | Architecture; padding is a speed choice (97 B) | The handler calls an action |
| Path IDs, descriptors, matrix, context capture | `browser-direct.md`, *parameterised markup templates and visit verification* and *selected entry points* (both 2026-10-15): precise group selection per call path, verified against the analysis | Precision of visits, a speed design, not a language guarantee | A dependency graph built at run time |
| Handlers and dispatcher | `browser-direct.md`, *measured dispatch and shared update bodies* (2026-10-15): one shared `update`, one handler per key for the mask index | Encoding of the key, after the update was shared for speed | None |
| `{a: model, b: cmd}`, spreads | `update : Msg, Model → Model × Cmd Msg`; immutable records, and field identity is load-bearing (rule 8) | Architecture and a guarantee | Stores edited in place through setters |
| `Cmd.task` thunks, typed errors | Managed effects; each failure typed (rule 9) | Guarantees | `await`, one broad `catch` |

## 8. Conclusions

1. **On tea, the views' excess over Solid is about 2.8 kB, nearly all
   bookkeeping (1.8 kB) and scaffolding (1.2 kB).** The rest is at par. Four
   uniform rewrites that change no behaviour recover 0.86 kB of it; two of them
   (one test per hole, static liveness) are lowering knowledge, not new design.
2. **On direct, the views cost 5.2 kB more than tea's, and the
   parameterised-template protocol is all of it.** Research 101's redesign
   envelope (0–2 kB) and 99's short IDs remain the candidates; this report adds
   dead stores (106 B) and the observation that the per-key handlers have
   become tea's tag dispatch plus a key lookup (dispatcher 376 B).
3. **The update code's excess (about 2.8 kB over Solid's logic) is the
   architecture and the features**: messages as values, pairs and spreads, nested
   pages, typed failures and their messages, client validation, a real router.
   Minification takes about 4% of it.
4. **Brotli prices difference, not volume.** A shape the bundle repeats is
   nearly free, and stops being free when the shapes around it change (§6.1);
   per-site names and codes are never free. §6.3 suggests pricing any redesign
   applied to all views at once, and timing it against Solid 2 before it is
   proposed (rule 8).

## 9. Reproduction

[`bench/app-code-size/README.md`](../../../bench/app-code-size/README.md) lists
the commands. The archived bundles and maps reprice without a compiler. No
compiler, core, platform, application, test, budget or run-hash file changes, so
the gates are not affected by this branch beyond its new files.
