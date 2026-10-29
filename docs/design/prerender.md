# Prerendered pages — a static site build of `browser-inline`

*2026-10-29, #1160. **Specified; slices P1, P2a, P2b, P3 and P4 built** (2026-10-29, #1165, #1178, #1206, #1194, #1218, §11 *As built — P1*, *As built — P2a*, *As built — P2b*, *As built — P3*, *As built — P4*). The contract for a build of a `browser-inline`
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

   *Amended 2026-10-29, as built for #1170.* The walk reads code in every module of the app and
   of its platforms, not only the program's, and needs no new fact of the checker: it reads the
   checker's `impure` answer at each call of the module it is in (`Dispatch.EffectSite`, every
   module's table, as `checkDataSchema` reads them, §8.4's amendment), and the total bit
   (`checker-v2.md` §26.1). Core's code is answered at its calls, as before. So:

   - **A call of a function of another module** that the checker answers impure is answered by
     that function's body, walked once in its own module, as a function of the program's is. A
     function whose only effect is `Debug`'s, in whichever module, adds `Debug`'s effect and no
     other; a call it makes that may be impure is named where it is, in its module's file.
   - **A field that names a top-level function**, of the program's module or of another
     (`init = Counter.init`), is answered as a call of it: pure when the checker proves the
     function total, else by its body.
   - **A read of another module's constant** is answered by the constant's body, as a constant of
     the program's module is: it is computed where its module loads, in the build as in the
     browser (`Theme.seed = Clock.now ⊤` is refused at the read). So is a read of another
     module's function bound point-free, whose body runs there too: `shift = (at = Clock.now ⊤;
     λn → n + at)` is pure to call and impure to make. The build accepted that read before, as a
     function's (`build/bad/prerender/OtherImpureClosure`), and the page held the clock.
   - **A constant is found wherever the code may read it.** The checker does not count a read of
     a constant as an effect, so a call that reads one is answered pure (`addSeed n = n + seed`),
     and the walk of calls above never enters it; nor a lambda's body. A second walk follows every
     reference of `init`, `view` and the route list instead — each declaration of the app's and
     the platforms' modules they name, lambdas' bodies, and the functions each dispatch site and
     its evidence name, the bodies of this module's derived functions among them — each once, and
     answers each constant it meets by its body. A dispatch to another module's derived function
     or to a codec, and a use of a schema's member (`Count.parse`, whose conversions its plan
     holds), are not followed; each is refused when any constant of those modules may have an
     effect at all, a limit of the build. Before this, a read behind a pure call, in a lambda or in
     a schema's conversion was accepted, in the program's module too
     (`build/bad/prerender/ConstantBehindCall`, `ConstantInLambda`, `ConstantInSchema`): a
     defect, not a limit.
   - **Only a function with parameters, or whose whole body is a lambda, has a body a call
     runs.** A function bound point-free — `stamp = Clock.now`, `stamp = Debug.log "s"
     Clock.now` — is a value its body computes, and the body's walk says nothing of what calling
     that value does. A call of one the checker answers impure is the effect, whatever its body
     shows, and a field that names one is refused unless the checker proves it total. Before
     this, both were accepted when the body showed no effect, or only `Debug`'s, and the page held
     the build machine's clock (`build/bad/prerender/PointFreeInit`, `PointFreeDebug`): a
     defect, not a limit.

   A method call or an operator the checker answers impure is still refused at the call, whatever
   the type's function does: the walk does not follow a dispatch target yet (#1247). Since the
   walk reads another module's body and not only its interface, the program module's lowering
   depends on that body; the program module is the app's, and an app module is lowered by every
   build, never read from a row (`backend.md` §9, *The join*), so no build answers with a stale
   body. The fixtures are `browser/prerender/NamedInit` (`init = Counter.init`, a view that reads
   `Theme.title`) and `DebugHelper` (another module's helper that logs), and
   `build/bad/prerender/` `OtherImpureInit`, `OtherImpureHelper` (the clock read two modules
   away, behind a `Debug.log`), `OtherPointFree`, `OtherImpureConstant`, `OtherImpureClosure`,
   `ConstantBehindCall`, `ConstantInLambda`, `ConstantInSchema`,
   `PointFreeInit` and `PointFreeDebug`.
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

*Amended 2026-10-29 (#1207, specified for P4).* With build-time data the input is the route and
the value the page carries, decoded by the same code in both places from the same bytes (§8.1,
§8.6); the data program that made those bytes is outside the claim, and may be impure (§8.3). A
page whose bytes a host changed is §8.6's.

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

*Amended 2026-10-29, as built in P3 (#1194).* A program that does not call `Browser.prerender`
does not prerender, whatever its constructor: a `Tea.sandbox` that wants its one page prerendered
says `Browser.prerender (Tea.sandbox app) [ "/" ]`. The build reads `main`'s body when the program
is checked, before anything is emitted, so it knows whether to build the prerender tree. The
hidden `--prerender` is gone; a hidden, test-only `--no-prerender` takes its place for the corpus,
which builds each prerendered project as if `main` did not say so and compares the two pages'
transcripts (`tests/corpus/README.md`, *Prerendered pages*). A `--library` build never prerenders.

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

*Amended 2026-10-29 (#1207, specified for P4):* with build-time data, the data program's records
join the list, §8.9.

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
load — focus, selection and scroll inside the unit are reset. The owner decided this over stopping the
page as a defect (§10, question 3, 2026-10-29).

*Amended 2026-10-29, as built in P2a (#1178).* An arm opens where its comment stands, so the
check covers the comments too, in every build: a comment whose text is a number names an arm;
the arms it names follow each other in their ordinals' order, none inside another the page
hides, and each comment's parent is the element the arm's parent is, between the page's element
before the arm and the one after it in document order. A comment of any other text is not the
program's and is passed over. The tags are compared first, over the table as far as it was
merged, so the warning names the element a host inserted or replaced (`browser/prerender/
Tampered`, `Retagged`); the count and the comments' places come after. One string of tags,
space-separated, one per element of the table — the top element first — carries the count as
well (`emit/prerender/`, `emit/release/prerender/`).

*Amended 2026-10-29, in P2a (#1186, the manager's decision on the review of #1183): a release build
checks every element's tag too.* The first bullet's *"An element no code refers to is not checked:
a binding cannot attach to it"* was wrong. The table is by index, so taking out an element no code
refers to, and putting another in further on, moves every element between them by one place while
the count stays the same: a release build that compares only the referenced tags saw a button where
`+` was and a button where `-` was, and wired `Inc` to `-` and `Dec` to the host's button — a silent
wrong answer (`browser/prerender/Shifted`, red before this amendment). So **every build checks
every element's tag in document order, the element count and the comments' places**; the second
bullet's development-only check is now every build's. The cost is the tags of the elements no code
refers to in each client, a few bytes after compression (§11, *As built — P2a*).

**What the check does not catch**, a known limit of every hydration that finds elements by their
place, and not a guarantee: a page whose tag sequence, count and comments are the program's. A host
that swaps two elements of the same tag — two buttons — keeps the sequence, and the mount takes the
page over with each listener on the element now at its place; a host that edits a static text, or
an attribute the program never writes, keeps it too, and the page shows the edit (§3.2: only a
binding's text is rewritten by the first pass). Solid checks less: its hydration finds each
template's root by its `_hk` key and walks the rest by `firstChild` and `nextSibling`, and compares
tags only in a development build, where a difference is a `console.warn` and the walk goes on
(`references/dom-expressions/packages/runtime/src/client.js`, `getNextElement`, `getFirstChild`,
`getNextSibling`); a production Solid page takes over a swapped or retagged element as it stands.

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

*Amended 2026-10-29, before slice P2b is built (#1206): the shape.*

- **Which pages get it, and which events.** A page gets the script when its program has at least
  one listener the lowering wires on an element of the unit — the program's own and those of every
  other module's piece it places — of a kind the script records. It records every kind but the
  pointer events (`pointerdown`, `pointermove`, … — `Html.onPointer*`): their payload is read while
  the event is dispatched, the box of the element whose listener runs (`currentTarget`), which a
  delivery after the dispatch cannot give, and a gesture is a run of them that a later delivery
  cannot take part in; the `click` a tap makes is recorded. A page whose program has no such
  listener gets no script, and its client has no code of this section
  (`browser/prerender/EarlyNone`). A listener a subscription adds to the window or the document
  (`Listen`) is not the unit's: input before the takeover does not reach it.
- **Where it stands, and what it holds.** The render function of the program site writes it first
  in the unit's HTML, before the unit's top element, so it is the first child the build writes
  where `{{view}}` stands: a classic inline script, which the parser runs as it reaches it, before
  any of the unit is shown. Its text is one constant of the lowering, the kinds it records in it
  (`K`, a JSON array of each kind once, sorted by code point, `"click"` for `onClick`):

  ```text
  <script>(()=>{let d=document,r=[],k=K,f=e=>{let t=e.target;t.closest?.("[data-beni]")&&r.push([e,t.value,t.checked,t.selectedIndex])};for(let n of k)d.addEventListener(n,f,!0);window.$beni=()=>{for(let n of k)d.removeEventListener(n,f,!0);return r};d.currentScript.remove()})()</script>
  ```

  It listens at the document in the capture phase, so it hears an event before any listener of the
  page and adds none to the unit's elements. It takes itself out of the page as it runs, so the
  page the mount meets holds the unit alone where `{{view}}` stood, as before, and a page taken
  over keeps no node a fresh one lacks.
- **A record.** One per event whose target is inside the unit (`closest("[data-beni]")`): the
  event object itself, and the target's `value`, `checked` and `selectedIndex` as they are at that
  moment, `undefined` where the element has no such property.
- **How the target is identified.** By the event's own `target`, a reference to the page's element.
  The takeover keeps every element of the page it adopts (§6.1: no element is replaced), so the
  reference is the element the mount's table holds and the lowering wired a listener on. An index
  into the element table would need the merged table (§6.2), which only the client can make, and
  would add nothing a reference does not give.
- **How the records reach the mount, and when the script stops.** The script defines one global,
  `window.$beni`, a function that removes its listeners and gives the records. The hydrating mount
  calls it once, `Inline.caught(at)`, before `take` (§6.1), so the script stops however the mount
  goes on — a development build's fault for a unit outside the mount element included — and sets
  `$beni` to `undefined`, so the records are not held after the delivery. `caught` keeps the
  records whose target is inside `at`, the mount element, and adds to each its target's control
  state as it is then: the state the user left, before the first pass writes `init`'s. A page
  where the script did not run (a content security policy) has no `$beni`, and the mount has
  nothing to deliver.
- **On a fresh mount, the records are dropped.** The delivery hands on only the records whose
  target is inside the unit's top element the mount took, `E[0]`. When `take` mounted fresh
  (§6.4), the prerendered unit is out of the page and no record's target is inside the fresh one,
  so every record is dropped: the input was made on elements the program did not take over, and
  the page starts as the fresh page does (`browser/prerender/EarlyFresh`).
- **How a record finds its listener.** In the client of a prerendering build the lowering wires each
  listener through `Inline.listen(node, kind, f)` — and `onTaken`, `onArmTaken` in place of `on`
  and `onArm` (`browser-inline.md` §8.2) — which add the listener as before and, while `caught`
  holds a record, also note `f` under its element and kind in a `Map`. The map exists from `caught`
  to the delivery only, and only on a page whose script recorded something; the lowering of a
  program that does not prerender is unchanged.
- **The delivery.** `Inline.deliver(E[0])`, the hydrating mount's last statement — after the first
  pass, the title, the subscriptions' start, `arrived` (§7.3) and `init`'s command queued. A record
  is *heard* when the map holds a listener of its event's type on its target or, when the event
  bubbles, on an ancestor. A record no listener hears changes nothing. For each record heard, in
  order: the recorded `value`, `checked` and `selectedIndex` written back to the target, each one
  the record has and the element does not show, in that order; then each listener the map holds for
  the record's event type called with the recorded event, on the target first and then on each of
  its ancestors when the event bubbles, until one calls `stopPropagation`; then the state `caught`
  found written back the same way, so a record never undoes what the user did after it — the text
  typed after a `focus`, the key after a `keydown`. A file input's state is never written, since
  its `value` cannot be. The event is the user's own, not one made again: its `target` is the
  element and `currentTarget` is `null`, and `preventDefault` does nothing, since its default has
  already run. The mount runs inside one dispatch (`Inline.run`), so each listener's `via`
  extractor reads the control at once, while the record's state is written back, and each message
  is queued: the messages reach `update` once each, in the records' order, behind the bodies of
  `init`'s command, each followed by its write pass. The map and the records are then dropped.
- **What it does not restore.** A text control's caret (the write back puts it at the end), a
  `select multiple`'s other selected options, and a radio button's group beyond the target. A
  control no record is heard on keeps what the first pass writes, `init`'s, as before this
  section. The program's view of the controls is what its messages make of them, as on any page.


There is no `catch` anywhere in this (CLAUDE.md rule 9): a listener that throws when delivered is
a defect, as it is when the event is dispatched.


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

*Amended 2026-10-29, as built in P3 (#1194; `boundary.md` §9.4.6, version 1.22).* "Where it is
called" is `main`'s spine: `main`'s body, or the first argument, again and again, of a
`Browser.mountAt` or a `Browser.prerender` there. A call anywhere else would say nothing the build
acts on, and is `program_shape`; so is a second call on the spine, and `Browser.prerender` used as
a value rather than called (`staticSite = Browser.prerender`), which a page would otherwise run
as written. In the client tree the call is
compiled as its program and reachability follows neither `Browser.prerender` nor the list, so a
client page ships neither, nor a declaration only the list names (a blog's posts, when the `view`
does not show them). In the prerender tree the call runs as written: `Browser.prerender` is beni
over `Js` that gives `[render, routes]`, the routes copied into an array, and the entry exports
both. In that tree a `Browser.mountAt` around the program is compiled away whatever its element:
the render function mounts nowhere. `browser-tea`'s identity is in `browser`'s `Browser`, which
`browser-tea` re-exports, so `browser` has it too.

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
its query; a program that reads the query reads it in `onUrlChange`. The owner decided it (§10,
question 2, 2026-10-29).

*Amended 2026-10-29, as built in P3 (#1194).* The `Url` is core's `Url.fromString` of the origin,
the base less its last `/`, and the route (`Inline.routeUrl`), in the build and in the browser
alike. The hydrating client reads the route from the page's `[data-beni]` before `init` runs
(`Inline.pageUrl`), so a page whose unit is then mounted fresh, because the host changed it
(§6.4), still starts from its route. Once `onUrlChange` listens — after the first pass, before
`init`'s command — the mount replaces a file-name address and then, when `Url.fromString` of the
address is not the route's `Url`, dispatches `Browser.Navigation`'s own announcement,
`"beni:navigate"`, which `onUrlChange`'s listener answers with the address, as it answers a push
(`Inline.arrived`). An address that is not a `Url` — a page opened from a file — is announced too
and sends nothing, as `onUrlChange` sends nothing for one: the page shows its route, and does not
stop. `"build"."origin"` is `http://` or `https://`, a host and at most a port (`frontend.md`
§10.1); any other value fails the build with exit 2.

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

