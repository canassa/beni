## 2026-09-20 21:36 CEST — report 30: what Elm's users complained about, 2011–2026

**What I did**

- Built a corpus with the new `hackernews` skill: searched `"elm"` as an exact phrase, took the
  first five pages of relevance-ranked stories (100), kept the **80 with ≥ 20 comments**, and
  downloaded every comment tree in full — **7 285 comments, 2 776 distinct commenters, 2011–2026**.
- Fanned out **8 agents** over byte-balanced ~450 KB shards, each reading its shard in full against
  a fixed schema (distinct-commenter counts, date ranges, verbatim quotes with ids,
  production-vs-speculation flags, and the counter-case). Ran a mechanical term-frequency pass over
  all 7 285 comments separately, so the frequency table is measured rather than inferred from eight
  partial views.
- **Spot-checked 38 load-bearing quotes against the source. Every id, author, date and wording
  matched exactly, in all eight shards.**
- Wrote [`docs/design/research/30-elm-complaints-on-hackernews.md`](../docs/design/research/30-elm-complaints-on-hackernews.md).

**What I learned**

- **The premise of the question did not survive the data.** Counting distinct commenters:
  ecosystem 480, governance 234, ports/interop 188, forks 141, "dead" 119, type classes 108,
  0.19 breakage 97, boilerplate 77 — and **centralized state, named explicitly, 20**. People left
  Elm over interop, governance and ecosystem, not over TEA. Three of eight agents opened with an
  unprompted caveat that their threads were thin on the state question.
- **Where the state pain does show up, it attaches to `Msg`, not to `Model`** — "The Model for that
  is pretty straightforward. It's just a tree of data. The Msg for that is what is being complained
  about" (phamilton, #12076766). That relocates beni's open question: the tractable design target is
  letting a subtree own a message type without every ancestor naming it, *not* adding local state.
- **Two mechanical findings, not ergonomics.** (1) The message queue can silently drop a message,
  because the delay between issuing and `update` is undefined — and the idiom people reach for to
  cut `Msg` boilerplate (a coarse `SetModel`) is exactly the unsound one (dwohnitmok, #25098676).
  (2) A whole-model rebuild destroys the reference identity `Html.Lazy` tests on, making it
  "worthless" (Existenceblinks, #28223910) — which is the exact failure W27 exists to prevent, so
  the corpus is evidence that beni's identity promise is load-bearing rather than theoretical.
- **Four complaints beni already answers by construction**: privileged `comparable` (static
  dispatch removes the caste), `Int` is a double (`core/Int32` shipped for that reason), the `lazy`
  identity cliff (W27), and the `foreign` wall (rule 7) — where the escape valves users asked for
  are rule 7's exact shape, "a scary compilation warning… like `unsafe` in Rust".
- **One finding that could change `boundary.md`:** a production user gets synchronous, type-safe FFI
  by encoding/decoding through a prototype hack and argues "it's still safe FFI!" — i.e. the safety
  came from the **serialisation boundary, not the asynchrony** (1-more, #48806400). If that holds, a
  synchronous codec-checked `foreign` closes the `Intl`-shaped gap without weakening a guarantee.
- **Costs get pushed out of the program**, which is the strongest evidence that centralization has a
  real price: one compiled build per language to avoid threading i18n through the model (#19302138),
  a JS code generator emitting `main.elm` (#13620638), an 800-line diff to display a timezone
  (#26865296).
- **I got a number wrong and caught it in review.** I wrote that SSR appears "from perhaps five
  commenters"; the measured figure is 28 distinct authors. The direction held — it is still an
  order of magnitude below interop and governance — but the figure was invented rather than counted,
  in a report whose whole standard is that figures get counted. Corrected before commit. Count it,
  then write it.
