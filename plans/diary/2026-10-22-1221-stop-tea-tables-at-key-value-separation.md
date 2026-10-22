## 2026-10-22 12:21 CEST — Stop Tea tables at key/value separation

**What I did**

Started #294's private Tea-table slice from current origin/master
(d22343831) on dagon, before the separate Int/String constraint. Reused and
reviewed the archived private table draft: binary-search lookup, preserving
the existing key on comparison EQ, and prefix-range cancellation with
in-place permutation/removal operations. A new blackbox assertion that a
keyed command/subscription page does not emit core Dict failed on master
at that assertion, then passed after replacement. The custom comparison-equal
subscription fixture passed all three browser modes.

Inspected ownership separately: ordinary browser build success does not
prove Tea's table writes accepted. Removed a generic upsert callback,
replaced singleton append with push, and tried a direct recursive wanted
walk. The wanted-table loop still refuses. Reduced it outside Tea to a
List of (List Int key, List Int value) pairs, built from two fresh list keys
by a fold. It compares the stored key, focuses the matching row and pushes
a scalar into its fresh value list. The checker rejects the fold callback's
accumulator and value list as possibly shared. No key is mutated and the
keys share nothing with the value lists. The same fold with String keys
passes; two explicit calls of the list-key helper pass and print the full
result `[([1],[7,7])]`. Checker sources and core are unchanged from master.

Stopped at the owner's safe-code refusal condition and reported the full
reduction on #294. Preserved the incomplete draft, red-first log, accepted
controls, complete result, diagnostics and ownership dumps on dagon at
`~/worktree-evidence/tea-private-key-tables-stop-20261022/`, with README and
verified SHA256SUMS. Restored the worktree to the base before publishing
this diary-only record. No implementation or pending fixture is merged.
The Tea slice and Int/String constraint, including generated skill API,
remain outstanding. All builds and edits stayed on dagon; no measurements,
LLVM, copying fallback, manifest workaround, exemptions or budget raises.

**What I learned**

A comparison-equal key can be retained read-only while its separately owned
value list is edited. A table's key provenance must not erase the facts
needed to write that value through a loop. The reduction passes with scalar
keys and in two explicit calls, but loses the necessary separation through
the fold for list keys. A direct recursive Tea walk also refuses. This is
a safe-code ownership blocker, distinct from merely finding Tea still uses
Dict or from the draft passing browser behavior tests.
