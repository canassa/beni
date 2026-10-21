# Marko 6: Fulfilling the Promise of Less JavaScript w/ Dylan Piercey — organised notes

**Speakers** Ryan Carniato (host; author of SolidJS, formerly on the Marko team at eBay) and Dylan
Piercey (Marko core team, eBay) · **Date** a Friday in early September 2025, inferred (the paste has
no date) · **Length** 5 h 38 m · **Video** <https://www.youtube.com/watch?v=x-3RxGf4KA8>
**Transcript** [`transcript.md`](transcript.md) · **Raw paste** [`raw.txt`](raw.txt)

The first 3 h 51 m are the Marko 6 demo and Q&A with Dylan (the first 51 minutes of that are lost
to a StreamYard failure, chapters 1 and 7). From 3:52 Ryan carries on alone with *This Week in
JavaScript*: Solid news, a React-ecosystem growth argument, React transitions, and a rant on
state in forms. The paste files all of it under chapter 17. The notes below cover the Marko half in
detail and the second half in one section.

Times are plain text; the matching paragraph in [`transcript.md`](transcript.md) links into the video. Quotes are from YouTube's
automatic captions, lightly cleaned, so **quote from the video, not from this file**. A claim is
**He:** when a speaker made it; everything else is **inference** and is marked so.

---

## Thesis

Islands send less JavaScript to the browser, but the cut is made by hand and at component
granularity, and the first piece of shared state turns an island into "a continent". Marko 6 moves
the cut to the **variable, event handler and script**: the compiler follows reactivity across files,
sends only the code reachable from an effect or event handler, and serialises only what those
closures read. Dylan: "this little class, this little element, this thing over here that's derived
from some state or event handler, that is what needs to be sent to the browser"
(9:03). The author never labels a client or server component — "the opt-in was
based off of state".

Ryan's framing is the **JavaScript paradox**: "the best way to remove the reduced amount of
JavaScript on the client is put it on the server" (4:14, 5:13). Marko is the proof that you can
keep declarative, stateful authoring and still ship less than hand-written HTML plus sprinkles
once a page grows.

## What Marko 6 is

| Fact | Where |
|---|---|
| **Status.** A beta, tagged `next`; "all of the APIs are considered final"; released about two months before the stream; eBay teams are starting to use it. `npm init marko`, playground at `next.markojs.com`. | 23:12, 2:33:59, 2:35:10 |
| **Syntax.** HTML first: "pretty much any valid HTML is also valid Marko". Attributes are JavaScript expressions; a method shorthand works (`onClick() {…}`). A concise mode drops the brackets. | 51:15, 1:38:38 |
| **Tags API.** Everything is a tag: `const`, `let`, `if`, `for`, `define`, `script`, `log`, `return`. A tag returns a variable written `/name` and may inject parameters into its body. | 1:05:40, 1:21:30 |
| **Language, not library.** Five or six syntactic parts (tag names, attributes, tag variables, tag parameters, body content, imports/exports); no attribute has special meaning. Ryan's name for the property is *idempotence*: you can write your own `if` with the same syntax. | 1:19:57, 1:27:48 |
| **Compiler.** Babel-based, has its own `evaluate`. Stages up to an *analyze* step are cached between the client and server builds. A tag's inputs are followed across files, so a count passed through 100 components compiles to a direct call. | 26:20, 27:21, 1:48:30 |
| **Meta-framework.** Marko Run: file-system routing with `+` files, an MPA by default, Vite based. | 1:50:23 |
| **Streaming.** In-order and out-of-order together (Marko 5 could not nest them). A `try` tag with a placeholder; static content of the hole is sent eagerly and hidden. `await` now works in the browser. | 1:57:03, 3:30:30 |

## Argument, in order

**1. Islands, and why Marko 6 leaves them (11:21 – 22:01).** State that two islands need must be
hoisted up the tree, and the island grows. Dylan drew it: server components with a client island,
state flowing between them. Ryan: "who wants to manage or think about this stuff". The fix is
granularity below the component: "children actually can become siblings" once the unit of blocking
is smaller than a component (17:20). **Inference:** this is the same observation as beni's
field-identity rule (CLAUDE.md rule 8) seen from the other side — the finer the unit, the less
has to move.

**2. The demo as a size ladder (51:15 – 1:36:07).** Each step shows what the browser receives. These
are the numbers the speakers read off the playground; they are as captioned.

