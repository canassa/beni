## 2026-11-19 06:56 CET — ownership v3: records converge, then four precision lanes

**What I did**

- Managed the ownership v3 prototype on `ownership-v2-design-review` (PR #2451) through the records phase.
- Merged `master` into the branch: 26 missing patches, a merge commit, no rebase. `master` had moved `Cmd` into `browser-base`, and the alias lost v3's `sender` word, so v3 silently dropped 200 `send` lines until the word was added back.
- Records converged for soundness: four blind rounds in a row (X, Y, Z, AA) found no fault in about 136,000 programs.
- Ran four records precision lanes (research reports 153, 154, 158 and 159):
  - kept handlers, read-first field hoists and list-pattern parts;
  - a `Hosted.compare` comparer table;
  - constructor parts and joins;
  - a v3-only `position` word, a later via, the entry judged one answer value at a time, and linear budget paths.
- The lanes won back TodoMVC, the chat page, Sternhalma and the GPU code, among others. The real-writes ledger went from 294 to 296 of 308, and no line ever went from accepted to refused.
- Blind rounds between the lanes found two faults that only a platform author could reach: a worded row read as holding a value once (#2557), and a disagreement between the marker and the safe check that panicked (#2559). Reviewers found two older holes. All of these are fixed.
- On `master`:
  - a fuzzer found a type-checker rank panic (#2560). PR #2561 fixed it and #2537 with it.
  - `master` had been red on a stale fixture; the owner chose to keep suspending command bodies on `browser-inline` (#2553, PR #2562).
- Owner decisions:
  - close `Key` (#2552, built as a private comparer table);
  - drop the message-delivery rule for now (#2551).
- My decisions:
  - row words state positions, so a row whose code breaks them is a false row (#2558);
  - v1 enforces evidence refusals in every package (#2556);
  - a `position` word in a v3-only column (#2563).
- Jayson's 29 own2 record PRs were harvested into `bench/ownership-sweeps/harvest-v2-records/` and closed.

**What I learned**

- A branch that lags `master` costs whole rounds: fix152 rediscovered a release bug `master` had fixed two days earlier. Merge `master` before a convergence loop, not after.
- A refusal hides every other write in the same program from the four-leg oracle. Blind rounds that hunt wrong acceptances must use wholly accepted programs; the random fuzzers that repair programs until v3 accepts them found more than hand-written grids.
- Precision lanes that only win fixtures (lane 3) are a warning sign. Measure every lane by the real ledger and stop the phase when the remaining rows need a design of their own (`Dict` positions belong to the Dict phase).
- Two readings of the same words, one in the marker and one in the safe check, will drift. Share one function.
