## 2026-11-15 16:26 CET — a module-level Js.ref callback keeps its suspension

**What I did**
- Reproduced #1788 on master e72a8bfd80. The issue's program printed `0/0`, not `42/42`, in development and release. The cell was split into `Main$slot` and `Main$slot$s`.
- Found the cause: §14.3 rule 3 (amended for #1662) fixes a top-level value's effect classes only when its evaluation is not `pure`. `Js.ref` is `pure` and makes a cell.
- Fixed it: a top-level value whose body may make something is fixed too. A body makes nothing when it is a value by checker-v2.md §8.4's syntax, or a block of such bindings with no statement.
- Added `run/core/TopLevelJsRefSuspendingCallback`: a direct `Js.ref`, a helper that makes the cell, and a block's closures. Without the fix all three lines print `0, seen 0`.
- Opened #2520: the type rule of §8.4 has the same hole (`cell = Js.ref []` checks and prints `text01`).

**What I learned**
- `Js.ref` as `foreign impure` is not a small change: core's `Schema.derivedInt32` then fails as `impure_polymorphic_value`, because `Schema.compiled` makes a monomorphic memo cell inside a polymorphic value.
- The first version called every block expansive. `cache_test`'s "constrained function constant rewritten as a block" caught it: the block `f = maxOf` then `f` makes nothing, and the importer must stay cached.
