# 62 — Conduit's write sets: a realistic application against research 58's criterion

*2026-10-08. `plans/compile-away.md` §4 V1: before the per-message write-set work (R4, R5) is
specified, run research 61's classifier on one realistic application. This is that application:
**Conduit**, the RealWorld spec's Medium clone, written in beni the way `rtfeldman/elm-spa-example`
writes it in Elm (`examples/conduit/`). Every figure is **[measured]** by
`bench/writesets/classify.mjs` unless marked **[by hand]**; the commands are in §8.*

---

## 0. The answer in seven sentences

1. Conduit is 3 387 lines in 16 modules and works end to end against a scripted API: sign in and
   up, the feed with its tabs, tag filter and pages, an article with favorite, follow and
   comments, the editor (new and edit, client checks and the server's 422), settings, profiles,
   sign out, the user kept in `localStorage` (§1).
2. Its **page fixtures cannot fit the test budget**: the release build alone retires 5.8 billion
   instructions against a 4.3 billion budget for the whole case, and the release optimiser's
   `specialise` phase is 77% of that build. The fixtures are parked with their goldens in
   `examples/conduit/tests/` (§1.3).
3. **Read literally, the classifier says 100% bounded**, at both levels measured: Main's 9
   constructors are all *exact*, and the 65 constructors of the pages and the feed are 83% exact
   and 17% indexed — no structural, no `*` (§3).
4. **That figure is an artefact.** 8 of Main's 9 constructors write the model's **root**:
   Conduit's model is a union of pages, `update` rebuilds it with `Home (Home.update sub home)`,
   and the classifier's `*` rule only fires for a *record* model. A root write marks every group:
   each of the 8 reaches all 241 dynamic holes. Counted as what it costs, **1 of 9 (11%) of the
   constructors the runtime dispatches is bounded** (§3.1).
5. Followed into the pages and the feed, **61 of 65 (94%)** are bounded; the 4 that are not are
   `Feed`'s, whose opaque `Model Internals` wrapper makes every write a root write. 16 of the 61
   are bounded only coarsely, at a status variant rebuilt around its own parts (listed in §5)
   (`Loaded ( Editing text, comments )`, `Editing slug problems (transform form)`). The wrappers
   also hide every list idiom the app has: the map-by-slug, the filter-by-id and the prepend all
   read as *exact* at the wrapper (§3.2, §5).
6. **Verdict:** against the constructors R4 dispatches on, Conduit is **11% bounded, below two
   thirds, so by the plan's criterion R4 and R5 shrink** to R2, R3 and R5's append/clear —
   unless R4's specification takes on nested-message dispatch and same-variant rebuilds. The
   tool implements neither: its 94% for the pages comes from analysing each page's `update` as
   a program of its own, which already assumes nested dispatch, and what same-variant rebuilds
   would add (every constructor bounded) is counted by hand, not measured (§6).
7. Four capability gaps were stubbed visibly — the `Dict` schema for 422 bodies, Markdown,
   dates, and a storage-change subscription — each with a `-- GAP:` comment (§7).

## 1. The application

### 1.1 Shape

`examples/conduit/` is a `beni new`-shaped project (`beni.json`, `src/`) for `browser-tea`. Its
modules follow elm-spa-example's, flattened (`Page.Article` is `ArticlePage`):

| module | lines | what it is |
|---|--:|---|
| `Main` | 259 | `Tea.application`; `Model` is a union of pages (`Redirect`, `NotFound`, `Home Home.Model`, …, `Editor (Maybe String) Editor.Model`); `update` is `case ( msg, model ) of ( GotHomeMsg sub, Home home ) → updateWith Home GotHomeMsg (Home.update sub home)`; `changeRouteTo` replaces the page on every address change and hands it the old page's session |
| `Api` | 292 | `Cred`, `Viewer`, their schemas, the stored user, `get`/`post`/`put`/`delete` with the token header, `Api.Error` (`Rejected (List String)` for a 422, `Failed Http.Error`) |
| `Route`, `Session`, `Page` | 259 | routes over `Url.Parser`; `LoggedIn Key Viewer \| Guest Key`; the frame (navbar marking the active page, footer), error list, loading indicators and `slowThreshold` |
| `Article`, `Author`, `Comment` | 451 | the API's article, profile and comment schemas, the requests on them, and their shared markup |
| `Feed` | 175 | elm-spa's `Article.Feed`: **opaque** `Model = Model Internals`, its own messages (favorite, dismiss errors), previews keyed by slug, pagination, tabs |
| `Home`, `ArticlePage`, `Editor`, `Login`, `Register`, `Settings`, `ProfilePage` | 1 951 | the pages, each with its own `Model`, `Msg`, `init`, `update`, `view` and `toSession` |

The idioms the brief asked for are all present, written as an Elm developer would: whole-model
replacement from decoded data (`CompletedLoadArticle (Ok article) → { model | article = Loaded
article }`), nested page states (`Status a = Loading | LoadingSlowly | Loaded a | Failed`),
forms behind a status (`Editor.Status` with seven variants and an `updateForm` that rebuilds
whichever variant holds the form), lists edited by id (`List.map articles (replaceArticle new _)`,
`List.filter comments λc → c.id ≠ id`), prepend (`[ comment, …comments ]`), error-list append and
clear, keyed `Restart` commands for the feed (a new tab cancels the old request), and `Cmd.map`
of each page's commands.

The release bundle is 124 093 bytes, 30 842 brotli **[measured, once]**.

### 1.2 What works

Driven by three scripts in `tests/browser/driver.mjs` under happy-dom, development and release
builds alike, all transcripts equal **[measured]**:

- **Reader**: sign in (POST, token stored), the empty "Your Feed", the "Global Feed" tab, open an
  article (body, tags, follow and favorite buttons), favorite it (count 0 → 1), post a comment
  (form disabled while sending, the comment prepended with its delete icon).
- **Editor**: a user stored from an earlier visit opens `/editor/<slug>`, the article loads into
  the form; a blank title is refused before anything is sent; the next save gets a **422**, whose
  body is shown (§7.1); the third save goes through and the address and the title become the new
  article's.
- **Tour**: page 3 of the feed then a tag (the page's request is aborted, `Restart`), a profile
  and its favorites tab, settings loaded, a bio saved (`PUT /api/user`, the stored user updated),
  sign out (storage cleared, guest feed), sign-up checks twice.

Not driven by a script, but written and type-checked: follow/unfollow, delete a comment, delete
an article, create a new article, the slow-load indicators.

### 1.3 The fixtures do not fit the budget

The scripts were first added as `tests/corpus/browser/tea/` project fixtures, which build the
program twice (development, and `--release --allow-debug`) and load it into three pages
(development, release, and development with listeners in fibers). Both failed on the budget
alone: **9 142M and 8 837M instructions against 4 300M**; with `-Dtest-budget=0` both passed,
all three pages equal to the golden. By piece, with `bench/list-in-beni/icount.c`:

| piece | Conduit | `ApiAndRoutes` (for scale) |
|---|--:|--:|
| development build | 1 610M | 891M |
| **release build** | **5 814M** | 2 364M |
| Node: three pages, the Reader script | 1 190M | 742M |

The release build alone is 1.35 budgets, so no split of the steps can fit: every Conduit fixture
builds the whole program. A single-threaded `--self-profile` of the release build puts **2.38 s
of its 3.09 s in `specialise`** (`emit_module` 0.53 s; the whole check 0.15 s). This is a finding
about the release optimiser's cost on a 3 400-line program, not about the test: the budget was
not raised and the release pass was not dropped (CLAUDE.md rule 10). `ApiAndRoutes` sits at the
edge for the same reason: 2.4 billion of its instructions are its release build.

The three scripts and their transcripts are kept in `examples/conduit/tests/`
(`Reader`, `Editor`, `Tour`; §8 has the command). Moving them into the corpus needs two things:
a release build of Conduit that fits, and a way for a project fixture to name sources outside the
corpus (a 20-line `_expected.sources` pointer in `corpus_test.zig`'s `writeSources` was
prototyped and worked; it is not committed, since nothing in the corpus would use it yet).

## 2. Method

The classifier is research 61's, rules unchanged (§2.2–§2.3 there). It needed five fixes to read a
multi-module application at all; each leaves research 61's three outputs (`--table`, `--table
--set=dom`, the full listing) **byte-identical**:

1. **`pub` declarations.** The AST dump writes `(type_decl pub Msg …)` and `(annotation pub
   update …)`; the tool took `pub` as the name, so no `pub` type, alias or annotation of any
   module was ever found. Every corpus program of research 61 declares its types without `pub`.
2. **Names resolved where they are written.** A `Msg` or a `Model` was looked up by its last
   segment in whichever module came last; Conduit has eight of each. Now the annotation's module
   is asked first, an alias lookup stops at a custom type of the same name, and a name inside an
   alias is resolved in the module the alias came from.
3. **A program of several roots** (`a+b`), so a measuring module can sit beside the application.
4. **A `Tea.Document` made by a helper.** Markup reached through a record field (`page.content`,
   `(Home.view model).content`) or a record built by a function (`Page.frame … { title, body }`)
   was one opaque hole; it is now walked like any helper's markup, the helper's parameters bound
   to its arguments where it is called.
5. **A row written as a placeholder call** (`{viewPreview maybeCred _}`): the row was bound to the
   first parameter, not the placeholder's.

Fixes 1, 2, 3 and 5 change no rule. **Fix 4 widens research 61 §2.3's hole walking**, in three
ways:

- a record holding markup is walked as a `Tea.Document` is, at any depth, every field of it
  (not only at the view's top, and not only `title` and `body`), so a record that also held a
  non-markup field would give that field a hole of its own;
- a `case` or `if` on the way to a record field the view reads (`ArticlePage.view`'s `case
  model.article of Loaded article → { title, content }`) gets a `switch` hole, though its
  branches are records, not markup;
- **every** helper's plain-name parameters are now bound as thunks of the call's arguments, not
  as their values, so that markup passed to a helper is walked where the helper places it. The
  reads a parameter contributes are the same either way.

None of the three moves a research 61 result: `master`'s classifier and this one give
byte-identical output on research 61's `--table` (84 lines), `--table --set=dom` (51),
`--list` (75), the full listing (610) and the full `--set=dom` listing (389).

Two levels are measured:

- **Main**, as the runtime dispatches messages: `examples/conduit/src`, 9 constructors.
- **The pages**, as an analysis that followed `Main.update` into the page a message is for would
  see them: `bench/writesets/conduit/Pages.beni` mounts each page's `update` and the `content` of
  its `view` as a program of its own, plus `Feed` (which `Home` and `ProfilePage` delegate to),
  65 constructors. It only measures; it is checked and formatted, and not built.

**Root writes.** A write whose path is the model's root (`(model)`) and that is not `*` is a
**root write**: the classifier calls it *exact* — research 61 §2.2's `*` row needs a record
model — but it conflicts with every read path, so a handler would mark every group, which is
today's path. Counting it as unbounded is a reading this report adds on top of research 61's
rules, not one of them. The tool reports it with `--root` (which changes no output without it):
`--root --table` gives one row per mounted program with a `root` column and the bounded and
exact + indexed counts both ways, and `--root` alone marks root writers `(root)` in the listing.
Every figure in §3 and §6, and Appendix A's `(root)` markers, come from those reports (§8). The
holes a constructor reaches (§3, Appendix A) are the listing's `touched` count, in `--json`.

## 3. Results — constructors

### 3.1 Main: the messages the runtime dispatches

| constructor | tool | root | reaches (of 507 holes; 241 dynamic) |
|---|---|---|--:|
| `ChangedUrl` | exact | yes | 241 |
| `ClickedLink` | exact, writes nothing | | 0 |
| `GotHomeMsg`, `GotSettingsMsg`, `GotLoginMsg`, `GotRegisterMsg`, `GotProfileMsg`, `GotArticleMsg`, `GotEditorMsg` | exact | yes | 241 each |

**Tool: 9 of 9 bounded (100%), exact + indexed 100%. Counting a root write as unbounded: 1 of 9
(11%), exact + indexed 11%** (`--root --table examples/conduit/src`).

### 3.2 The pages and the feed

| program | ctors | exact (writes nothing) | indexed | structural | `*` | root writes | list replaced | mean share of holes reached |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| home | 7 | 7 (0) | 0 | 0 | 0 | 0 | 0 | 34% |
| feed | 4 | 4 (0) | 0 | 0 | 0 | **4** | 0 | 90% |
| article | 17 | 11 (6) | 6 | 0 | 0 | 0 | 0 | 18% |
| editor | 9 | 9 (0) | 0 | 0 | 0 | 0 | 0 | 55% |
| login | 4 | 3 (0) | 1 | 0 | 0 | 0 | 2 | 30% |
| register | 5 | 4 (0) | 1 | 0 | 0 | 0 | 2 | 23% |
| settings | 9 | 8 (0) | 1 | 0 | 0 | 0 | 2 | 47% |
| profile | 10 | 8 (2) | 2 | 0 | 0 | 0 | 0 | 23% |
| **total** | **65** | **54 (8)** | **11** | **0** | **0** | **4** | **6** | **35%** |

**Tool: 65 of 65 bounded (100%) and exact + indexed 100%; exact + indexed with no list replaced
59 of 65 (91%). Counting root writes as unbounded: 61 of 65 (94%), exact + indexed 61 of 65
(94%)** (`--root --table --skip=main` on the pages; the mean share is from `--json`). 27 of the 65 reach more than half of
their page's holes, and 13 reach every dynamic hole of their page (editor's 9, feed's 4).

Research 61's applications (TodoMVC, the table) were 47–53% exact + indexed with 47% structural.
Conduit has **no** structural constructor — not because it edits lists less, but because every
list edit it makes sits under a wrapper the rules stop at (§5).

## 4. Results — holes

| | static | literal-init | static (key) | dynamic | total | event bindings |
|---|--:|--:|--:|--:|--:|--:|
| Main (the whole app's view) | 0 | 264 (52%) | 2 | 241 (48%) | 507 | 81 |
| pages + feed | 9 (4%) | 48 (21%) | 3 (1%) | 167 (74%) | 227 | 64 |

| page | static | literal-init | static (key) | dynamic |
|---|--:|--:|--:|--:|
| home | 1 | 3 | 1 | 29 |
| feed | 0 | 1 | 1 | 18 |
| article | 5 | 20 | 0 | 46 |
| editor | 1 | 16 | 0 | 21 |
| login | 0 | 1 | 0 | 4 |
| register | 0 | 1 | 0 | 5 |
| settings | 0 | 2 | 0 | 9 |
| profile | 2 | 4 | 1 | 35 |

In Main, every hole that reads any path is dynamic (the root writes), and every literal-init hole
reads nothing: markup a helper makes from literals — the navbar's links and labels, the footer,
`Route.href Route.Login`, `class=""` of an avatar, the `For` over `[]` of a form being saved. The
frame is inlined once per page branch (nine times), which inflates Main's 264; per page, 21% of
holes are literal-init. **R3's win does not depend on the root writes**: a hole with an empty read
set is constant whatever a message writes.

The 9 static holes are of two kinds: what a page shows of the session (the comment form's
`case` on the viewer, the avatar's `src`), which no message of those pages writes — and the rows of the append-and-clear error lists. The
`static (key)` holes are each preview's link, which reads only the row's key, the slug.

## 5. The unbounded and coarse writes, idiom by idiom

| idiom | where | constructors | what the tool reports | what a person sees |
|---|---|--:|---|---|
| **a union of pages, rebuilt with its own variant** | `Main.update`: `( GotHomeMsg sub, Home home ) → updateWith Home GotHomeMsg (Home.update sub home)` | 7 | root | the `Home` variant kept, the page's writes below `Home#0` |
| **a route change** | `ChangedUrl → changeRouteTo …` | 1 | root | genuinely a new page: every hole of the old page goes, the new page mounts; the frame's reads of the session are the only holes that survive |
| **an opaque record wrapper** | `Feed`: `Model { model \| articles = List.map … }` | 4 | root of the feed | `Model` kept; `articles` mapped by slug (structural), `errors` appended or cleared (indexed) |
| **a status variant rebuilt around its own parts** | `Editing slug errors (transform form)`, `Loaded (transform form)`, `Loaded ( Editing text, comments )`, `Loaded { article \| author = a }`, `Loaded newFeed` | 16 (listed below) | exact at `status` / `comments` / `article` / `feed` | one field of the form; the comment draft; the author; the feed's own writes |
| **list edits under a wrapper** | `Loaded ( Editing "", [ comment, …comments ] )`, `Loaded ( text, List.filter comments … )` | 2 | exact at `comments` | prepend (indexed); filter by id (structural) |

**The 16, by hand.** A constructor is counted when, on some branch, it rebuilds the variant it
matched around that value's own parts; one whose write changes the variant (`Loading` →
`LoadingSlowly`, `Saving` → `Editing`, `Loading` → `Loaded` from decoded data) or replaces
the value from a payload (`Loaded newArticle`) is not, because a write of the whole path is
then what a person would say too:

- Editor (4): `EnteredTitle`, `EnteredDescription`, `EnteredBody`, `EnteredTags` — not
  `ClickedSave` (`Editing` → `Saving`), `CompletedCreate` and `CompletedEdit` (`Ok`: nothing;
  `Err`: `Saving` → `Editing`), `CompletedArticleLoad` (`Loading` → `Editing`),
  `PassedSlowLoadThreshold`;
- Settings (5): `EnteredEmail`, `EnteredUsername`, `EnteredPassword`, `EnteredBio`,
  `EnteredAvatar` — not `CompletedFormLoad` (`Loading` → `Loaded`) or `PassedSlowLoadThreshold`;
- Article (5): `EnteredCommentText`, `ClickedPostComment`, `CompletedPostComment`,
  `CompletedDeleteComment` (`Loaded` kept around the comment list), `CompletedFollowChange`
  (`Loaded { article | author = … }`) — not `CompletedFavoriteChange` (`Loaded newArticle`, a
  payload), `CompletedLoadArticle`, `CompletedLoadComments`;
- Home (1) and Profile (1): `GotFeedMsg` (`Loaded newFeed` under `Loaded feed`).

Of the 16 `status` writes in Appendix A, then, 9 are rebuilds and 7 are variant changes; the
list-edit row below overlaps this one (its 2 are `CompletedPostComment` and
`CompletedDeleteComment`).

Every `*`-in-effect is one of the first three rows: 8 root writes in Main and 4 in `Feed`. None is
research 61's `*` patterns (restore from a decoder, recursion over the model, undo snapshot):
Conduit has none of those at the root. What it has instead is the elm-spa structure itself, which
research 61's corpus did not contain.

What an analysis needs to recover them, in order of what it buys:

1. **Same-variant rebuilds.** "A constructor applied to the matched value's own parts is that
   value, with the parts' writes below it" — `Home (Home.update sub home)` under `( _, Home home )`,
   `Model { model | … }` under `(Model model)`, `Loaded (transform form)` under `Loaded form`. This
   turns Main's 7 page constructors from root writes into page-bounded ones, `Feed`'s 4 into
   `articles`/`errors`, and the 16 coarse status writes into field writes.
2. **Nested dispatch.** With (1) alone, `GotEditorMsg`'s write set is the union over all nine
   `Editor.Msg` constructors, which is `Editor#1.status` — the whole editor. Per-constructor
   precision needs R4's handler table keyed by the message *path*
   (`GotEditorMsg (EnteredTitle _)`), which `Html.map` and `Cmd.map` make statically visible.
3. **List edits inside wrappers**, which then follow from (1): R5's order holds (append and
   clear, then `map` by key, then `filter` by key), with prepend for comments.

