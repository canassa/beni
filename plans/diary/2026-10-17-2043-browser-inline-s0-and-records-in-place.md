## 2026-10-17 20:43 CEST — browser-inline S0, and records in place

**What I did**

I managed slice S0 of #295 (#296) as manager, planner and validator: one Opus planner, one
implementer, and four read-only reviewers, with every deviation taken to the owner.

- **The platform.** It is `platforms/browser-inline`, beside `browser-direct`, which stays as the
  reference. It landed in PR #325 as 53 commits.
  - It runs with no task kernel and no `Dict`, and exports `stop`.
  - A layer module's subscription start is lifted in its own module and fused in release.
  - A `read` whose error nothing reads compiles to a validator.
  - `read` sees the keys ordinary JavaScript access sees.
- **General release-optimiser work:**
  - a `case` is fused across a call, gated by a node-count proxy;
  - a function called once in another module is taken in;
  - reachability runs after the optimiser;
  - a single-use arrow is placed at its use, with eta-reduction;
  - a short `switch` on literals becomes `if`s;
  - `String.fromInt` inside a template is written as the `Int`.
- **The bar.** The owner pinned it once on the final build: EmptyElement 289 B, EmptySandbox 303 B,
  PushAndTimer 589 B brotli. For comparison, `browser-direct` ships 752 B empty and 7 065 B with
  these subscriptions.
- **The reviews** found two release miscompiles. One read a literal from freed memory when it was
  copied within its own module. The other folded a binding into a `for…of` head, where the loop
  variable captured it; that one was already on master. Both have `run/` fixtures.
- **Owner decisions taken on the way:**
  - D3 is synchronous: one write pass at the end of the dispatch.
  - `Dict` is the keyed collection: an ordered entries array plus a `Map` index, `Int` or `String`
    keys, `eq` includes order, no `compare`, and `List` is positional with no recogniser.
  - D5 is deferred to S4. D6 is an error until S6, where Conduit adds per-row registration.
  - D7, §8's ledger, is confirmed.
  - Refusals are of two kinds: compiler limits, which are temporary, and language rules, which are
    permanent.
- **Ownership.** The owner restated that the checker, in-place lists and in-place records are the
  base language, with no limits and no precision loss. I opened #317 as the parent, #318–#322 for
  O2–O6, #315 for the record checker work (Zig) and #316 for the record oracle (Lean, assigned to
  Jayson). The record spec is PR #327: `ownership-checker.md` §31. An unproven update is an error.
  Liveness is judged per field, and the lowering hoists written-field reads. Calls follow the
  callee's summary. The explicit copy is `{ Record.copy r | … }`. Its static measurement finds 9
  programs certainly refused, out of 1 050.
- **Other work started.** The no-limits fixes (#286 first, then #289 and #293) are running on
  `ownership-no-limits`. The research `beni-inline` entry is being measured into a scratch
  directory, for the owner's `./rr serve` check.
- **Jayson's PRs.** Eleven of them were merged on the owner's word.

**What I learned**

- **The plan and its numbers.**
  - The hand-written target (437 B) was optimistic, because it left out guarantees the owner keeps:
    own-property checks, the `!dead` check, and the guard's queue.
  - My hand attribution of the gap by cumulative edits was the useful number. It said which levers
    were the compiler's to pull (the fused validator's sentinel threading was worth 67 B) and which
    were structural.
- **Reviews of general optimiser rules find miscompiles that goldens miss.** Both bugs passed the
  corpus by luck, once through spare buffer capacity. Every round that touched `Spec.zig` or
  `Opt.zig` got its own review before the PR, and two of the four rounds found a bug.
- **The owner's ownership rule is stricter than the docs read alone.** I proposed a spread fallback
  for records, and Rust-style coarseness for the path cut. Both contradicted rules already in my
  memory ("never a copy", "no precision loss"). Read the ownership memory before proposing anything
  in that area.
- **"Already decided" may be decided and not built.** On master, O0 is built, O1 is open, and O2–O6
  had no issues at all, while the language-wide decision was a week old. S2 depends on O5, which
  nothing tracked.
- **The research harness pins one commit for every beni framework,** so moving it for
  `beni-inline` moves `beni-tea` and `beni-direct` too.
