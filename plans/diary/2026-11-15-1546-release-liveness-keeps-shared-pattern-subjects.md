## 2026-11-15 15:46 CET — release liveness keeps shared pattern subjects

**What I did**
- Reproduced #1654 on `origin/master` (`e72a8bfd80`): `read ((Pair a b) as pair)` with `pair` unread printed `84` in development and threw `TypeError` under `--release`. The release output was `undefined.a[0]+undefined.b[0]`.
- Found the cause in `Spec.liveness` (`src/js/Spec.zig`). It dropped a dead local binding by rewriting the initialiser node to `undefined`. `Lower.bindings` gives every binding of a pattern the same subject node, so the alias initialiser was also the subject of the field reads.
- Fixed it: the dropped binding becomes a statement of a new `undefined_lit` node, and the initialiser stays as it is. `grow` then sizes the per-node tables.
- Added `tests/corpus/run/ReleaseUnusedPatternAlias` (a constructor alias and a tuple alias). It fails under `--release` before the fix and prints `87` in both builds after it.

**What I learned**
- JsIr from lowering is a DAG: one expression node can have more than one parent. A pass that rewrites a node in place must know that nobody else holds it. To remove a parent's use of a node, rewrite the parent, not the shared child.
