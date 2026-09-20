# Are There Actually That Many Different Ways to Build Web Apps? — organised notes

**Speaker** Ryan Carniato (author of SolidJS) · **Date** 2024-10-18 · **Length** 5 h 05 m
**Video** <https://www.youtube.com/watch?v=ja4LIaxxUeA> · **Transcript** [`transcript.md`](transcript.md)
· **Raw paste** [`raw.txt`](raw.txt)

This is a live stream, not a prepared talk: he brainstorms on a whiteboard, reads chat, and changes
his mind out loud. The notes below reconstruct the argument. Every claim is time-linked; quotes are
from YouTube's automatic captions, lightly cleaned, so **quote from the video, not from this file**.

---

## Thesis

Despite a combinatorial explosion of framework features — SSR, SSG, streaming, hydration, islands,
resumability, server components, partial prerendering — there are only **three application
architectures**, and they are separated by two questions: *who owns the UI state* and *who decides
what gets rendered*. Everything else is a **technology**, not an architecture: htmx, resumability,
hydration, JSX, web components and SSR all sit *inside* one of the three buckets rather than forming
their own. MPAs are not an application architecture at all — they are the base case everything else
extends, or "server components crippled".

Scored across the four things a user actually does in a web app (client-only interaction, committed
mutation, navigation, initial page load), the two architectures that **commit fully to one side**
score best and the hybrid in the middle scores worst: SPA 10, stateful servers 10, server components
8. The SPA's single weakness is initial page load; the stateful server's is client-only interaction;
server components are mediocre at mutation because every mutation costs template *plus* data and
forces caching to become architectural. Only Phoenix LiveView hits the trifecta of no hydration, no
double data, and client-side routing — at a cost most people cannot pay.

His open speculation: a **"server signals"** architecture that serialises a *coloured reactive graph*
instead of diffing HTML, keeping value updates on the client and structural rendering on the server.

---

## The taxonomy

### The three buckets — [22:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1365s), [27:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1635s), [45:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2700s)

| | **1. Single-page app** | **2. Server components / islands** | **3. Stateful servers** |
|---|---|---|---|
| **UI state owned by** | browser | browser, but only inside islands | server |
| **Who renders / decides** | client | server (islands are client) | server |
| **Server** | stateless (REST-ish) | stateless | **stateful — required, not optional** |
| **Navigation** | client routing, client-rendered | client routing, **server-rendered** | server-rendered over the socket |
| **Transport** | JSON | HTML / RSC payload ("template + data") | HTML partial diffs over WebSocket |
| **Placed here** | Solid / SolidStart, React SPA, **Remix (all modes, incl. RSC-as-loader)**, TanStack Start, SvelteKit, **Qwik**, offline-first, "Lakes" | React Server Components, Next.js app dir, Astro, Fresh, Marko, (htmx), MPAs as a degenerate case | Phoenix LiveView, LiveViewJS, Blazor (some modes), Turbo/Rails (partly) |

His own summary of the axes:
> "Who's left holding the state … who owns the state of the UI, who knows which checkboxes are
> ticked" — [48:24](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2904s)

**The 2×2 he draws** — *where state lives* × *where the view is decided*
([43:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2584s)):

| | server view | client view |
|---|---|---|
| **server state** | stateful servers | ~empty (SPA + WebSocket; "you can't have a socket without an API") |
| **client state** | server components / islands | SPA |

### Technologies, not architectures

| Thing | Where he puts it | Time |
|---|---|---|
| **SSR / CSR** | "a toggle, a switch; it doesn't change fundamentally that it's a single page app" | [27:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1636s) |
| **htmx** | "a technology not an architecture" — works in bucket 2 or 3; base case is bucket 2 | [34:48](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2088s) |
| **Resumability** (Qwik, Marko 6, Wiz) | technology; changes page-load *math*, not the architecture; Qwik stays a SPA | [36:10](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2170s), [2:34:57](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9297s) |
| **Hydration** | technology; "hovers these lines" | [37:32](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2252s) |
| **Islands** | bucket 2; they don't own state, they *discard* it | [33:48](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2028s) |
| **"Lakes"** (inverse of islands) | bucket 1 — "inert server components"; HTML instead of JSON; only useful for non-interactive regions | [2:31:05](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9065s) |
| **MPAs** | "not an application architecture"; "server components crippled"; "MPAs are just the web" | [50:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3006s), [51:22](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3082s) |
| **JSX** | "a templating language, no more no less" — same class as `.svelte` files or lit templates | [52:07](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3127s) |
| **Web components** | a wrapper; "the actual mechanism is never determined by the web components themselves" | [4:35:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16504s) |
| **Service workers** | an unexplored place to put bucket 3 (a stateful server inside the browser) | [58:52](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3532s) |

