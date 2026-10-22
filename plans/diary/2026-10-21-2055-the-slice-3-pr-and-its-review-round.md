## 2026-10-21 20:55 CEST — The slice-3 PR and its review round

**What I did.** Pushed `emit-cache-read` and opened **#631** (`Part of #94`) with the counter table
and the #629 finding. Rewrote the PR body and the five commit bodies in STE before the review ran
(a scripted `rebase -i` reword; the tree hash stayed identical, so the gates' verdict carried
over). The Claude review found no blocker; its one real question was whether the row's canonical
edges are safe for a declaration this build **lowers** — `siteTops` reads the module's own BIR,
dispatch table and schema plans, and `Edges.termsEdges` "reads only the two tables it is handed"
(it has no effect leg yet), so the row's edges are the build's edges and only the root set
differs, which `replayOrder` takes from this build. Wrote that proof into `replayOrder`'s comment,
plus comments for the `.markup`/`.steps` facts, the `seedReuse` invariant, the `wanted` loop and
the map normalization (comment-only commit `8f0a5a0b1`, gates green). Opened **#633** for the
deferred `perf stat` measurement and answered every finding on the PR. Every CI check passed on
`8f0a5a0b1`: tests (no budget), examples, playground wasm-against-native, lean, claude-review.

**What I learned.** The review's sharpest question had its answer in a module's own header
comment — the proof was one grep away, but the next reader stands at `replayOrder`, so the comment
belongs there. The automatic `claude-review` run posts nothing; an explicit `@claude …` comment
gets a real review in under a minute. And commit bodies are durable artifacts: rewriting them to
STE before the PR opens costs one scripted rebase and no CI cycle, while rewriting after the PR
is open costs a full CI restart.