## 6. Verdict against research 58's criterion

The plan's rule (§4 V1): *if fewer than about two thirds of Conduit's constructors have a bounded
write set (exact + indexed + structural), R4 and R5 shrink to R2, R3 and R5's append/clear.*

| level | bounded, tool | bounded, root counted as unbounded | exact + indexed, tool | exact + indexed, root as unbounded |
|---|--:|--:|--:|--:|
| Main (what R4 as specified dispatches on) | 9/9 (100%) | **1/9 (11%)** | 100% | **11%** |
| pages + feed, each page's `update` analysed as its own program (assumes nested dispatch) | 65/65 (100%) | 61/65 (94%) | 100% | 94% |
| the same, **if** same-variant rebuilds were analysed — **[by hand]**, not measured | 65/65 | 65/65 | 63/65 (97%) | 63/65 (97%) |

R4 as `compile-away.md` §3 specifies it emits one handler per `Msg` constructor. Conduit's `Msg`
has 9, and 8 of them write the whole model: R4 would mark every group for 8 of 9 messages, which
is today's path with extra code. **By the criterion as stated, Conduit fails it (11%), and R4 and
R5 shrink to R2, R3 and R5's append/clear.**

The finding behind the number matters more than the number: the deciding factor is not list
idioms, persistence or undo, but **nested pages**. The two lower rows of the table are not a
measurement of the analysis R4 would need. The tool implements neither part of it: the 94% row
comes from `Pages.beni` mounting each page's `update` as a program of its own, which is nested
dispatch assumed, not analysed — the Main row and that row differ only by that assumption — and
the tool has no same-variant rule, so the last row is what such a rule would give, counted by
hand from §5. What they say is that if R4's specification includes dispatch on the message path
and same-variant rebuilds (§5 items 1–2), Conduit's constructors are no longer root writes, its
list edits become visible to R5, and the criterion would be met with room. Whether
that analysis is in scope is the decision this measurement hands to R4's spec; without it, R4 has
nothing to work with on an elm-spa-shaped application.

