## 2026-10-15 10:29 CEST — Nullary methods preserve record reads

**What I did**

Read CLAUDE.md and research 96, then specified the owner's accepted 2026-10-15
rule in the language and dispatch contracts, with checker, ownership and write-set
pointers. Implemented receiver-directed nullary dots using deferred obligations,
record defaults at the owner's generalisation boundary, and a single checked-BIR
rewrite to ordinary method calls before effect planning. Cache hits replay the
rewrite; check-cache entries are v11. Core call sites and apps are untouched.

Added runtime, browser-direct, ownership, diagnostic, formatter, emitted-call and
warm-cache fixtures, including generic evidence and suspension. Set aside the
implementation and proved the runtime/ownership examples failed before it; also
reproduced and fixed an arity check confusing a method's evidence with its call.
Recorded the new run hashes. `zorg build test test-blackbox fmt-check beni-fmt-check`
finished with 1,301 passed, 15 skipped and only the two known macOS case-folding
failures in build_test. The full corpus and unit/format checks pass. `zorg build
gates` refuses this aarch64 macOS host's missing Linux instruction counter; the
budgeted gate is owed on x86-64 Linux. Work is isolated in /tmp/beni-nullary-method-calls
because another session switched the shared checkout's branch.

**What I learned**

Nullary dots must stay independent of name-keyed method requirements: a record's
function field can be read and called at different arities. Unifying record reads
against the original receiver preserves existing alias presentation in diagnostics.
Arity checks must apply only to the original dot's callee, because evidence
requirements inherit its source location and can legitimately take more arguments.
The browser page preserves the old trail while appending to the fresh copy, and
the ownership report distinguishes that call from the rejected plain field path.
