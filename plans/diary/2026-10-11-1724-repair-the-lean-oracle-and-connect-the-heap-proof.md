## 2026-10-11 17:24 CEST — repair the Lean oracle and connect the heap proof

**What I did.** Replaced partial type/domain/checker/evaluator definitions with
structural or fuel-decreasing definitions, including explicitly total equality
for nested values. Gave permanent escape holders real external observations,
propagated traversal escapes to a stable fixpoint, and prevented temporary
position loans from hiding permanent aliases. The expected-reject regression
now passes; both historical defects remain executable negative controls. Expanded
the typed generator with recursion, captures, nested towers and library pipelines,
completed the applicable fixture audit, and retained every mismatch report.
The final suite has 74 passing fixtures; 60,000 typed campaign candidates yielded
19,105 accepted equivalent traces in 15,554 ms, with no corrected mismatch.
Higher-order recursive limits and duplicate AST counts are reported separately.
The original old-rule generator still finds 7 map and 9 initialize failures.

Connected the builder proof to actual heap allocation, put and both close paths,
with snapshot correctness, frame preservation and permanent-observer preservation.
Added kernel checks of the repaired checker rules. The proof library and oracle
build with Nix Lean 4.29.1; the shell now checks the version pin. Zero sorrys or
extra axioms; map/summary/main soundness remain unproved. Kept the PR draft and
used a normal commit without the earlier CI-skipping marker. No Zig command or
paid external tool was invoked for this repair, following the owner's scope.

**What I learned.** Making the visible functions total is insufficient when
nested derived equality remains opaque. Kernel reduction caught that second
boundary. An escape marker without a reader cannot test observational soundness;
retaining real references and observing execution prefixes makes the omitted
summary effect visible. A footprint lemma becomes relevant only after relating
its cells to executable heap operations and their outside observers.

Later the same session: PR #45 merged — an executable Lean 4 core of the checker
(`proofs/ownership/`): value and in-place interpreters, a differential oracle, and `map`,
`initialize`, `foldl` and `update` derived from five primitives rather than asserted. With the
old freshness rule it rediscovers T59 within 100 programs; its first draft also found its own
traversal dropping escape facts. I checked it by building it and running a fresh seed (5,000
programs, zero mismatches). It answers soundness, not the error rate; that needs the report-mode
prototype in the Zig compiler.
