# Front-End's Existential Crisis — organised notes

**Ryan Carniato** (author of SolidJS) · 2024-01-26 · 5 h 16 m ·
[video](https://www.youtube.com/watch?v=aA7Xeh7WG4E) · full text in
[`transcript.md`](transcript.md) · source paste in [`raw.txt`](raw.txt)

A live stream, not a conference talk: about 3 h 20 m of prepared argument drawn on a timeline and
answered against live chat, then a SolidStart release retrospective and a news segment. Everything
below is sourced to a moment in the video. **The transcript is automatic captioning — quote the
video, never this file.** Where a reading of mine goes beyond what he said, it is marked
*(inference)*.

---

## The thesis

Thirty years of the web read as a pendulum between a **single mental model** and a **split one** —
static web (one model) → dynamic backend (one model, on the server) → the AJAX/jQuery "dark ages"
(split, with state serialised both ways) → JS frameworks (one model, in the browser, paid for in
JavaScript) → SSR from 2016 (split again, with no clean seam). Every swing is marked by the same two
things: a **declarative system replacing an imperative one**, and a **change in where routing lives**
(static → server → client).

The field is now stuck at the top of that swing, because the properties that made the client model
good — one model, total control, granular updates — are exactly the ones that make it expensive. He
decomposes the bill as **hydration = code size + execution + serialisation**, and argues no shipped
approach (islands, React Server Components, resumability/Qwik, htmx) clears all three; the immovable
requirement underneath is **persistence of client state**, which is why client-side routing exists.
His conclusion is deliberately not a solution: the field **does not know which of the three costs
dominates** and should go back to benchmarking to find out — and meanwhile it is trading
**simplicity for easiness** by piling on abstraction, which is the one trade that cannot be undone.

---

## Chapter by chapter

### 1. Starting Soon…
No captions — the stream had not begun.

### 2. Preamble — [3:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=180s)
- Frames the stream as a deliberate zoom-out after two long arcs: interviewing meta-framework
  authors, then a year on partial hydration and React Server Components.
- Says the pieces are finally in place to draw a conclusion; worries he has been "nerd-sniped" into
  detail and lost the big picture.
- Two questions from recent streams set the agenda: *why can't I just ship a CSR SPA?* and *why
  can't I just use Rails or htmx?*
- The framing claim: front-end technology is better than it has ever been, but **expectations have
  outgrown the platform faster than the platform improves**.

### 3. Frontend vs. Backend & Too Much Change? — [11:31](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=691s)
- The front/back split is now wide enough that the two sides cannot describe the problem to each
  other in the same words; he names Alex Russell as the voice that does care about the front end
  from outside it.
- "Too much change" is a real complaint, but asking *why* the web churns is the better question than
  demanding it stop.
- The demand for stability is itself the main reason React is dominant — and you cannot have both
  stability and progress.
- On consolidating effort into one framework: the counterexample is that consolidation would have
  cost the industry signals.

> "The idea is we should all just work on making React better. Of course, if we did that, we
> wouldn't have signals now, would we?"
> — [20:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=1209s)

### 4. 1993–1997: The Static Web — [20:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=1233s)
- Live-demos building a 1995 page in a text editor — and the demo fails, because modern TextEdit
  encodes the HTML and uses smart quotes. The failure is the point: the tools have moved.
- The era's properties: file-system routing, view-source as the whole program, edit-save-refresh with
  no build step, FTP as deployment.
- There was no front/back split because there was no back end: form posts went to `mailto:`.
- Credits Steve Sanderson's "Why Web Tech Is Like This" as the inspiration and the more detailed
  account.

> "The whole app basically existed on this page. In a sense, everyone was a front-end developer."
> — [33:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2004s)

### 5. 1997–2005: Dynamic Web & AJAX — [38:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2295s)
- ASP and PHP replace "a Perl script that rewrites an HTML file" with templates rendered per request;
  one file serves a thousand pages.
- Flash and Java applets exist because the web could not build applications; JavaScript was "dirt
  slow" and treated as a toy.
- 2005's AJAX is the hinge: partial updates without a full page reload. He notes this is exactly the
  shape htmx would later formalise.
- The mental model remained split — app and server "were pretty far apart".

> "Before 2005 you couldn't do asynchronous requests from the client. You essentially loaded a page
> and then you were stuck with it until you went back to the server and reloaded the whole page."
> — [41:27](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2487s)

### 6. 2005–2010: Split-Model Thinking — [47:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2835s)
- He calls this period the **dark ages**, and the diagnosis is ownership of state: the client owns
  some, the stateful server owns the rest, and neither can be authoritative.
- The cost is serialisation in both directions plus duplicated logic in JavaScript and on the server.
- Meanwhile JS engines get ~50× faster between 2006 and 2009 — a jump he compares to, and says
  dwarfs, Moore's-law era hardware doubling.
- The iPhone (2007) sets the expectation the web then has to meet; browser vendors push hard so the
  web does not lose to mobile.
- Praises htmx for being **innately stateless**, which is precisely what the technologies of this era
  were not.

> "It got really, really nasty, because — who owns the state?"
> — [49:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2964s)

### 7. 2010–2016: JS Frameworks & Client-Side Routing — [57:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=3471s)
- Knockout and Angular feel like the web again: a single model, fast feedback, back to "text file,
  save" after a decade of minute-long builds.
- At a high level the framework choice barely matters — the era's real change is the **third routing
  paradigm**: static, then server, then client.
- Client routing is also where the drift from web standards begins, because the browser could not do
  what was being asked of it.
- Companies bet on JavaScript for the *web tier* specifically (Marko at eBay, 2012–13; PayPal), to
  hire one skill set rather than to replace their back ends.
- Notes the macro coincidence: microservices and the move off monolithic stateful servers happen in
  the same window.

> "Whether you pick Angular or React or Vue or whatever, they're all kind of just doing the same
> thing fundamentally."
> — [1:05:10](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=3910s)

### 8. 2016–????: SSR — [1:14:34](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4474s)
- Big companies adopt React 2015–16 on two-to-three-year migrations; by 2018 some conclude it was a
  mistake. Netflix keeps React for SSR and sprinkles JS on the client; Amazon largely never moves.
- The aside that carries the chapter: **SSR does not shrink the bundle** — it usually grows it, and
  adds a serialised copy of the data, so you see the page sooner but interact no sooner.
- Google's 2017-era PWA/offline-first pitch vanishes from its own conferences by 2018–19, replaced by
  Next.js; Core Web Vitals (2020) then accelerates the server turn.
- An irony he keeps returning to: the markets with the worst connectivity often prefer offline-first
  mini-apps, not the page-load metric the industry optimises.
- Rejects stack-mixing (SSR + Alpine + htmx) as solving nothing structural — and notes Alpine is one
  of the slowest and largest client runtimes for the job it does.

> "SSR does not actually reduce the size of your JavaScript bundle — it makes it probably larger …
> although you see the page sooner, it doesn't become interactive any sooner."
> — [1:27:21](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5241s)

> "SSR isn't a significant improvement over CSR — I think, is the problem."
> — [1:32:32](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5552s)

### 9. The Dark Ages & Abstraction — [1:34:34](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5674s)
- Claims we are in, or entering, a second dark age: in 2005–10 the technologies at least had clear
  responsibilities; today "there's no clear responsibility" because everything was merged.
- The merge was not a mistake — it was **boundary alignment** — but boundaries need realigning now.
- Reads the interest in htmx, Astro and signals as one phenomenon: an appetite for things that **do
  less**.
- On components: his long-standing position is that they are a **developer-facing** abstraction, and
  the runtime should not be organised around them.
- Endorses a chat aphorism about abstraction being a symptom, not a cure.

> "Signals … we've boiled all of the modern front-end web development now to a simple primitive that
> just updates. That's why people are stoked on Solid."
> — [1:37:35](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5855s)

> "Components are a useful abstraction for the developer, but not useful from the runtime."
> — [1:39:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5992s)

> "You can always add another abstraction, but it's almost impossible to take one away. You can
> always make something easier to do, but you can't make it simpler."
> — [1:41:07](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6067s)

### 10. Hydration & State Boundaries — [1:44:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6255s)
- States the era's goal plainly: **solve hydration**, and the single-model client architecture needs
  no compromise at all.
- The decomposition the rest of the talk runs on — hydration costs **code size** (bandwidth and
  parse), **execution** on load, and **serialisation**, paid on both sides.
- No solution has completely solved it, in his opinion, a year after he wrote an article trying.
- "There are always two sources of truth; every website starts from the server" — the models differ
  only in which side is the proxy of the other. He sketches three: SPA-with-server-proxy,
  even-keeled split, and server-first with a thin client (Phoenix LiveView).

> "What is hydration? It's code size … it's execution cost … and it's a serialization cost that you
> also pay on both sides."
> — [1:47:38](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6458s)

> "There is always two sources of truth. Every website starts from the server."
> — [1:49:20](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6560s)

### 11. The Trade-Offs of Resumability — [1:53:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6797s)
- Why resumability still counts as hydration: jQuery was **not declarative**, so it inspected the DOM
  and needed no agreement about state. Any declarative framework, Qwik included, requires the
  client's state to match the server's.
- Maps the three costs onto the solutions: resumability is an absolute answer to **execution** and
  none at all to **code size**; islands and RSCs are partial on both; Qwik adds progressive
  lazy-loading as a separate mechanism.
- Islands genuinely solve the **double-data** problem (no data for what never hydrates); RSCs could
  in theory but do not, serialising both HTML and a JSON payload.
- The structural limit on static analysis: if the point of change is at the top of the app — a
  client-side router — the analysis cannot prove a piece of code or data will never be needed.
- Islands come closest to all three boxes, but islands plus client-side routing is not RSCs, and the
  gap is real.

> "No solution actually solves all three of these cleanly. There's always some kind of trade-off."
> — [2:00:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7252s)

### 12. Unified Client/Server Data Model — [2:02:34](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7354s)
- Sketches the theoretical best: explicit client/server boundaries for code size, resumable islands
  for execution, and something smarter than today's RSCs for data.
- The blocker he keeps hitting: on the server, rendering is top-down and a request-lifetime affair,
  so any invalidation refetches everything unless you add server-side caches.
- Contrasts the two data models directly — client data persists across navigation and can update
  granularly; server-component data lasts the request and is never granular.
- Restates the immovable requirement: **we want to persist state.** That is why AJAX happened; it is
  why getting rid of client-side routing is not on the table.

> "We want to persist state. That's the whole point."
> — [2:05:50](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7550s)

### 13. Is This Worth The Added Complexity? — [2:09:03](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7743s)
- Describes his own design (in Solid) for a unified client/server data API: key-based invalidation,
  single-flight mutations, streaming — "kind of everything you want", with one catch.
- The catch: granular data has to live on the client, so the frequently-updating parts forfeit the
  hydration benefit; over time everything migrates back to the client anyway.
- Therefore the server-component model is really **two models side by side**, and the split shows up
  in view rendering as well as data.
- The question he leaves standing: *are server components an optimisation rather than a DX
  improvement?* If a model does not make the code simpler and only makes the page faster, other
  optimisations may be cheaper.
- His DX/UX priority ordering: DX matters because it makes good UX the default — "the pit of
  success" — and DX that does not reach UX ranks low.

> "At that point, are server components just an optimization, not a DX improvement?"
> — [2:14:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8040s)

> "I care about DX as far as you producing good UX."
> — [2:14:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8049s)

> "The things that make client-side rendering the best are the same things that are hurting it."
> — [2:17:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8220s)

### 14. Q&A: Back to Basics? Performance? Elm? — [2:19:50](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8390s)
- Waterfalls, not update performance, are where most real page-load pain lives; this is why Remix
  pushed loaders so hard.
- Solid's CSR beat SSR frameworks on Lighthouse for a long time purely because those frameworks
  were not streaming and were waterfall-shaped.
- His benchmarking method, stated explicitly: take an existing benchmark, write the best **vanilla
  JS** implementation you can — not to prove vanilla is faster, but to model what an optimal
  framework would emit — and measure against that. He wants the same thing done for hydration.
- Admits the three-cost list is a hypothesis: he cannot say to what degree each one matters, and
  "we're all speculating".
- **Elm**, asked by chat: strong, structured, ahead of its time on concepts and compilation, much
  harder to write errors in — but he flags it as *primarily client-side*, which he counts against it.

> "This is how I describe Elm: Elm is a really strong structured language … ahead of its time in
> terms of concepts, language, compilation … it's a lot harder to write errors in."
> — [2:25:57](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8757s)

### 15. Q&A: DX? Local-First? React Crisis? — [2:26:37](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8797s)
- Ranks the client/server boundary by sharpness: Astro's file-format split is the hardest, `use
  client`/`use server` is fuzzier, Marko and Qwik make any code either — and the question becomes
  only "is it serialisable?".
- Suspects that being made to *see* the boundary is itself the problem: if you never had to think
  about it, fuzziness would not matter.
- Local-first is consistent, but does not answer the e-commerce middle ground that Core Web Vitals
  put pressure on.
- **The crisis is not React's.** All SPA-style rendering has the same Lighthouse problem — faster
  frameworks like Solid win a few points and no more.
- Adoption is the real constraint on the solutions that do work: people balk at resumability's
  syntax, and signals are a hard sell.

> "All single-page-app-style rendering — not even React, faster ones like Solid — sure, we win a few
> points, but fundamentally have the same problems."
> — [2:30:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9009s)

### 16. Q&A: WebSockets? We Don't Know! — [2:33:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9204s)
- Serverless infrastructure, not merit, is what killed stateful servers: "maybe we'd all be on
  Phoenix LiveView by now" otherwise.
- His prior: the closer interaction processing is to the client, the better the experience —
  server-first can never be completely right for the user.
- The requirement that rules out going back: persistence of client state. HTML-partial approaches do
  not have an answer for it.
- Prefers RSCs to progressive hydration if forced to choose, because the bigger mental shift in Qwik
  is the progressive lazy-loading, not resumability.
- The honest admission that names the chapter: **we do not know which cost dominates**, and the
  answer changes which solutions look like a waste.

> "We don't actually know what the most expensive part of the equation is. We're just guessing and
> trying different things."
> — [2:37:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9420s)

### 17. Q&A: Signals? React? JS Paradox? Jobs? — [2:39:21](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9561s)
- Signals are not RxJS: every framework author agrees signals do what they want, and even React's
  team agrees on the *result* while disagreeing on the mechanism.
- The historical analogy: React's virtual DOM in 2014 became a gravity well every framework
  reimplemented. Signals are that well now.
- The paradox he enjoys: if you want less JavaScript, the best way is to use a JavaScript framework.
- On why Solid has fewer jobs: it is not a technology question and not a "meta" question — the
  ecosystem wants to feel mature, and nothing he can build addresses that.

> "Every framework is picking it up — there's something legit here. Just because the biggest player
> isn't playing along doesn't mean it's not as big a pull."
> — [2:40:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9658s)

### 18. Q&A: State Mismatch? Tooling? WASM? — [2:44:22](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9862s)
- The clearest statement in the talk on where state should live: pulling state fully out of the tree
  is MVC, and MVC was abandoned for a reason. **"MVC in stateless is lovely; MVC in stateful is a
  disaster."**
- What he wants instead: state in regions *tied to* the tree but not one-for-one with it — which is
  why he likes signals.
- RSCs try the same separation by making two trees; the duplication is the cost.
- Ephemeral UI state is permanent and unavoidable: stateful servers only move the problem, and bring
  persistent-connection trade-offs.
- On WASM: it lets other languages render on the server, but that is an optimisation. The problem is
  architectural, so WASM does not change the math.

> "MVC in stateless is lovely; MVC in stateful is a disaster. … I like things like signals because
> you can kind of live in the tree but not be owned by the tree one for one."
> — [2:44:54](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9894s)

> "There's always UI state, there's always temporary, ephemeral state related to how the end user
> works, and we need a way of persisting that."
> — [2:46:53](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10013s)

### 19. Gift Sub Bonanza!! — [2:57:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10620s)
- Mostly thanking subscribers; two substantive asides.
- Wonders aloud whether code size is really the top cost: "if you load the code but you don't execute
  it… does anyone hear it?"
- On the "best-in-class composition" idea: combine resumable islands for execution cost with RSC-like
  boundaries for serialisation cost and it might be good enough.
- Notes that **every** framework is now pulling state management into the framework — React through
  hooks and concurrent mode, Angular and the rest through signals — because knowing the state
  mechanism is what lets the framework optimise updates.

### 20. Q&A: Caching? MST? Space Jam? SWs? — [3:05:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11133s)
- Caching as architecture is his last resort, and the aggressive default caching in Next.js is his
  biggest single objection to the RSC model.
- His background explains the bias: social media and eBay — sites where almost nothing is cacheable
  because everything is personalised and write-heavy.
- Wants MobX-State-Tree-class state management built on signals; observes nobody has done it.
- Client and server caches live in different places but can share one key system and one API, because
  invalidation only has to go as deep as you care about.
- Visits the 1996 Space Jam site to show tables inside tables, inconsistent tag case, and — to his
  credit — `alt` text.

> "I want the architecture to be sound before I optimize it with caching. … This is probably my
> biggest resistance to RSCs — they almost tell you you have to cache."
> — [3:05:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11158s)

### 21. Conclusion: Finding What's Important — [3:18:05](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11885s)
- The load-bearing claim about architecture: **a diff-based framework drives you into caches**,
  because it is memoisation — running code you did not need to run, since it is not granular.
- States plainly that he does **not** have a solution, and that the back-end world has not solved this
  either: "they haven't moved an inch in over a decade."
- His recommendation is temperamental rather than technical: the front end should accept its nature,
  expect incremental improvement, and stop fighting itself. He suspects his own expectations were too
  high.
- When stuck like this, the move is to drop one constraint or assumption and rethink — and for him
  personally, the next step is to find out **through benchmarks** what actually matters.
- Rejects "just go back end" as putting your head under a pillow. Different solutions are allowed;
  React cannot follow everywhere (resumability needs something signal-like).
- Last wish: more work on granular invalidation — notes TanStack Query's keys are "basically signals",
  a dependency graph triggered by hand.

> "If you … have a diff-based framework you're going to find yourself relying on caches more … it's
> like relying on memoization: you're going to be running code that you don't need to run, because
> it's not granular."
> — [3:19:20](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11960s)

> "I think front end needs to accept its flaws, needs to understand its true nature."
> — [3:21:18](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12078s)

> "Usually when we're in these kind of stuck tough places we have to just back off on one of our
> constraints or assumptions and rethink the problem."
> — [3:27:42](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12462s)

### 22. One Month of SolidStart Beta 2 — [3:34:30](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12870s)
- Calls SolidStart an **anti-meta-framework**: keep it low-level, ship as little opinion as possible;
  it is "basically a client-rendered app in 5 kB of JavaScript" with an SSR switch, router-agnostic,
  with file-system routing as a convention that feeds a configuration you can always reach.
- Vinxi (over Nitro and H3) is the core, and the thing he is excited about: it lets a framework
  *declare* its conventions instead of inheriting someone else's.
- Why "bling" (the earlier compiler approach) died: hoisting server functions needs a compiler, but
  code splitting needs a bundler — and it was a bundling problem all along.

### 23. OMoSSB2: Streaming & API Routes — [3:44:05](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=13445s)
- Beta 2 made streaming the default; it is shaking out real hydration bugs, with `ssr: "async"` as
  the escape hatch.
- Aligning on React's `use server` / `use client` directives was an ecosystem decision, not a design
  preference — the bundler support follows React.
- API routes will split out of page routes: because the page router is configurable at runtime, the
  server cannot know the page routes in time to order them against API routes.
- The meta-framework field is serverless-shaped because serverless is the lowest common deployment
  denominator — which he admits may be Vercel/Netlify/Cloudflare bias.

### 24. OMoSSB2: Base Path Fiasco & `a` vs. `A` — [3:53:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=13995s)
- Reverses an earlier decision: pushing everyone to lowercase `<a>` broke base-path support, because
  a base path can only be applied by the framework's own `<A>` component.
- The deeper demonstration: an `<a>` inside `<svg>` is a *different element* from an HTML anchor, and
  a template compiler splitting templates at a `<Show>` boundary loses the namespace context.
- `<rect>` works because it is unambiguously SVG; `<a>` is one of about four elements that could be
  either, so the compiler must guess, and a component hoisted out of the template cannot know at all.
- The general statement, and the most transferable moment of the SolidStart segment: **compilers can
  only analyse within a scope**, so a purely analysis-based approach can always be broken; the runtime
  alternative costs every app, including the ones with no SVG.
- Explicitly notes this is not Solid-specific — Svelte analyses the template and does not solve it
  either; React can, because it builds the whole tree and processes it in one go.

> "Compilers have limits on the scope of which they can analyze, so it's always possible to find a
> way to break a compiler if you depend on scope analysis purely."
> — [4:02:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14544s)

> "There is basically no way that capital `A` could know whether it's used in XML or SVG or not."
> — [4:00:40](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14440s)

### 25. OMoSSB2: To Wrap or Not to Wrap? — [4:04:37](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14677s)
- The governing question for a framework sitting on someone else's stack: **who owns the
  specification?** Whoever diverged from the base gets the nod.
- Concretely: `app.config.ts` is Vite config that is not quite Vite config, and `start.server` is
  Nitro config that is not quite Nitro config — leaky in both directions.
- Solid needs its own request event rather than H3's so libraries can be server-agnostic, but then
  every boundary crossing has to translate. `AsyncLocalStorage` would remove the problem; it is not
  universally available, so a wrapper is the pragmatic answer.

### 26. OMoSSB2: Conclusion & New Experiments — [4:16:02](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=15362s)
- Decides to follow Vinxi rather than Nitro and to document to Vinxi's surface — which puts a lot of
  weight on one maintainer. Notes SolidStart's own public surface is about a dozen exports, which he
  treats as a success condition.
- Demos cacheable server functions: a server function wrapped so it issues a `GET`, with a
  `Cache-Control` header, returning a streamed self-resolving promise — "throwing a promise over the
  wire", cached by the plain HTTP browser cache with no framework cache involved.
- Fixes the typing so `redirect`/`reload`/`json` return `never` and no longer pollute an action's
  return type.

### 27. This Week in JavaScript: Data Loading — [4:33:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16413s)
- His summary of the RSC data model: it is as if a page had a single GET endpoint — every mutation
  grabs everything, and write-heavy or independently-updating workloads struggle.
- You can still use client data patterns alongside SSR, but then you are solving waterfalls again.
- A genuine open problem he raises with Tanner Linsley: when props can update from the server *and*
  a client cache can invalidate, which source wins on revalidation is unclear.
- The personal crisis in one sentence: adding server components left him with his old client app plus
  a server app — "this is more, not less".

> "Now I just have my old React app beside my server component app. … This is more, not less. Did I
> actually simplify anything? Not really."
> — [4:37:22](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16642s)

### 28. TWiJ: Is Solid 10x Better? — [4:38:18](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16698s)
- Rejects the "10× better to justify switching" framing outright: **nothing is ever 10× better**, and
  React was not 10× better than AngularJS.
- The joke underneath: Solid *has* been 10× on individual metrics (SSR throughput, bundle size) at
  various times, and it changed nothing about adoption.
- What he will claim: Solid is one of the points the ecosystem warped around, as React was in 2014 —
  "people aren't just adopting signals, they're adopting Solid's rendering patterns".
- Also: you do not get into the conversation at all unless you are arguably better on several axes.

> "Nothing is ever 10 times better. React wasn't 10 times better than AngularJS. It can be better
> across multiple metrics, but nothing is ever 10 times better."
> — [4:39:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16755s)

### 29. TWiJ: Next.js vs. Rails — [4:44:48](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17088s)
- Reads a Reddit post from a founder who moved from Next.js to Rails and found it dramatically
  easier to ship an MVP. Agrees it is a legitimate fit and that Rails is not dead — and notes the
  symmetry: plenty of people feel about Rails what this person feels about React.
- His counter-anecdote: a 2010 Rails social-media startup moved to full JavaScript because Rails was
  fine at page rendering and "dreadfully slow" at the interactive parts.
- The meta-point: the person felt he had no choice, which is the actual failure.

### 30. TWiJ: Solid News — [4:53:04](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17584s)
- Granular (sub-component) HMR lands in `solid-refresh` 7: swap sections of code without unmounting
  the component. It is possible for an architectural reason — **because Solid does not diff,
  components have no instances**, so code can be replaced beneath them.
- Caveat he states himself: Solid still cannot preserve state above or below the change.

### 31. TWiJ: The Balance of Complexity — [4:55:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17733s)
- The framework that closes the stream, built on Rich Hickey's simple-vs-easy and extended with a
  second axis.
- **Simple vs complex** = how predictable the system is from its parts. If it decomposes into bounded
  pieces that each do one thing, it is simple; complexity is emergent behaviour you cannot see by
  looking at the parts.
- **Easy vs complicated** = how much effort the task takes. The two axes are independent, and often
  anti-correlated: a simple system tends to be complicated in practice, an easy one tends to be
  complex underneath.
- **Redux is his worked example of "too simple"**: `data = function of previous data` is about as
  simple as anything gets, and precisely because of that it does not map onto the real problem, so
  you layer things on top until the result is complicated.
- Abstraction converts complicated into easy while making the system more complex — and the direction
  is one-way. Complexity's only real cure is burning it down and starting over.
- Credits React's longevity to having been **simple, not easy**, and worries the field's current
  trajectory (accepting complexity, then reaching for easiness) is a feedback loop.
- The practical rule: **err on the side of simplicity** — someone will make a too-complicated thing
  easier, but nobody will make a too-complex thing simpler for you.
- In the closing chat he reads and agrees with: *"Elm should bring back signals — they were early."*

> "The simpler the system is, the more complicated it ends up being in practice; and often the easier
> a system is, the more complex it actually is under the hood."
> — [5:01:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18071s)

> "Sometimes when a system is too simple it leaves too much open, and the gap between it and where
> you want to achieve is too far, and it forces you into complicated solutions."
> — [5:02:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18137s)

> "Err on the side of simplicity … if it's a little bit too complicated, someone will figure out how
> to make it easier. If you err on the side of easiness, no one is ever going to make it less complex
> for you."
> — [5:05:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18311s)

### 32. The Future of These Streams — [5:10:07](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18607s)
- Says he has run out of new architectures to explore: view transitions, blocks, resumability have
  all been covered, and nothing new is jumping out.
- Therefore the next arc is measurement: "the only way we know where we're going to go is
  benchmarks."
- Flags Solid 2.0 work starting, and an article on lazy vs eager.

---

## Topic index

| Topic | Where |
|---|---|
| **Timeline / eras** | static web [20:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=1233s) · dynamic backend [38:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2295s) · split model [47:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2835s) · JS frameworks [57:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=3471s) · SSR [1:14:34](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4474s) |
| **Hydration — the three costs** | [1:47:38](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6458s) · [1:48:16](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6496s) · applied to each solution [1:55:56](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6956s) · "we don't know which dominates" [2:37:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9420s) |
| **SSR vs CSR** | [1:27:21](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5241s) · [1:27:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5272s) · [1:32:32](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5552s) |
| **Resumability / Qwik** | [1:53:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6797s) · [1:54:36](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6876s) · [1:57:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7031s) · [2:35:30](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9330s) · [2:53:40](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10420s) |
| **React Server Components** | [1:47:38](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6458s) · [1:57:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7031s) · [2:02:34](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7354s) · [2:09:03](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7743s) · [2:44:54](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9894s) · [4:33:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16413s) |
| **Islands** | [1:55:56](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6956s) · [1:57:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7031s) · [2:01:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7269s) · [3:00:02](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10802s) |
| **Signals / fine-grained reactivity** | [1:37:35](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5855s) · [2:39:21](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9561s) · [2:40:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9658s) · [2:44:54](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9894s) · [3:04:03](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11043s) · [5:09:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18591s) |
| **Virtual DOM** | [1:05:10](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=3910s) · [1:37:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5871s) · [2:40:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9658s) · [4:00:40](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14440s) |
| **Diffing vs granularity (and caches)** | [3:19:20](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11960s) · [4:53:22](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17602s) |
| **Compilers and their limits** | [3:31:50](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12710s) · [3:55:26](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14126s) · [4:00:40](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14440s) · [4:02:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14544s) · [4:03:39](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14619s) · [3:43:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=13404s) (compiler vs bundler) |
| **Components as an abstraction** | [1:38:23](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5903s) · [1:39:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5992s) |
| **Local vs global state, MVC, state in the tree** | [2:44:54](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9894s) · [2:46:53](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10013s) · [3:04:03](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11043s) · [3:09:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11373s) (MST on signals) |
| **Redux / unidirectional flow** | [3:09:33](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11373s) · [5:01:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18071s) |
| **Persistence of client state** | [2:05:50](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7550s) · [2:34:48](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9288s) · [2:46:53](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10013s) |
| **SPAs vs MPAs, client-side routing** | [1:08:21](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4101s) · [1:09:43](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4183s) · [1:59:48](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7188s) · [2:15:37](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8137s) · [2:34:48](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9288s) |
| **htmx** | [7:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=420s) · [46:04](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=2764s) · [51:12](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=3072s) · [1:44:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6255s) |
| **Astro, Marko, Wiz, Alpine** | [1:17:16](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4636s) · [1:30:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5424s) · [1:37:35](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5855s) · [2:26:37](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8797s) |
| **Phoenix LiveView / stateful servers** | [1:51:48](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6708s) · [2:33:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9204s) · [2:46:53](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10013s) |
| **Complexity vs simplicity, easy vs complicated** | [1:41:07](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6067s) · [4:59:30](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17970s) · [5:01:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18071s) · [5:02:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18137s) · [5:05:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18311s) |
| **Elm** | [2:25:57](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8757s) (his assessment) · [5:09:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18591s) ("Elm should bring back signals") |
| **Benchmarks and method** | [2:22:28](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8548s) · [2:23:46](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8626s) · [3:27:26](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12446s) · [5:11:06](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18666s) |
| **Caching** | [3:05:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11158s) · [3:14:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11657s) · [3:18:05](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11885s) · [4:23:46](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=15826s) |
| **WASM** | [1:21:22](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=4882s) · [2:49:40](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10180s) · [2:55:38](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10538s) · [3:31:50](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=12710s) |
| **Local-first / offline-first / PWAs** | [1:25:16](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5116s) · [1:23:57](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5037s) · [2:28:47](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8927s) · [2:51:01](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10261s) |
| **Adoption, jobs, "10× better"** | [2:30:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9009s) · [2:43:04](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9784s) · [4:39:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16755s) |
| **Solid 2.0** | [5:13:57](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18837s) |
| **AI / LLMs** | **never mentioned** — zero occurrences in 5 h 16 m |

---

## What this means for beni

Ids are from [`plans/browser-decisions.md`](../../../plans/browser-decisions.md). For each item:
what *he* claims, where, whether it supports or challenges beni's current recommendation, and what
if anything it suggests beni should look into. Where I am reasoning past his words I say so.

### 1. Components are a developer abstraction, not a runtime one — **supports W25 / W20**

**His claim** ([1:39:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5992s)): "Components are a
useful abstraction for the developer, but not useful from the runtime." He expands it at
[1:38:23](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5903s): the component model has properties
worth keeping, but taking it whole is over-correction.

**Reading.** This is the author of the framework beni benchmarks against agreeing with beni's split:
TEA is blessed (**W25**), a component/local-state library is unshipped but not forbidden (**W20**),
and the runtime is organised around something other than components. It also supports **W26**: if
components are not a runtime concept, nothing about the rendering strategy owes them instance
identity.

**Research:** none required. Worth quoting in W20 as outside corroboration that "no components in the
runtime" is not an Elm eccentricity.

### 2. "MVC in stateful is a disaster" and ephemeral UI state never goes away — **challenges beni's no-local-state position**

**His claim** ([2:44:54](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9894s)): pulling state fully
out of the tree *is* MVC, and "we know there's a reason we got away from model-view-controller —
too simple of a model. … MVC in stateless is lovely; MVC in stateful is a disaster." What he wants is
state in regions **tied to the tree but not one-for-one with it**, which is his stated reason for
liking signals. And ([2:46:53](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=10013s)) "there's always
UI state, there's always temporary, ephemeral state related to how the end user works, and we need a
way of persisting that."

**This is the strongest challenge in the talk to beni's direction, and it should not be softened.**
beni's model is one cell, updated by a pure `update` — structurally the thing he calls "too simple a
model" for stateful UI. He is not arguing from ignorance of the alternative: he ran a stateful MVC
codebase for years and is describing why the industry left.

**Where beni has an answer** *(inference)*: beni is not MVC. MVC's failure was two mutable models
kept in sync by a controller; TEA has one model and no synchronisation. Elm's counter-argument —
that ephemeral state is simply *in* the model, and that this is what makes time travel possible —
is not addressed anywhere in the talk, because nobody asked.

**Research.** (a) **W24** (child-owned state) and **W39** (wide model records) are where this lands:
if every dropdown's open/closed flag lives in one `Model` record, what does a 40-field model cost,
and does a nested sub-record shape actually pay for itself? W39 already flags the 17→18-field V8
clone cliff and says the measurement has not been taken. (b) Write down, in the sheet, the answer to
"where does ephemeral UI state live?" — it is currently implied rather than stated, and it is the
first question a Solid user will ask.

### 3. Redux is "too simple", and too-simple systems push complication into user code — **challenges W25's framing, supports rule 7**

**His claim** ([5:01:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18071s) →
[5:02:17](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18137s)): Redux is `data = function of previous
data` — "there is almost nothing simpler in the world" — and *that is the problem*: "sometimes when a
system is too simple it leaves too much open, and the gap between it and where you want to achieve is
too far, and it forces you into complicated solutions."

**Reading.** beni's `update : Msg, Model -> Model` is exactly that shape, so the criticism transfers
directly. He is not saying it is wrong — his closing rule is *"err on the side of simplicity"*
([5:05:11](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18311s)), which is CLAUDE.md rule 7 stated by
someone else — but he is saying the bill arrives as boilerplate in application code, and that it is
the framework's job to close the gap.

**Research.** Treat this as a checklist against what beni ships *around* the kernel: keyed lists
(**W33**), an indexable sequence (**W35**), subscriptions (**W6**), the `send`-shaped command
(**W25**), a `TestStore` (**W16**). Every one of those is beni closing a "too simple" gap. It would
be worth recording, once, which known Redux-era pain points beni's core answers and which it leaves
to a library — that is the honest version of the rule-7 check.

### 4. A diff-based framework drives you into caches — **challenges W26, and W27 is the answer**

**His claim** ([3:19:20](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11960s)): "If you … have a
diff-based framework you're going to find yourself relying on caches more … it's like relying on
memoization: you're going to be running code that you don't need to run, because it's not granular."
Related, at [4:53:22](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=17602s): sub-component HMR is
possible in Solid *because* Solid does not diff, so components have no instances.

**Reading** *(inference beyond his words)*: his target is a virtual DOM, where "not granular" means
re-running `view` for a whole subtree and comparing trees. beni's **W26** is not that: a compiled
template with one `===` per hole re-runs nothing it does not need, and the "cache" he warns about is
replaced by **W27**'s identity promise — an untouched field of an updated record is the *same
object*, so the reference check is exact rather than heuristic. On his own axis, beni's design is
granular. But the warning is real for the part of beni that *is* a diff: whatever **W29** settles on
as the fallback.

**Research.** (a) W29's cost question — "what fraction of an idiomatic beni view falls back at all"
— is the same question he is asking, and his framing gives it a sharper exit criterion: *does the
fallback ever make the programmer reach for memoisation?* If it does, the fallback is wrong. (b)
Note that beni's templates **do** keep per-instance records (R29's `{el, row, sel, idT, lbT}`), so
Solid's granular-HMR trick is not automatically available to beni — relevant if M4/M5 ever wants hot
reload.

### 5. Compilers can only analyse within a scope — **supports W29 being the real open question**

**His claim** ([4:02:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=14544s)): "Compilers have
limits on the scope of which they can analyze, so it's always possible to find a way to break a
compiler if you depend on scope analysis purely." The worked example is an `<a>` inside `<svg>`: the
element is created before it knows its parent, a `<Show>` splits the template and loses the
namespace, and a component hoisted out of the template "could never know whether it's used in XML or
SVG or not". He notes Svelte does not solve it either, and that React can only because it builds the
whole tree first.

**Reading.** This is a practitioner hitting, in production, exactly the seam **W29** identifies: a
template recogniser cannot see the whole path from root to hole once an `Html msg` value escapes.
It is direct evidence against W29 option (a) — "inline everything" — and evidence that option (b) or
(c) is where the answer lives. It also confirms the sheet's judgement that W29 is the design's one
unanswered technical question rather than a detail.

**Research.** (a) **Namespaces are a beni problem nobody has written down yet.** The element
vocabulary is a platform package's declarations (**W37**, R28 §5.1); if that vocabulary contains SVG,
then "which namespace do I create this element in?" is a question beni's template lowering must
answer, and his example shows the answer cannot always be static. Add it to W29/W37 explicitly. (b)
His runtime alternative — track the current namespace scope and pay for it in every app, including
those with no SVG — is a concrete cost to weigh, and he rejected it.

### 6. Hydration, SSR and resumability are the era's central problem — **a gap: beni has barely considered it**

**His claim**: the whole spine of the talk. Hydration decomposes into code size, execution and
serialisation ([1:47:38](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=6458s)); SSR alone is not a
significant improvement over CSR ([1:32:32](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=5552s)); no
approach clears all three ([2:00:52](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=7252s)); and the
field does not know which cost dominates ([2:37:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9420s)).

**Reading.** beni's sheet touches this twice and thinly: **W22** says hydration is "cheaper to design
in than to add" and records that Solid's hydration costs +28 % bytes and an unconditional
`isHydrating` check at every attribute write; **W38** requires a render-to-string platform, for
testability. There is no server story, no position on serialisation, and no statement of whether beni
intends islands, resumability or none of them. If he is right that this is *the* problem of the era,
that is a real gap — and beni's browser-first rule makes it beni's gap too, not somebody else's.

**Research.** (a) Adopt the three-cost decomposition as a written budget next to **W11** (bytes) and
**W36** (1 ms model-to-screen): beni's floor is 833 brotli today and its serialisation cost is
literally zero because nothing is serialised — that is a genuinely strong starting position and
should be stated before a server story is designed, not after. (b) His method
([2:23:46](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8626s)) — hand-write the optimal vanilla-JS
implementation and measure against it — is exactly R29's prototype method, so beni already owns the
harness to answer the hydration question for its own architecture. (c) Decide explicitly whether the
CSR and SSR builds are separable (W22 already says they must be); his Qwik/RSC analysis is the
argument for why that decision is structural, not an optimisation.

### 7. Speed is not why anyone switches — **challenges how CLAUDE.md rule 8 gets used**

**His claim** ([4:39:15](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=16755s)): "Nothing is ever 10
times better. React wasn't 10 times better than AngularJS." Solid *has* been 10× on individual
metrics and it changed nothing. And ([2:30:09](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=9009s))
"all single-page-app-style rendering — not even React, faster ones like Solid — sure, we win a few
points, but fundamentally have the same problems."

**Reading.** Rule 8 makes Solid 2 the performance gold standard and R29 reports beating it on script
on 9 of 9 operations. He would not dispute the measurement; he would dispute what it is worth. His
own R27-corroborating claim is that the browser dominates — Solid's share of building 1 000 rows is
3.35 ms of 21.9. So *(inference)* beni's "as fast as Solid" requirement is best read as a
**constraint that must not be violated** rather than a feature: it buys the right to be in the
conversation, and nothing more. That is already close to how rule 8 is phrased ("the runtime cannot
be a limitation"), and this talk is evidence for keeping it phrased that way.

**Research:** none. But it argues against ever quoting a benchmark ratio as a reason for a design
decision that costs something else — which is also the manager's validation note on R29.

### 8. His two remarks on Elm — one criticism beni should answer

**His claims.** At [2:25:57](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8757s), asked about Elm:
strong, structured, ahead of its time on concepts and compilation, "a lot harder to write errors in"
— and then the qualifier, that Elm is **primarily client-side**, which he counts against it on DX.
At [5:09:51](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=18591s) he reads and agrees with a chat
line: "Elm should bring back signals — they were early."

**Reading.** The compliment is about exactly the properties beni is built to keep. The criticism is
the same gap as item 6, stated about beni's ancestor: a client-only language has no answer for the
half of the problem this talk says is now the hard half. Note also that the caption text around the
Elm answer is garbled and the second remark is a viewer's line, not his own thesis — **check both
against the video before citing either.**

### 9. Smaller points worth keeping

- **Every framework is pulling state management inside** ([3:04:03](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11043s)):
  "the framework being aware of the specific state mechanisms allows it to optimize significantly."
  **Supports** beni's whole premise — the compiler knowing the model is what makes the per-hole check
  possible. *(inference)* beni takes this further than any of them, because the model is a value in a
  typed language rather than a framework-owned container.
- **"Is the DX actually better?"** ([2:14:00](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=8040s)) is
  the same honesty the sheet already applies to JSX in **W32** ("the speed does not depend on JSX").
  A useful precedent when W32 is argued.
- **Caching as architecture is a smell** ([3:05:58](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=11158s)):
  "I want the architecture to be sound before I optimize it with caching." Reads as support for
  **W43**'s refusal of a platform `createSelector` on rule-7 grounds, and for parking `lazy`
  (**W27**) rather than shipping a memoisation primitive.
- **Compiler vs bundler** ([3:43:24](https://www.youtube.com/watch?v=aA7Xeh7WG4E&t=13404s)): hoisting
  needs a compiler, code splitting needs a bundler, and conflating them killed his earlier attempt.
  Relevant to `backend.md` §10 chunking and **W13** (the single-file bundle first).
- **He never mentions AI or LLMs**, in 5 h 16 m, in January 2024.
