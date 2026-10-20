## 2026-10-21 09:00 CEST — type keys: cost, phantoms, schemas, crossing in the check

**What I did.** Finished slice 2 (#489, PR #560) on review feedback from the
stacked slices:
- a key per top-level declaration;
- a quantifier crosses only where the type's representation holds it
  (`backend.md` §9 amended; phantom parameters do not cross);
- a schema's endpoints and tagged payloads join the wild set;
- the crossing pass now reads what `Instantiate` records as it copies a scheme,
  instead of walking the module again.

A run of core or a platform alone, which has no reader for the bits, computes
none, and its cache key says `crossing=0`. Five optimisations of the key walk:
- a nullary-type table;
- a nullary-alias memo;
- an allocation-free text sort;
- records as label pairs;
- one-level types keyed without a frame.

**What I learned.**
- The whole-core `check_test` cases sit at 99.8% of the instruction budget on
  master (4 293M of 4 300M), so any per-module cost in the checker shows there
  first. Every crossing optimisation that kept a separate walk moved them by a
  few million at most. The real fix was not to compute bits nobody in the run
  reads, with the cache key keeping it sound.
- Callgrind on the safe build is the instrument for this: `perf stat` totals
  are deterministic to about 0.5M, but only callgrind says where.
- `git stash` is shared across worktrees of one repository; pop only your own.
- Keys still cost 2.6% of `check` on `bench/corpus` (1.64M of 63.8M
  instructions); the owner's coordinator accepted that.
