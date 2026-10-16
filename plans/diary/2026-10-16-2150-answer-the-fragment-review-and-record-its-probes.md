## 2026-10-16 21:50 CEST — Answer the fragment review and record its probes

**What I did**

- Answered the two reviews of PR #267 (the first flat fragment). Neither found a correctness defect. The adversarial review proved by `rfl` that the corollary is the main theorem's proposition plus one hypothesis, and built the relation at a nontrivial state.
- Fixed its three document findings: `COVERAGE.md` names the fragment theorems by their real namespaces (`Preservation`, `HeapFrame`, `Push`); `PROOF-PLAN.md` lists the four flat-only clauses of `FlatInvariant` and the step that replaces each one, and says that `invariant_preserved_fragment` in its planned form stays open.
- Added the reviewer's probe programs to `Trace.lean` as `#guard`s with kernel `FlatANF0` proofs: `every` uses all six forms, is accepted, makes one in-place write, and both runs agree; `liveAlias` and `observed` are in the fragment, are rejected by the Dead and the Unescaped test, and their runs differ.

**What I learned**

- The kernel cannot run the checker (mutual well-founded recursion), and the audit refuses `native_decide`. A `#guard` is the kernel-free way to pin a concrete instance: the build evaluates it, and the audit's source scan allows it.
- `links = []` is the flat-only clause where the #169 link clauses enter the relation; the other three (`heapInts`, `types`, `abstractShapes`) fall with field atoms and records.
