## 2026-10-27 00:49 CET — item 6: a forwarding lambda is its callee (#1111)

**What I did.** Specified `backend.md` §9's *Item 6 — a forwarding lambda is its callee* (the review
of #1116 measured `Hosted.key`'s `λa b → a.compare b` at +3.2–3.4 % in release on a page that makes
1 000 keys per message), then built it: `Opt.eta` records a plain arrow whose body is exactly
`return f(p₁ … pₙ)` over its own parameters as its callee's `ident` in the plan's node table, when `f`
is a parameter nothing assigns, a top-level `const`, function or import, or a local `const`;
`Print.resolve` follows the plan at an `arrow` as at an `ident`, two steps at most. Fixtures
`emit/release/core/EtaReduce` and `run/EtaReduce`. Against master `d331cb7da`: 296 `browser/` pages
−348 B brotli (73 smaller, 203 equal, 20 larger by 1–31 at fewer raw bytes), 643 node lines −614
(151/446/46), 19 `size.mjs` pages −23; every moved line has fewer raw bytes, the common one the fiber
runtime's `()=>e()` → `e`. Seven release goldens move, each a forwarding arrow printed as its callee;
no development golden moves. Gates at `-j4` green; the full-width gate dies at heavy-run's 10 GB cap
since the v2 differential joined it (9.5–9.9 GB at `-j4`).

**What I learned.**
- Three forwarding shapes I expected to stay were already gone or reduced for other reasons: a tiny
  callee (`a + b`) is written in place inside the lambda before item 6 sees it, so is a private
  function called once (as a loop when recursive); a lambda forwarding to a function made once and
  returned reduces to that name (item 1 moves a function into a later statement, not into an arrow's
  body); and a tail-call loop forwards to the per-iteration copy of its parameter, which nothing
  assigns, so the loop case reduces while the parameter itself is excluded. A fixture header must
  describe what the build does, so the golden was read first and the header written after.
- A `where` clause's evidence is a leading parameter and `viaEvidence _ = λx y → x.compare y` is
  `a=>a`: the unused parameter is dropped and the lambda is the evidence.
- Brotli on a 6-byte deletion moves either way by up to ±31 bytes; 69 of 958 lines grow while every
  one of them has fewer raw bytes. The reading of R47-3 for this is `runtime-in-beni-q1`, still open.
- Zig: a per-declaration `bool` slot behind the stamp needs its own reader; reading it through the
  `u32` one is a compile error the first build finds, not the review.
