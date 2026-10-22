## 2026-10-22 18:22 CEST — the second solve measured, and a read of freed memory

**What I did**

- Found out why `specialise` solves twice. Before the second solve, almost every module has changed (77 of 78 on nowd), so module reuse cannot apply. Taking the second solve out, or running it without fact 3, grows the release `run/` corpus by 35.7 kB or by 26.5 kB. Both measurements are on #464.
- Measured part 3 (the rewrite on workers) against its cost. It would save about 3 ms at `--jobs=8` and needs a context for each worker across shared mutable `Spec` state, so the coordinator skipped it.
- Prototyped option 1: the structural passes that need no facts run before the first solve. N = 64 drops 19.6% of its instructions, nowd 19.2% and 100k 14.2%. All three solve once, with byte-identical output. The corpus grows by 88 bytes over 18 programs, all phase-order effects. The prototype is on the local branch `spec-preinline`.
- Fixed the defect the prototype found (#770). `returnExpr` read its body, a slice of `extra`, after a nested conditional's append had moved `extra`. An in-source test with an allocator that never resizes in place panics without the fix.

**What I learned**

- `Mod.extra` starts at exactly the input's length, so the first append to a module always moves it. Code that keeps a slice of `extra` across an append is only safe on master because the first rewrite has already appended to almost every module. Any reordering of passes uncovers these slices.
- On these programs the second solve's work comes from the structural pass, not from cascades of the first rewrite. Re-solving after any rewrite change brought the second solve back everywhere, and the corpus still grew.
