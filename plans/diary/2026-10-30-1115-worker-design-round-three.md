## 2026-10-30 11:15 CET — Worker design round three

**What I did**

Revised the same PR #1304 and branch on Dagon only. Added a three-way comparison
of manually authored typed wrappers, the retained hidden-provenance mechanism,
and generated real beni native types. Recommended the last without adopting it;
owner decision #1315 gates #1295. The migration CSV preserves all 726 native/mixed
census rows: 556 native, 130 callable-dependent and 40 other mixed paths.
Specified compiler/interface/cache costs, diagnostics and erased release-byte
acceptance goldens, including the substantial typed-container migration cost.

Made Worker.program borrow stable state and removed consuming-state retirement.
Separated call/stream requests under a type-only protocol alias across dedicated,
shared, pool and machine APIs and generic entry-kind type-role paths. The example
cancels a stream and then calls the same worker again. Runtime run is explicitly
impure and non-suspending: it starts an owned Task root; init suspends there.
Updated adjacent boundary/backend amendments, ownership guidance and slice issues.

The requested new adversarial reviewer found an untyped-intake ambiguity in
option C, an overstatement about IDL event callback subtypes, and a constructor/
type-name typo. Fixed all and the follow-up error-union spelling. Unknown intake
now uses privileged Host.Raw quarantine and exact native/data validation, never
a cast or a fictitious Proxy detector. The reviewer rechecked all findings and
migration totals and confirmed no remaining blockers.

Full `nix develop --command zig build gates` returned exit 0 on Dagon. Subsequent
changes are documentation clarifications only. Diff whitespace, new local links,
fences, section-number preservation and census migration totals pass. APIs remain
proposed, not compiled; no implementation or performance result is claimed.
Final-head CI is awaited after this commit; its result and removal of the owned
Dagon worktree/local branch/scratch will be recorded on the PR after completion.

**What I learned**

Typed native objects avoid a parallel shape-flow system only if callbacks,
containers, builtin callables and raw host intake cannot erase the ordinary
types. WebIDL callback Event does not establish an event-name subtype mapping.
Stable borrowed state is the right cancellation default for expensive worker
resources; serial admission supplies ordering without consuming the state.
A protocol record used only as a type argument groups six roles without a new
associated-type feature or a runtime object. The actual emitter calls run
synchronously, so a non-suspending root-fiber starter makes that contract clear.
