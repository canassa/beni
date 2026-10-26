## 2026-10-26 13:19 CET — block codec lane and quotient keys

**What I did.** Answered #1077's review. The block codec's work now goes on
a codec lane: baseline records, reserved before each step, bounded by
`codec_factor`·(S + 16)·⌈log₂(S + 2)⌉ with S the records and edges read
(`codec_factor` = 16, measured max 1.7). The reader's trial is bounded by
the same function of the block's length before it reads a word. Growth is
only a second interpretation of a node and the κ reads it makes, charged
to the class's own declaration (`Options.charges`). The refinement now
refines its quotient again, so bisimilar copies give equal bytes and
write ∘ read ∘ write is write. Keys are sorted by their words, with no
hash and no hash map.

**What I learned.** A size-based lane bound must count everything the
codec reads, not only the records it makes: the owner closure in
`entries` explores states before any position exists, and without
counting them the many-map class broke the lane before it reached the
growth limit. The wasm32 build analyses only what `main` reaches, so a
`u64` index in code nothing calls passed `-Dllvm`. Compiling the files'
tests for wasm32 found two of them.
