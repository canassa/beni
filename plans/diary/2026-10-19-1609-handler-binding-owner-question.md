# Handler bindings need an owner decision

Continuing #295 management through native Codex agents on the Mac and SSH edits on dagon. Lean remains paused.

## Merged

#465 merged the validator call-site work as a23c066ca after reference-host full gates, CI, and GitHub review. Original #454 and intermediate #461 are closed. #460 previously merged the send demands; #462 merged the corrected bound argument. #463 recorded the earlier owner approvals. #449's clean retirement successor is staged against the new master and queued for combined hashes, gates and pending checks.

## Owner question: helper arguments captured by events (#466)

The helper-call probe is red before any implementation: `helper (Debug.log "argument" model.value)` binds `n`, renders a button with `onClick={Pick n}`, and displays `n`. Current #436 head a719f4266 logs the argument at rendering and again before each click's `update`. Both development and release do this. Ordinary eager-call/closure behavior reads the existing binding at dispatch rather than executing the argument expression again. Exact source and transcripts are preserved under `/home/canassa/.cache/beni-codex-helper-review/`; #466 records the defect and the assigned implementer.

I recommend evaluating helper arguments in source order at the selected source helper call, retaining the values read by its handlers until relevant reevaluation or arm exit, and letting dispatch read those bindings. Successful reevaluation publishes current bindings together; failed preparation publishes none. Arm exit/teardown ends retention, hidden updates do no argument work, and reentry computes fresh current-model values. I recommend making inactive-arm handlers inert, including their event modifiers, so they neither send nor access invalidated bindings. The ownership implications must be validated against the existing checker contract.

This adds handler state across dispatches beyond the invocation-local preparation approved for #459. It requires an explicit amendment to browser-inline §8.2/§8.4 and plan §9 under the no-persistent-memo condition; it is not authorized as a silent implementation detail. May the plan adopt this scoped handler-binding lifetime and inactive-event behavior, with the ownership guarantees and size bars unchanged? That is the recommendation; no general derived memo mechanism, source refusal, copying fallback or reduced measurement bar is proposed. Dependent production implementation is paused pending the owner's answer.

## Other running work

#459's selected-arm change is pushed in #436 as a719f4266. Its permanent hidden-effect/current-value/throw-order fixtures, full hashes, self-hosted gates and LLVM gates pass. Fresh GitHub review requested two classifier consistency comments/fixes and additional partial-argument/event coverage. The event probe found #466, so the event representation is awaiting this decision. The required two-app byte-identity measurement remains unverified.

#464 is localized to specialization's first points-to analysis. Debug/Safe builds grew to gigabytes, and the actual benchmark ReleaseFast compiler reached 4 GiB in a deliberately stopped 3-second N=64 diagnostic. This is not a completed fit or proof of eventual failure. The implementer has a red-before/green-after bounded-allocation regression for redundant immutable unions, and is testing dependency-pool lifetime in the existing fixpoint arena. No cap, skipped analysis or benchmark-flag change is involved.

#456 remains an isolated spike, not production-approved. Revision 3 extends the same value-scoped construction condition through #379's marker to constructors, tuples and records; all required initial controls pass. Core costs are 4,881,071,561 and 4,864,976,861 instructions, against baselines 4,275,523,142 and 4,261,552,039, each over the unchanged 4,300M budget. Its full 5,536-unit comparison is running; partial results are not a zero-delta claim. The proposal and precise invariant are under `/home/canassa/beni-codex-evidence/ownership-soundness/proposal.md`. No production code or normative spec change from this spike is pushed.

The owner requested `/tmp` cleanup and deletion of old artifacts. Eighteen inactive historical binaries and six generated cache/output directories were deleted. `/tmp` then had 6.6 GiB free (19% used); current evidence was relocated to `/home` and active files/lock inode retained. New large evidence goes on `/home`.

The last completed beni fits remain the handoff figures: unique-components 2,328 + 274.4 B/widget against tea 2,025 + 146.1; big-component 2,068 + 92.7 against tea 1,552 + 71.8. No new completed beni fit or validation line is claimed.

## Owner response: approved with corrected framing

The owner approved #466 and rejected the proposed exception framing: this is ordinary source handler-binding semantics. The handler's message, with its bound argument inside, is built during view and lives on the node until the next view. Amend §8.2 to state that bound arguments are part of the handler binding and share its lifetime: refreshed when the binding reruns, gone when the arm exits. There is no general memo exception or addition to plan §9.

The owner requires complete refresh dependencies, including arguments read only by handlers; a fixture must update such an argument, click, and observe the new message value. Proven pure, total arguments may instead be recomputed at dispatch when that is smaller; effectful or possibly throwing arguments must be retained. Inactive-arm handlers are inert, modifiers included, as a node outside the view has no handler in TEA. Bindings are distinct per call occurrence. Ownership guarantees and both measured size bars (`unique-components`, `big-component`, `--lists none`) stay unchanged. The implementer has the corrected decision; the earlier memo-exception recommendation is not the approved design.

## Later validation and restart

#436 now has green combined hashes/gates at fe17728a7 and a fresh GitHub review request. Its #466 coverage includes effect timing, handler-only refresh, separate call occurrences, inactive detached-node modifiers, throw-before-publish, and a real private partial primitive exposed only in an isolated test core. Both required scenario measurements remain unverified, so #436 stays held. #470 tracks a separate pre-existing direct event-message timing defect; it is not claimed fixed.

#469 merged at b19b91643 after root validation, green GitHub checks, full reference-host hashes/gates/LLVM gates, and answered review notes. It reuses containing immutable union slices and allocates dependency records in their fixpoint arena. No output hashes changed. Exact-flags ReleaseFast N64 was intentionally stopped at4,237,740KiB/31.655s; this is not a completed measurement or proof of eventual failure, and #464 remains open. The continuation experiment is isolated and tests exact dependency-reader word storage without changing facts, scheduling or limits.

The #456 full R3 comparison completed5,536 units:10 intended alias-family changes,6 preservation regressions,4 rejection-cause changes. DictFocus and SplitCap regressions fail the owner's bar; R3's unchanged-budget core costs also fail. Later isolated experiments restore SplitCap but not DictFocus. A proposed endpoint-correlation representation refinement is written for review, not implemented or production-approved. No trusted-Dict exemption was implemented. Exact-master verification of a newly reduced nested tuple/Dict alias program is assigned separately.

#468 is the clean retirement successor to #449. Its original validation is green; GitHub review identified remaining live benchmark selectors/readers and documentation cleanup. Those findings are assigned to the implementer before merge. #467 records the already authorized threshold25-to29 follow-up, queued after the review cleanup.

The owner correctly observed an idle period: two agents had completed and no build/test processes remained on dagon. Root resumed their next assignments and continued manager validation; a prior running-status report was stale. No owner approval is currently needed for these routine tasks. Any substantive ownership representation change will return to the owner before implementation.
