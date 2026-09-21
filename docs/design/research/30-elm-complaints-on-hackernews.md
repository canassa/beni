# 30 — What Elm's users complained about, 2011–2026

**Corpus** 80 Hacker News threads · 7 285 comments · 2 776 distinct commenters · 2011-12 → 2026-07
**Collected** 2026-09-20 with the `hackernews` skill · **Method** §1 · **Reliability** §9

This report answers two questions the owner asked: what people commonly complain about in Elm and
The Elm Architecture, and — specifically — what they say about Elm's **enforced centralized state**,
the single top-level `Model` with no component-local state.

**Hacker News is evidence of what objections exist and how common they are. It is not evidence that
they are correct.** It selects for people with a grievance, half the corpus predates Elm 0.19
(2018-08), and a confident comment about a compiler is still an anonymous comment about a compiler.
Everything below is attributed with a comment id so it can be checked. Where the reading goes past
what was said it is marked *(inference)*.

---

## 1. Method

Searched `"elm"` as an exact phrase (`tags=story`), took the first five pages of relevance-ranked
results (100 stories), kept the **80 with ≥ 20 comments**, and downloaded each thread's complete
reply tree — full depth, no truncation. Eight agents read the corpus in byte-balanced shards of
~450 KB, each reading its shard in full and reporting against a fixed schema: distinct-commenter
counts, date ranges, verbatim quotes with ids, production-vs-speculation flags, and the counter-case.

Two independent layers cross-check each other. The agents read the text; a mechanical pass counted
term families across all 7 285 comments, which is how §2's frequency table was built rather than
inferred from eight partial views. **38 load-bearing quotes were then spot-checked against the
source corpus — every id, author, date and wording matched exactly, in all eight shards.**

Raw data and the per-shard reports are outside the repo, in the session scratchpad
(`hn-elm/`: `raw/`, `text/`, `all-comments.ndjson`, `index.md`).

---

## 2. The headline finding: this is not what people complain about

Counting distinct commenters, not repetitions, across the whole corpus:

| theme | distinct authors |
|---|---:|
| ecosystem / libraries | 480 |
| governance / Evan / BDFL | 234 |
| ports / JS interop | 188 |
| forks (Gren, Zokka, Guida, …) | 141 |
| "dead / abandoned / unmaintained" | 119 |
| type classes | 108 |
| 0.19 breakage | 97 |
| refactoring | 87 |
| boilerplate | 77 |
| reuse / composition | 74 |
| native modules / kernel code | 68 |
| **centralized state, named explicitly** | **20** |

**People overwhelmingly left Elm over interop, governance and ecosystem — not over TEA.** In eight
shards the agents independently reported the same distribution, and three of them opened with an
unprompted caveat that their threads were thin on the state question. That is the single most
important result here, and it cuts against the premise of the question rather than confirming it.

Two qualifications keep it from being the whole story:

1. **The pain is renamed.** "Boilerplate" (77), "reuse/composition" (74) and "refactoring" (87) are
   where centralized state gets discussed without being named — the agents found the substance
   there, which a regex cannot.
2. **Selection.** Nobody writes a blog post called *Elm's state model worked fine for four years*,
   so it never becomes a thread. The defences in §5 are almost all replies, never submissions.

---

## 3. Centralized state: nine distinct problems

Ordered by how much evidence stands behind them.

### 3.1 The ripple — a stateless leaf becoming stateful changes every ancestor

The most concretely worked-out complaint in the corpus, and the one that most deserves an answer.
It is not a size problem; it is a *locality* problem. A stateless subscribe button sits inside a
stateless header; the designer asks for a dropdown; the dropdown needs state, so the button gets a
model and an update, and now the header must become stateful to carry them, and so must everything
up to `main`.

> "I think the bigger problem here is the load it takes to change from stateless to stateful."
> — `mistersys, #14296484, 2017-05-08`

The abstract statement of the same thing, from a production user:

> "dropping a stateful component (view+behaviour+state) anywhere in your app without anything else
> changing. That's not possible in Elm since the only place to store state is the central state
> storage." — `zoul, #19300789, 2019-03-04`

One person names it as why they left: "The lack of component-local state is what ultimately drove
me away from Elm for my last project" (`hathawsh, #14295133, 2017-05-08`). Across shards, **~20
distinct commenters** describe this shape; it appears from 2015 to 2026 with no change in character
across 0.19.

### 3.2 The grievance attaches to `Msg`, not to `Model`

The sharpest correction in the corpus, from someone who works the whole example through:

