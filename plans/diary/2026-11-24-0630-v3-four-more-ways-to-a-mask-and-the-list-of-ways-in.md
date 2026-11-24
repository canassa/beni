## 2026-11-24 06:30 CET — v3: four more ways to a mask, and the list of ways in

**What I did**

- Fix lane fix206 on `ownership-v2-design-review`, for #2653 (code reader CR7 on 87e622129c): three
  soundness faults of kernel §13 item 12 (d), and a fourth that a probe found.
  - F1: a started closure that runs a captured or handed function which forks a hosting fiber, then
    one that masks. `startedAt` asked `siblingRunsOn` only in the other order. Now either order;
    the lane's reviewer then found a sibling that masks through a lambda over the helper's own
    function parameter (`k = λn → g n`), now `valRunsOn`.
  - F2: the `send` exemption of `forked_refusal` keyed on the `Cmd.Send` type. Removed: the
    runtime's `send` reaches only a body the platform loses, which is refused where it hosts, so
    the exemption only ever exempted user functions. Blind round CF's `send Done` refusal agrees.
  - F3: `Task.scope`'s close runs deferred finalisers masked through a JavaScript reference
    (`afterDeferred` → `deferral.run`). `scope` has `Contract.runs_on` by name (`runsOnBody`);
    `within`'s scopes have no deferred finalisers.
  - F4: a helper that forks a writer and a reader of its own cell and returns, then a mask in the
    caller. `hostsCall` now sets `hosts_forked` (also closes CR7's U1, `jsArgsRunOn`).
- Kernel: amendments to *After such a call*, *Descendants of a masked fiber* and
  `Contract.runs_on`; the table's rows 1, 3 and 9; and *The ways in, from the code*: every mask,
  lend, scheduler slot, stored-function application, finaliser list, hook registry and `within`
  user in `core/` and the platforms' runtimes, each with its row. Only the deferred run was unseen.
- Fixtures: `run/CellScopeClose` (+Live) and `browser/inline/CellSendTyped` (+Live), each live twin
  accepted by the base; the mains of `CellRunsOn*` and `CellParkedOutside*` now run each shape in
  a fiber of its own (their main called a hosting shape and then a masking one). `cells.mjs`
  `runon.frame` +10 shapes, rooted at `init` by `Task.start`: base 9 TRAP, fix 0 faults.
- Evidence: root dumps 0 verdict changes on real roots; ledger 309 of 319, rows identical; sweep
  dump-diff of 50 204 programs (Ref and fibers): 71 dead twins accepted → refused, all `Task.scope`
  shapes of `cells.mjs` (the pessimistic side), 0 refused → accepted, the 336 changed programs
  REFUSED on the four legs. Precision debt: #2661.

**What I learned**

- An exemption decided by a type is a claim about who calls the function, which the frame cannot
  see; the caller can. Here no caller ever needed it.
- The runtime reaches its own masks through JavaScript references the walk does not follow: a
  list of ways in has to be made from the runtime's code, not from the contracts.
- LLVM ReleaseSafe dumps ran about four times faster than the self-hosted ones on a loaded machine;
  a long sweep should start on them.
