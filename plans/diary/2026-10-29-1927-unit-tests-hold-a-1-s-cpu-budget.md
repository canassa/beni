## 2026-10-29 19:27 CET — unit tests hold a 1 s CPU budget

**What I did**

- Timed all 912 unit tests once. Six were over 1 s, all in `src/own2`, each because of its fixed size.
- Brought each under the budget without weakening what it proves:
  - two deep-recursion tests now use a smaller depth on a proportionally smaller stack;
  - the growth curve runs at half its old sizes (the test compares ratios);
  - the exhaustive mutation sweep is split into thirds;
  - the random sweeps and the variants are split into tests of their own.
- `build.zig` now gives the unit tests `BENI_TEST_BUDGET_MS=1000`. The runner fails any test whose
  CPU time is over the budget, naming the test and the cost. A gates probe pins this (#1197).

**What I learned**

- Under a load average of 25, CPU time still matched wall time for these tests. They are slow by
  their own work, not because of contention, which is why the budget is on CPU time.