*Amended 2026-10-29 (#1207, specified for P4):* a data site's routes are the data program's, checked
by the same rules, and its `index.html` is the page of `/` or is not written (§8.5, §8.6).

Non-ASCII routes (`/blog/café`) are a limit, lifted only with a Unicode case folding for rule 2:
APFS and NTFS fold more than ASCII, so the check would miss a collision there.

*Amended 2026-10-29, as built in P3 (#1194).* The routes are checked after Node has run, from its
first record, the list itself: a list that holds a route the rules refuse is `invalid_route` for
each such route whatever the renders did, since a render of a route that is not a path may throw
for that reason alone. Both diagnostics are at `main`. `output_path_collision` also covers a page
whose file is, under the folding, a directory of another page or of a file the build writes —
`/a` and `/a.html/`, or `/index.html/` beside the shell — which one file system could not hold.
The check is one pass over each path's directories. A prerendering build needs an absolute base
(`frontend.md` §10.1 allows a relative one): a page below the root names its entry from the base,
and a route's `Url` has the base in its path, so `"./"` is refused with exit 2. `beni serve`
answers a directory with no `index.html` with the page of its name, `/blog` with `blog.html` beside
`blog/x.html`, as a static host does.

### 7.5 A title per page

A page is found by its `<title>`. `Tea.document`'s and `Tea.application`'s `view` gives a `Document`
with a `title` (§9.8.13 there); the shell gets a fourth placeholder, `{{title}}`, which a
prerendering build replaces with the route's title, escaped, and a client build with nothing. The
platform's own shell keeps its `<title>beni</title>`; an app that wants a title per page writes
`<title>{{title}}</title>` in its shell. P3 builds it with `Tea.document`. Other head content (a description, an Open Graph image) is a later
amendment, once a program can say it.

*Amended 2026-10-29, as built in P3 (#1194).* "Escaped" is §4.1's rule for a text — `&`, `<` and a
carriage return — and `"` and `'` as well, since a shell may write `{{title}}` in a quoted
attribute (`<meta property="og:title" content="{{title}}">`). The render function of a `document` or an `application` gives `[html, title]`,
and the record carries the title. A shell's `{{title}}` and `{{view}}` are replaced in one pass, so
a title that says `{{view}}` stays text; a page with no title — a `sandbox`'s, or the shell with
no view — writes nothing there.

## 8. Build-time data

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

*Specified 2026-10-29 (#1207, slice P4; the heading lost its "(later)" the same day).* §8.1–§8.11
are the contract; the paragraph above is kept as the direction it was, and they keep it. Built in P4 (#1218), as §11 *As built — P4* amends them.

### 8.1 The shape

A site with build-time data is **two programs over shared modules**, one project:

- **the data program**, built for `node`, whose `main` is `Prerender.pages schema body` (§8.3): it
  may read files, and gives a list of routes, each with its value;
- **the site**, built for `browser-inline` as today, whose `main` is
  `Browser.prerenderData schema λvalue → program` (§8.4): its `init` reads the value.

The build builds and runs the data program first, under the `node` on `PATH`, and gets each route's
value encoded by the data program's schema as JSON text. For each route it then writes a page that
holds that text in a `<script type="application/json">` (§8.6), and renders the page in the
prerender tree **from the value the site's schema decodes from the bytes the page holds**. The
client decodes the same bytes, by the same code, before `init`. So the build's `init` and the
browser's get the same value, whatever the schema does to it, and §3's claim becomes: for every
route `r` with bytes `b`, the page holds `view (init r (decode b))`, and the browser computes
`view (init r (decode b))` from the page.

```text
beni.json
shell.html
src/Main.beni        the site: browser-inline
data/Main.beni       the data program: node
shared/Blog.beni     the schema both programs compile
posts/hello.txt      what the data program reads
```

The schema module is in both programs' paths, so both compile one declaration. The build does not
check that they do: the tie between the two programs is the bytes, and the site's decode of every
page's bytes at build time is the check (§8.5 item 5). Two schemas that differ, but whose bytes the
site still decodes, give a page and a client that agree, because both read the decoded value.

**Rejected: the data functions in the site's own modules**, compiled a second time for `node`, as
elm-pages and Next.js put a page's data function beside its view. A build is one entry point and
one platform (`boundary.md` §5.3); a module that holds both a browser view and a file read resolves
under neither platform. Two programs over a shared module is what §5.3 already gives a client and
a server, and needs no new compiler concept.

### 8.2 Naming the data program: `"build"."data"`

```json
{
  "build": {
    "platform": "browser-inline",
    "paths": ["src", "shared"],
    "origin": "https://example.com",
    "data": { "paths": ["data", "shared"], "inputs": ["posts"] }
  },
  "html": "shell.html"
}
```

- **`"paths"`** — required, a nonempty list of strings: the data program's `<path>`s, relative to
  the project root as `"build"."paths"` are, with module names derived the same way (`frontend.md`
  §1). A path that cannot be read is the build's exit-2 failure for an unreadable path, when the
  build uses the data program (§8.5 item 1).
- **`"inputs"`** — optional, a list of strings, files or directories relative to the project root:
  what `serve` and `--watch` watch for the data program, besides its sources (§8.8). The build
  reads nothing from them itself.
- A value of another JSON type, or a `"data"` that is not an object, is `frontend.md` §10.1's
  exit-2 failure, `beni: cannot read '<root>/beni.json': it is not a JSON object`. A key `"data"`
  does not know is ignored, as every manifest ignores one. There is no flag.

**The platform is `node`, always.** The build runs the data program under Node, and `node` is the
platform with a file system (`boundary.md` §5.1). A data program on a platform layered on `node` is
a later key, once one exists that needs it.

**The data program is an ordinary `node` build**: one `main` in its paths, with `missing_main`,
`duplicate_main` and `main_not_program` as for any build. A module in both lists is compiled twice,
once per platform, and sees only that platform's modules (`boundary.md` §5.3): a shared module that
imports `Tea` fails to resolve in the data build, which is the diagnostic wanted. Both builds use
the project's one cache directory, which is safe because a module's cache key is the whole input of
its check, what its imports resolve to included (`fast-compiler.md` §8).

*Why a key:* the data program is a second pair of entry point and platform in one project, which
`boundary.md` §5.3 says the manifest should carry (*"the manifest concept M4 introduces should carry
the set"*). `"data"` is the first such pair a manifest names; it names one, for one purpose, and is
not the general set.

### 8.3 The data program: `Prerender.pages`

`node` gets a module `Prerender`:

```text
Prerender.pages : Schema e d, (⊤ → Result String (List (String × d))) → Program
```

- **`body` runs in a fiber**, as `Io.run`'s does, so it may wait: `Io.readFile`, `Io.sleep`, a
  `Task.spawn` per file. It **may be impure**: it runs once, in the build, and what it gives is the
  pages' input. §3's guarantee is about what is computed from that input, by both the build and the
  browser; the data program is computed by the build alone.
- **`Ok pages`** — each pair is a route and its value, in the order the build writes the pages.
- **`Err why`** — the build fails, `prerender_data_failed`, quoting `why`.
- **Each value is encoded with `Schema.print schema value`.** An encode that fails — an `Int` past
  2⁵³, a non-finite `Float`, a refinement (`schema.md` §5: *"Typed encode still validates
  refinements"*) — is `prerender_data_failed`, naming the route, each issue's path and message.
- **Where the records go.** The build runs `node <data tree>/_main.mjs <records file>`. After `body`
  returns, `Prerender.pages` writes, in one write, one JSON line per page, `{"route": r, "data":
  text}`, then `{"end": n}` with the count, to the file its first argument names, and the program
  exits 0. With no argument it writes the same lines to standard output, so a data program built on
  its own (`beni build --platform=node --out=data-out data shared`, an `--out` of its own so it
  does not write over the site's) and run by hand shows what it gives. The
  records are not on standard output under the build because `Debug.log` writes there (§5.1).
  `Prerender` is beni over `Js`, with one `impure` `foreign` that writes the records.
- **A throw** in `body` is a defect: Node ends with a non-zero exit and the error on its standard
  error, with no `end` record, and the build reports `prerender_data_failed` with what Node wrote,
  less the machine's paths, as §5.5's amendment does. A run that exits 0 with no `end` record — a
  `main` that is not `Prerender.pages` — is `prerender_data_failed`, saying that the data program's
  `main` must be `Prerender.pages`. A line that is not one of these records is the same code.
- **It runs with its working directory at the project root** (the directory of the app's
  `beni.json`), so `Io.readFile "posts/hello.txt"` names a project file wherever `beni` was started.
  It inherits the build's environment.
- **It is built in development mode in every build, `--release` included.** It never ships, and
  what it gives is the same in both modes (`schema.md` §10's differential tests pin a schema's print
  in both), so `Debug` is allowed in it under `--release`: `debug_in_release` guards what a page
  ships (`backend.md` §9). Its source maps are off. It is built into `.<out>.data` beside `--out`,
  named and placed by §5.1's amended rule for the prerender tree (`.beni-data` inside an output
  named `.` or `..`), and removed whether the build succeeds or not.

**The data program gives the routes**, and the site lists none. A blog's routes are its posts, which
are files: the site cannot list them (it is pure, and `browser-inline` has no file API), and the
data program can. One list of pairs cannot hold a route without its value, or a value without its
route. A page with no data of its own is a constructor of the data's type:

```beni
--! What the data program gives each page, and what the site's `init`
--! receives: one schema, in a module both programs compile.

pub schema Page tagged "page" of
    Home as "home"
        titles : List String
    Article as "article"
        slug : String
        title : String
        body : String
```

The data program, `data/Main.beni`:

```text
import Blog exposing (Page)
import Io
import Node exposing (Program)
import Prerender


slugs : List String
slugs = [ "hello", "second" ]


article : String → Result String (String × Page.Type)
article slug =
    case Io.readFile "posts/${slug}.txt" of
        Ok body →
            Ok ( "/blog/${slug}", Page.Article { slug = slug, title = slug, body = body } )

        Err _ →
            Err "cannot read posts/${slug}.txt"


pages : ⊤ → Result String (List (String × Page.Type))
pages _ =
    articles = Result.combine (List.map slugs article)?
    Ok [ ( "/", Page.Home { titles = slugs } ), …articles ]


main : Program
main = Prerender.pages (Page.schema ⊤) pages
```

(Checked and formatted against a stub of `Prerender.pages` with this signature, 2026-10-29. The list
of slugs is written in beni because `Io` has no directory listing yet, §8.11.)

### 8.4 The site: `Browser.prerenderData`

`browser-inline`'s `Browser` gets:

```text
Browser.prerenderData : Schema e d, (d → Program) → Program
```

```text
main : Tea.Program
main = Browser.prerenderData (Page.schema ⊤) λpage →
    Tea.document
        { init = λ⊤ → ( { page = page, open = False }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = λ_ → Sub.none
        }
```

(Checked and formatted against a stub of `Browser.prerenderData`, with a `view` that reads
`model.page`, 2026-10-29; `beni build` of it already accepts a program constructor called inside a
lambda.)

- **Where it is written** is §7.2's spine, amended: `main`'s body, or the first argument of a
  `Browser.mountAt` there, may be a call of `Browser.prerenderData` whose second argument is a
  lambda written in place, whose body is in turn a program constructor's call or a `Browser.mountAt`
  around one. Anywhere else, a named function in the lambda's place, a lambda whose body binds names
  first, or `Browser.prerenderData` used as a value is `program_shape`, as for `Browser.prerender`;
  so is `Browser.prerender` and `Browser.prerenderData` on one spine (*"prerendered twice"*).
- **The lambda's parameter is read only by the record's `init`** — its body, or a function `init`
  calls with it. A read anywhere else, by `view`, `update`, `subscriptions` or the element of a
  `mountAt`, is `program_shape`, saying to put the value in the model in `init`. This is a limit of
  the compiler (`browser-inline.md` §5, class 4), not a rule: the lowering compiles `view`,
  `update` and `subscriptions` as functions of the model, whose writes it tracks by model path
  (`write-sets.md`), and the value is not in the model until `init` puts it there. It costs a
  program one field. What lifts the limit is a value the lowering treats as a constant of the page,
  which would be an amendment here.
- **The type is the checker's.** `d` is the schema's Type endpoint, and `init`'s use of the
  parameter is checked as any expression is: an `init` that reads a field the schema does not have,
  or reads it at another type, is a compile error of the site, and every page's value is decoded
  with that schema, so no page can hand `init` a value of another shape.
- **The schema is statically known**: a `schema` declaration's `X.schema ⊤`, a derived
  `Schema.derived ⊤`, or a composition of those by `list`, `nullable`, `converted` and generic
  arguments — what `schema.md` §6, *A statically known schema runs compiled*, compiles to a parse
  worker. The two trees then run the same worker (§3.1 item 4). A schema built when the page runs,
  by the library's builders, is refused, `program_shape`, as a limit of the compiler (class 4), not
  a rule: its conversions are values inside an opaque `Schema`, which the builders require only to
  be `sync` (`core/Schema.beni`), and no walk of the program can read them, so the build could not
  tell that the decode is pure. What lifts it is `schema.md` §13's per-schema classes.
- **The decode must be pure**, as `init` must: the value `init` gets is computed from it. Each
  `via` conversion and check of the schema's resolved plan, in whichever module it is declared, is
  answered by the checker's rung of that function (`checker-v2.md` §26), not by the walk of one
  module's bodies §3.1's amendment does; one that may be impure — or may suspend, since `init` is
  `sync` — is `prerender_impure`, at that conversion. The schema argument itself is checked pure as
  P3 checks the route list, so it cannot choose another schema in the build than in the browser.
- **`init` receives what §7.3 says** — `⊤`, or an application's route `Url` and key — with the
  value in scope as the lambda's parameter. An application needs `"build"."origin"` as in §7.3.
- **The write-set pass** evaluates `init` at compile time and bakes the string and integer values
  of model paths into the unit's string (`write-sets.md` §9.1). The lambda's parameter is unknown
  to it: a model path whose value reads the parameter is not baked, and is a hole with a binding,
  which the client's first pass checks (§3.2). A path `init` sets to a literal is baked as today.
- **On `browser-tea`** there is no `Browser.prerenderData`: that platform is retired (#966) and gets
  correctness fixes only. A program that uses it builds on `browser-inline` alone; §7.2's promise
  that one source builds on both is `Browser.prerender`'s.

### 8.5 The build, in order

1. **The site is checked**, as today. A `main` that says `Browser.prerenderData` needs
   `"build"."data"`, or the build fails with `prerender_needs_data`, against the app's `beni.json` at
   `1:1`, as `prerender_needs_origin` is. A `"data"` with a `main` that does not say it is the
   warning `prerender_data_ignored`, at the same place, and the data program is neither built nor
   run, nor its `"paths"` read (CLAUDE.md rule 7: a key that does nothing protects no guarantee,
   and is not an error). The warning is not given to a build whose own `main` is
   `Prerender.pages`: that build is the data program, built by hand.
2. **The data program is built and the prerender tree is built**, both before either runs, so a
   program the build refuses never runs (§5.1's amendment, item 3) — the data program included,
   whose run may read and write files. The data program is a second build in the same process
   (§8.3); the tree is §5.1's, where `prerender_impure`, `program_shape` and `invalid_html_shell`
   are found. **The diagnostics of the site, the data program and the tree are one render**, sorted
   together as the build's late diagnostics are (`src/build/Command.zig`), so `--diagnostics=json`
   is one array and `--watch` prints one render per build (`frontend.md` §1, §10.3). A warning of a
   module both programs compile, at the same place with the same text, is rendered once, as the
   tree's repeated warnings are dropped today. An error stops the build, exit 1, and nothing is
   written or run.
3. **Node runs the data program** (§8.3), or the build fails with `prerender_needs_node` (§5.1). Its
   records are read; any failure of §8.3 is `prerender_data_failed`, at the data program's `main`.
4. **The routes are checked** by §7.4's rules, on the whole list, before anything renders: a route
   the rules refuse is `invalid_route`, two routes that write one file `output_path_collision`, both
   at the site's `main` as P3 reports them, the message saying the data program gave the route.
5. **Node runs the prerender tree** as §5.1 says. Its runner, `_node.mjs`, is handed the data
   records too, and calls, for each page in order, `render(route, text)`, where `text` is the bytes
   the page will hold (§8.6), not the data program's. `render` decodes `text` with the site's
   schema, by the function the client calls, and renders the route from the value, or gives the
   issues: a decode that fails is `prerender_data_invalid`, at the `Browser.prerenderData` call,
   naming the route, each issue's path and message, and the build fails.
6. **The client tree and the pages** are written as §5.1 item 3 says, through `pending`. Both trees
   are removed.

Node runs twice: once per program, the data program's run ending before the tree's starts. The two
builds of item 2 may run at the same time, which is the implementation's choice: the output is the
same either way (§8.9).

### 8.6 The value in the page

`{{view}}` (§5.3) is replaced with the script, then the unit:

```text
<script type="application/json" data-beni-data="/blog/hello">{"page":"article","slug":"hello",…}</script><main data-beni="/blog/hello">…</main>
```

- **The script carries the route too**, in `data-beni-data`, and on a data site the client takes
  both the route and the value from it — the route `init`'s `Url` is made from (§7.3) included,
  where P3's mount reads `[data-beni]`. So the route and the value always come from one element:
  on a `--no-prerender` page (§8.10), and on one whose unit a host removed, the value is never one
  route's and the `Url` another's. The route is written as `data-beni`'s is: §7.4's characters,
  which need no escaping in a quoted attribute.

- **The text is the data program's JSON text with every `<` written `\u003c`.** HTML parses the
  inside of a `script` as script data: it ends at the first `</script` in any case, and a `<!--` or
  `<script` inside changes where it ends; with no `<`, neither can occur. A character reference is
  not decoded there, so `&` stays as it is. JSON text holds a `<` only inside a string, where
  `\u003c` is the same character, so `JSON.parse` of the page's text gives what the data program's
  would. The parser changes two more things in a script: a NUL becomes U+FFFD, and a carriage
  return, alone or before a line feed, becomes a line feed. `Schema.print` writes neither:
  `JSON.stringify` escapes every control character in a string and writes no whitespace between
  tokens. A record whose text holds a character below U+0020 is not one `Prerender.pages` wrote, and
  is `prerender_data_failed`.
- **Every character past U+007E is written as a `\uXXXX` escape too** (a character past U+FFFF as
  its two surrogates), so the text is ASCII. JSON text holds such a character only inside a string,
  where the escape is the same character. The client reads `textContent` after the browser has
  decoded the page by its encoding, and a shell need not declare one: a page with no
  `<meta charset="utf-8">`, served with no charset, is decoded as windows-1252, which would turn
  non-ASCII UTF-8 bytes into other characters and give the browser's `init` another value than the
  build's. ASCII is the same bytes in every encoding a page can declare (HTML reads a declared UTF-16
  as UTF-8). The cost is bytes on non-Latin text, before compression. So the `textContent` the
  client reads is the text the build wrote, byte for byte, in every page, and the build decodes
  exactly those bytes (§8.5 item 5).
- **`type="application/json"` is a data block**: the browser never runs it, and a content security
  policy that forbids inline scripts does not block it (§6.5's script is another matter).
- **In the client**, the mount of a `Browser.prerenderData` program first finds the first child of
  the mount element that is a `script` with `data-beni-data`, reads its `textContent`, removes it,
  and decodes the text with the schema; `Ok value` is the parameter, and the mount goes on as §6.1
  says, `Inline.take` included. **`Err`, or no such script, stops the page as a defect** (the
  development crash screen, `browser-inline.md` §6, naming the issues or the missing script): the
  page is not one the build wrote — a host changed the text so it no longer decodes, or took it out
  — and with no value there is nothing `init` can start from, so the fresh mount of §6.4 is not
  open to it. This is how an application opened at a `file:` address stops (`boundary.md` §9.8.13
  (d)). A host that changes the text so that it decodes to another value gives `init` that value: a
  text the view then shows differently heals by the first pass (§3.2), and a structure that differs
  is found and mounted fresh, from that value, by §6.4.
- **After the takeover the page holds no script**, so it holds what a fresh mount makes, as §6.1
  removes `data-beni`.
- **`{{title}}` and `{{view}}` are replaced in one pass** (§7.5's amendment), so a value whose text
  says `{{title}}` stays text.
- **`index.html`** is the page of the route `/` when the data program gives it, and is **not
  written** otherwise: a page of a data site with no value could not start (the bullet above), so
  the shell with no view that §7.4 writes for a program whose list does not hold `/` would be a
  page that stops. A host's fallback for an address no route has is one of the program's routes
  (GitHub Pages serves `404.html`, which is the route `/404`). `beni serve` answers as it answers
  any output with no `index.html`: `/`, and an address its single-page fallback would answer with
  `index.html`, are `404` (`frontend.md` §10.4, amended).

### 8.7 Size

**Each page carries its own value and no other**: a site of 500 posts writes one post into each
page, and its client tree, which every page loads, holds none of them (§7.2's amendment keeps the
routes out of it too). The client tree gains the site schema's decode — the compiled parse worker,
or the library's engine for a schema built at run time — and the mount's read of the script.
**A page that does not prerender ships no new byte**: no `emit/inline/` or `emit/release/inline/`
golden moves, and `bench/size.mjs`'s `page` lines are the same bytes. What the data adds to a
client is measured in P4, release, brotli, and reported in its *As built* note.

A page holds its value twice in effect: as the HTML its view makes of it, and as the JSON `init` is
handed. That is the cost of taking over a page whose first model is computed from data, which every
hydrating framework pays; a data program keeps it small by giving only what `init` needs.

### 8.8 `beni serve` and `--watch`

Every build prerenders (§5.2), so every build runs the data program. **What is watched**, besides
§10.3's set (`frontend.md`): every file the data program's `"paths"` hold with §10.3's endings, and
every file under each `"inputs"` entry, whatever its ending (a post is a `.md` or a `.txt`), a
hidden entry skipped and `--out` and the two trees never watched. A change to any of them is a
rebuild, which runs the data program again; a run that fails is a failed build, and `serve` keeps
the last good one (§5.2). `"inputs"` is read when the command starts, as §10.3 reads `"build"`.

A data program may read what no watch can see — the clock, a file outside its `"inputs"` — and its
pages are then remade at the next change, not at that read's. A data program is run again by every
build rather than reused, because nothing tells the build what it read. If that is slow for a large
site, the step is §10 question 4's: render only the routes whose value or program changed, not skip
the run.

### 8.9 Determinism

The pages are a function of the site, the shell, the base, the origin and the data program's records
(CLAUDE.md rule 5). The data program runs once per build in one Node process, and the build writes
the pages in the order of its list, after the client tree's files; nothing depends on `--jobs`, and
the determinism test's corpus run covers a data site with no change (§5.4). What the data program
reads is its own input, as any program's is: one that reads the clock gives other pages on another
run, as a `node` program prints other lines. That is the program, not the build's thread timing.

### 8.10 The corpus, and `--no-prerender`

With the hidden, test-only `--no-prerender` (§5.2), a data site still builds and runs its data
program, and writes each route's page with its script and no view (`{{view}}` is the script alone);
the client mounts fresh from the value it decodes. So the corpus's two builds of a data fixture are
compared as every `browser/prerender/` fixture's are (`tests/corpus/README.md`, *Prerendered
pages*): one transcript for the page with no view and the prerendered one, each opened on the file
that a host answers the script's address with.

### 8.11 Out of scope

- **Client-side navigation to another route's value.** A page holds its own route's value. An
  application that pushes the address of another data route has no value for it, so its `update`
  loads that page (`Navigation.load`) instead. The direction for a later slice: the build also writes
  each route's text as a file below `_data/` (the compiler's region of the output, §7.4), and
  `Browser.Navigation` gets a command that fetches one and decodes it with the program's schema
  (#1211).
- **A directory listing in `node`'s `Io`.** Until it exists, a data program lists its files in beni
  or reads an index file. It is a capability `node` owes (CLAUDE.md rule 7), filed on its own
  (#1210).
- **HTML text from data**, such as Markdown rendered to HTML: `browser-inline` has no node that
  inserts HTML text. A data program that parses Markdown gives a structure the view renders.
- A data program on another platform than `node`; a data site on `browser-tea`; a value read by
  `view` or `update` directly (§8.4's limit); head content other than the title (§7.5); mapping a
  data program's stack to `.beni` positions (§5.5).

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
| `prerender_needs_data` | a program says `Browser.prerenderData` and `beni.json` has no `"build"."data"`; against `beni.json` at `1:1` (§8.5) | P4 |
| `prerender_data_failed` | the data program's `body` gave `Err`, threw, gave a value its schema cannot encode, or ended without its records; at the data program's `main`, naming the route when there is one (§8.3) | P4 |
| `prerender_data_invalid` | the site's schema cannot decode a route's text; at the `Browser.prerenderData` call, naming the route and the issues (§8.5) | P4 |
| `prerender_data_ignored` (warning) | `beni.json` names a data program and `main` does not say `Browser.prerenderData` (§8.5) | P4 |
| `program_shape` (existing) | also: `Browser.prerenderData` off the spine, not given a lambda written in place, given a schema built at run time, or its parameter read outside `init` (§8.4) | P4 |
| `prerender_impure` (existing) | also: a conversion or a check of the site's schema that may be impure (§8.4) | P4 |
| `invalid_route`, `output_path_collision` (existing) | also: the routes the data program gives (§8.5) | P4 |

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
2. ~~**What does `init` receive on a prerendered page?**~~ **Decided** (the owner, 2026-10-29: "go
   with the recommendation"): §7.3 as written. I recommended §7.3: the route as the page
   carries it, with the origin from `"build"."origin"` and no query or fragment, and the real
   address afterwards as an `onUrlChange` message. The alternative is Elm's: `init` gets the address
   the page was opened at. Then any page opened with a query, a fragment, a `.html` suffix or on a
   preview host computes a different first model than the build did, and the guarantee of §3 is
   gone for exactly the pages people share. The cost of the recommendation is a departure from
   `browser-tea`'s `application`: a program that reads the query does it in `update`. One source
   still builds on both platforms; it can differ in its first render only.
3. ~~**What does a page do when its HTML is not what the program would make?**~~ **Decided** (the
   owner, 2026-10-29: "go with the recommendation"): §6.4 as written, built in P2a. I recommended §6.4: mount
   fresh in the same task, with a warning in development. The page is then correct; it loses only
   the prerender's benefit for that load. The causes are outside the program — a browser extension
   that inserts an element, a CDN that rewrites links — and stopping the page as a defect would make
   the site fail for every user of that extension, for something no beni code did. I know you
   rejected fallbacks in the compiler ("no 'fallbacks', i want a proper implementation", ownership,
   2026-10-15). This is not one of that kind: it is not code the compiler could not prove, but a page
   the host changed after the build, found by a check at run time, and the fresh mount is the
   program as written. If you want it to stop instead, it is the same check with a different answer.
4. ~~**Should `beni serve` prerender on every rebuild?**~~ **Decided** (the owner, 2026-10-29: "go
   with the recommendation"): yes, §5.2 as written. I recommended yes (§5.2): development then takes
   the page over as production does, and a hydration fault is found where the developer works. It
   costs one run of the prerender tree per rebuild, measured in P1; if it is slow for a large site, the step is
   to prerender only the routes whose pages changed, not to skip it.

*2026-10-29 (#1207):* §8's contract adds no question. Each of its choices follows from what is
decided: a build is one entry point and one platform (`boundary.md` §5.3), so the data is a second
program; §3's guarantee, so the build renders from the bytes the page holds; TEA, so the value
reaches the program through `init`.

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
| **P4** — build-time data | §8: `"build"."data"` (and its row in `frontend.md` §10.1); `node`'s `Prerender.pages` and its records; `Browser.prerenderData` on `browser-inline` — the spine and the parameter rule (§8.4), the client's read of the script before `init`, the tree's `render(route, text)`; the data program built and run before the tree, in development mode, at the project root; the script and its escaping (§8.6); `index.html` only for `/`; the four new codes and the existing ones' new cases (§9); `serve` and `--watch` watching the data program's paths and `"inputs"` (§8.8); `--no-prerender` for a data site (§8.10); the lowering interface's next version, recorded in `boundary.md` §9.4.6, if the placement needs one; `skills/beni/references/prerender.md` | a blog whose posts are files under `posts/` builds, through a data program that reads them, a page per post and one for `/`, each holding only its own value, and each taken over with no element replaced; its transcripts equal the `--no-prerender` build's; a post whose text holds `</script>`, `<!--` and `&amp;` shows them as text in the build and after the takeover; a site whose schema reads a field at another type than the data program's writes fails with `prerender_data_invalid` naming the route; an edit of a post under `serve` rebuilds and the page reloads with it; no `emit/inline/` golden and no `bench/size.mjs` `page` line moves; the determinism test builds a data site; what the data adds to a client is measured, release, brotli | `browser/prerender/` adds `DataBlog` (`data/`, `shared/`, `posts/`; a `Tea.document`), `DataEscapes` (`</script>`, `<!--`, `<script`, `&amp;`, U+2028, a character past U+FFFF, a backslash, a quote), `DataSandbox` (a `Tea.sandbox` with data), `DataApplication` (a `Tea.application`: the route's `Url` and the value), `DataBaked` (a model path `init` sets to a literal baked, one it sets from the value a hole), `DataTampered` (the script's text changed before load so that it does not decode: the page stops, in both modes and in the `--no-prerender` build too; the harness learns a setup step that edits the script's text, which acts on a page with no unit as well, and the kind a golden per mode for the `--no-prerender` build, both written in `tests/corpus/README.md`), `DataScriptRoute` (a `--no-prerender` application whose `init` gets the script's route), `DataDebugRelease` (a data program that calls `Debug.log`, built with `--release` and no `--allow-debug`: it builds), `DataUnicode` (a value with non-ASCII text in a shell with no `charset`: the same value in both), `DataLibrarySchema` in `build/bad/prerender/` (a schema built by the library's builders: `program_shape`), `DataIgnored` (a `"data"` and a `main` with `Browser.prerender`: the warning, as `_expected.diag`); `build/bad/prerender/`: `DataMissing` (`prerender_needs_data`), `DataErr` (`Err`), `DataThrows`, `DataUnencodable` (an `Int` past 2⁵³), `DataNotPages` (a data `main` that is `Node.print`), `DataMismatch` (`prerender_data_invalid`), `DataReadInView` and `DataOffSpine` (`program_shape`), `DataImpureConversion` (`prerender_impure` at a `via`), `DataRoute` (`invalid_route` from the data), `DataTypeMismatch` (an `init` that reads a field the schema does not have: the checker's error), `DataSharedImportsTea` (a shared module that imports `Tea`: the data build's `unknown_module`); `tests/blackbox/devloop_test.zig`: *serve reruns the data program when an input changes*; `tests/blackbox/build_test.zig`: the data program built and run from another working directory reads the project's files |

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
the steps `fresh`, `inject`, `retag` and `remove`, the normalisation, and goldens of a build's own; the P2a
fixtures are `Tampered`, `Retagged`, `RetagUnseen` (an element no code refers to: every build mounts
fresh), `Shifted` (an element no code refers to taken out and one put in: every build mounts fresh, #1186), `ArmOpens`, `PieceArm`, `LoneElement` and
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
| `counter` (a text hole, two buttons) | 0.680 | 3.135 | 1 104 B | 18 493 B |
| `static` (research 29's static-heavy page, ~2 000 elements, 50 holes) | 1.560 | 4.960 | 1 485 B | 21 090 B |
| `arms` (30 panels, every other body hidden) | 1.675 | 5.415 | 2 034 B | 19 743 B |

From the navigation's start to the same point, beni's medians are 12.0, 15.2 and 12.9 ms, Solid's
15.3, 18.9 and 17.9 ms. What hydration adds to beni's client, against the same program built
without `--prerender`, is 583, 660 and 711 B brotli on the three pages (the runtime's `take` and
the unit's arms and every element's tag, #1186), against Solid's 1 439 B of hydration (research 27 §6.8). The run takes
under a minute.

**As built — P3** (2026-10-29, #1194). A program prerenders when `main` says `Browser.prerender`
(§5.2's amendment): `Emit.prerenders` reads `main`'s spine from the checked BIR, so the build knows
before it emits whether to build the prerender tree, and whether the program is a `Named.routed`
constructor's. The lowering interface is version 1.22 (`boundary.md` §9.4.6): the placement kind
`prerender`, `Named.routed`, `Build.address`. In the compiler (`src/js/Lower.zig`,
`findPrerenders`, `prerenderCall`) a call on the spine is compiled as its program outside the
prerender tree, and the emitter cuts its callee and its list from reachability (`cutPrerender`);
in the tree it is called, its list checked pure by the walk `programPure` uses. The prerender
tree's entry exports `render = main[0]` and `routes = main[1]`; Node's runner writes the route list
as its first record, then one record per route, `{ route, html, title }`, and the build checks the
routes, maps each to its file, checks collisions and writes every page through `pending`
(`src/build/Command.zig`, `Emit.emitShell`). The render function writes the route in `data-beni`;
for a `document` or an `application` it gives `[html, title]`, and an application's `init` is
handed `Inline.routeUrl(address, route)`. The hydrating application's mount hands `init`
`Inline.pageUrl(address)` and calls `Inline.arrived(url)` once its subscriptions listen (§7.3's
amendment). `serve` answers `<path>.html` (`src/devloop/Serve.zig`), and prerenders every build as
any build does. Core's `Url.percentDecode` is now `Js.pure` — it reads and changes nothing, and
without it every `Url.Parser` segment parser made an `init` impure (`prerender_impure`), so no
routed program could prerender; its emitted code did not change.

The fixtures are `browser/prerender/Blog` (a page per post from the list, opened at
`/blog/hello?ref=feed#comments`, a link click that navigates with no page load, `back`) and
`Titles`, `FileName` (opened at `/about.html?from=feed#team`, the address replaced by the route); `browser/tea/PrerenderedBlog.beni`, `Blog`'s source byte for byte on `browser-tea`;
`build/bad/prerender/` `RouteUnderscore`, `RouteDotDot`, `RouteNonAscii`, `RouteCollision`,
`RouteFolded`, `RouteImpure`, `PrerenderAsValue` and `NeedsOrigin` (the old `Application`, whose refusal P3 lifts);
`tests/blackbox/devloop_test.zig`'s *serve prerenders every build, and answers /about with
about.html*; and the determinism test of §5.4 now builds three routes. Every existing
`browser/prerender/`, `build/bad/prerender/` and `emit/prerender/` fixture says `Browser.prerender`
in place of the flag. A page that does not prerender ships what it did: no `emit/inline/` golden
moved, and `bench/size.mjs --pages-only` prints the same bytes. What prerendering adds to a client,
release, brotli, against the same program built with `--no-prerender`: 577 B for `Counter`, and
1 049 B for `Blog`, whose `pageUrl`, `routeUrl` and `arrived` are the routes' share.

**As built — P2b** (2026-10-29, #1206). §6.5's amendment as written, with the review's fixes in
it: the lowering's `Page.captureScript` writes the script at the start of the program site's
render function's string (`platforms/browser-inline/zig/inline.zig`), its kinds from the unit's
events and each piece's (`PieceData.kinds`), the pointer events left out (`capturedKinds`); the
hydrating mount calls `Inline.caught(at)` before `take` and `Inline.deliver(E[0])` last; and in a
prerendering client every listener, a piece's too, is wired through `Inline.listen`, `onTaken` or
`onArmTaken`. The lowering interface does not change. The browser driver runs a prerendered page's
inline scripts where the page holds them, and its setup step `early <step>` acts on the page before
the program loads (`tests/corpus/README.md`, *Prerendered pages*). The fixtures are
`browser/prerender/EarlyInput` (a click on a button's child, typed text, a checked box, a
`select`'s `change` and a second click, delivered in that order; the box stays checked; the
script's listeners are gone after the load), `EarlyKept` (a field no listener hears keeps the text
typed into it; a field heard on `focus`, which does not bubble, gets its message and keeps the text
typed after it; a `pointerdown` is not recorded, and the click after it is delivered), `EarlyParts`
(a listener inside a shown eager arm, a form's `onSubmit`, which prevents its default, and a
piece's buttons), `EarlyNone` (no listener: no script in the page) and `EarlyFresh` (a page a host
changed: the input is dropped). Every existing prerendered page whose program listens holds the
script, so their `_expected/` pages moved, and the `emit/prerender/` goldens show the new calls. A
page that does not prerender ships what it did: no `emit/inline/` or `emit/release/inline/` golden
moved, and `bench/size.mjs --pages-only` prints the same bytes as `master`'s compiler.

The script is 294 B raw, 161 B brotli alone (one kind, `click`); in a page it adds 123–145 B
brotli to the HTML. The runtime adds 382–403 B brotli to the client (`caught`, `listen`,
`onTaken`, `deliver` and its walks): with `bench/ui/hydrate.mjs`, release, 61 loads per page and
subject, what hydration adds against `--no-prerender` went from 583, 660 and 711 B to 967, 1 063
and 1 093 B on `counter`, `static` and `arms`, against Solid's 1 439 B. Time to interactive, by the
same harness, `master`'s compiler and this one run one after the other on a quiet machine (load
average 4–6), medians, ms:

| page | module start → handlers, before | after | navigation → handlers, before | after |
|---|--:|--:|--:|--:|
| `counter` | 0.665 | 0.515 | 11.5 | 11.9 |
| `static` | 1.530 | 1.380 | 14.8 | 15.3 |
| `arms` | 1.735 | 1.570 | 13.3 | 13.3 |

The mount itself is not slower; from the navigation's start the two differ by 0–0.5 ms, the page's
larger HTML and client. The harness loads each page with no input before the takeover, so `deliver`
has nothing to hand on: what a delivery costs is a walk and a call per record.

**As built — P4** (2026-10-29, #1218). §8 as written, with these amendments. The lowering interface
is version 1.23 (`boundary.md` §9.4.6): the placement kind `prerender_data`, `Program.data`, and
`programDataSchema` and `programDataBind`. In the compiler (`src/js/Lower.zig`, `dataCall`) the
`Browser.prerenderData` call on `main`'s spine is compiled, in every tree, as its lambda's body, and
the emitter cuts its callee from reachability (`cutPrerender`); the lambda is never made. The
program there evaluates the schema and binds the lambda's parameter itself: the mount, right after
`Inline.root`, calls `Inline.pageData(schema, root)`, which takes
`:scope>script[data-beni-data]` out of the mount element and gives `[route, value]`, an
application's `init` then handed `Inline.routeUrl(address, route)` and `arrived` called after its
subscriptions listen, hydrating or not; the render function takes `(route, text)` and calls
`Inline.decoded(schema, text)`, returning its `{ issues }` when the text does not decode. A page
with no script, or whose text does not decode, throws inside the mount's guard in both modes, the
issues named only in a development build. A `--no-prerender` data build is `Emit.Prerender.fresh`:
the pages are written with their script and no view, and the client is the one a program that does
not prerender gets. The lambda's parameter is a name or `_`: a parameter that takes the value apart
is `program_shape`, a limit of the compiler; take it apart in `init`.

The schema's checks are the emitter's (`Emit.checkDataSchema`), once the modules are lowered: a
schema that is not statically known — a top-level constant naming one is followed — is
`program_shape` at the schema; in the prerender tree, the schema's own expression (what a
`Schema.converted` is handed) and every `via` and check of every plan the schema reaches are walked
in their own modules, through lambdas and the bodies of the app's and the platforms' declarations
they name, and a call the checker answers impure or suspending, `Debug`'s aside, is
`prerender_impure` at the conversion. A statically known schema is made by makers that compute
nothing else, so of the schema argument only what a `Schema.converted` is handed is walked. A
`Schema.derived ⊤` is one of the derived codecs of `main`'s module, and each of them joins the walk,
which follows `codec_ref` nodes and, at a `codec_value`, the body of the type's own `codec`. The
calls of core `Schema`'s makers are exempt: they build a schema with `Js`, which the checker
answers impure, and decode nothing; the functions they are handed are walked as their arguments.
`.<out>.data` is guarded as the prerender tree is: one there that holds no record beni wrote is the
user's, refused with exit 2 and not removed. Each run of Node first removes a records file an
earlier run left.

The data program (`src/build/Command.zig`, `buildData`, `runData`) is a second `Session` over the
same cache, built for `node` into `.<out>.data` in development mode with no source maps; its paths
are each a source root of their own, so a site built with `--root` (which names the site's modules)
does not lend it its root. Its diagnostics are rendered in the site's one render
(`Session.foreign`, `Session.exportLate`), a diagnostic the site says already at the same place
with the same text dropped. `Prerender.pages` (`platforms/node/Prerender.beni`, one `impure`
`foreign`, `writeRecords`) writes `{"route", "data"}` per page and `{"end": n}`; an `Err` is one
record `{"error": why}`, and a value its schema cannot encode ends the records at
`{"route", "issues"}`, each issue a line `.path: message`; both exit 1 after a line on standard
output. The build escapes each text as §8.6 says (`pageText`), refuses one with a control
character or bytes that are not UTF-8, checks the routes, and hands the tree's runner a file of
`{route, text}` lines. `prerender_data_ignored` is not given to a `--library` build or to a build
whose `main` is `Prerender.pages`; a `Browser.prerenderData` off the spine leaves `main` not saying
it, so that build warns as well as refusing.

`programInit` now binds what the ownership pass hoists at an `init` lambda it evaluates as its
body: a read of a field of a captured record — the page's value is one — was hoisted there and
never bound (`ownership: a hoisted record read is lowered before its placement`). The emitter's
early refusals before lowering leak in a `--release` build; the schema's checks run after lowering
to avoid them, and the leak is #1237.

The fixtures are §11's P4 row, with three changes: `DataEarly`'s case is `DataSandbox`'s early
click (delivered after the takeover, lost on the `--no-prerender` page); `DataIgnored` is a
`browser/prerender/` project whose build's warnings are its `_expected.diag`, which the kind now
reads; `DataDebugRelease` is `tests/blackbox/build_test.zig`'s *a data program runs at its
project's root, and may say Debug.log under --release*, with the working directory, and the
determinism claim is *a data site's pages are byte-identical at every --jobs*. The harness's
setup step `retext <selector> "<text>"` changes the script, and a `--no-prerender` build may have
its own golden, `.dev-noprerender-expected` or `.release-noprerender-expected`
(`tests/corpus/README.md`, *Prerendered pages*). The browser driver keeps a page's data block and
does not run it.

No page that does not prerender moved: no `emit/inline/` golden, and `bench/size.mjs --pages-only`
prints the same bytes as origin/master's binary. What the data adds to a client, release, brotli
11: `DataBlog`'s client is 2 621 B against 1 581 B for the same site whose `init` sets a constant
`Page.Home` and says `Browser.prerender` — 1 040 B, the `Page` schema's parse worker and
`compiledParse`, `Inline.pageData`, and the issue's path in development builds only.
