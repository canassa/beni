## 2026-10-16 07:00 CEST — A host value named once, and conditions instantiated once (#220)

**What I did.** #220's follow-up. I set out to stop the read-off spelling a place inside a JavaScript
value five ways (`π1`, `π1#Just.0`, `π1#NonNull.0` and both orders). Master's "derive what a schema's run
answers from its declaration" (#218) had already removed it: `Todo.replace` is now `π1 R`. I pinned that
with `ownership/HostValueOnePlace`, which shows the five spellings on the commit before it.
Measuring the dashboard again after the rebase found a new cost: N=1024 went from 2.9 s to 6.0 s and
3.2 GB. All of it was in instantiating summary conditions. `instXSum` folded `condAnd` over a result's
spine atoms, which re-sorts the growing set at every atom, and it projected the same wide model again for
every atom. I gathered the atoms and sorted them once, and memoised the projections of a wide value by
slice and path. I also narrowed the safety cross-check of the indexed spine condition to results of up to
8 entries, because `ownership/EntryValueCommand` sits at the 4 300M budget on master.

**What I learned.** Dashboard dump, ReleaseFast: N=256 0.14 s / 75 MB, N=1024 1.42 s / 818 MB. Master
before #220 gave 2.8 s / 2.3 GB and 12.0 s / 3.5 GB there, and refused both. The reports are byte-identical
at every size before and after this change. Much of what remains is the entry's
model-invariant fixpoint, which runs all 32 rounds because it never settles (#229). Fixing that is the
next large saving.
