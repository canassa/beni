## 2026-10-22 15:40 CEST — Stop Tea tables at hosted state boundary

**What I did**

Resumed #294's private Tea sorted-table draft after #737, from master
537558a81, entirely on dagon. Restored fixtures first: the keyed no-Dict
assertion failed on master and passed with the draft. The wanted-table and
tap-list writes blocked by #720 are now accepted.

Found an independent command-fold refusal (#749): queued work can retain an
inner value list while the fold writes only the outer table's slots. Explicit
calls and direct recursion pass; a control that retains the outer storage
correctly rejects its direct push. A focused slot update did not change the fold
refusal. Replaced the draft's command fold with an equivalent direct traversal,
which removes both rejections without changing the representation or lifecycle.

The platform-clean ownership check still fails: 50 accepted demands, two pending,
zero rejected. Reduced the remaining boundary to Browser.hosted with fresh
List Int state, scalar-appending update/settle callbacks, and a view that ignores
state and sends only scalar message 1. Enforcement refuses both callback demands
as stored in a record. Filed #750, with exact source and diagnostics, and reported
the final safe-code stop on #294. The initial fold-only report was superseded by
this narrower result.

Preserved the direct-loop and fold drafts, node controls, browser reduction,
red/green no-Dict evidence and ownership dumps in
~/worktree-evidence/tea-private-key-tables-retained-values-20261022/ on dagon.
The earlier archive is untouched. No implementation is included in this diary-only
change; both requested implementation slices and the full browser regression run
remain unfinished. No checker/core/browser source changes, local Zig, LLVM,
measuring, copying fallback, cap, broad catch, budget change or weakened check.

**What I learned**

The direct loop lets the intended command-table implementation pass its local
writes. The remaining gap is its runtime boundary: ownership-checker.md §20.2
explicitly gives Browser.hosted no entry row, and entryRow recognizes neither
its Host parameter nor its settle-before-view transition. The runtime owns and
replaces this private state through Js.Ref, but inference cannot establish that
protocol. The new mutable private arrays need a precise hosted ownership contract;
the old persistent dictionaries did not. Ignoring those pending demands or granting
the table an exemption would violate the intended design.

The diary-only gate's first attempt also reproduced the existing chat receive
timeout #695: the expected "joined guest2" arrived after the receive step printed
"(nothing arrived)". No test, timeout or implementation was changed for this
failure; its log and an issue comment preserve it.
