# Integrate the reviewed fiber protocol with native host projections

#1941 focused re-review accepted the implementation. Merge workers-hostfree e6e796fd5d into the reviewed branch without rebasing, retaining the native-host projection work and platform ring FIFOs. The source merges automatically; regenerate ProgramBoundary and typed Rows/Events release outputs from the combined compiler. They change by −33/−79/0 raw bytes against the reviewed head, respectively.

Re-read and re-pin Js.cell, cellRead, cellWrite, none, some, optMatch and optWithDefault. Their shared Lower span changes optNone/optCoreValue to pub so the native adapter can reuse the same sentinel. This affects Zig visibility, not runtime identity, aliases, loans or callback counts. All incoming pinned keys are retained; the ownership words and publication rules stay fixed. The Browser.Bridge isBrowser fence and host-projection Opt reachability additions remain intact.

Follow-ups stay separate: quadratic clone keep-mark scans join #1942, conservative ref boxing is #1952, misplaced splitSuspensions documentation is #1953. The master's dropped-effect bug #1951 is next after the manager merges #1941. #1927 stays paused with its prototype and audit evidence saved; its reader fix restores13 of the20 named Task declarations and33 core entries overall in the final-kernel probe, but no checker changes enter this merge.

Targeted overlap results and the full Workers/Chrome runs are preserved in ~/worktree-evidence/wd-fiber/p6/merge-1941/. No new full base suite was run; the accepted gate comparison remains in p6/review-fixes/.
