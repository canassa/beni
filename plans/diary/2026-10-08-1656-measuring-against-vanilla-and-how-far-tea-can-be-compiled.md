## 2026-10-08 16:56 CEST — Measuring against vanilla, and how far TEA can be compiled away

**What I did** (as manager; work now lands through GitHub PRs reviewed by Claude)
- Re-measured the merged renderer against Solid 1 and vanilla JS on every sweep and the table
  benchmark, with bundle sizes per page. I fixed the scaling harness, which reused pages a
  previous compiler had built, and corrected research 56 §9.9's mislabelled "master" column, the
  PR #3 body and the handover.
- On the owner's question, why not compile down to vanilla, a Fable agent wrote an adversarial
  review (research 58). It found TEA is not the obstacle and recommended message-indexed
  rendering with kill criteria. Three Opus spikes followed:
  - research 59: real-click untraced timing shows research 58's "0.035 ms plumbing" was mostly the
    trace; beni is 7.7 µs over P2, 6.8 µs of it removable. V8's 1 020-property limit is
    confirmed. The table app's bytes are attributed part by part.
  - research 60: hand-written message-indexed pages (P3). The renderer reaches about 1.2× vanilla;
    all three kill criteria are missed, every miss in the model half (`List` cold paths, the depth
    page's per-level update functions, core `List` bytes). The agent's proposal to restate the
    criteria is the owner's call; I recommended keeping them as the unmet overall bar.
  - research 61: 231 TEA constructors, none with an unbounded write set. Real apps are about half
    `List.map`/`filter` idioms; the corpus is mostly our own fixtures.

**What I learned**
- The Chrome trace multiplies every subject's per-message time about 4–5×. A constant measured
  only traced can send work after the instrument; real clicks timed in the page are the honest unit.
- A spike that misses its criteria can still be the most useful result. The point was where the
  gap lives, and it now lives in the model and `List`, not the renderer.
- In this environment Chromium needs `LD_LIBRARY_PATH` unset; `pgrep -f` with a pattern also in the
  current command line kills the command itself; a stray `MERGE_RR.lock` race interrupts rebases.
