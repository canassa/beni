## 2026-10-25 23:52 CET — List writers are never total, so arms keep them

**What I did.** #1028: the browser-inline lowering ran `List.push` ahead of its
`if`/`case` branch because the checker called it total. `Totality.zig` now
leaves the eight `List` writers of `ownership-checker.md` §3.1 out of the
total set (the `writes/Core.zig` rows name them), so a caller outside core,
and every declaration that calls one, is not total either; core's own callers
are exempt. Under `--sanitize-lists` (PR #1032's tree) `TotalCallBranchOwnership`
trapped before and runs clean after, and so does all of `browser/inline/`.
Goldens: `emit/inline/TotalCallBranchOwnership` and `TotalCallBranchForms`
(dot-call, `++`, `update`, `set`, a user helper). One run-hash changed.

**What I learned.** The fix lives in the `total` bit, not the lowering, so the
lowering needed no name matching. `Dict` writers edit in place too and are not
covered. A page that reads a list in one arm and writes it in another, with
three or more arms, already stops at the S3 memo-node limit before this change.
