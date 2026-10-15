## 2026-10-15 10:19 CEST — close the bridge's ownership soundness clusters

**What I did**

Merged PR #115 after reconciling its append-only diary with master; its Linux
CI passed, and the local four-step run had only the two known macOS case-folding
failures. Specified the fix rules in ownership-checker.md §29 before changing
src/own: terminal result consumption, capture creation reads, symbolic recursive
environments, call-environment disjointness and taken-loan feedback obligations.
Promoted the six red fixtures with full diagnostics, added class coverage and
accepted twins, and fixed the diagnostic harness's missing platform argument.
All six promoted tests fail with the ownership code set aside and pass restored.
The full local four-step run again had only the same two macOS failures.

The unchanged 201 confirmed original bridge witnesses are all refused. The
CI-bound bridge's confirmed originals fell from 7 to 0 (15 to 6 total leads).
All 401 reverse leads remain refused with identical refusal details. Four
TodoMVC variants and TodoRouting remain clean; Sternhalma's three existing
top-level-sharing diagnostics are byte-identical. A frozen-binary full campaign
is running; its original-program interpreter audit and retained evidence follow.

**What I learned**

Selecting browser-direct on a diagnostic fixture did not put it on the actual
compiler command: only build/page paths used the selection. This was independently
confirmed by explicit browser-direct checks before fixing it. A taken item is a
conditional loan, not ownership for a fold accumulator's later lifetime. Persistent
JavaScript executions and their reducer cannot judge that lifetime; the fix audit
uses both Lean interpreters on originals and complete traces.
