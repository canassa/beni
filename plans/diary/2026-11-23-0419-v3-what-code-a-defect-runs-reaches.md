## 2026-11-23 04:19 CET — v3: what code a defect runs reaches carries the defect bit

**What I did**

- Fix lane fix186 on `ownership-v2-design-review`, for #2609 (code reader cr4's F1): a helper
  `install f = Task.onDefect λ⊤ → f ⊤` lost `Fn.defect`, so its caller's reader of a cell stayed a
  reader and a write in place before a throw was accepted (TRAP, in place DIFF).
- Kernel §13 item 12, *A defect*, amended, then the code (`src/own3/Frame.zig`):
  - the bit goes down every use below code a defect runs (`Use.defect_above`, set by `innerUse`
    and on the default use `flowCode` makes where a holder loses the function; in `FlowKey`);
  - (a) a function with `defect` on its own parameter is refused as a value (`paramsDefect`), so
    `Task.onDefect` never reaches an unknown callee: blind round BT's other direction (a record
    field, an `if` with a lambda, a cell, a list pattern, `Log.setSink` in a record) was already
    refused by it when the manager sent it;
  - (b) code a defect runs that captured a value that can hold a function: each used function
    parameter gets the bit (a field, an element, a cell's contents, a type variable can hold a
    closure over it: the reviewer's `b = { h = λ⊤ → f ⊤ }`), each lost one for an opaque value;
  - (c) `onSchedulerIdle`, `onSchedulerCount`, `stopScheduler`, `onShutdown`, `shutdown`,
    `chainDefect` and `Log.withSink` named as hooks.
- `run/CellDefectReach` and its live twin (proven against the base binary), `cells.mjs`'
  `reach.*` (108 programs) and `runon.*` (36 pages, #2613, open). Opened #2610 (masked fibers),
  folded into the manager's #2613.
- Evidence: root dumps 4 of 2 547 differ (core's hook words, the two new fixtures, one summary);
  0 accepted → refused. Ledger 309 of 319 on both, identical lines. Hook-mentioning sweep
  programs (5 731 of 136 410; core's only contract changes are the hooks) dump-diffed: 71
  differ (66 new `reach`, the fixtures, 1 summary, 2 `nested-arms` that were identical on 12
  reruns and are LIMIT on both), all run under the four legs: 0 faults. Families: base 80 TRAP
  (48 `reach`, 32 reviewer programs), head 0 of 322. v3 on the real roots 6 882 vs 6 979 ms
  (ReleaseFast, load 60+).
- One Opus reviewer: one fault class (a closure over the parameter inside data; 5 programs,
  fixed by (b)), two precision notes.
- #2613 tried and reverted: naming the masks' and `withScheduler`'s work as hooks closes BS's
  programs and `runon.*`, but cascades through `bracket`'s acquire and type-variable captures
  and newly refuses 16 real page roots (`Cmd.perform`, `Cmd.keyed`, `Sub.listen` as values).
  The design for the next lane is on the issue.

**What I learned**

- "Lost" and "defect" are two different facts about an unknown holder: a lost function runs at
  switch points only as long as no hook installer can ever be an unknown callee, which is what
  makes refusing installers as values the load-bearing rule.
- A broad `held` rule is cheap to state and expensive in platforms: generic code captures type
  variables everywhere, so the rule must be split by what can actually hold a closure.
- An export of the source taken before the last edit gave a ReleaseFast binary that disagreed
  with the safe one; compare build ids before trusting a ledger.
- The check_test "fifth blind test" timeout fires on base as well under load 60+ (base 106-110 s
  for its 20 cases vs a 120 s guard): #2603.
