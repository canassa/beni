## 2026-10-31 01:24 CET — own2 slice 4a: review fixes, and a κ keyed below a choice

**What I did.** I answered #1395's review on `own2-s3b4a`.
- Group members are walked by name (§3.8), so declaration order no longer moves a group's accounts. A new ordering test pins it.
- The known-limit key now accepts only `ownership_summary_size`.
- `Walk.renumber` is gone: it dropped κ.
- Q1 is recorded as the owner's decision.
- The HIGH defect is not fixed. It is #1399, pinned by the red fixture `tests/pending/ownership/GroupJoinShared`.

**What I learned.** The port's join is right: `kappaOf` at `proj(res, [*])` reads `shared`. When both rounds' arms intern to one node, the entry is keyed on the choice's frontier node at `[*]`. Readers that go through the arm, or relabel by node (the printer, `kappaRelabel`, the call view), never meet that node, so the caller reads `yes`.

Also, perl's `s|…|…|` alternation trap bit me a second time. Use the Edit tool.