### The vocabulary he builds the rest of the argument on

**code / data / template** — [1:40:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6006s).
*Code* is the JavaScript (and CSS); *data* is the unique JSON; *template* is the static part of the
HTML. Server-rendered HTML **is** template + data, fused. So:

- A **SPA** ships the template *once*, inside the code, and then fetches only **data** forever after.
- **Server components / stateful servers** ship **template + data** on *every* interaction —
  re-sending the template each time, which is a bandwidth cost but saves client work.
- **Double data / double template** — an SSR'd SPA sends the data twice (once in the HTML, once as
  serialised JSON for hydration) and the template twice (once in the HTML, once in the JS bundle).
  Server components still pay both. Stateful servers pay **neither** —
  [2:00:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7185s),
  [2:05:07](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7507s).

**The client/server tension** — [1:01:03](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3663s).
A single line from "closer to the user" to "closer to your data". Ephemeral UI state, optimistic
updates and selection state belong near the user; data processing belongs near the data. The middle
bucket has to straddle it and therefore ends up with **two models**.

### The scorecard — "what do you actually do in a web app?"

Five activities ([1:09:24](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=4164s)), reordered
simplest-to-hardest; the fifth (server-initiated communication) he **drops**, because given a
persistent connection it looks the same everywhere. Scores are 1–3, "holistic, mechanical, **not
DX**" ([1:45:32](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6332s)). Tally at
[2:09:01](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7741s):

| | SPA | Server components | Stateful servers |
|---|:--:|:--:|:--:|
| **Client-only interaction** (selection, toggles, ephemeral state) | **3** | 3 | **1** |
| **Committed interaction** (mutation → server) | **3** | **1** | 3 |
| **Navigate to a different page** | 3 | 2 | 3 |
| **Load the page** (first paint / first interactive) | **1** | 2 | **3** |
| **Total (equal weighting)** | **10** | **8** | **10** |

Why each low score:

- **SPA · load page = 1.** All the JS, plus double data and double template. He notes a *client-only*
  CSR SPA with no SSR would be "**minus one**" here —
  [2:30:xx](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9065s),
  [2:25:42](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8742s).
- **Server components · committed interaction = 1.** A mutation must re-render a partial, so it must
  re-fetch *all* the data that partial needs and ship template + data back. "Without caching to guard
  here you're basically always doing more work on the mutation — it's the physics of it" —
  [1:42:42](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6162s). This is why Next.js is so
  cache-obsessed.
- **Server components · navigate = 2.** One request gets the next page, but the client does not know
  which islands it will need, so there is a **code waterfall** after the HTML lands. Link preloading
  rescues it from a 1 — [1:54:42](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6882s).
- **Stateful servers · client-only interaction = 1.** Every interaction is a round trip, so ephemeral
  state either goes to the server unnecessarily or needs a **second, imperative, non-declarative
  escape hatch** (hyperscript, LiveView's class helpers) that is not part of the state model —
  [1:30:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5400s).

**Room to grow** ([2:12:17](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7937s)):

- SPA 1 → 2 on page load via **optimal hydration / resumability** (Qwik): this would make a SPA's
  initial-load story "basically the same as server components", taking the SPA to **11**.
- Stateful servers 1 → 2+ on client-only interaction: his "server signals" idea (below).
- Server components 1 → 3 on mutation would require solving double data *and* double templating —
  "theoretically possible … very very hard", and the reason he lost interest in them.

**Conclusions he draws** — [2:16:52](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8212s):

- If page load is your priority, don't pick a SPA (but it can improve).
- If your primary content changes **often**, don't pick server components. (He thinks this weakness
  is under-appreciated.)
- If you are heavily interactive / latency-sensitive, don't pick stateful servers.
- Stateful servers win mechanically and are **not an option for most people** — serverless economics
  push against holding a connection per user.
- **Pure islands** (no client routing) score 3 on page load. Client-side routing is what makes page
  load hard, and it is also what defeats every island/resumability optimisation —
  [2:24:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8667s),
  [4:33:03](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16383s).

---

## Chapter-by-chapter outline

Chapter numbers match [`transcript.md`](transcript.md).

