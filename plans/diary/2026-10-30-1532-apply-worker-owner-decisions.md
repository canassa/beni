## Apply the owner's worker decisions

**What I did**

Read the owner's comments on #1315, #1305, #1319, #1302 and #1301 before editing.
Continued PR #1304 in an isolated Dagon worktree. No task files or commands used
the local checkout. This is a design-only change, with no compiler or runtime
implementation and no claim that the proposed worker modules compile today.

Made generated WebIDL native types and inferred realm summaries normative in
workers.md §4 and all adjacent amendments. A and B remain compared alternatives.
#1295 first measures the Task and renderer callback-typing migration: 130 erased
callable use sites, including 41 in Task. The >250k LOC/s and emit/release/ byte
budgets remain acceptance gates. Shared wire names are now normative in §3, §5
and the wire research. #1296 and #1300 implement and measure that design; they
do not choose between it and universal codecs.

Rewrote callback contracts around entryKinds callbackProtocol rows and parameter
indices. Ownership checker v2 applies those obligations to inferred user
summaries; v1 is frozen. The effect checker enforces implicit non-suspension.
Removed record-field qualifiers, constructor entry markers that depended on the
rejected alias amendment, and proposed realm keyword syntax. Closed #1319 with
the rewrite. #1315 and #1305 remain open with closing references in the PR body.

Recorded fatal abandonment, shared defect propagation, proposal transfer gating
and the separate Service Worker scope with exact owner-comment links. The private
abandonedWorkers report identifies each unfinished worker and termination status.
The browser has no SharedWorker.terminate: shared stop requests and unreachable
instances cannot be reported as native termination. This capability limit is
explicit in the design and tracked in #1302 and #1298. Normal close remains
cooperative; the fatal-deadline exception is distinct throughout the API.

Updated #1290, #1293 through #1300 and #1302. Shortened the binding-count receipt
to source identity, totals by kind and method, removing per-block rows. Downloaded
the pinned archive, checked SHA-256 and reproduced every retained total: 346 files,
2,782 blocks and 11,620 member rows. The comparison's A and B snippets now visibly
differ, with no invented source syntax. The decided #1315 issue body was untouched.

One new adversarial reviewer audited decision consistency and all record fields.
It found two unconditional normal-close statements that needed the fatal exception.
Fixed both. Also clarified A's manual storage wrapper and the compiler's generic
protocol checking. The reviewer rechecked and reported no remaining blockers.

Full nix develop --command zig build gates passed with exit 0 on Dagon. Later
changes only clarify documentation. Relative links and heading anchors, numbered
section preservation, code fences, qualifier scans, reproduced pinned totals and
whitespace checks pass. Final-head CI is awaited after this diary commit. The PR
will record its final result and removal of the owned worktree, local branch and
scratch directory. The remote PR stays open for owner review.

**What I learned**

Protocol metadata can supply implicit callback obligations without changing the
language grammar or trusting user annotations. Owner decisions must replace
contradictory normative alternatives across adjacent documents, not only receive
a decision banner. Fatal abandonment must also distinguish the requested runtime
policy from native termination authority the browser does not provide.
