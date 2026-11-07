## 2026-11-07 02:10 CET — Port the nullary sharing coverage fix (#2177)

**What I did**

Ported the `shareNullaries` half of #1850 from the deleted workers-hostfree branch:
`nullaryCovers`, `copyNullaryLiteral`, the grouping in `Emit.shareNullaries`, and its unit test.
Added a dated amendment to backend.md §4's #916 note and `run/NullaryCoverage`. On master its
release pass prints `different {} {}`; with the fix it prints the full `Nothing` twice. No emit
golden moved and page sizes are byte-identical to master. The schema-worker fusion half
(`Spec.zig`, `HeldConstants`, `SchemaWorkerFusion`) was not ported, as the issue asks.

**What I learned**

Master's `Js.same` is `a, a → Bool`, so the original's `Js.same (Js.global "probe") Nothing`
does not check here. `Js.same Nothing (Just 1)` keeps the use identity-only and reproduces the defect.
