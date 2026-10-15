## 2026-10-15 18:24 CEST — Inline start-up reads; price the local transforms

**What I did**

- Built research 102's item 2 as `backend.md` §9's slice 10
  (`Spec.inlineReads`). Under `--release`, a top-level `const` whose
  initialiser only makes a value, whose name the program mentions once, is
  copied to that mention when the mention is in a later top-level statement
  of the same module and start-up evaluates it exactly once. Every local of
  the copy gets a fresh name, and `prune` drops the declaration. Conduit
  release brotli: tea 31,745 → 31,471, direct 38,243 → 36,456. Both beat
  the research prototype (−180 / −1,577). The three Conduit corpus scripts
  give the same transcripts. `bench/size.mjs` release total 723,980 →
  723,908, and development output is byte for byte the same. The `bench/ui`
  app's release bundles do not change at all, on either platform.
- Fixtures: `emit/release/app/InlineStartReads`, and
  `run/InlineStartReads`, which turns red when the inert test is removed
  (logged values move past each other). The build test for the release map
  has new short names.
- Priced item 8 (quote choice) and item 4 (Terser-style local transforms)
  one at a time on the post-slice-10 bundles. None saves on both Conduit
  platforms, so none is built. The table is in §9's *Explicitly not built*,
  and `bench/output-size/transforms.mjs` reruns it.

**What I learned**

- Item 8 flipped sign after item 2. The fewer-escapes quote was −123 on
  tea in research 102. It is +12 tea and +124 direct on today's bundle.
  On the `missing key "x"` messages, mixed quotes break brotli's matches.
- Writing a function where it is called was worse than keeping the call
  (35 brotli bytes on direct). Slice 10 therefore skips callees.
- Terser's `conditionals` and `booleans` save bytes on Terser's own reprint
  but lose on beni's spelling. Price a minifier option on the compiler's
  real output, never on Terser's.
- A per-scope global skip set in `Rename` saves 1,815 bytes over the
  `size.mjs` corpus and shrinks every empty page. It still loses 24–60
  bytes on the three largest browser apps. If anyone revisits it, the
  question is why large apps prefer the declaration-wide set.
