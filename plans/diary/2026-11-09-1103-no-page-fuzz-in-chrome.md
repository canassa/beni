## 2026-11-09 11:03 CET — no page fuzz in Chrome

**What I did.** Took the owner's decision of 2026-11-09 ("disable the
fuzzer test", option 4 of #2340) as #2369. Under `BENI_BROWSER=chrome`
(`zig build test-browser`, CI's `Chrome` job) the corpus walker no longer
adds the `browser/tea` value-fuzz cases, and `fuzzPair` returns null, so a
page case runs its development, release and fiber pages and no fuzz. The
gates (happy-dom) are unchanged: same cases, same fuzz, same digests.
CLAUDE.md, `tests/corpus/README.md`, `build.zig`'s step comment and the
walker's comments say so.

**What I learned.** On dagon, the full `test-browser` went from 1029 cases
in 500 s (the step's run 7 min) to 745 cases in 219 s (3 min). The 284
removed cases are exactly the tea pages, because `no-value-fuzz.txt`
names none today. The walker prints its case count only on failure; I
counted with a temporary print, not committed.
