## 2026-10-30 16:07 CET — Worker implementation blockers

**What I did**

Started the implementation audit for PR #1304 on Dagon. Assigned three agents
to the entry runtime foundation, typed callback migration and multi-entry wire
planning. All were instructed to use Zig development builds, avoid /tmp, stop
for language changes or major restructuring, and clean up their own artifacts.
No agent edited code, built a compiler or created a worktree or scratch directory.

The callback audit found the user's stop condition. Task's architecture explicitly
stores scheduler records and callbacks as Js.Value and calls through Js.apply
(core/Task.beni:33–40). Its host and guest conversions erase arbitrary generic
values (:92–98). Pending continuations, the suspension sentinel and heterogeneous
ready-work queues (:110–139, :224–286) depend on that representation. The compiler's
suspension pass emits Task.andThen and Task.isWaiting (src/js/Suspend.zig:14–18).
C therefore needs a major typed continuation and scheduler redesign across the
compiler/runtime boundary, not just replacement of 41 callable-use expressions.
No new language syntax was established as necessary in this audit.

The independent multi-entry audit found a second major restructuring requirement.
Emit selects one entry, performs one reachability elimination and emits once
(src/js/Emit.zig:702, :731, :756). Its Emitter owns one live result and associated
runtime, boundary, field-name and hoisting state. Reach.Input has one entry
(src/js/Reach.zig:289). Isolated page and worker initializers with shared wire
names require separating build-wide planning from per-entry projection and
emission. Extra entry shims cannot establish the specified isolation.

I independently read the cited Task, Suspend, Emit and Reach code and verified
both findings. Stopped all implementation immediately and notified the user.
The #1293 runtime-module foundation was assessed but not implemented after the
stop condition. Its current selection is coupled to markup, while run's full
type and effect contract is not validated by the existing arity-only check.

Only this audit diary is added. No implementation code or tests changed, and
no build or suite was needed to validate a source-only stop finding. The base
44aaab2f4 had green gates and CI from the completed design session. Whitespace
and the diary diff were checked. Findings are recorded on #1294, #1295 and the
PR. Agent-owned cleanup is complete. Manager-owned worktree, branch and scratch
are removed after this diary is pushed to the same PR.

**What I learned**

The decided architecture still entails major changes to existing runtime and
emitter structures. The user's instruction to stop for such changes applies
even when the desired guarantee is already documented. Do not replace native
types with erased values or append worker shims to bypass the restructuring.
