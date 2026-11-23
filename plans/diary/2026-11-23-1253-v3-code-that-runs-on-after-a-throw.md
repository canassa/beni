## 2026-11-23 12:53 CET — v3: code that runs on after a throw reads no cell written in place

**What I did**

- Fix lane fix188 on `ownership-v2-design-review`, for #2613: on a page a defect leaves other
  fibers running. A fiber parked in a mask runs on to its next suspension point, and a throw under
  `Task.withScheduler` stops that scheduler alone, so code read a list that an update had written in
  place and then thrown out of.
- Before coding, six more live shapes were found on the base, all wholly accepted and TRAP: the
  frame itself parked in a mask while a writer fiber throws, a caller that masks a function hosting
  a writer (the reverted coarse patch still accepts both), and a detached or root reader of the
  frame's write under another scheduler. Posted on #2613.
- Kernel §13 item 12, *A defect*, (d), then the code (`src/own3/`):
  - `Contract.runs_on` (the body can park its fiber masked or lent: the three named entries, a
    callee or a function run within with the bit, code the walk does not know; JavaScript bodies
    count only through the functions they are handed) and `Contract.hosts` (a writer or reader of
    the body's cell runs in another fiber);
  - `Fn.runs_on` (the work of the three, and a parameter handed on to one) and `Fn.forks`
    (`Task.spawn`, `spawnDetached`, a race's branches);
  - a writer or reader registers only at a fork holder and only with no `runs_on`;
  - a call that can park the frame masked or lent, and every call after it in the body (the
    fiber stays there up to its next suspension point), revokes the frame's writers, and its
    readers where the call writes in place;
  - a hosting function is refused at a use that can mask it, at an unknown holder, and when it is
    called after such a call.
- One Opus reviewer found three more classes, all on the base too: a root scope listed under
  another scheduler (`spawnIn` no longer forks), a reader started by `withScheduler`'s work before
  it parks (readers now count for `hosts`), and code after `withScheduler` returns, which runs on
  that scheduler's drain (the window after the call). All 15 of its live pages are refused now.
- `run/CellRunsOn` and its live twin (base accepts every live shape); `cells.mjs` `runon.*`
  extended to 66 pages: base 30 TRAP, head 0 faults.
- Evidence: root dumps 2 548 roots, 0 root verdict changes (1 920 accepted, 618 refused, 10 exit 1
  on both); verdict lines changed only in 7 already-refused roots. Ledger 309 of 319 on both,
  identical lines. Sweep dump-diff of every cell or fiber program of every sweep (74 658 of 133 963;
  the rest cannot reach a writer): 977 differ, all in `cells`, 35 accepted → refused (26 live
  faults, 9 safe `runon` pages: documented pessimism), 3 refused → accepted (`defect.field.*.dead`,
  safe copies); the 977 under the four legs: 0 faults. v3 on the real roots 2 334 ms → 2 271 ms
  (ReleaseFast). Gates exit 0.

**What I learned**

- "Masked" is not a scope in the source. A fiber's mask and its scheduler outlive the call that
  set them, up to the next suspension point, and they reach into the caller. A rule that follows
  only the calls inside the mask misses the frame's own code after the call.
- Registering a writer at any holder the walk does not follow is only safe while no such holder
  can mask it. Limiting registration to the runtime's fork points removed a whole family of cases
  (unknown values, data, wrappers) that would otherwise each need a rule.
- Batching sweep programs as modules of one project checks core once per batch. A dump-diff of
  74 658 programs then takes about 40 minutes instead of hours. Verdicts match the dumps of each
  program on its own.