> "The Model for that is pretty straightforward. It's just a tree of data. The Msg for that is what
> is being complained about." — `phamilton, #12076766, 2016-07-12`

Nobody contradicts him. What people actually pay for is message *routing*: a constructor added to
the root `Msg` per feature, a case in the root `update`, a `Cmd.map` on the way out, at every level.

> "How do you stop your main update function from growing endlessly as you add new Msgs?"
> — `leshow, #12914298, 2016-11-09`

*(inference)* This matters for beni more than the headline count suggests: it means the cost is in
the **plumbing mechanism**, which a language can change, not in the single-value model, which is the
part beni is committed to.

### 3.3 Domain data and transient UI state end up in one record

Raised once, but it is the cleanest statement of the structural cost and no one answered it:

> "another consequence is that the model is a mix of business data and UI state data. The selected
> month shouldn't affect the business logic, but it is bundled with THAT data which is annoying."
> — `bbcbasic, #13033492, 2016-11-24`

His example is a calendar inside a grid inside a tab, where clicking "next month" must bubble
through every layer. He adds: "Not sure what the solutions are though."

### 3.4 You cannot ship a stateful widget, so the ecosystem doesn't grow one

A second-order effect that only one person frames correctly, and it may be the most consequential
item in this section:

> "components are hard to do in Elm and are discouraged in the documentation"
> — `aeturnum, #28226305, 2021-08-18`

Because the unit people normally share *is* a stateful component, discouraging components suppresses
the package ecosystem; his own workflow became copying and modifying source instead of depending on
packages. The ecosystem-wide version:

> "All libraries written for Elm, assume that the consumer is writing their application using TEA."
> — `poleprediction, #33189694, 2022-10-13`

The practical consequence recurs for a decade: grids, calendars, typeaheads and rich-text editors
have "a hassle with no clear path" (`bbcbasic, #13027365`), and the sanctioned answer became **web
components** — endorsed by a CTO running Elm at a billion-dollar company as "the way" over ports
(`aaronwhite, #33166250`), and described by another production user as "a workaround for elm being
anti-component. It's infuriating. It makes me write JS instead of elm" (`boxed, #33212202`).

### 3.5 Nesting the Model to get structure is a trap; flatten instead

The most useful *convergent* advice in the corpus, because it comes from people who tried both and
from opposite sides of the argument. A widely-cited article needed 14 lines to update one field of a
nested record, and reached for lenses; the response from the largest production codebase was that
the nesting was the mistake, not the ergonomics:

> "in retrospect nesting did more harm than good, and knowing that, I would have happily left it
> flat." — `rtfeldman, #25095821, 2020-11-14`

Two other production teams independently report the same migration — "I went from a nested to a
flat, decoupled architecture" (`mordrax, #16798695, 2018-04-10`), "We have moved to a very flat
architecture where most things are at the top level of the state tree" (`antew, #19303396,
2019-03-04`, 60k LOC). And the type-level diagnosis:

> "If Elm had extensible unions I would advocate as much as possible staying away from nested
> hierarchies. They lock you into a single access pattern. Unfortunately Elm does not, so nested
> hierarchies it is." — `dwohnitmok, #25094417, 2020-11-14`

*(inference)* That is the strongest claim in the corpus that **the nesting pain is a type-system gap,
not an architecture gap** — which makes it beni's kind of problem.

### 3.6 Child-to-parent communication has no canonical answer

Three competing hand-rolled conventions — `Config` records, `OutMsg`, and a flat `Msg` type — are
named by a defender as the *one* place in Elm where choice exists (`mjaniczek, #36044376`). A
production team reports the shape it degenerates into:

> "it was fairly cumbersome to have `(Model, Cmd, ExternalMsg)` in lots of places"
> — `antew, #26866959, 2021-04-19`

and, without one of these patterns:

> "Elm applications … end up being horrendous spaghetti code of everything knowing about
> everything." — `thepratt, #20982715, 2019-09-16`

### 3.7 Mechanical: the message queue can silently drop a message

The most load-bearing *technical* finding, and it is not an ergonomics complaint. There is an
undefined delay between a message being issued and `update` running on it, so a snapshot-style
message carrying a whole new model can land after a subscription message and overwrite it — the
subscription's effect lost permanently, with no error.

> "there is an undefined delay between a message is issued and when `update` is called on the
> message" — `dwohnitmok, #25098676, 2020-11-15`

