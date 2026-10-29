# Prerendered pages — a static site build of `browser-inline`

*2026-10-29, #1160. **Specified; slices P1 and P2a built** (2026-10-29, #1165, #1178, §11 *As built — P1*, *As built — P2a*). The contract for a build of a `browser-inline`
program that writes one HTML page per route, each the program's first render, which the same
program then takes over in the browser. It holds what is decided, what is open with a
recommendation (§10), and the slices with what "done" means for each (§11). Section numbers are
never renumbered (CLAUDE.md rule 2); a later change is a dated amendment in place.*

## 1. What this is

The owner's request, 2026-10-29: write an ordinary website in beni, and have the build write one
prerendered `.html` per route — `index.html`, `blog/my-blog.html` — that a static host serves as
files. There is **no backend** and **no rendering at request time**. Each page holds the program's
view of its first model, rendered when the program is built. The browser then loads the same
single-page app, which **takes the page over** (hydration) and runs as every `browser-inline` page
runs: events, `update`, write passes, commands.

What the first model does not show is not in the page. A popup that `init` closes is not in the
HTML: the client makes it from its template when it opens, as a client-rendered page does today.

What it buys: a page that shows its content before any JavaScript runs, which a crawler reads, and
which a host serves with no server code. What it does not do: render per request, stream, or
fetch data on a server. Those need a server: `node` serves HTTP (`boundary.md` §9.10) and has the
`ssr` lowering (§9.1's table there).

The words used below:

- **the string form** — what the `inline` lowering writes for a view so that it gives the page's
  HTML as a string (§4);
- **the prerender tree** — a second emit of the program, with the string form, that the build runs
  under the `node` on `PATH` to get the pages (§5);
- **a route** — a path below the base that the build writes a page for (§7);
- **a unit** — as in `browser-inline.md` §8.2: the program's `view`, with the pieces of other
  modules written into its one string (§8.4 there), whose elements the mount numbers `E[n]`. Each
  piece's root also has a table of its own, read from the page with `Inline.part` below its
  placement element (`Inline.roots`), and an element some code refers to alone is reached by a
  `firstChild`/`childNodes[i]` path instead of a table (§8.2 there, amended 2026-10-17). §6.2 covers
  all three.

The citations of `references/dom-expressions` and `references/solid` need those submodules checked
out (`references/README.md`).

## 2. Where it lives: a build of `browser-inline`, not a new platform

**It is a build of the existing `browser-inline` platform.** `main` keeps its type,
`Browser.Program` (`boundary.md` §5), and the JavaScript the browser loads is the platform's.
A new platform is needed only for a new `Program` type or a new output shape that the manifest
cannot declare (§5, §5.2 there); neither is the case. The page is the platform's `"html"` shell
with the view written into it (§5.3), and the routes are a value of `main` (§7.2).

**`node`'s `ssr` lowering cannot render a `browser-inline` program.** A chain has one markup
lowering, the first one found (`boundary.md` §9.2: *"the first found wins, which is how one
vocabulary is lowered two ways"*), so a build gets either `inline` or `ssr`, never both. And a
`browser-inline` program imports `Tea`, `Browser`, `Cmd` and `Inline`, which a `node` build does
not have (§5.3 there: *"a module that uses a browser-only capability simply fails to resolve when
compiled for the server"*). The `ssr` lowering also writes a string per markup value at run time
(`platforms/node/Ssr.beni`, `markup.js`), with none of `inline`'s numbering, so its output could not
be taken over by the `inline` mount even if it could be built.

**So the `inline` lowering compiles one view to two forms**, as dom-expressions compiles one
component to `dom` and to `ssr` with `hydratable` set (research 36 §5.5: *"a target variant the
platform opts into, not new platform code"*). The mount form is what the lowering writes today; the
string form is new (§4). This is Solid's design, taken by default (CLAUDE.md rule 8).

**Rejected: render with a DOM emulator at build time.** The build could run the client mount under
happy-dom (vendored for the tests, `tests/browser/happy-dom.mjs`) and serialise the document. It
needs no string form, but it makes the build's output depend on the emulator's HTML serialiser and
parser — `tests/corpus/README.md` lists the known differences between happy-dom and Chrome — it
puts a test dependency into every user's build, and it serialises a `when`'s hidden arm as nothing
at all, so the client could not tell where the arm goes (§6.3). Solid does not do it either.

## 3. The guarantee: the build and the browser compute the same first render

**The claim.** For every route `r`, the page the build writes holds the HTML of
`view (init r)`, and the browser's first render of that page computes `view (init r)` too, with
the same `r`. So the page the client takes over is the page it would have made: **no mismatch
between the prerendered page and the program is possible for a program the build accepts**, except
by the causes §3.3 names, none of which is in the program.

### 3.1 What makes it hold

1. **`init` and `view` are functions of their arguments.** They are `sync` already
   (`platforms/browser-inline/Tea.beni`: `init : sync (⊤ → model)`, `view : sync (model → Html
   msg)`), so neither suspends. `sync` does not make them pure: a `sync` function may still call an
   impure `foreign` (`language.md` §5.4, the `sync` row; `checker-v2.md` §26). **A prerendered
   program's `init`, `view` and route list must be pure**, by the checker's inferred rung, or the
   build refuses it (`prerender_impure`, §9), naming the call that makes it impure. The one exempt
   call is `Debug.log` (and `Debug.logAs`), whose value is its argument. It is `console.log`
   (`core/Debug.beni`), so under Node it writes to standard output, which is why the records do not
   use that stream (§5.1); the build passes what Node writes on to its own standard error. A release
   build refuses `Debug` anyway (`backend.md` §9).

   *Amended 2026-10-29, as built in P1 (#1165).* The compiler reads the rung at each call of
   `init`'s and `view`'s bodies (the checker's `impure` answer, `checker-v2.md` §26): a call of a
   function of `Debug` is exempt, a call of a function of the program's own module is answered by
   that function's body, walked once, and any other call the checker says may be impure is the
   call `prerender_impure` names. A call the checker answers impure whose body the walk finds no
   effect in — a function bound point-free, `stamp = Clock.now` — is refused at the call: its
   value carries the effect. A read of a top-level constant of the program's module is answered by
   the constant's body, since the constant is computed where the module loads, in the build as in
   the browser (`seed = Clock.now ⊤`). What the build cannot read is refused too, as limits of the
   build, not rules (#1170): an `init` or a `view` that is another module's function named in the
   record (write `λ⊤ → Other.init ⊤`), a read of another app module's constant, a call of a
   function of another module whose only effect is `Debug`'s, and a method call or an operator
   dispatched to a type's function (`<` on a type whose `compare` logs) the checker answers
   impure.
2. **The input is the same value in both places.** The build passes the route it lists; the page
   carries that route (§6.1), and the client passes what the page carries, never what it reads
   from `location` (§7.3). The address the page was opened at reaches the program only after the
   first render, as a message (§7.3).
3. **Effects run only after the first render.** A `Tea.element` program's `init` command runs after
   the first pass, in the browser (`browser-inline.md` §4); subscriptions start then too (§3
   there). The build never runs a command, starts a subscription or calls `update`.
4. **The same code computes it.** The prerender tree and the client tree are two emits of one
   checked program, by one lowering, in the build's mode (§5.1). Both run on an ECMAScript engine:
   numbers print by the standard's `Number::toString`, which is exact and the same on every engine,
   and sorting is stable by the standard. One part is not computed by emitted code: the values the
   write-set pass bakes from `init` into the unit's string at compile time, in Zig (`write-sets.md`
   §9.1, *O8 widened*: a model path whose `init` value is a string or an integer of at most 2⁵³).
   The string form writes the same baked bytes, so the two agree; baking is exact by §9.1's rules.

### 3.2 Why a text or a property that differs does no harm

The first pass of the client runs every binding function once (`Inline.first`), and each binding
compares before it writes (`text`, `prop`, `browser-inline.md` §8.2). So a text or a property that
the page shows differently from the model is **written by the first pass, not trusted**: the page
heals. This is where beni differs from Solid, which claims text by position and never compares it
(`references/dom-expressions/packages/runtime/src/client.js`, `claimInitial`). This covers the
holes that have a binding only. A baked value (§3.1 item 4) has no binding, so a host that edits a
baked text keeps its edit, as it would on a fresh page whose string it edited. What a first pass
cannot heal is **structure**: which elements exist, because `E[n]` numbers them by document order
(§6.2). Structure is what §3.3 and §6.4 guard.

### 3.3 What could still break it, and what the build or the page does about each

| Cause | Where | What happens |
|---|---|---|
| an impure `init`, `view` or route list: a read of the host, the clock, randomness | the program | refused at build, `prerender_impure` (§3.1) |
| a `foreign` declared `pure` that reads the host | a platform or core | a platform defect, outside the guarantee: `pure` is the platform's promise (`boundary.md` §4); a review that finds one treats it as a defect |
| a `Math` function whose result the standard leaves to the engine (`Math.sin`, `Math.exp`, `Math.pow` of non-integers), printed into a text | the engine | the text differs in its last digits; the first pass rewrites it (§3.2); no structure depends on it unless a branch compares such a value, which is the next row |
| a branch chosen by such a value (`if Float.sin x > 0.5`) | the engine | a structural mismatch, found and handled at hydration (§6.4) |
| the HTML changed after the build: a CDN that rewrites e-mail links, a browser extension that inserts elements, a hand edit | the host | found and handled at hydration (§6.4) |
| a view that throws or does not end | the program | a throw fails the build, `prerender_failed`, with the route (§5.5); a view that never ends never ends in the browser either, and the build waits as any program does |

## 4. The string form

### 4.1 What the lowering writes

For each program site (`browser-inline.md` §7), the `inline` lowering writes, beside the mount, a
top-level exported function `<Module>$<declaration>$$render`: given the route (§7.3), it evaluates
`init` and gives the unit's HTML as a string. For each view piece of another module (§8.4 there),
the module that declares it writes `<Module>$<declaration>$$render$<n>` beside `$$html$<n>` and the
`$$bind$<n>$<k>` functions, taking the piece's parameters and giving its HTML. The names follow §7's
rule there: input-derived, never an instruction index (CLAUDE.md rule 5).

Nothing the client loads reaches these functions, so reachability (`backend.md` §9) leaves them out
of the client tree, and **a program that does not prerender, and the client tree of one that does,
is byte for byte what the lowering writes today** — the existing `emit/inline/` and
`emit/release/inline/` goldens do not move (§11, every slice).

*Amended 2026-10-29, as built in P1 (#1165).* The lowering is told which tree it writes
(`Build.prerender`, §4.4), and writes a render function only in the prerender tree, so no client
tree holds one and reachability has nothing to leave out. In the prerender tree the program
site's render function takes the mount's place: the call of the program constructor compiles to
it, so `main` is the render function, and the entry exports it (§5.1); no
`<Module>$<declaration>$$render` is named. A piece's `<Module>$<declaration>$$render$<n>` takes,
before the piece's parameters — the values its factory is handed after its elements — the
ordinal of the piece's first eager arm in the unit, so its comments number the unit's arms (§4.1,
*An eager `when`*); the program site passes it and counts the piece's arms after it.

The string is the unit's static string (`browser-inline.md` §8.2) with each hole's value in its
place:

- **A text hole and a mixed text** — the text the binding would write, escaped by the rules
  `write-sets.md` §9.1 already gives for a baked string (amended 2026-10-09): `&`, `<` and a
  carriage return as `&amp;`, `&lt;` and `&#13;`, so the parsed text is the text written. A NUL is
  written as it is; the parser replaces it with U+FFFD and the first pass rewrites the text (§3.2).
  An empty text writes nothing, as the client's string does, so the element has no child in both.
  In a `pre`, a `textarea` or a `listing`, a text that begins with a newline gets one more newline in
  front, which the parser drops.
- **An attribute** — a constant one as in the client's string. One whose value changes is written
  with the value `init` gives it, escaped and quoted by the same rules. A `prop` of a boolean
  attribute (`disabled`, `hidden`, `checked`, `selected`, …) is the bare attribute when true and
  absent when false. A control's `value` is its `value` attribute (a `textarea`'s, its text); a
  `select`'s `value` marks the `option` whose `value` it equals as `selected`, where the option's
  value is a constant or a hole of the same unit, and otherwise the first pass writes it.
- **An event** — nothing. A listener is the client's (research 36 §2.12 records the same for
  Solid's `ssr`).
- **An eager `when`** (§8.2 there) — the arm `init`'s model shows is written; **an arm it hides is
  not**, as the owner asked. In its place the string writes a comment, `<!--n-->`, where `n` is the
  arm's ordinal among the unit's eager arms in document order. An arm inside a hidden arm writes
  nothing at all: its outer arm is not in the page.
- **The evaluation order** is §8.2's: a value that may throw is evaluated before the string is
  built, and guarded arms are evaluated only when shown. With `init` and `view` pure (§3.1), the
  order changes only which throw a view that throws reports first.

### 4.2 End tags, and the unit's top element

The string form keeps §8.2's rules for end tags inside the unit, which are rules of the HTML tree
builder and hold wherever the string is parsed. It **writes the closing run of end tags at the end
of the unit**, which §8.2 leaves out only for *"a string parsed alone"*: in a page, the shell's own
markup follows the unit, and the run must not depend on it.

*Amended 2026-10-29, as built in P1 (#1165).* The string form writes **every end tag** but a void
element's. §8.2 leaves an end tag out where the next sibling's start tag closes the element as the
end tag would, and in the string form the next sibling may be an arm `init` hides, written as its
comment, which closes nothing. An end tag written is closed by the parser exactly as one left out
would be, so the tree is §8.2's either way, at a few bytes per page.

The unit's top element gets one attribute, `data-beni` (its value, the route, from slice P3, §7.3).
It is how the client finds the unit (§6.1): an attribute on the element survives the whitespace, the
comments and the scripts a template or an extension puts around it, which a position such as
`lastChild` does not. Solid marks the root of each template with `_hk` for the same reason
(`references/dom-expressions/packages/runtime/src/server.js`, `ssrHydrationKey`); beni needs one
mark per page, because one string holds the whole unit and its elements are found by number.

### 4.3 The runtime it calls

The escaping functions are `pub` functions of `Inline.beni`, the platform's runtime module
(`boundary.md` §9.2, *A runtime module*), written in beni over `Js`. Only the prerender tree reaches
them, so a client page ships none of them.

### 4.4 The interface

The string form is facts the lowering already has — each hole's value, each arm's branch — so the
markup lowering interface needs two additions, both additive (`boundary.md` §9.4.6): a program
lowering may write a render function at its program site, and the emitter roots the prerender tree
at it; and the lowering learns the rung of `init`, `view` and the route list from the checker, as
`programCommand` learns whether a body may suspend (§2 there). They are version 1.20, recorded in
§9.4.6 when slice P1 lands.

*Amended 2026-10-29, as built in P1 (#1165; `boundary.md` §9.4.6, version 1.20).* The two
additions are three members: `Lowering.prerenders`, that the lowering writes render functions — a
prerendering build of a chain whose lowering does not is refused; `Build.prerender`, which tree is
lowered (`none`, `tree`, `client`), in place of the emitter rooting a tree at a render function
(§4.1's amendment); and `programPure(part)`, which refuses an `init` or a `view` that may have an
effect: the compiler, which alone can name the call, reports `prerender_impure` (§3.1's
amendment), so the lowering learns the answer, not the rung. The route list's rung is P3's.

## 5. The build

### 5.1 The prerender tree, and Node

`beni build` has never run JavaScript: every thread it starts is its own, and only the test
harness starts `node` (`tests/blackbox/world.zig`, `runNode`). A prerendered program changes that,
for that program only:

1. The build checks the program once and emits **two trees**: the client tree into `--out`, as
   today, and the prerender tree into a directory of the build's own, outside `--out` (the cache
   directory when there is one). The prerender tree is rooted at the render function and the route
   list, emitted in the build's mode (development or `--release`), and written **without** the
   manifest's `"host": "page"` promise (`boundary.md` §5.2), since it does not run in a page.
2. The build runs `node` on the prerender tree's entry, `_prerender.mjs`, and gives it the path of
   a records file in the prerender tree's directory. The entry evaluates the route list and, for
   each route in order, the render function, and appends one record per route to that file: the
   route and its HTML, as JSON lines. The records are not on standard output, which a
   `Debug.log` writes to (§3.1); the build passes Node's standard output and standard error on to
   its own standard error.
3. **Node computes; beni writes.** The build reads the records, checks each route (§7.4), writes
   each page into the shell (§5.3), and puts every page through `pending` like every other output
   (`backend.md` §2). So rule 2's folding check, `_manifest.txt` and the removal of stale files all
   apply to pages unchanged, and a refused build writes nothing.
4. The build removes the prerender tree.

*Amended 2026-10-29, as built in P1 (#1165).* Item 1: the prerender tree's directory is beside
`--out`, `.<out>.prerender` — never inside it, and named after it so that two builds of different
outputs do not share one (an output named `.` or `..` keeps it inside, as `.beni-prerender`,
removed before the output is written) — rather than the cache directory, which a build need not have; the
build removes it whether the build succeeds or not. Item 2: `_prerender.mjs` **exports** `routes`
and `render` and runs nothing, so that it is the part of the tree an engine that runs ES modules
runs as it is; beside it the build writes `_node.mjs`, Node's
runner, the one file that uses Node's API, which renders each route in order and appends its
record. What Node writes is passed on to the build's standard error when the diagnostics are
text; under `--diagnostics=json` that stream is the array of diagnostics alone (`frontend.md`
§1), and Node's output is dropped. Item 3: the build checks the tree first — `init`, `view`, the
shell's `{{view}}` (§5.3) — so a program the build refuses never runs.

**The tree runs under the `node` on `PATH`, and that is the design** (the owner, 2026-10-29, §10
question 1). Node is a dependency of the build only for a program that prerenders. With none on
`PATH` the build fails with `prerender_needs_node` (§9), saying what to install, and `beni` looks
for `node` in `PATH`'s directories alone, never in a default path. The flake pins Node 24
(CLAUDE.md, *Details about the project*). Node is V8, as Chrome is, so where the standard leaves a
result to the engine (§3.3's `Math` rows), the build and Chrome agree, and every host API core
calls during a render — `URL` among them — is there. The playground, which cannot start a process,
refuses a prerendered program with `prerender_needs_node`.

*Corrected 2026-10-29.* An entry of the same day said the end state embeds a JavaScript engine in
`beni`, with a slice P5 to add it. That was the manager's misreading of the owner's "go with the
recommendation", which meant this document's recommendation, Node. The owner did not decide an
embedded engine; it is withdrawn, with P5 and `prerender_unsupported`.
[`research/108`](research/108-embedded-js-engine.md) stays as the measurement of that option, should
it ever be reopened: QuickJS-ng, and what it would owe (a `URL`, a pinned `Math`, a static link).

### 5.2 When a program prerenders

A program prerenders when its `main` says so, with `Browser.prerender` (§7.2): the build needs no
flag, and a program builds the same way under `build`, `build --watch` and `serve`. `serve` and
`--watch` prerender after each successful build, so development takes over a prerendered page as
production does; a build that fails at prerender is a failed build, and `serve` keeps the last good
one (`frontend.md` §10.4). Slices P1 and P2, before the route list, prerender only `index.html`, and
are switched on by a hidden, test-only flag until P3 gives the program its own way to say so (§11).

### 5.3 The page shell gets `{{view}}`

The shell is the chain's or the app's `"html"` (`backend.md` §2, *The page shell*). It gets a third
placeholder, **`{{view}}`**, which the build replaces with the route's HTML. The template writes it
where the program mounts: inside `<body>` for a program that mounts at `document.body`, inside the
element `Browser.mountAt` names otherwise, and as that element's last content, since a mount writes
after the element's children (`Browser.mountAt`'s doc comment).

- In a build that does not prerender, `{{view}}` is replaced with nothing, so a template may hold it
  always. `platforms/browser-inline/index.html` gets `<body>{{view}}</body>`.
- **A prerendering build needs exactly one `{{view}}`**: none, or two, is `invalid_html_shell`,
  against the template at `1:1`, as a missing `{{entry}}` is. A page whose view is nowhere is a
  build that succeeded and shows nothing, the silent wrong answer §2's rule for `{{entry}}` refuses.
- The build cannot see where in the template `{{view}}` stands without parsing HTML, and does not
  parse it. A `{{view}}` outside the mount element is found in the page: a development build's mount
  throws *"cannot take over the page at …: the prerendered view is not inside the element the program
  mounts at"*, as it throws for a missing mount element (`browser-inline.md` §6); a release build
  mounts fresh (§6.4).

  *Amended 2026-10-29, as built in P2a (#1178).* "Inside" is "a child of": the mount takes the
  unit over only when its parent is the mount element, as a fresh mount's unit is. A unit deeper
  down — `{{view}}` inside a `<main>` of a body-mounted program's shell — is outside it in this
  sense, since taking it over would leave the program where a fresh mount never puts it. A release
  build takes such a unit out of the page before it mounts fresh, so the page does not show it
  twice. Where among the mount element's children the unit stands is not checked.
- `{{entry}}` stays an absolute path from the base, so a page at `blog/my-blog.html` loads
  `/_main.mjs` as `index.html` does (`backend.md` §2, *Absolute, from the base*).

### 5.4 Determinism

The pages are a function of the program, the shell, the base and the route list (CLAUDE.md rule 5).
Node runs the routes in the list's order in one thread, and the build writes them in that order
after the client tree's files. The determinism test's corpus run at `--jobs=1` and `--jobs=8` covers
the pages with no change, since they are files the build writes.

### 5.5 Failures

A throw in a render, or in the route list, fails the build: `prerender_failed`. **The entry has no
`catch`** (CLAUDE.md rule 9): a throw ends Node with a non-zero exit and the error on its standard
error. The build names the route as the first route of the list with no record (or the route
list, when there is no record at all) and quotes what Node wrote to its standard error. A records
file that is not the entry's records is the same code. Mapping the
stack to `.beni` positions through the prerender tree's source maps (`backend.md` §11) is a later
improvement and not a slice of this document.

*Amended 2026-10-29, as built in P1 (#1165).* The diagnostic is at `main`'s name, and quotes what
the render threw as Node prints it, less the parts that name the machine: the source line Node
quotes above the error, the stack below it and Node's version line all hold the prerender tree's
paths, which would make the message differ between two builds of one program. The whole text
still reaches the build's standard error under text diagnostics (§5.1's amendment). In P1 the
route list is the constant `["/"]`, which cannot throw, so a run with no record names `/`.

## 6. Hydration

### 6.1 The mount takes the page over

The client of a prerendering build is compiled with a **hydrating mount**, in place of the mount
`browser-inline.md` §8.2 writes. It finds the mount element as today (`Inline.root`), and in it the
element with `data-beni`:

- **found** — it takes that element as the unit's top node, instead of inserting the string, and
  builds the element table (§6.2). Then everything is as today: the bindings are made, the events
  wired, and the first pass runs (`Inline.first`), writing only what differs (§3.2); then
  subscriptions start and `init`'s command runs.
- **not found** — a page the build did not prerender, such as `index.html` when the route list does
  not hold `/` (§7.4): it mounts fresh, as today.

After the takeover the mount removes `data-beni` from the top element, so the page holds what a
fresh mount makes, but for one difference it keeps: a control's `value`, `checked` and `selected`
are attributes of the page as well as properties (§4.1), where a fresh mount writes only the
property. A form's reset and a `[value]` selector see `init`'s values on a hydrated page and the
empty defaults on a fresh one; the program cannot tell, and the difference is accepted.

The client knows that it hydrates because the build prerenders, not by a test on every page: a
program that does not prerender is compiled with today's mount, and **no write path tests for
hydration**. That is the separation `plans/browser-decisions.md` W22 asks for (Solid's
`isHydrating` check *"at every attribute write site … so a CSR-only app pays it forever"*, research
27 §6.8). The hydrating mount and its runtime functions are `pub` functions of `Inline.beni` that a
page reaches only when it hydrates.

`stop` removes the unit's top node as it does today (`Inline.own`), so a hydrated page unmounts as a
fresh one does.

*Amended 2026-10-29, as built in P2a (#1178).* The page keeps a second difference from a fresh one,
which §6.2 decides: a hidden arm's anchor is its comment `<!--n-->`, where a fresh mount keeps an
empty text node. Neither difference reaches the program, and the corpus's transcript prints both
pages alike (`tests/corpus/README.md`, *Prerendered pages*). The hydrating mount is one runtime
function, `Inline.take`, which finds the unit, merges the table, checks the page and, on a
difference or with no unit, mounts fresh; the mount's code after it is today's.

### 6.2 The element table

The mount refers to an element as `E[n]`, the `n`-th descendant of the top element in document
order, read with one `querySelectorAll("*")` (§8.2 there). On a hydrated page, **the table must be
the one the fresh mount would have made**, element for element. The fresh string holds every arm's
elements; the page holds only the arms `init` shows (§4.1). So the hydrating mount builds the table
by merging two sources in document order:

- the page's elements, for every element that is not inside a hidden arm;
- for each arm that is hidden — each `<!--n-->` comment the page holds names one — the arm's
  elements, made from the unit's string, which the client tree has anyway: the string is parsed
  once, into a node that is never put in the page, only when the page holds at least one hidden arm.

An arm's elements are a contiguous run of `E`, and the lowering knows each arm's run, so the merge
is a walk of numbers, not of two trees.

**Every table comes from the merge, and no path is used.** The fresh mount finds elements three
ways (§1): the program's table, each piece root's own table (`Inline.part` of its placement
element, through `Inline.roots`), and a `firstChild`/`childNodes[i]` path for an element some code
refers to alone. On a hydrated page, a piece's table read from the page lacks the elements of the
piece's hidden arms, and a path through a hidden arm lands on its comment. So the hydrating mount
reads none of them from the page: it builds the merged table once, takes each piece root's table
as the slice of it below that root (its elements are a contiguous run too, since the piece's
string is written in place in the unit's string, §8.4 there), and reaches a lone element by its
number in the merged table. This is code the hydrating mount writes, and the fresh mount keeps its
paths unchanged. The arm's element made from the string is held by its `when`
while hidden, as a fresh mount's `when` holds the element it took out of the page; **the comment is
the `when`'s anchor**, in the place of the empty text node the fresh mount makes (`Inline.when`),
since an empty text node cannot be written in HTML. So the arm opens by `replaceWith`, as today, and
its holes are written by the bindings it already has.

Keyed rows (`browser-inline.md` §9, specified and not built) are not covered here: when S2c builds
the row unit, its prerendered rows and how the mount adopts them are an amendment of this section.

### 6.3 What the comment marker costs, and why it is a comment

A comment is the one node the parser keeps in place with no effect on layout, styles, `textContent`
of its parent or `querySelectorAll("*")`. Solid writes `<!--$-->` and `<!--/-->` around each
inserted expression for a reason beni does not have: an inserted expression there is a run of
nodes, and the markers bound it (`getNextMarker`). A beni text hole is the whole text of its element
(`text`, §8.2 there; a text hole beside an element is refused, §8.7), so **no text needs a marker**,
and only a hidden arm writes one, a few bytes. That refusal is a limit of the compiler (class 4,
§5 there), to be lifted; the slice that lifts it also gives the string form a marker around such a
hole, as Solid's `<!--$-->` and `<!--/-->`, and amends this section.

### 6.4 When the page is not what the program would make

The page can differ from the program only by §3.3's last rows: a host that changed the HTML, or an
engine-dependent branch. The hydrating mount checks the structure it depends on before it binds
anything:

- **in every build**, that the number of elements it merged is the number the lowering expects for
  the arms the comments say are hidden, and that each element some binding or listener refers to
  has the tag the lowering compiled it for — one string of those tags, which the lowering writes
  and P2a measures in bytes. An element no code refers to is not checked: a binding cannot attach to
  it;
- **in a development build**, also every other element's tag, which a release build does not ship
  (`browser-inline.md` §6, *The mount fault is development's*).

On a difference, the mount **removes the prerendered unit and mounts fresh**, in the same task, so
the browser paints no frame between the two; a development build first writes a `console.warn` that
names the first element that differs. The program is then exactly the fresh page: no binding is
attached to an element it was not compiled for. The cost is the prerender's benefit for that page
load — focus, selection and scroll inside the unit are reset. Whether this, or stopping the page as
a defect, is right is the owner's decision (§10, question 3).

*Amended 2026-10-29, as built in P2a (#1178).* An arm opens where its comment stands, so the
check covers the comments too, in every build: a comment whose text is a number names an arm;
the arms it names follow each other in their ordinals' order, none inside another the page
hides, and each comment's parent is the element the arm's parent is, between the page's element
before the arm and the one after it in document order. A comment of any other text is not the
program's and is passed over. The tags are compared first, over the table as far as it was
merged, so the warning names the element a host inserted or replaced (`browser/prerender/
Tampered`, `Retagged`); the count and the comments' places come after. One string of tags,
space-separated, one per element of the table — the top element first — and empty in a release
build for an element no code refers to, carries the count as well (`emit/prerender/`,
`emit/release/prerender/`).

### 6.5 Input before the program runs

The entry is a module script, which runs after the page is parsed, so a user can click, type or
check a box in a prerendered page before the program has taken it over. Solid captures such events
with an inline script and replays them after hydration
(`references/dom-expressions/packages/runtime/src/server.js`, `generateHydrationScript`;
`client.js`, `runHydrationEvents`). Its replay finds the handler by walking Solid's delegated
containers, and **beni has no delegation**: `Inline.on` and `onArm` add a listener to each
element and keep no table of them. So Solid's capture is taken and its delivery is not:

- **What is captured.** An inline script, written by the build into each prerendered page beside
  the unit, listens at the document, in the capture phase, for each event kind the program has a
  listener of — `click`, `input`, `change` (`Html.onCheck` and `onChange` listen to it) and
  `submit` among them — and records the target and, for a control, its `value`, `checked` and
  `selectedIndex` at that moment. It stops when the program has taken over.
- **What is delivered.** After the first pass, the hydrating mount hands each record, in order, to
  the listener the lowering wired on that element for that kind, called directly with an object
  that gives the recorded target: the event is **not** dispatched again, so no default action runs a
  second time and no untrusted event is made. Before the call it writes the recorded control state
  back, which the first pass overwrote with `init`'s, so an extractor (`via`) reads what the user
  left. The mount keeps the element-to-listener table for this one pass only, and only on a page
  whose script recorded something.
- **A `submit` before the takeover** follows the form's default, a page load, as it does on any
  page before its script runs; a form whose `onSubmit` prevents the default is the program's only
  after the takeover.

Under a content security policy that forbids inline scripts the script does not run and input
before the takeover is lost; nothing else changes. This is P2b's (§11): its shape is fixed in an
amendment here before it is built, measured in bytes and in time to interactive.


## 7. Routes

### 7.1 What `browser-inline` lacks today

`browser-inline`'s `Tea` has `sandbox` and `element`, whose `init` takes `⊤`
(`platforms/browser-inline/Tea.beni`). It has no `Tea.application`, no `Browser.Navigation`, no
`UrlRequest` and no `Url` in `init`. `browser-tea` has all of them, by `boundary.md` §9.8.13: Elm's
`application`, whose `init` takes the `Url` and a `Navigation.Key`, with `onUrlRequest` and
`onUrlChange`, and navigation as commands (§9.8.17 (b) there). A page per route needs `init` to know
its route, so **per-route pages come with routing (slice P3)**, not before: P1 and P2 prerender
`index.html` alone, for `sandbox` and `element`.

*Amended 2026-10-29 (#1163):* `Tea.document`, `Tea.application` and `Browser.Navigation` are built
on `browser-inline` for a page the browser renders (`browser-inline.md` §10); §7.2's
`Browser.prerender` and §7.3–§7.5 are still P3's.

### 7.2 `Tea.application` and `Browser.prerender`

`browser-inline` gets `browser-tea`'s `Tea.application` and `Tea.document`, with the same signatures,
so one source builds on both (the promise of `browser-inline.md` §1), and `Browser.Navigation`'s
commands, `onUrlRequest` and `onUrlChange`, with §9.8.13's semantics. The lowering compiles
`onUrlRequest` and `onUrlChange` as subscriptions of constant keys (§3 there), and navigation as
`Cmd.perform` bodies, which are `sync` (§4 there).

The route list is a value of `main`:

```text
main : Tea.Program
main =
    Browser.prerender (Tea.application app) (List.map posts λpost → "/blog/" ++ post.slug)
```

`Browser.prerender : Program, List String → Program` is recognised by the lowering where it is
called, as `Browser.mountAt` is, and compiled away: the client tree holds neither the call nor the
list, and the prerender tree evaluates the list (§5.1). It composes with `mountAt` either way round.
The list is a beni value, so blog slugs come from beni data; data the build reads from files is §8's.
`browser-tea` gets the same function, which returns its program unchanged, so a prerendered program
still builds there as a client-rendered one.

### 7.3 What `init` receives

**The route, from the page, never from `location`.** The build gives `init` the `Url` of the route;
the page carries the route in its `data-beni` attribute (§4.2); the hydrating client gives `init`
the `Url` of what the page carries. The same page is reachable at several addresses —
`/blog/my-blog`, `/blog/my-blog.html`, `/blog/my-blog?utm_source=x#top`, another host's preview
deploy — and a static host's fallback may answer any address with a page made for another route. So
the address the page was opened at is not the route. What `init` gets is:

- `path`: the base with the route after it (`"/app/blog/my-blog"` for base `/app/`), since
  §9.8.13 (e) says nothing hides the base from the program;
- `query` and `fragment`: `Nothing`, since the build cannot know them;
- `protocol`, `host` and `port_`: from the project's `"build"."origin"`, a new key of `frontend.md`
  §10.1 that a prerendering build needs, `"https://example.com"`;

and the address the page was opened at, when its `Url` differs from that one, reaches the program as
`onUrlChange`'s message once the first render has run — an ordinary message, whose write pass
patches the page. The address is replaced (`history.replaceState`) only where its path is the
route's file name rather than the route — the route's path with `.html` after it, or a route ending
in `/` with `index.html` after it — keeping its query and fragment, so a `.html` suffix never
reaches the program as a different path. A page a host's fallback served for another address
(`/blog/missing` answered with `/`'s page) keeps its address, and the program gets it as
`onUrlChange`'s message, where its parser can answer it with a page of its own.

**A page with no prerendered view** — `index.html` when the list does not hold `/` (§7.4), and so
whatever a host's fallback answers with it — mounts fresh (§6.1), and its `init` gets the `Url` of
`location`, as `browser-tea`'s does: there is no prerendered page for it to agree with, so §3's
guarantee has nothing to hold.

A prerendering build of an `application` with no `"build"."origin"` is `prerender_needs_origin`
(§9), against the app's `beni.json` at `1:1`, as `invalid_entry_export` is. That is a departure from `browser-tea`'s `application`, whose `init` sees the address with
its query; a program that reads the query reads it in `onUrlChange`. It is the owner's (§10,
question 2).

### 7.4 From a route to a file

A route is a path below the base: `/`, `/about`, `/blog/my-blog`, `/blog/`.

| Route | File under `--out` | Served at (base `/`) |
|---|---|---|
| `/` | `index.html` | `/` |
| `/about` | `about.html` | `/about` |
| `/blog/my-blog` | `blog/my-blog.html` | `/blog/my-blog` |
| `/blog/` | `blog/index.html` | `/blog/` |

A route ending in `/` is the directory's `index.html`; any other route is its path with `.html`
after it, the owner's example. GitHub Pages, Netlify and Cloudflare Pages answer `/about` with
`about.html`; a host that does not is configured to, which the user guide says, as it says for the
single-page fallback (`boundary.md` §9.8.13 (e)). `beni serve` gets the same rule: a path that names
no file is answered with `<path>.html` when that file exists, before the single-page fallback
(`frontend.md` §10.4, amended by P3).

**What a route may hold.** It begins with `/`. Its segments are not empty (but for the last, in a
route ending in `/`), not `.` and not `..`, and hold only the characters a URL path never escapes:
ASCII letters, digits, `-`, `.`, `_` and `~`. So the address and the file name are the same bytes,
and rule 2's ASCII folding (`backend.md` §2) is exact for them. **The first segment does not begin
with `_`**: that region of the output's root is the compiler's (`_main.mjs`, `_core/`,
`_platform/`, `_manifest.txt`, rule 1 there) and the server's (`/_beni/`, `frontend.md` §10.4), so no
route can name a file the build writes for itself. A route that breaks one of these is
`invalid_route` (§9), naming it and the rule. Two routes that write one file — `/a/` and `/a/index`,
`/About` and `/about`, a route listed twice — are `output_path_collision`, naming both routes. When
the list holds `/`, its page is the `index.html` the build writes; otherwise `index.html` is the
shell with no view, which mounts fresh (§6.1) and serves a host's single-page fallback.

Non-ASCII routes (`/blog/café`) are a limit, lifted only with a Unicode case folding for rule 2:
APFS and NTFS fold more than ASCII, so the check would miss a collision there.

### 7.5 A title per page

A page is found by its `<title>`. `Tea.document`'s and `Tea.application`'s `view` gives a `Document`
with a `title` (§9.8.13 there); the shell gets a fourth placeholder, `{{title}}`, which a
prerendering build replaces with the route's title, escaped, and a client build with nothing. The
platform's own shell keeps its `<title>beni</title>`; an app that wants a title per page writes
`<title>{{title}}</title>` in its shell. P3 builds it with `Tea.document`. Other head content (a description, an Open Graph image) is a later
amendment, once a program can say it.

## 8. Build-time data (later)

A blog's posts are files. `init` cannot read them: it is pure (§3.1), and `browser-inline` has no
`readFile`. The data has to be read once at build time, by a program that may read files — one
built for `node`, since a build is one platform per entry point (`boundary.md` §5.3) — and handed to
each page so that the build's `init` and the browser's see the same value.

The recommended shape, for the slice after P3: the project names a data program built for `node`,
which the build runs before the prerender and which gives, per route, a value of a type with a
schema (`schema.md`). The build checks it with that schema, and writes it into the page, encoded, in
a `<script type="application/json">` beside the unit; `init` receives it decoded with the same
schema, **in the build too**: the build renders from the value it decodes from the bytes it writes,
not from the value the data program gave. A schema does not promise `decode (encode x) == x`
(`schema.md` §5: *"No general guarantee … is claimed for normalising or lossy conversions"*), so
rendering from `x` could differ from the client, which only ever sees the decoded value; rendering
from the decoded value makes the two inputs the same bytes read by the same code. Each page carries only its own
data, so a site of 500 posts does not ship 500 posts to every page — the reason not to write the
data into the program as beni values, which would keep the guarantee with no schema but make every
page carry every post. This section is a direction, not a contract: it is specified before its
slice, after P3.

## 9. Diagnostics

Appended to the code list when each slice lands, never inserted:

| Code | When | Slice |
|---|---|---|
| `prerender_impure` | `init`, `view` or the route list of a prerendered program may be impure; at the call that makes it so | P1 |
| `prerender_failed` | a render or the route list threw, or Node gave no record for a route; names the route and the error | P1 |
| `prerender_needs_node` | a prerendered program, and no `node` on `PATH` (or the playground) | P1 |
| `prerender_needs_origin` | a prerendered `application` and no `"build"."origin"` (§7.3) | P3 |
| `invalid_route` | a route breaks §7.4's rules; names it and the rule | P3 |
| `invalid_html_shell` (existing) | also: a prerendering build's shell has no `{{view}}`, or two | P1 |
| `output_path_collision` (existing) | also: two routes write one file | P3 |

A construct the string form cannot write yet — keyed rows, until §6.2's amendment — is
`browser-inline.md` §5's class 1, *"A limit of the compiler: … does not prerender yet"*.

## 10. Questions for the owner

Each with its recommendation. Everything else in this document follows from what is already
decided and is not a question.

1. ~~**May a build of a prerendered program run Node?**~~ **Decided** (the owner, 2026-10-29): yes,
   the `node` on `PATH` (§5.1). *Corrected the same day:* an earlier entry here said the owner chose
   an engine embedded in `beni`; that was a misreading, withdrawn (§5.1). An evaluator of
   `init` and `view` in Zig is not taken: it would be a second evaluator of beni that must agree
   with the emitted JavaScript bit for bit — float printing, `Int` past 2⁵³, string operations,
   every `foreign` of core — while the guarantee of §3 is exactly that the two computations agree.
   An engine runs the emitted code, so that agreement stays true by construction. The write-set
   pass's evaluator (`write-sets.md` §9.1) stays narrow on purpose and does not grow into one.
2. **What does `init` receive on a prerendered page?** I recommend §7.3: the route as the page
   carries it, with the origin from `"build"."origin"` and no query or fragment, and the real
   address afterwards as an `onUrlChange` message. The alternative is Elm's: `init` gets the address
   the page was opened at. Then any page opened with a query, a fragment, a `.html` suffix or on a
   preview host computes a different first model than the build did, and the guarantee of §3 is
   gone for exactly the pages people share. The cost of the recommendation is a departure from
   `browser-tea`'s `application`: a program that reads the query does it in `update`. One source
   still builds on both platforms; it can differ in its first render only.
3. **What does a page do when its HTML is not what the program would make?** I recommend §6.4: mount
   fresh in the same task, with a warning in development. The page is then correct; it loses only
   the prerender's benefit for that load. The causes are outside the program — a browser extension
   that inserts an element, a CDN that rewrites links — and stopping the page as a defect would make
   the site fail for every user of that extension, for something no beni code did. I know you
   rejected fallbacks in the compiler ("no 'fallbacks', i want a proper implementation", ownership,
   2026-10-15). This is not one of that kind: it is not code the compiler could not prove, but a page
   the host changed after the build, found by a check at run time, and the fresh mount is the
   program as written. If you want it to stop instead, it is the same check with a different answer.
4. **Should `beni serve` prerender on every rebuild?** I recommend yes (§5.2): development then takes
   the page over as production does, and a hydration fault is found where the developer works. It
   costs one run of the prerender tree per rebuild, measured in P1; if it is slow for a large site, the step is
   to prerender only the routes whose pages changed, not to skip it.

## 11. The slices

Each a pull request with its goldens, part of #1160, in this order. The brief proposed the same
order with per-route pages in the first slice; they move to P3, because a page per route needs an
`init` that receives its route, which only the routing constructor gives (§7.1).

| Slice | What lands | Done when | Fixtures |
|---|---|---|---|
| **P1** — the string form, one page, replaced on load | §4: the render functions of the program site and the pieces, the escaping in `Inline.beni`, interface 1.20; §5: the prerender tree, Node, the records, `{{view}}`, `prerender_*` codes; the client of a prerendering build **removes** the prerendered unit and mounts fresh (no hydration yet); switched on by a hidden test-only flag; the browser driver learns to load the page the build wrote, where today it loads a blank page and makes the mount element with an `element` step (`tests/browser/driver.mjs`) | each `browser/prerender/` project, which carries its own shell with `{{view}}` inside its mount element, writes an `index.html` whose view is the first render, and its transcript after the load and after each step is the one the same program gives from its shell with no view; the existing `emit/inline/` and `emit/release/inline/` goldens do not move by a byte; the determinism test covers the pages | a new corpus kind, `browser/prerender/`: a project's pages are goldens (`_expected/<route>.html`), and its `.steps` run twice against one `.expected` — from the shell, and from the prerendered page; fixtures: `Counter` (holes, mixed text, `disabled`), `HiddenArm` (the popup: the arm absent, `<!--0-->` in its place), `Escapes` (`&`, `<`, `\r`, a leading newline in `textarea`, NUL), `Controls` (`value`, `checked`, a `select`'s option), `Pieces` (another module's view); `build/bad/prerender/`: `ImpureView`, `ImpureInit`, `ViewThrows`, `NoViewInShell`, `TwoViewsInShell`; `tests/blackbox/` for `prerender_needs_node` (an empty `PATH`) |
| **P2a** — hydration | §6.1–§6.4: the hydrating mount, the merged table and the piece tables cut from it, the comment as anchor, the structure check and the fresh mount on a difference, `data-beni` removed | the `browser/prerender/` transcripts with the page taken over equal the fresh ones, but for the control attributes §6.1 accepts, which the prerender kind's transcript prints as properties (its normalisation, written in `tests/corpus/README.md`): no element of the page is replaced, which the harness checks by marking every element before the program loads; a page whose HTML was changed mounts fresh, with the warning in development; a client page that does not prerender ships no new byte (`bench/size.mjs`'s `page` lines unchanged); measured against Solid 2's `hydrate` of its own hydratable `renderToString` output on the same pages, in headless Chrome by report 29's method, extended with a page-load scenario (the time from the module's start to the handlers attached, and its bytes): beni's time is at most Solid's, per page, by the median, and its hydration bytes are reported beside Solid's 1 439 B (research 27 §6.8) — a loss is read in Solid's code and answered there (CLAUDE.md rule 8) | `browser/prerender/` adds `Tampered` (an element inserted in the page before load: fresh mount), `Retagged` (an element some code refers to replaced by one of another tag, the count unchanged: fresh mount in release too), `ArmOpens` (a hidden arm opened after the takeover, then closed), `PieceArm` (a hidden arm inside another module's piece), `LoneElement` (a page whose code refers to one element, behind a hidden arm), `WrongPlace` (`{{view}}` outside the mount element: the development fault); `emit/prerender/` pins the hydrating mount's shape in both modes |
| **P2b** — input before the takeover | §6.5, its shape amended there first: the capture script, delivery by direct call with the control state written back | a click, typed text and a checked box made before the module runs reach `update` once each, in order, after the first pass; no default action runs twice; the script's bytes and the time to interactive are measured | `browser/prerender/EarlyInput` (click, `input`, `change` on a checkbox, a `select`), `EarlyNone` (a page whose program has no listener: no script written) |
| **P3** — routes | §7: `Tea.application` and `Tea.document` on `browser-inline`, `Browser.Navigation`'s commands and the two subscriptions, `Browser.prerender` (and `browser-tea`'s identity), `"build"."origin"`, the route in `data-beni`, the address replaced and sent after the first render, route files and `invalid_route`, `{{title}}`, `beni serve`'s `.html` rule; the hidden flag goes | a site of three routes and a blog of two posts builds into five files a static server answers, each taken over by the program, and a link click navigates on the client with no page load | `browser/prerender/Blog/` (routes from a list of posts; a link click; back; a page opened with a query and a fragment), `Titles`; `build/bad/prerender/`: `RouteUnderscore`, `RouteDotDot`, `RouteNonAscii`, `RouteCollision` (`/a/` and `/a/index`), `RouteFolded` (`/About`, `/about`), `RouteImpure`; a `browser/tea/` page showing that the same source builds on `browser-tea`; a `serve` case in `tests/blackbox/` for `/about` → `about.html` |
| **P4** — build-time data | §8, specified in this document first (rule 1) | — | — |

The hang guard of 120 s applies to every case as to any other, and a prerendered fixture's Node run
is part of its case.

**As built — P1** (2026-10-29, #1165). The hidden flag is `--prerender`, for `build` alone (a
`--watch`, `serve` or `--library` build refuses it, until P3 makes it the program's word, §5.2),
on a chain whose lowering prerenders (`Lowering.prerenders`, §4.4's amendment). The build
(`src/build/Command.zig`) builds the prerender tree, runs it, and hands what it gave — the view,
`needs_node`, or the failure — to the client tree's build (`src/js/Emit.zig`, `Prerender`), which
writes the page or refuses the build, so a refused build writes nothing (§5.1 item 3). The string
form is `Render` in `platforms/browser-inline/zig/inline.zig`, its escapes `Inline.escape`,
`escapePre` and `escapeAttribute`, and the client of a prerendering build calls
`Inline.unprerender` on the mount element before it mounts: the element with `data-beni` below it
is taken out, and the mount is today's. The top element's `data-beni` has no value until P3
(§4.2). A `view` whose top-level node is not one element of its own — another module's markup —
does not prerender yet (`browser-inline.md` §5, class 1). `{{view}}` is replaced with nothing in
every build that does not prerender, and `platforms/browser-inline/index.html` says
`<body>{{view}}</body>` (§5.3). The browser driver opens a page on the `index.html` beside its
entry with `--html-page` (`tests/browser/driver.mjs`); the corpus kind is `tests/corpus/README.md`'s
*Prerendered pages*; the determinism claim of §5.4 is `tests/blackbox/build_test.zig`'s *a
prerendered page is byte-identical at every --jobs*, and `prerender_needs_node` is
`tests/blackbox/browser_test.zig`'s, an empty `PATH`. The emitted code of a build that does not
prerender is unchanged: no `emit/inline/` or `emit/release/inline/` golden moved, and only the
development source maps of `_platform/Inline.mjs`, which carry the module's text, did.

**As built — P2a** (2026-10-29, #1178). The client of a prerendering build calls `Inline.take` in
place of the string's insertion (§6.1's amendment): `take(at, html, arms, tags)`, the mount
element, the unit's string, three numbers per eager arm — its element's index in the table, the
elements it holds, its parent's index — and the tag string of §6.4's amendment. It gives the
table with the top element at 0, so the mount refers to every element as `E[n + 1]` and to no
path; each piece's table is `E.slice` below its top element, and pieces are not mounted as a run
(`Inline.roots`), which reads each root's table from the page. A piece's owner records its arms
and the elements its factory refers to (`PieceData.arm_runs`, `refs`) for the program site.
`Inline.unprerender` is gone. The lowering interface does not change. The corpus's checks are
`tests/corpus/README.md`'s *Prerendered pages*, since P2a: every element is marked before load,
the steps `fresh`, `inject` and `retag`, the normalisation, and goldens of a build's own; the P2a
fixtures are `Tampered`, `Retagged`, `RetagUnseen` (an element no code refers to: a release build
takes the page over, a development build mounts fresh), `ArmOpens`, `PieceArm`, `LoneElement` and
`WrongPlace`, with `MovedComment` (a comment out of place) and `ExtraElement` (the count), and `emit/prerender/` and `emit/release/prerender/` pin the shape. A page that does
not prerender ships what it did: no `emit/inline/` or `emit/release/inline/` golden moved, and
`bench/size.mjs`'s `page` lines are the same bytes.

Measured with `bench/ui/hydrate.mjs` (report 29's harness; headless Chrome, 21 fresh loads per
page and subject, rotated; release builds): beni's hydrating mount of the page
`beni build --prerender --release` wrote, against Solid 2's (`2.0.0-rc.9`) `hydrate` of its own
hydratable `renderToString` output of the same page, its hydration script in the page's head.
The time is from the module's start to the end of the mount, every handler attached, and the
microtasks the mount queued; then a real click must change the page. Medians, in ms:

| page | beni | Solid 2 | beni's JS, brotli | Solid's JS, brotli |
|---|--:|--:|--:|--:|
| `counter` (a text hole, two buttons) | 0.730 | 3.460 | 1 104 B | 18 493 B |
| `static` (research 29's static-heavy page, ~2 000 elements, 50 holes) | 1.745 | 5.280 | 1 465 B | 21 090 B |
| `arms` (30 panels, every other body hidden) | 1.695 | 5.475 | 2 010 B | 19 743 B |

From the navigation's start to the same point, beni's medians are 13.8, 16.4 and 12.9 ms, Solid's
17.1, 20.3 and 17.8 ms. What hydration adds to beni's client, against the same program built
without `--prerender`, is 583, 640 and 687 B brotli on the three pages (the runtime's `take` and
the unit's arms and tags), against Solid's 1 439 B of hydration (research 27 §6.8). The run takes
under a minute.