| Step | Bundle (as read out) |
|---|---|
| Static `<div>`; 33 bytes of HTML | no JavaScript |
| `script` calling `alert` | "791 bytes … minified 528" |
| Click handler | about 200 bytes more (delegation runtime) |
| Counter with `let` | "half a kilobyte" more: scheduler, dedupe, text helper |
| Two counters with `if` | 2.6 KB — control flow ships, so the counter is client-renderable |
| Same with `display: none` instead of `if` | back to the small bundle |
| Hacker News comments page | 1.9 KB for a whole app; "pretty much" all of it is a server component |

The speakers' comparison: a React app has shipped "42 kilobytes gzipped" by this point, React
Server Components 50, Remix 63, Next about 70; Svelte and Solid about 5–6 KB for the hello-click
(1:02:05). Ryan's caveat, repeated twice: the runtime size is a one-time cost and not the point;
"the most important thing is we're not sending some of your code" (1:02:05, 1:03:06).

**3. How the browser side works (1:09:12 – 1:16:42).** The compiler tree-shakes by construction.
The component module has several exports; the default one renders everything and is used only when
the component is imported in client code. "All we do when we're hydrating is running these
scripts." A `let` is "a very simple wrapper", with no subscription graph: when `count` changes,
call the one function that sets the text node. A *scope* is "a pile of references" to server data
and to elements, matched to ids the server wrote into the HTML. He compares it with Qwik, with two
differences: no dollar signs, and a finer tree shake after the runtime's fixed cost
(1:16:42, 1:24:48).

**4. Why the slash is the dollar sign (1:17:12 – 1:26:29).** `/count` marks "a reactive variable
that Marko knows and controls and can track through your application". Qwik's `$` plays the same
role plus a split boundary; Marko's compiler reads reactivity across files and so does not need
the boundary marker. What is serialised: values read inside a script or event handler, and state
that meets something server-only. Ryan on the alternative, compilers that reinterpret JavaScript:
Svelte and Ripple "take existing JavaScript syntax and say I'm going to give this meaning that this
syntax doesn't normally have".

**5. Controlled and uncontrolled, in one syntax (3:00:16 – 3:26:04).** The longest single topic.
An attribute on a native tag is a plain attribute: uncontrolled, works in a form. Passing a
`valueChange` handler means "I own the state now"; the DOM property then always matches what you
specified, and Marko keeps the cursor position. `value:=text` is sugar for the pair. The same
convention works on user components through `let`, and on `return`: a component can be written
once and the *parent* chooses whether it is controlled. There is no effect and no two-way
binding: "the parent has the final say". Form `reset` goes through the same handler. Ryan: this is
"surprisingly difficult to write in most frameworks", and the reason Solid 2.0's derived signals
"only solved half the problem" (3:11:30).

**6. Where the cost goes (2:04:14 – 2:12:30, 2:51:41).** Dylan: at eBay "half the time spent
rendering, half the time spent serializing", so the serialiser matters as much as the renderer.
Ryan's *Front-End's Existential Crisis* result is recalled: SolidStart, RSC and Qwik all scored the
same on a Hacker News test and the reason was serialisation, and Astro beat them because it did
not navigate on the client. He says the Solid serialiser was modelled on Dylan's code.
**He:** on the Hacker News test "I can't tell the difference between Marko and Astro optimized with
solid", because that page's interactivity is too simple to separate them (2:06:50).

**7. The unsolved part (2:23:27 – 2:28:06).** Client navigation with server content. What Dylan
wants: on navigation the server "tells you how to update the HTML you have" and sends only the
dynamic holes that exist only on the server; client state stays where it is. It is "like React
server components" but the compiler knows where the holes are, and "it's like automatic HTMX
fine-grained down to where the changes are" (Ryan). Today: micro-frames fetch HTML from an
endpoint. **He:** no such thing is built; it is "our biggest next goal".

**8. Smaller answers.**
- **Rust rewrite.** Dylan tried the parser in Rust and it was slower because of strings crossing
  the boundary; he then rewrote it to avoid passing strings and "it was still slower"
  (2:21:43). The compiler integrates with JavaScript tools, so the hand-off would cost.
- **SPA mode.** No blessed SPA path, but a top-level render API exists and the client-only
  performance is "in the same ballpark" as Solid, Svelte 5 and Vue Vapor. They once had a
  version faster than Solid and declined it because the compiled templates were larger
  (2:30:23).
