## 2026-11-09 16:15 CET — Wait for native data URL responses

**What I did**

Finished the browser-base foundation's zorg.1 gate comparison against a
clean detached 620c322a45 worktree with only the temporary Contract.zig
patch. Failure identities matched exactly: six ownership corpus cases,
two CPU budgets and two case-folding cases. No goldens or budgets changed.
Switched to the owner's zorg.3 and removed the patch in both worktrees;
both built successfully. Empty inline-page outputs also matched exactly
on zorg.3 before and after the foundation.

The foundation Chrome run passed 743 of 745 pages. Clean master reproduced
DomCapabilities but not HttpDefect. Five targeted trials per build gave
four lane passes and five master passes; the failed lane trial delivered
the successful data-URL reply one transcript step late. Compared complete
emitted trees, including maps and HTML: byte-identical. Recorded the
investigation and the mode-divergence and incremental-toolchain reports
under zig-out/scratch, as the manager requested.

The manager agreed the cause was the driver and requested a separate
commit. Saved the foundation, including its index, in stash
270254dd7f3c25159f0e8948ac54321f25da77ad. Added a deterministic black-box
driver test with native promises resolved on controlled MessagePort host
turns. The old driver showed loading; the fixed driver showed hello.
Counted native data fetches and finite body reads without replacing their
promises; scripted HTTP still waits for explicit response steps. Updated
the corpus protocol documentation. The targeted regression and the full
Node browser_test file passed on zorg.3 with a branch-specific run-hash
cache. No golden, runtime or timing threshold changed.

**What I learned**

A parked fiber waiting on native fetch leaves no queued scheduler
continuation. The driver already counted native image/GPU promises, but
its data-URL path bypassed that count, and response.text was uncounted too.
A scheduler-only settle could therefore snapshot before the reply even
when emitted application code was identical. Both the fetch and its body
must finish before the transcript moves to the next step.

Validation is pending the manager's next Chrome/full-gate slot, shared
with beni-binary. No job is running, no implementation commit has been
made, and no GitHub activity is authorized. Keep this driver repair in a
commit of its own, then restore the saved foundation. Do not restore the
Contract.zig workaround or retry the incremental MachO2 crash.

## 2026-11-09 16:43 CET — Settle repair validated

The manager granted the sequential validation slot. All five fixed
HttpDefect Chrome repetitions passed. Clean master 620c322a45 and the
final lane gates on zorg.3 have identical failure identities: six
ownership golden mismatches, two ownership CPU budgets and two APFS
case-folding tests. No new failure remains. The first lane run also found
an obsolete installed browser-base API reference left by stashing the
foundation; removed that generated orphan. Its socket and page-fuzz tests
hit the unchanged 120-second guards once, then passed in the final full
rerun. Kept both original and final logs; the final comparison is
zig-out/scratch/driver-gate-comparison.json. No golden or budget changed.
Released the slot with no validation job running. This commit contains
only the driver repair, deterministic regression and documentation. The
foundation remains saved separately until this commit is made. Nothing
has been pushed or sent to GitHub.