He gives a five-step trace and answers the obvious objection directly: single-threaded JavaScript
does not save you, because concurrency is not parallelism. A production user reports the same class
of bug with pointer events (`Latty, #25094289`). **The ergonomic fix people reach for — a coarse
`SetModel` message carrying the whole new model, to dodge per-field `Msg` boilerplate — is exactly
the unsound one.** A counter-report from three years of production Elm says it never bit them
(`pyrale, #25094021`), so this is a latent hazard rather than a common one.

### 3.8 Mechanical: whole-model rebuild destroys the identity `lazy` depends on

The second mechanical finding, and the one most directly relevant to beni's rendering design:

> "the reference (memory location) almost always changes on every update cycle because it needs to
> update model, thus, a new reference as a result. And that makes Html.Lazy worthless."
> — `Existenceblinks, #28223910, 2021-08-18`

Reported cost: ~1 000 nodes re-rendering every update, several days spent, unsolved. He hedges ("I
probably did something not right") and no one replied, so treat it as one unreplicated report — but
the mechanism is real, not speculative, and it is corroborated from the other direction by people who
say most Elm projects don't use `Html.Lazy` because it is tricky (`hellofunk, #14890513`).

### 3.9 Costs that get pushed out of the program entirely

Three production reports where centralization moved a cost into the build system or a metaprogram —
the clearest evidence that the constraint has a price beyond taste:

- **One compiled build per language.** "Translation was solved with one build for each language to
  avoid passing down the model everywhere" — `jlundberg, #19302138, 2019-03-04`. Nobody replied.
- **A code generator for `main`.** A three-person team shipping a commercial kiosk ended with "a
  huge Elm main program that was 90% case-statements" and replaced it with a JS templating library
  that emits the root file from a JSON spec — `Fr0styMatt88, #13620638, 2017-02-11`; he adds "I
  still feel like it's working around a shortcoming of the language" (`#22245066`).
- **An 800-line diff for a timezone.** "displaying timestamps in 'the current user's timezone' in
  our application required an 800+ line change" — `al2o3cr, #26865296, 2021-04-19`.

---

## 4. TEA complaints other than centralized state

- **Ports are async-only, so a synchronous JS call forces an architectural change.** Named by ~15
  commenters and the single most-repeated TEA-shaped complaint. "This turns what should've been a
  one line call into potentially dozens of lines that also forces an architectural change in how the
  calling code actually calls the function" — `dwohnitmok, #22248658, 2020-02-05`.
- **JSON decoders are hand-written.** The dominant grievance of the 2017 threads; ~20 commenters.
  "The complaint is that humans have to write and maintain code that the compiler could be writing"
  — `jeremyjh, #21321990, 2019-10-22`, who ties it to the absence of type classes.
- **The virtual DOM assumes it owns the DOM.** A production user lost real users to it: browser
  extensions (Grammarly, 1Password) mutate the DOM under Elm's root and break it — `sheept,
  #48806604, 2026-07-06`, who stopped using Elm over it. Mitigation named:
  `lydell/elm-safe-virtual-dom`.
- **Purity of `view` forces a second pass.** "I had to walk through my data twice — once to render
  it and another time to collect cache misses" — `dunham, #48807843, 2026-07-06`.
- **Time-travel debugging is oversold.** No filtering, no message exclusion, the list fills from a
  timer, long messages truncate — `antew, #19303396, 2019-03-04`. And replay needs *determinism*,
  not just serializability: "If even one call is nondeterministic, you've corrupted your entire
  replay" — `verdagon, #28331526, 2021-08-27`.

---

## 5. The defences, which are stronger than the complaint volume suggests

- **Frequency, not possibility.** Answering "you must do X for every stateful child", Feldman posted
  a 4 000-LoC open-source SPA where the pattern appears in exactly one file: "The technique you're
  saying 'must' be done in 'every single' case came up a grand total of once in the entire code
  base" — `rtfeldman, #14297669, 2017-05-09`. **The exchange is never resolved.** My read: the
  critic is right that the mechanism has no abstraction, and Feldman is right that at 4k LoC it
  fires once. Neither tests the large-codebase case, and that gap is the real finding.
- **Stop organising the Model by page.** "The solution to this particular problem is to stop
  thinking in terms of page" — `pyrale, #25095717, 2020-11-14` (three years professional). His
  interlocutor ends up half-persuaded.
- **One serialisable value is worth the wiring.** "The great thing about storing all the data in a
  top-level datastructure is that you could dump that entire thing into JSON, send it along in bug
  reports" — `Skinney, #14297675, 2017-05-09`.
- **Explicit state is testable state.** With explicit state you call the view with the state you
  want; with implicit state "at the very least I have to write a driver to run render() into the
  clicked state" — `_0w8t, #18872662, 2019-01-10`.
- **The pre-wired parent.** "from the very beginning, it gives the parent all the hooks it will ever
  need to observe and modify the behavior of children" — `jwmerrill, #10596840, 2015-11-19`.
- **Refactoring is the repeated payoff**, reported by a dozen production users. The one number:
  equivalent refactors took **5 hours in Elm vs ~25 hours plus ~150 new tests in Elixir**, touching
  ~75% of files in each — `jayshua, #34753897, 2023-02-11` (50 000-line app, 2 bugs since launch).
- **Uniformity.** "all Elm apps having the same architecture ('TEA') is one of the biggest wins" —
  `hombre_fatal, #36043447, 2023-05-23`.

The most honest note comes from the other side of the same debate, in 2015, and names the design
target neither camp had: *"Local state backed to global store — Has all the pros and none of the
cons. Unfortunately doesn't exist yet today"* (`nwienert, #10597217`).

---

## 6. Why Elm could not simply add local state

Two commenters — both critics — explain the coupling, and this is the most useful thing in the
corpus for a language designer:

> "local state would invalidate many things in the Elm ecosystem like the time travel debugger …
> you have to write a new reconciler that only renders the things that have changed instead of
> always rendering the entire tree." — `boubiyeah, #14295920, 2017-05-08`

**The whole-tree re-render is what pays for the single Model.** Stated independently a year earlier:
local state would break time travel, "but it would make their 'time travelling debugger' and other
similar tooling stop to work" (`boubiyeah, #13031112`). And from the pro-Elm side, the same
dependency listed as a benefit (`k_bx, #18873859`).

---

## 7. Language complaints, for completeness

Ranked by distinct commenters; these dwarf the architecture complaints.

1. **The 0.19 kernel-code lockdown** (~60+ across shards). Non-core packages may not ship JS, so a
   missing browser API cannot be filled from user space. "Elm prohibits glue code" — `dhucerbin,
   #30038730, 2022-01-22`. The canonical casualty is `Intl`: "Conceptually it's `Float -> String` …
   but you can't use it in Elm anyhow" (`toastal, #22839232`). Multiple people forked the compiler
   to delete the check.
2. **Governance and bus factor** (234). Locked issues, bans, no roadmap, a seven-year release gap.
3. **Type classes — specifically, that `comparable` is privileged** (108). "why is there comparable,
   which quacks like a typeclass and why can only kernel code use it?" — `quickthrower2, #36278977,
   2023-06-11`. Sharpest form: "the API reference lies by claiming things like `(==) : a -> a ->
   Bool`, because it lacks a generic mechanism" — `endgame, #14890020, 2017-07-31`.
4. **"No runtime exceptions" has holes** — `modBy 0`, stack overflow on non-tail recursion, `==` on
   functions, and: "Integers in elm are a lie. I got scientific notation for a float back when an
   integer went over the limit" — `boxed, #26866505, 2021-04-19`.
5. **Ecosystem and breaking upgrades** — 70% of one project's dependencies never left 0.18.

---

## 8. What this means for beni

Ids are from [`plans/browser-decisions.md`](../../../plans/browser-decisions.md). *(inference)*
throughout this section unless a quote is attached.

### 8.1 Four findings beni already answers by construction

- **`comparable` is privileged** (§7.3) is precisely the defect static dispatch removes: a type's
  `eq`/`compare` are its module's `pub` values, derived when absent, with no compiler-blessed caste
  ([`static-dispatch-spike.md`](../static-dispatch-spike.md)). This corpus is ten years of users
  asking for what beni adopted on 2026-09-18.
- **`Int` is a double** (§7.4) is beni's property too — and `core/Int32` is the answer already
  shipped, for exactly the reason the complaint names. The residual gap is that ordinary `Int`
  overflow is still silent; worth a note in `language.md` §2.5 rather than a change.
- **`Html.Lazy` is worthless because identity never survives** (§3.8) is the failure mode **W27**
  exists to prevent. beni's promise — an untouched field of an updated record is the *same object*,
  so a per-hole `===` is exact rather than heuristic — is the structural fix, and this report is
  evidence that the problem is real rather than theoretical. It also raises the stakes on W27: if
  any optimiser change breaks field identity, beni inherits Elm's cliff.
- **The `foreign` wall** (§7.1) is the corpus's dominant grievance, and CLAUDE.md rule 7 is already
  the answer. Note that the escape valves users asked for are exactly rule 7's shape — "A non-default
  CLI flag, a scary compilation warning… Like how you need to use `unsafe` in Rust" (`jgilias,
  #36278533`). One finding sharpens the rule: safety came from the **serialisation boundary, not the
  asynchrony** — a production user gets synchronous, type-safe FFI by encoding and decoding through
  a prototype hack and notes "it's still safe FFI!" (`1-more, #48806400, 2026-07-06`). If that is
  right, `boundary.md`'s two-shape rule could permit a *synchronous* codec-checked `foreign` without
  weakening any guarantee, which would close the `Intl`-shaped gap that drove people out of Elm.

### 8.2 Three findings that transfer and are not yet answered

- **The ripple (§3.1) is the real question behind W24, and it is a question about `Msg`, not
  `Model`.** §3.2 relocates it: what costs is that a child's messages must be named, wrapped and
  routed by every ancestor. Any beni mechanism that lets a subtree own a message type without every
  ancestor naming it would address the single most-reported architectural pain in ten years of
  Elm — and would do so without giving up the one-value model. That is a more tractable design
  target than "add local state", and it is what W24/W20 should be scoped against.
- **Flatten, don't nest (§3.5), with the cause named as a type-system gap.** Convergent advice from
  three production teams, plus the diagnosis that nesting is forced by the absence of extensible
  unions. This lands directly on **W39** (wide model records), whose 17→18-field V8 clone cliff is
  still unmeasured — and the corpus says a flat wide record is what large codebases converge on, so
  W39's measurement is on the critical path rather than a detail.
- **You cannot ship a stateful widget (§3.4).** This is the ecosystem consequence of the no-components
  position and it is invisible from inside a single codebase. It is the strongest argument in the
  corpus for **W20** shipping *something* — even unshipped-but-not-forbidden leaves the package
  ecosystem with no unit to trade.

### 8.3 Two hazards to write into a spec before they are discovered

- **Message-queue ordering (§3.7).** beni has a fiber runtime and an update queue. The Elm defect is
  that the delay between issuing a message and running `update` is undefined, so a snapshot-carrying
  message can clobber a subscription result silently. beni should state its ordering and
  at-most-once/at-least-once semantics in the platform contract rather than let them be discovered,
  and should note that the obvious boilerplate-saving idiom is the unsound one.
- **The renderer assumes it owns its nodes (§4).** Compiled templates have the same exposure as a
  vdom to extensions that mutate the DOM — and a real production user lost real users to it. This
  belongs in **W26/W29** as a stated limitation with a chosen mitigation, not as a surprise.

### 8.4 What the corpus says about scope, given the last two decisions

The frequency table is the argument for the owner's browser-first, no-SSR, frontend-only position
rather than against it. **Server rendering is mentioned at all by 28 distinct commenters of 2 776**
(searching SSR, server-side rendering, isomorphic) — and only some of those are complaints; the rest
are people noting the gap in passing or arguing it is out of scope. Against interop at 188 and
governance at 234, it is an order of magnitude down the list. People did not abandon Elm because it
lacked a server story; they abandoned it because they could not call `Intl`, could not fork a
package, and could not get an issue answered. *(inference)* For beni that reorders the risk
register: the `foreign` wall's escape hatches and the package story are existential; the server
story is not.

---

## 9. Threats to validity

- **Selection.** HN threads exist because someone wrote a grievance post. Satisfied users appear
  only as repliers. The defences in §5 are systematically under-counted relative to the complaints.
- **Staleness.** Roughly half the corpus predates 0.19 (2018-08). Threads from 2016 and from 2023
  are describing different languages, and several complaints here (routing, compile times, bundle
  size, dead-code elimination) were fixed and stopped recurring.
- **The single-Model question is thinly covered**, and three of eight agents said so unprompted.
  §3's nine problems rest on roughly 40 substantive comments, not on hundreds. The counts in §2 are
  mechanical and reliable; the structure in §3 is a reading of a small sample.
- **Governance contaminates everything.** Most "why I left Elm" narratives mix a language complaint
  with a governance complaint, and only the first is design input. They are separated here on a
  best-effort basis.
- **Quotes are verified; conclusions are not.** 38 of them were checked verbatim against the source.
  The inferences in §8 are mine and are marked.

---

## Appendix — citing this corpus

Format: `"author" on HN, "<thread title>", YYYY-MM-DD, https://news.ycombinator.com/item?id=<id>`.
Quote as a report ("several commenters reported X"), never as a fact, unless code or a measurement
confirms it — the standard [`references/talks/README.md`](../../../references/talks/README.md) sets
for talks. Re-collect with the `hackernews` skill; `hn-item.fish <id>` reproduces any thread here in
full.