- **Context and DI.** Not yet; a `context` tag is planned for 6.1, held back because "you have to
  know when you're going to serialize it" (2:43:43).
- **Web components.** No first-class support; the hard part is server rendering them, and the
  ecosystem is the only gain (2:39:09).
- **Astro-style "force this component static".** Ryan declines it: a component that defines its
  own interactive behaviour should not have its consumer override it (2:18:06).
- **Control state with measurements.** Use a `script` and an observer; reading the DOM is the
  legitimate use of an effect (3:27:08).
- **HTMX and hypermedia.** Both speakers: they break once client state is shared across the
  swapped boundary (2:45:14, 5:15:16). Dylan's rule of thumb: "if you have to fetch something from
  the server, might as well do some rendering there"; if it can happen on the client, do it there
  (2:48:33).

**9. Ripple, briefly (3:32:06 – 3:50:06).** Ryan screen-shares Dominic Gannaway's new framework
beside a Marko counter. Both like the `component` keyword and the nested scopes. Both are wary of
`$`-prefixed variables and of `if`/`for` that look like JavaScript but compile to something else:
"I'd just be curious where the abstraction leaks". Dylan has not studied it; Ryan will have its
author on.

## After Dylan leaves (3:52:20 – 5:37:50)

Ryan's own material. Short because little of it bears on beni.

- **Solid news (3:53).** A new SolidStart team lead and a four-person team funded by Anomaly
  (makers of SST and OpenCode); SolidStart 2.0 is a move off Vinxi, ahead of Solid 2.0. Solid 2.0
  is "about two months behind" and the last client-side core feature is in progress.
- **Growth graphs (4:08 – 4:49).** Against React's curve every other framework looks flat; "the
  larger the framework is the faster it grows". Ryan's reply to an independent consultant who will
  switch "when React stops winning": that is "a mentality that will always have you a decade
  behind".
- **Transitions (4:51 – 5:02).** Follow-up to the previous stream: transitions that update the same
  state should entangle; unrelated ones should run in parallel; a reactive graph can tell which is
  which. Effects "should always be the end of the line not the middle".
- **A form with many `useState`s (5:04 – 5:28).** Derive, do not store; a getter-style `isAdmin()`
  is better than a stored boolean. Ryan's point that returns to the Marko half: forms are simple
  as DOM and simple as state, and "the combination becomes this matrix".
- **Closing (5:28).** Front-end frameworks matter less than they did: the meta-framework is the
  choice now, and under AI-written code fewer people care about the details.

## Topic index

| Topic | Times |
|---|---|
| Server first, JavaScript on the server | 0:05, 4:14, 5:13 |
| Islands, the "continent" problem | 9:03, 11:21, 16:10 |
| Granularity below the component | 17:20, 19:57, 1:50:23 |
| Compiler: cross-file analysis, caching, `evaluate`, Babel | 23:12 – 28:21 |
| Marko vs Qwik | 18:54, 1:16:42, 1:24:48, 2:32:39 |
| Bundle-size ladder | 51:15 – 1:36:07 |
| Hydration as "run these scripts"; scopes | 1:12:09 – 1:15:03 |
| Tag variables, `ref` generalised | 1:17:12 – 1:26:29 |
| Control flow as tags; idempotence | 1:27:48 – 1:33:18 |
| Hacker News demo, MPA streaming | 1:51:35 – 2:02:53 |
| In-order and out-of-order streaming | 1:57:03 – 2:00:44 |
| Serialisation cost | 2:06:50, 2:12:30, 2:51:41 |
| Server navigation, partial updates | 2:23:27 – 2:28:06 |
| SPA mode, benchmarks | 2:28:06 – 2:32:39 |
| Controlled / uncontrolled, `valueChange`, `:=` | 3:00:16 – 3:26:04 |
| Effects and state synchronisation | 3:24:57 – 3:29:23, 4:57:31 |
| Ripple | 3:32:06 – 3:50:06 |
| HTMX and hypermedia limits | 2:23:27, 2:45:14, 5:13:10 |
| Rust vs JavaScript for the compiler | 2:21:43 |

## What this means for beni

Read with [`plans/browser-decisions.md`](../../../plans/browser-decisions.md) open; the question
here is **W22** (is hydration a requirement) and the status table's row "SSR + hydration:
`Ssr.render` to a string exists; hydration not designed"
([`plans/status-2026-10.md`](../../../plans/status-2026-10.md)). Everything below is **inference**.
I did not re-measure anything; the sizes are the speakers' own readings of a playground.