### 1–2. Preamble and Q&A — [0:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=0s), [6:30](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=390s)

- Is slow performance a bug? Nobody files "this is faster in Svelte" on React's tracker; people treat
  performance as the baseline, not a defect.
- Solid's *runtime* code size is "maybe 300–400 bytes … a little less than half a kilobyte"; the rest
  of the speed is the compiler, which he is happy to make arbitrarily complicated so the runtime can
  stay small — [4:57](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=297s).
- Web components "don't do anything": moving from React to web components says nothing about
  architecture, authoring, or change propagation.
- Solid's UI-library ecosystem (Corvu, Kobalte, Ark UI, shadcn-for-Solid) exists but he does not
  track it; TanStack Start is building on the same bones, and Tanner Linsley has to invent more
  because React constrains him.

> "I'm approaching this from the basis … what if we didn't have React, what if we were just starting
> from scratch again?" — [18:55](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1135s)

### 3–5. The three buckets — [22:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1365s)

- He is responding to his own 2022 article and an Addy Osmani feature chart: the combinatorics give
  ~60–120 viable framework configurations, which is "a mess".
- Collapse it: **SPA, server components, stateful servers**. SSR/CSR is a toggle within bucket 1.
- Remix "does it backwards" — using RSCs as data loaders keeps you client-driven, so it stays bucket 1.
- Islands "don't bother with the state, they throw it away"; that is a *choice*, not an inability.
- htmx and resumability are technologies that hover across the lines.

> "Whether you do SSR or not, it's a toggle, it's a switch; it doesn't change fundamentally that it's
> a single page app." — [27:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1636s)

### 6–7. Charting state, and stateful servers — [38:30](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2310s)

- He looks for the axes, the way he once found Solid by spotting an empty quadrant in a
  fine-grained × data-flow chart.
- Lands on *state* × *view*, each client-or-server (the 2×2 above). The server-state/client-view cell
  is nearly empty.
- Stateful servers: state on the server, server-rendered navigation, **a persistent backend is a
  precondition, not an optimisation**. The stateless/stateful split "has existed since the dawn of the
  web" and is driven by infrastructure and cost, not capability.

### 8–10. MPAs, service workers, the single app experience — [50:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3000s)

- MPAs: not an app architecture; everything is a superset of them; "closer to the middle category".
- Unexplored idea: put a **stateful-server architecture inside a service worker** — both sides on the
  same side, for offline-first.
- SPAs and stateful servers each optimise hard for *their* side and get a **single model and a single
  DX** out of it; server components are inherently split, and the split is not just "this runs here"
  but changes how mutations and actions are modelled —
  [1:05:10](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3910s).

> "The extremes share more common ground than the middle." (chat, agreed) —
> [1:07:43](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=4063s)

### 11. What do you actually do in a web app? — [1:09:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=4155s)

- Enumerates: load the page · navigate · client-only interaction · committed mutation · (added by
  chat) server-initiated communication.
- Reorders them simplest-to-hardest and drops the fifth as non-discriminating.
- Notes José Valim's point that LiveView survives deploys because the BEAM can ship a VM across.

### 12. Client-only interaction — [1:24:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5085s)

- SPA: `event → state → UI`, synchronous, in the browser. **3.**
- Server components: islands behave like a SPA here. **3.**
- Stateful servers: **1**. LiveView is event delegation plus a named server function; the state lives
  on the server, so ephemeral state either round-trips or needs a second, imperative mechanism.

> "The secondary mechanism is not tied into the state of the application on the server … it's a kind
> of separate imperative API." — [1:30:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5400s)

### 13. Committed interaction — [1:32:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5535s)

- SPA: POST the delta, get back exactly what you need. Even the lazier TanStack-style
  invalidate-and-refetch is fine, and single-flight mutations remove the double round trip. **3.**
- Server components: **1** — template + data, must gather *all* the data for the partial, caching
  becomes mandatory. Introduces the code/data/template vocabulary here.
- Stateful servers: **3** — the previous state is already on the server, so it sends a granular diff.
  HTML-vs-JSON as a wire format is "a coin toss".

> "You can make your whole page a SPA in here … but that defeats the point." —
> [1:38:44](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5924s)

### 14. Navigation — [1:45:30](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6330s)

- SPA: code-split routes, parallel code + data fetch, and after the first visit **only data**. Client
  rendering cost is a wash — measured against innerHTML and against streaming SSR chunks. **3.**
