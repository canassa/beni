## 2026-10-29 22:46 CET — Ownership v2 S3b slice 1: calls of walked declarations

**What I did**

- A call of a declaration of an earlier group now applies that declaration's class. A call within
  its own group, or to an unbuilt or limited callee, stays unbuilt. A cold run walks the callees
  it reaches first.
- Making the ownership corpus agree with v1 found six defects in the call path:
  - the callee's `xreq` was folded into the caller's own and never checked;
  - a write's path was dropped from its demand;
  - item 3's "every other path of the argument" was not built;
  - a `⟲` write landed on the root object;
  - applying an unbuilt callee's pessimistic class accepted interior sharing;
  - a stepped recast that keeps its whole inner read the literal around it as fresh.
- Item 3 needed three rules, now written in §2.11 with twins in `CallOtherPaths`. Removing each
  rule fails its refused twin.
- Added `SharedHolderRoutesCall` (#1223) and `PatternWideCall` (#1224). `EvidenceDagBuildDepth32`
  is pinned as CK-313 (#1252), and the precision debt is #1253.

**What I learned**

- An approximate answer has to count as a hold: `~π1` may be `π1`. The precision it costs comes
  from the summary, not the value.
- Two summary paths of one caller parameter can fold into one canonical cell. That fold is
  neither a conflict nor nothing: it is a reliance (`excl`) that the caller owes upward.
- `linkArgs` keyed by path is exponential on a DAG with shared children. Lists hide this,
  because they have one child.
