## 2026-10-15 22:50 CEST — schema constructor crash and the ownership-everywhere flag

**What I did.** I did slice O0 of `ownership-checker.md` §30.7 (issue #156), in two PRs.

- **#195** fixes the summary-block crash. It was **live on `browser-direct`**: a pattern on a tagged
  schema's constructor crashed `check` when it wrote cache entries, or when another module read the
  summary. The fix numbers schema constructors after the BIR's own. It adds two red-first ownership
  fixtures and a `.cached` leg in the corpus harness.
- **The second PR** adds the hidden `--ownership-everywhere` flag and `bench/ownership-everywhere.mjs`.
  The script reproduces §30.2's table.

**What I learned.**

- The pass gave every reference it did not know a constructor id with module `none`. A schema
  constructor in a pattern was one of these, so its id came from the instruction. Two patterns on one
  constructor got different ids, and so did two modules' patterns at the same instruction index.
- The crash showed in `--no-cache` runs too, whenever a summary was sealed across a module boundary.
  §30.2 had missed it because its minimal program had no pattern.
- **Putting a flag into the key build id would defeat the embedded checked core.** Every core and
  platform module missed and was checked from source. Conduit's "with the pass" time went from 51 ms
  to 207 ms (a cost of +287 %, not +74 %). So the flag moves the cache into a subdirectory instead.
- The reproduced table matches §30.2 cause for cause: 31 programs rejected and no crashes. There are
  4 more programs than §30.2's 831, all of them landed after #148's tree, and all of them pass.
- `main = … List.set xs 0 9 …` writes a top-level `xs` from `main`, which is itself a top-level value.
  The pass accepts it as a `call` demand, while the same write inside a function is `top-level`. I did
  not dig into it. It is noted in the PR.