- Server components: one request for the page, but the client cannot know which islands it needs →
  **code waterfall**. Preloading on hover rescues it. **2.** "This is why Next's app directory looks
  the way it does."
- Stateful servers: socket is already open, no code to load. **3.**

### 15–17. Load the page, tally, conclusions — [1:59:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7185s)

- SPA: **1** — all the JS, double data, double template.
- **The JS that scales with page size is the template, not the logic**: in Solid's playground, adding
  a `div` grows the template string, not the component function.
- Server components: **2** — less JS *runs*, but still double data and double template.
- Stateful servers: **3** — nothing to hydrate; "event delegation is only hydration really"; the
  socket connect time is comparable to hydration time and could use event replay.
- Totals 10 / 8 / 10, and the conclusions listed under *The scorecard* above.

> "Server components are really good if you don't care about mutating." —
> [2:16:52](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8212s)

> "As your page gets larger, the thing that actually grows the most are these template elements." —
> [2:01:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7264s)

### 18. Q&A: CDN, Lakes, resumability — [2:29:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8985s)

- "Lakes" = inert server components: HTML instead of JSON, saves client JS, only useful where nothing
  is interactive. "Like having a SPA and loading htmx into the middle of it."
- Resumability already gets most of this, because it assumes the outside is server-owned until
  something needs to render.

### 19–20. Optimising actions — [2:36:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9360s)

- The standard loop (mutate → revalidate key → refetch) is popular because it is *easy* and makes
  `UI = f(state)` fall out; single-flight mutations move it server-side.
- In the Strello demo (a SolidStart Trello clone) every mutation ships **the whole board** back.
- Proposal: let a server function know whether the client has JS; when it does, return only the
  changed record, and give actions an `onComplete` hook that writes the cache and calls
  `revalidate: false` (commit the signals without refetching).
- Chat improves it: use the **submission input**, not the result — then nothing needs to come back
  at all — [2:49:38](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10178s).

### 21–23. Caching with router APIs — [2:52:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10320s)

- He is renaming Solid's `cache` to **`query`** — it dedupes per request, holds 5 s on preload, 5 min
  for back/forward, and bypasses on link clicks. "The most unobtrusive cache you can imagine … it
  basically is not a cache," and the name scares people off a thing everyone should use.
- **The load-bearing finding**: a wrapper around a server function only intercepts the **render**
  path. When the client calls the endpoint, execution starts *inside* the function, so an outer
  wrapper never runs. Therefore server-side caching **cannot** be a wrapper —
  [2:58:44](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10724s).
- Wrapping outside also detaches reactivity (the query's internal signal is never read, so
  revalidation stops working); wrapping inside loses the key and the hydration payload. HOC-based
  caching "doesn't really work … composing them is a mess".

### 24–30. Next.js `"use cache"` — [3:11:30](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=11490s)

- Why a directive rather than a function? Because it is **inside** the block, so it works from every
  call path — exactly the hole he just found. "It's a wrapper, but a wrapper we know exists from all
  contexts."
- He checks in AST Explorer that Babel treats it as a directive at function-block scope, and that
  ordering two directives would be ambiguous.
- Reads it as **compiler + runtime + infrastructure**: the directive only means something where a KV
  store exists, which makes it awkward to port off Vercel.
- The cache-key problem: `"use cache"` is keyed on arguments with time-based expiry, plus a `tag`
  helper. His counter-proposal — **the function reference is the key**, because it never crosses a
  serialisation boundary, so `revalidate(getUser)` needs no string key at all. TypeScript is the only
  obstacle (it cannot see compiler-added methods, so you need a real wrapper) —
  [3:41:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=13264s).
- Verdict: set a default cache profile, drop `use cache` where needed, custom profiles for the
  80/90-percentile exceptions. "DX-wise very attractive."

### 31–37. Server signals as architecture — [3:52:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=13935s)

The most speculative section, and the one where he designs rather than surveys.

- Starting objection: **signals are pull-based and lazy, so they are a bad fit for pushing events**
  from a socket, and he cannot see what a signal graph *does* on a server at all.

> "I don't understand what the signals are doing on the server at all." —
> [3:59:56](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14396s)

- The one job he can imagine for them is **render** — so: *can signals make LiveView better?*
- Invert the usual framing: stop starting from render and **start from the event**. LiveView turns
  events into named RPC calls; Qwik's resumability also starts from the event. So make **event
  handlers the islands**, not components.
