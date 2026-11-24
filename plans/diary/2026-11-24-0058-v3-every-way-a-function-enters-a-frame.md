## 2026-11-24 00:58 CET — v3: every way a function enters a frame, and a masked fiber's children

**What I did**

- Fix lane fix198 on `ownership-v2-design-review`, for #2633 (code reader CR6 on c37563221f) and
  #2638 (blind round CA, 142 pages), both soundness faults of kernel §13 item 12 (d).
- Kernel first: a table of every way a function value enters or leaves a frame (own parameters
  and captures, functions the frame makes or names, calls, method calls, `where` evidence, data and
  cells, answers, code the walk does not know, core's holders) against *Down*, *Up*, *In the frame*
  and *After*, each cell with the code that answers it and a `cells.mjs` page; and a new bullet,
  *Descendants of a masked fiber*.
- Three cells were holes, now closed in `src/own3/Frame.zig`:
  - hosting `where` evidence is refused where it is bound, unless derived code runs it within
    (`evidenceAt`): no contract says what a callee does with its evidence;
  - the frame's own function parameter run within a call beside a function that can mask or lend
    gets `Fn.runs_on`, in either order (`within_known_calls`, `within_own`);
  - a hosting function started in a fiber of its own makes the frame hosting, and no later call
    may mask or lend (`Contract.hosts_forked`, `noteHostsForked`, `forked_refusal`), since the
    page's defect stop does not reach a fiber whose ancestor is masked at the throw.
- `cells.mjs` `runon.frame.*` 98 → 172 pages (evidence, own parameters after a lend, partials,
  answers, cells, constructors, core's holders, recursion, masked children): base 18 TRAP, head
  0 faults. `run/CellRunsOnWays` and its live twin (the base accepts all 13 refusals).
- Evidence: root dumps 2 554 roots, 19 differ, 0 verdict changes on a real root (only the new
  fixture and `hosts-forked` summary lines); ledger 309 of 319 before and after, identical lines;
  sweep dump-diff of 137 010 programs: 5 688 differ, 50 verdict changes, all accepted → refused
  in `runon.frame` pages, and those 50 refused on the four legs; blind round CA's 140 trap pairs
  refused (live) and SAME (dead). One Opus reviewer attacked the table: no fault; one safe
  synthetic shape newly refused (a command that forks a worker whose child writes a cell the
  worker reads), with the other precision debt in #2644.

**What I learned**

- Fixing the holes one reader at a time kept missing the next way in. Writing the whole table first
  showed that only three cells were open, and that most ways in reduce to the default use.
- Evidence is a function that enters a callee with no contract at all: it must be judged at the
  binding as the default, or given a contract of its own.
- `Fn.forks` "whose stop stops it" was a claim about the runtime that the page broke: a masked
  ancestor keeps its children alive. Facts about the runtime need a runtime proof with no cells.