**1. This is the most direct counterexample to "ship the template" that the talks have given.**
beni's `dom` lowering (CLAUDE.md, *Markup runs in a page*) clones a template and patches holes, and
`tests/oracle/` compares it with Solid's compiler. In that design the template and the hole walk
ship with the program. Marko's answer is that, for markup the server has already rendered, the
template does not ship at all; the walk to a hole ships only if something can change the hole. On
their test pages that is the whole difference (a 2.6 KB counter page; a 1.9 KB comments page
against 5 KB for the next best). It is a claim about **delivery of server-rendered pages**, and it
does not touch the CSR benchmark ordering rule 8 uses.

**2. beni's value semantics remove the part Marko calls the "final boss".** Dylan and Ryan both
name serialisation: "the hidden final boss", half of eBay's render time. Marko has to decide which
*closures'* captured values to serialise. In beni an event handler is a message (a value) and the
state is one model, so a resumable page would serialise the model and the message constructors it
can produce, with no captured scope to chase. **Inference, unmeasured:** this is why beni could
make hydration cheaper to design in than Solid's; W22's note already says it is "cheaper to design
in than to add". The cost is the other direction: Elm-style `update` is one function over the
whole model, so the *code* that would have to ship is `update`, not a handler. Marko's trick of
shipping only what a handler reaches has no direct analogue until `update` can be split by message,
which is a checker and backend question and not a UI one.

**3. Granularity of what ships follows from the language's graph, not from a keyword.** Marko's
compiler can ship less because it sees every file and every tag variable: it "looks at the whole
tree". beni already compiles whole programs with reachability elimination (`src/js/Reach.zig`,
`backend.md` §9). The distance from there to "which part of `view` is reachable from a message the
browser can send" is real but is not a new kind of analysis. Worth a design note when W22 is
opened, not before.

**4. A syntax lesson that matches beni's own rule against special names.** Ryan's praise of Marko
is that no attribute is special and that a user-defined `if` is as capable as the built-in one. For
beni, where a platform package declares the element and attribute vocabulary and the compiler knows
none of it (rule 8, rule 6), the same point is a **test**: can a user module define a `Show`-like
function with the same call syntax as the platform's? Marko's `ref` generalisation is a reminder
that `ref` is the first item on beni's *later* list (status table) and is the place a special
attribute is likeliest to creep in.

**5. Controlled versus uncontrolled has a beni-shaped answer already.** In TEA the model owns
every input's value, so "controlled" is the only mode and uncontrolled forms are the thing that
needs designing. The Marko convention (a `valueChange` handler means "I own it") is what a
beni `input` would need if an uncontrolled mode were ever wanted, and the cursor-position
handling they mention is a real runtime cost of controlled inputs that `tests/corpus/browser/`
may not cover. **Open question, not a recommendation:** does the `dom` runtime preserve the cursor
when a message rewrites an input's value (uppercasing, masks)? Dylan's credit-card mask example is
a ready test.

**6. Two facts for the record.** (a) A Rust parser was slower than a JavaScript one for Marko
because of the boundary crossing. beni's compiler is Zig and its output is JavaScript text, so it
does not cross that boundary; the lesson is for any future in-process JavaScript tooling. (b) Marko
passed on a Solid-beating template layout because it made compiled templates bigger. That is the
same trade rule 8 weighs between per-operation speed and bytes, taken the other way by a team
whose product is bytes.

**7. What the talk does not give.** No Marko timing, no benchmark methodology, no error-handling
story, and nothing on typing: Marko 6's type checking is mentioned once ("we're not seeing
TypeScript here in this playground"). Everything about bundle size is read off a playground
display on a stream. The second half of the stream is commentary on the React ecosystem and
carries no design evidence.

## Corrections and caveats

- The paste has no date or speaker list; the date and the year in the directory name are inferred
  from what is said (see the header of `transcript.md`). Replace them when the stream's date is
  known.
- Auto-caption errors seen while reading: "Marco" for Marko throughout (fixed), "quick" for Qwik
  (fixed), "spelt" for Svelte (fixed), "Vinci" for Vinxi, "DNO" for Deno, "Misco" for Miško, "view
  transitions" and "ID potency" for idempotence. Two long runs around 3:19–3:21 and 5:02 are
  garbled.
- Chapter 17 of the paste ("Concurrency and closing") covers the whole second half of the stream,
  from Marko Q&A to the final goodbye; the titles are the paste's own.