R3 (constancy) is unaffected either way: 21% of a page's holes and 52% of the whole view's are
literal-init (§4).

## 7. Gaps

Each is stubbed with a `-- GAP:` comment where it bites; none was worked around with `foreign` or
an edit to `core/` or a platform.

1. **A `Dict` schema** (`Api.serverErrors`). The API's 422 body is `{"errors": {"<field>":
   ["<message>", …]}}`, an object whose keys are data. Needs `Schema.dict : Schema e a → Schema
   (Dict String e) (Dict String a)` and its declaration form (schema.md S8). Stub: the raw body is
   the one message shown (the Editor transcript shows `{"errors":{"title":["has already been
   taken"]}}`).
2. **Markdown → `Html`** (`Article.body`). Needs a Markdown library in beni (a CommonMark subset,
   specified first; elm-explorations/markdown is the Elm one), producing `Html msg` without
   `innerHTML`. Stub: paragraphs split on blank lines, as text.
3. **Dates** (`Article.timestamp`). Needs ISO 8601 parsing to `Time.Posix`, a time zone (Elm's
   `Time.here`), and month names, after Elm's `Time` and `elm-iso8601-date-strings`. Stub: the ISO
   string as sent. elm-spa's `GotTimeZone` messages are absent for the same reason.
4. **A storage-change subscription** (`Main.changeRouteTo`, `Logout`). elm-spa hears the stored
   user change through a port in every tab; beni has no `Storage.onChange` (the `storage` event).
   Stub: this tab signs itself out; other open tabs keep the old session until reloaded.

Smaller findings, not gaps:

- A `nullable` field of a `schema` declaration is a `Schema.Nullable a`, and a declaration cannot
  convert it to `Maybe` (`via` applies inside `nullable`; a library schema value is not a
  declaration operand), so every model converts by hand (`Api.fromNullable`).
- Markup cannot be a call's argument inside a hole (`{Article.link article <>…</>}` is
  `expected_token`); it is bound to a name first.
- `Http.expectStringResponse` (needed to read a 422's body) sends no `Accept: application/json`,
  where `expectJson` does.
- RealWorld routes with `#/`; this app routes on paths, which `Url.Parser` reads directly.

## 8. Reproducing it

```sh
# the classifier (BENI: any beni with `dump --stage=ast`)
BENI=zig-out/bin/beni node bench/writesets/classify.mjs examples/conduit/src
BENI=zig-out/bin/beni node bench/writesets/classify.mjs examples/conduit/src+bench/writesets/conduit/Pages.beni
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --table examples/conduit/src+bench/writesets/conduit/Pages.beni
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --json  examples/conduit/src+bench/writesets/conduit/Pages.beni

# root writes: §3.1's 11%, §3.2's 94%, Appendix A's (root) markers
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --root --table examples/conduit/src
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --root --table --skip=main examples/conduit/src+bench/writesets/conduit/Pages.beni
BENI=zig-out/bin/beni node bench/writesets/classify.mjs --root examples/conduit/src+bench/writesets/conduit/Pages.beni

# the parked page scripts, development and release
(cd examples/conduit && ../../zig-out/bin/beni build)
node tests/browser/driver.mjs --dom=tests/browser/happy-dom.mjs examples/conduit/out/_main.mjs \
    examples/conduit/tests/Reader.steps | diff - examples/conduit/tests/Reader.expected
```

The full listing gives every hole with its read set; the table in Appendix A gives every
constructor's writes.

## Appendix A — every constructor

`(root)` marks a root writer, as `--root` prints it (§2). *Sent by*: `event` from the view, `async` from a
command, `host` from `onUrlRequest`/`onUrlChange`, `unsent` built by an `init` the measuring module
does not mount (`Editor.initEdit`).

**main** (507 holes)

| constructor | class | sent by | writes (path [why]) | holes reached |
|---|---|---|---|--:|
| ChangedUrl | exact **(root)** | host | `(model)` [computed value]; `(model)` [value from call of a value] | 241 |
| ClickedLink | exact | host | nothing | 0 |
| GotHomeMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotSettingsMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotLoginMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotRegisterMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotProfileMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotArticleMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |
| GotEditorMsg | exact **(root)** | event+async | `(model)` [value from call of a value] | 241 |

**home** (34 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| ClickedTag | exact | event | `feedTab`, `feedPage` | 3 |
| ClickedTab | exact | event | `feedTab`, `feedPage` | 3 |
| ClickedFeedPage | exact | event | `feedPage` | 0 |
| CompletedFeedLoad | exact | async | `feed` | 23 |
| CompletedTagsLoad | exact | async | `tags` | 3 |
| GotFeedMsg | exact | event+async | `feed` | 23 |
| PassedSlowLoadThreshold | exact | async | `feed`, `tags` | 26 |

**feed** (20 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| ClickedDismissErrors | exact **(root)** | event | `(model)` | 18 |
| ClickedFavorite | exact **(root)** | event | `(model)` | 18 |
| ClickedUnfavorite | exact **(root)** | event | `(model)` | 18 |
| CompletedFavorite | exact **(root)** | async | `(model)` | 18 |

**article** (71 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| ClickedDeleteArticle | exact | event | nothing | 0 |
| ClickedDeleteComment | exact | event | nothing | 0 |
| ClickedDismissErrors | indexed | event | `errors{spine}` (clear) | 2 |
| ClickedFavorite | exact | event | nothing | 0 |
| ClickedUnfavorite | exact | event | nothing | 0 |
| ClickedFollow | exact | event | nothing | 0 |
| ClickedUnfollow | exact | event | nothing | 0 |
| ClickedPostComment | exact | event | `comments` | 12 |
| EnteredCommentText | exact | event | `comments` | 12 |
| CompletedLoadArticle | exact | async | `article` | 32 |
| CompletedLoadComments | exact | async | `comments` | 12 |
| CompletedDeleteArticle | indexed | async | `errors{spine}` (append) | 2 |
| CompletedDeleteComment | indexed | async | `comments`, `errors{spine}` (append) | 14 |
| CompletedFavoriteChange | indexed | async | `article`, `errors{spine}` (append) | 34 |
| CompletedFollowChange | indexed | async | `article`, `errors{spine}` (append) | 34 |
| CompletedPostComment | indexed | async | `comments`, `errors{spine}` (append) | 14 |
| PassedSlowLoadThreshold | exact | async | `article`, `comments` | 44 |

**editor** (38 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| ClickedSave | exact | event | `status` | 21 |
| EnteredBody | exact | event | `status` | 21 |
| EnteredDescription | exact | event | `status` | 21 |
| EnteredTags | exact | event | `status` | 21 |
| EnteredTitle | exact | event | `status` | 21 |
| CompletedCreate | exact | async | `status` | 21 |
| CompletedEdit | exact | async | `status` | 21 |
| CompletedArticleLoad | exact | unsent | `status` | 21 |
| PassedSlowLoadThreshold | exact | unsent | `status` | 21 |

**login** (5 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| SubmittedForm | indexed | event | `problems{spine}` (clear); `problems` (list replaced, `List.concatMap`) | 2 |
| EnteredEmail | exact | event | `form.email` | 1 |
| EnteredPassword | exact | event | `form.password` | 1 |
| CompletedLogin | exact | async | `problems` (list replaced), `session` | 2 |

**register** (6 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| SubmittedForm | indexed | event | `problems{spine}` (clear); `problems` (list replaced) | 2 |
| EnteredUsername | exact | event | `form.username` | 1 |
| EnteredEmail | exact | event | `form.email` | 1 |
| EnteredPassword | exact | event | `form.password` | 1 |
| CompletedRegister | exact | async | `problems` (list replaced), `session` | 2 |

**settings** (11 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| CompletedFormLoad | exact | async | `status` | 6 |
| SubmittedForm | indexed | event | `problems{spine}` (clear); `problems` (list replaced) | 2 |
| EnteredEmail | exact | event | `status` | 6 |
| EnteredUsername | exact | event | `status` | 6 |
| EnteredPassword | exact | event | `status` | 6 |
| EnteredBio | exact | event | `status` | 6 |
| EnteredAvatar | exact | event | `status` | 6 |
| CompletedSave | exact | async | `problems` (list replaced), `session` | 3 |
| PassedSlowLoadThreshold | exact | async | `status` | 6 |

**profile** (42 holes)

| constructor | class | sent by | writes | holes reached |
|---|---|---|---|--:|
| ClickedDismissErrors | indexed | event | `errors{spine}` (clear) | 2 |
| ClickedFollow | exact | event | nothing | 0 |
| ClickedUnfollow | exact | event | nothing | 0 |
| ClickedTab | exact | event | `feedTab`, `feedPage` | 3 |
| ClickedFeedPage | exact | event | `feedPage` | 0 |
| CompletedFollowChange | indexed | async | `author`, `errors{spine}` (append) | 9 |
| CompletedAuthorLoad | exact | async | `author` | 7 |
| CompletedFeedLoad | exact | async | `feed` | 23 |
| GotFeedMsg | exact | event+async | `feed` | 23 |
| PassedSlowLoadThreshold | exact | async | `author`, `feed` | 30 |

## Appendix B — hand checks

29 constructors, every root write among them, checked against the source. The tool's paths agree
with every one; where its path is coarser than a person's, the note says why.

| program · constructor | by hand | tool | note |
|---|---|---|---|
| Main · `ChangedUrl` | the whole page replaced by `changeRouteTo` (or kept: `Root` only navigates) | root | inherently whole-page |
| Main · `ClickedLink` | nothing (a navigation command) | exact ∅ | |
| Main · `GotHomeMsg` | `Home#0` rebuilt by `Home.update`; other pages: nothing (`( _, _ )`) | root | same-variant rebuild |
| Main · `GotSettingsMsg` | as `GotHomeMsg`, under `Settings#0` | root | same |
| Main · `GotLoginMsg` | under `Login#0` | root | same |
| Main · `GotRegisterMsg` | under `Register#0` | root | same |
| Main · `GotProfileMsg` | under `Profile#1` (the username kept) | root | same |
| Main · `GotArticleMsg` | under `Article#0` | root | same |
| Main · `GotEditorMsg` | under `Editor#1` (the slug kept) | root | same |
| Feed · `ClickedDismissErrors` | `errors` cleared | root | opaque wrapper |
| Feed · `ClickedFavorite` / `ClickedUnfavorite` | nothing (a command) — `Model model` rebuilt unchanged | root | the wrapper hides even "nothing" |
| Feed · `CompletedFavorite` | `articles` mapped, the slug's article replaced (structural); or `errors` appended | root | the map-by-id idiom, hidden |
| Home · `ClickedTag` | `feedTab`, `feedPage` | exact, same | |
| Home · `PassedSlowLoadThreshold` | `feed`, `tags`: `Loading` → `LoadingSlowly`, else unchanged | exact `feed`, `tags` | |
| Article · `EnteredCommentText` | `comments.Loaded#0.0` (the draft) | exact `comments` | same-variant rebuild; the 12 comment holes are reached |
| Article · `ClickedPostComment` | `Editing` → `Sending`, the list kept | exact `comments` | |
| Article · `CompletedPostComment` | draft cleared, comment prepended; or draft restored, `errors` appended | indexed: `comments`, `errors` | prepend hidden |
| Article · `CompletedDeleteComment` | `List.filter` by id inside `Loaded`; or `errors` appended | indexed: `comments`, `errors` | filter hidden |
| Article · `CompletedFollowChange` | `article.Loaded#0.author`; or `errors` appended | indexed: `article`, `errors` | |
| Editor · `EnteredTitle` | `status.<variant>.title`, whichever variant holds the form | exact `status` | `updateForm`'s seven arms |
| Editor · `ClickedSave` | `Editing` → `Saving` (or `Editing` with problems) | exact `status` | a variant change: `status` is right |
| Settings · `EnteredBio` | `status.Loaded#0.bio` | exact `status` | |
| Settings · `CompletedFormLoad` | `status`: `Loading`/`LoadingSlowly` → `Loaded form` (decoded), or → `Failed` | exact `status` | a variant change: `status` is right |
| Settings · `CompletedSave` | `Ok`: `session` (the viewer saved; the page then navigates away); `Err`: `problems` replaced by the server's | exact `problems` (list replaced), `session` | agrees |
| Editor · `CompletedEdit` | `Ok`: nothing (a navigation command); `Err`: `Saving slug form` → `Editing slug problems form` | exact `status` | the join of the two; `Ok` alone writes nothing |
| Editor · `CompletedArticleLoad` | `status`: `Loading slug` → `Editing slug [] form` from the article, or → `LoadingFailed slug` | exact `status` | a variant change: `status` is right |
| Login · `SubmittedForm` | `problems` cleared or replaced by `validate`'s list | indexed, list replaced | |
| Profile · `CompletedFollowChange` | `author` replaced; or `errors` appended | indexed | |
