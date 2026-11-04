## 2026-11-04 17:19 CET — Deep escape through summaries

**What I did**

Specified the owner's deep-escape decision at erased stores in ownership-checker.md §31.8.
Preserved whole-record escape facts through summary read-off instead of treating every record-only
cell as an object-only escape. Added the fresh-model command regression, nested-list and record
controls, eager-field capture, and an imported summary cache round trip for #1853.

The primary impact scan compared 2,261 roots, including every ownership fixture and the real apps.
Four accepted lines became refused: RecordCapture and the three new regressions. Each is a real
retained-value hole; no example, Conduit or TodoMVC write changed. The audit driver's 20 unavailable
auxiliary roots are checked separately with their corpus platforms. Baseline gate failures and
before/after evidence are saved in ~/worktree-evidence/wd-escape on dagon.

**What I learned**

A type containing no list does not make its escape shallow: a holder can still traverse its nested
records. The object-only exception cell must remain distinct from that whole-value escape. Typed
field captures still keep the eagerly read field rather than its containing record.