- The rule he proposes: **all new element rendering happens on the server** — "let's pretend JSX only
  exists on the server". Anything that creates structure (`<Show>`, `<For>`, a conditional, async
  data) is a server derivation. Anything that only *updates an existing node* (a class, an attribute,
  a text node's `data`) stays on the client —
  [4:09:25](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14965s),
  [4:10:43](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15043s).
- Propagation runs synchronously on the client as far as it can, batches what it cannot, and ships
  **only the part of the graph that changed** to the server, which finishes propagating and sends
  values back. Explicitly "like ASP.NET ViewState, but fine-grained enough to not be a disaster".
- **Colouring rules** ([4:20:05](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15605s)): signals are
  isomorphic; effects are client-only; a signal whose setter is never called from the client is a
  server node; derivations reading only server nodes are server nodes and need no serialisation;
  **only the intersection of server and isomorphic nodes has to be serialised**.
- Worked examples: the Solid Hacker News comment toggle (a class flip stays client-side; a `<Show>`
  would round-trip); a date-format toggle forces the user record to be serialised because client and
  server data intersect. Optimistic updates are the case where serialisation can never be avoided.
- Verdict: the prize is not finer-grained diffs, it is that **some updates stay client-side
  automatically** and you get **one model** rather than two. Cost: Qwik-level compiler complexity
  plus a persistent connection — and it still does not solve client-side routing.

> "They don't need to hydrate … they don't need the double data, and they have client-side routing.
> Literally nothing else has done that." (on LiveView) —
> [4:36:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16587s)

### 38. Web components and "sprinkles" — [4:35:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16500s)

- Web components are a packaging mechanism; the only thing they genuinely provide is Shadow-DOM style
  isolation. Their lifecycles would actively obstruct the fine-grained entry points he wants.
- The goal he states plainly: write an app the way you write React today, and have the output be an
  MPA with client-side routing and minimal JS, with no `"use client"` anywhere —
  [4:40:08](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16808s).

### 39–42. Intermission, This Week in JavaScript — [4:42:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16935s)

- On signals, generally:

> "Adding signals won't make things faster; it's the things you can remove when you add signals that
> make it faster." — [4:43:36](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17016s)

- `solid-events`: an RxJS-flavoured composable event chain feeding a signal at the end. He likes that
  it is *directional* where signals are not, and places it "one level out" from the core — start with
  `createProjection`, reach for event transformation when the model gets awkward.
- Optimistic UI explained: the client gets ahead of the server and reconciles on failure.

### 43. Stateful servers, and the single-language conclusion — [5:00:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18000s)

- The reason stateful servers are hard is not the protocol, it is the **platform**: Elixir's BEAM was
  built for hundreds of thousands of concurrent stateful connections and JavaScript has nothing like
  it.
- But an optimal client/server handoff wants **one language on both sides**, and that language is
  JavaScript. WASM, he says flatly, is not the answer.

> "The best way to actually solve these problems involves a single language model, which means
> JavaScript." — [5:00:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18006s)

> "WASM is not the answer … we need it to be native like JavaScript." —
> [5:00:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18006s)

- He expects JavaScript to get good on the backend before other languages get good in the browser.

---

## Topic index

| Topic | Times |
|---|---|
| **The three buckets** | [22:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1365s), [27:15](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1635s), [55:35](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3335s) |
| **SPA** | [27:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1636s), [1:24:50](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5090s), [1:33:23](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5603s), [1:46:49](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6409s), [1:59:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7185s) |
| **Server components / RSC** | [29:51](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1791s), [1:36:02](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5762s), [1:51:08](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6728s), [2:05:07](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7507s), [2:16:52](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8212s) |
| **Stateful servers / LiveView** | [45:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2700s), [1:27:24](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5244s), [1:42:42](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6162s), [2:06:26](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7586s), [4:02:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14540s), [5:00:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18006s) |
| **Islands** | [27:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1636s), [33:48](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2028s), [2:24:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8667s) |
| **Resumability / Qwik** | [36:10](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2170s), [2:33:37](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9217s), [2:15:03](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8103s), [4:13:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15184s), [4:31:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16305s) |
| **Hydration / event delegation** | [1:27:24](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5244s), [2:06:26](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7586s), [3:03:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=11000s) |
| **code / data / template; double data** | [1:40:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6006s), [1:59:45](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7185s), [2:01:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7264s), [4:29:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16160s) |
| **Client-side routing as the spoiler** | [1:51:08](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6728s), [2:24:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8667s), [4:25:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15920s), [4:33:03](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16383s), [4:41:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16876s) |
| **MPAs / Astro** | [50:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3006s), [53:22](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3202s), [4:40:08](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16808s) |
| **htmx / HTML partials** | [34:48](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=2088s), [2:32:21](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9141s) |
| **"Lakes"** | [2:31:05](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9065s) |
| **Optimistic updates / single-flight mutations** | [1:34:43](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=5683s), [2:38:41](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9521s), [2:41:18](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9678s), [4:56:21](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17781s) |
| **Caching: `query`, wrappers, `"use cache"`** | [2:52:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10324s), [2:58:44](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10724s), [3:11:32](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=11492s), [3:27:07](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=12427s), [3:41:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=13264s) |
| **Server signals (his proposal)** | [3:57:19](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14239s), [4:02:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14540s), [4:08:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14884s), [4:20:05](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15605s), [4:29:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16160s) |
| **Signals: limits** | [3:54:32](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14072s), [3:59:56](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14396s), [4:43:36](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17016s), [4:51:xx](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17448s) |
| **JSX as a templating language** | [52:07](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3127s), [4:09:25](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14965s) |
| **Web components** | [8:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=480s), [4:19:42](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15582s), [4:35:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16504s), [4:43:36](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17016s) |
| **Single language / WASM** | [1:03:53](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3833s), [5:00:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18006s), [5:02:46](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18166s) |
| **Serialisation (seroval) / Solid tooling** | [4:46:22](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17182s), [3:01:18](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=10878s) |

---

## What this means for beni

Read with [`plans/browser-decisions.md`](../../../plans/browser-decisions.md) open. **His claims are
marked "He:"; everything else is my inference and is marked so.** Question ids are that sheet's.

### Where a beni browser program sits in his taxonomy

**Inference.** beni's designed program is `init / update / view / subscriptions`, one model in the
browser, a compiled template, a `Program` mounted by the platform (W25, W26, W9). That is squarely
**bucket 1, the single-page app** — and specifically the sub-case he rates worst: **client-rendered,
no SSR**. Nothing in beni's plans produces HTML on a server, and `plans/browser-platform.md` has no
router, no data-loading story, no hydration, no islands, no streaming and no serialisation of the
model across a wire. The only server-side rendering beni has even contemplated is W38's
render-to-string platform, and that exists **so that views can be black-box tested under Node**, not
as a delivery mechanism.

So on his scorecard a beni program today scores **3 / 3 / (routing not designed) / −1 to 1**. He is
explicit that a pure CSR SPA is the one cell he would score below one
([2:30:xx](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=9065s)) — and equally explicit that most
people's mental model of "SPA" *is* that worst case, which is why the category has a bad reputation.

### Five points that matter most

**1. SSR is a toggle, not an architecture — so beni's position is recoverable. (SUPPORTS)**
*He:* "Whether you do SSR or not … it's a switch; it doesn't change fundamentally that it's a single
page app" — [27:16](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=1636s).
*Why it matters:* W25's decision to keep TEA is not a bet against server rendering. A beni program
that adds SSR later does not change bucket, does not change `update`, and does not invalidate W26's
compiled templates. *Research:* W38 already says a render-to-string platform is mandatory for
testing — treat it as **the first half of an SSR story**, not only a test harness, and record in
`boundary.md` §5 what a second (browser-hydrating) platform would need from it.

**2. The template is what scales with page size, and it is most of the JavaScript. (SUPPORTS W26,
and sharpens W11.)**
*He:* "As your page gets larger, the thing that actually grows the most are these template elements"
— [2:01:04](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=7264s); Solid's *runtime* is "maybe 300–400
bytes" ([4:57](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=297s)), everything else is compiler
output.
*Why it matters:* W11 asks how much runtime a browser program may ship and R29 measured a template
renderer's machinery at ~1.7 kB brotli. His figure says the **runtime is not the interesting number**
— the per-template static HTML strings are, and they grow linearly with the view. beni's floor
(2 147 B raw) is measured on programs with no view at all. *Research:* extend `bench/size.mjs` to
report **template bytes vs logic bytes** once `backend.md` §11 exists, and read §10's chunking
question as primarily a question about template bytes.

**3. He starts from the event, not from render — and his server/client split is exactly W29's
question. (SUPPORTS, and offers a ready-made answer.)**
*He:* "Let's pretend that JSX only exists on the server … anything that would lead to rendering new
JSX would be on the server" — [4:09:25](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14965s) — with
the client keeping *value* updates (a class, an attribute, a text node's `data`) and the server
owning *structural* changes (`<Show>`, `<For>`, conditionals, async). He demonstrates the distinction
in Solid's own compiler output ([4:10:43](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15043s)).
*Why it matters:* **W29 is beni's one open technical question** — what an `Html msg` is at run time
and where the compiler must fall back to building a tree. His line is the same line: a hole that
*sets a value on an existing node* needs no tree; a hole that *creates structure* does. That is a
principled way to name W29's hole kinds and to define which holes fall back. *Research:* when
experiment **X1** is specified, classify holes his way (value-update vs structure-creating) and
measure the fallback cost only for the second class. *Inference, not his claim:* he is solving a
serialisation problem and beni is solving a representation problem, but the partition is the same.

**4. Client-side routing defeats every optimisation in the space — and beni has no routing design at
all. (CHALLENGES.)**
*He:* "None of this actually solves through client-side routing"
([4:33:03](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16383s)); pure islands score 3 on page load
precisely *because* they do not route on the client
([2:24:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=8667s)); the server-component code waterfall
exists only because the client routes ([1:51:08](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6728s)).
*Why it matters:* routing is absent from `plans/browser-platform.md` and from every W. It is not a
library detail: it is what decides whether beni can ever occupy bucket 2, and it interacts with W9
(`main`/`Program`), W6 (subscriptions), W7 (command keys) and `backend.md` §10 (chunking, because
routes are the natural chunk boundary). *Research:* open a W for **what a route is in beni** before
the platform spec is written, and note that Elm's `Navigation.Key` already has an answer shape under
A7 (a record of functions).

**5. One language on both sides is the requirement — and beni already satisfies it. (SUPPORTS,
strongly, and it is the argument beni can make that Solid cannot.)**
*He:* "The best way to actually solve these problems involves a single language model, which means
JavaScript … WASM is not the answer, we need it to be native like JavaScript" —
[5:00:06](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=18006s). His whole "server signals" design
assumes a graph that both sides can hold, and his closing lament is that the best *concurrency*
platform (BEAM) and the best *handoff* language (JavaScript) are different runtimes.
*Why it matters:* beni compiles **the same source language to JavaScript for both sides**. It is not
WASM, so his objection does not apply; and `boundary.md` §5.2's `program`/`runtime` manifest keys
already give one language two platforms. *Inference:* this is the strongest structural argument in
the talk in beni's favour, and it is the one the owner should weigh when deciding whether a server
platform is in scope at all. *Research:* a note in `plans/browser-platform.md` that beni's
server-and-browser-same-language position is the precondition his three architectures all want.

### Points that bear on the open questions the owner is weighing

**W25 — TEA vs components-and-signals.** *He never argues the question beni is asking.* His axes are
*where state lives* (client/server) and *who renders*, not *who owns state within the client*. He
takes component-local state for granted because Solid has it, and never defends it. **Inference:**
this talk is **neutral** on TEA-vs-signals and should not be cited either way. What it *does* supply
is a reason to prefer a **single model**: SPAs and stateful servers win his scorecard precisely
because each has one model and one DX, and server components lose partly because they have two
([1:05:10](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=3910s),
[4:29:20](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=16160s) — "not two side by side but the same
model"). TEA is a one-model architecture. That is a supporting argument for W25, but an indirect one.

**The local-state question ("Elm has no components and no local state").** *He:* the Solid Hacker
News toggle is worth quoting at length in spirit — its state "is completely independent … you don't
see the data here", so the async data and the client signal never intersect, and *therefore nothing
needs to be serialised* ([4:24:00](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=15840s)). His
colouring rules turn that isolation into a compile-time saving.
**Inference, and the honest version:** he is not arguing that local state is *ergonomically*
necessary; he is arguing that **state whose reachability is narrow is cheaper**, because the compiler
can prove it never crosses the wire. Under a single global model that proof is harder — a field of
one big record is reachable from everywhere by construction. If beni ever wants bucket 2 or 3, "no
local state" has a **real cost that is not a matter of taste**, and it is a cost Elm never had to pay
because Elm never tried to render on a server. If beni stays in bucket 1, the cost is zero. This is
the sharpest thing in the talk for the owner's current decision, and it cuts *against* the
comfortable answer that local state is only ergonomics. He would probably not put it this way; the
framing is mine.

**W26 / W27 — compiled templates and identity.** He does not discuss diffing strategies or reference
identity at all. **Neutral.** His only adjacent claim is that client rendering cost is a wash against
shipping HTML unless the page is enormous
([1:49:27](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=6567s)) — which mildly *undercuts* the
importance of R29's script-time margins end to end, in the same direction as R27 §10.4's "the browser
is the cost".

**W29 — see point 3.** His structural-vs-value partition is the most directly usable idea in the talk.

**W19 / W20 — signals and component libraries, unshipped but not forbidden.** *He:* signals are
lazy and pull-based, so they are a poor fit for pushed events, and he cannot say what a server-side
signal graph is for ([3:54:32](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14072s),
[3:59:56](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=14396s)). And: "adding signals won't make
things faster; it's the things you can remove when you add signals that make it faster"
([4:43:36](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17016s)).
**Inference:** that last line is close to R29's finding that signals buy no speed over compiled
templates — the removal, not the graph, is the mechanism. It **supports** W19's "unshipped, never
forbidden". It also supports W20 from an unexpected angle: he notes `solid-events` belongs "one level
out" from the core ([4:51:xx](https://www.youtube.com/watch?v=ja4LIaxxUeA&t=17448s)) — the same
library-not-kernel placement W20 recommends.

**W9 — what `main` is.** **Inference.** In bucket 1, W9(c)'s answer (an opaque mount descriptor) is
complete. In buckets 2 and 3 it is not: a server-component program's entry point is a **route**
handler, and a stateful-server program's is a **connection**. If the owner ever wants those, `main`
grows a second and third meaning, and W9's "low reversibility for `main`'s type" becomes expensive.
Worth recording under W9 as a known future pressure rather than re-opening it now.

### What beni would need to occupy the other positions

**Inference throughout.** Ordered by distance from what exists.

| To reach | Compiler | Runtime | Platform |
|---|---|---|---|
| **SSR'd SPA** (bucket 1, his 1 → a real 1 not −1) | nothing new beyond W38's render-to-string path | a hydration pass that adopts server-rendered DOM instead of building it; event replay during the gap | an HTTP platform; a serialiser for the initial model (beni has a **per-port** generated codec at `boundary.md` §3.1, not a general one) |
| **Resumable SPA** (his 1 → 2, the lever he names) | a Qwik-class split: every event handler an independent entry point, closures serialisable, hole paths addressable by stable id | a resume protocol instead of a hydrate protocol | code-splitting per handler — `backend.md` §10's chunking, which is unstarted and whose decisions are PENDING |
| **Islands / server components** (bucket 2) | a **server/client module split** — beni has no such boundary; `foreign` is the only one, and rule 6 makes it privileged | an island mount protocol; per-island scopes | a router, a data-loading API, a manifest of which islands a route needs (his named waterfall), and a wire format that is template + data |
| **Stateful server** (bucket 3) | nothing large — the *view* compiles as it already does, on the server | **the fiber scheduler, per connection**, which beni already designs (A1, A7); plus a diff or a coloured-graph protocol | a persistent-connection platform and a process model that survives thousands of connections — his BEAM objection lands here, and beni's fibers are a scheduler in one process, not a BEAM |

Two observations from that table. First, **bucket 3 is closer to beni than bucket 2 is**: it needs no
module-splitting compiler pass, and beni's effects design (scoped fibers, infallible finalisers,
invisible interruption) is close to what a per-connection runtime wants. Second, **everything except
bucket 3 needs a router and a chunker first**, and beni has neither specified.

### Where he would disagree with beni's current direction

Stated plainly, without softening:

- He would call a client-rendered, non-SSR'd, non-routed single-page program the **weakest cell on
  his board** for initial load, and would say most of the industry's dislike of SPAs is aimed exactly
  there.
- He would not accept "the compiler makes it fast" as an answer to page load: his 1 for SPAs is about
  **bytes and round trips**, not script time, and beni's measured advantage (R29) is script time.
- He would regard beni's absence of a server story as putting it outside two of his three
  architectures entirely, not as a staging decision.
- He would probably regard TEA's single global model as an obstacle to the graph-colouring savings he
  wants — though he never says so, because he never considers TEA. *(Inference, and the weakest claim
  in this section.)*

And where he is on beni's side, equally plainly: **one language on both sides is his stated
requirement**, compiling to JavaScript rather than WASM is his stated constraint, the compiler doing
the work so the runtime stays tiny is his stated method, and a single model rather than two is his
stated preference. beni satisfies all four by construction.
