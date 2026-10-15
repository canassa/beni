## 2026-10-15 12:06 CEST — Nullary method review follow-ups

**What I did**

Added reversed-declaration runtime scenarios for NullaryMethods and a two-member
recursive group mixing a nullary field read with an applied dot-call. Made the
record-default hint name the actual helper and parameter, suppress annotated
helpers, recognise same-module private methods, and explain defaulted accessors
on list elements. Four check/bad goldens were captured from real runs; each
differs from the saved pre-fix compiler output. Renamed the missing-argument
fixture, aligned missing_field in the contracts, and recorded the independent
review’s checking-cost measurements without optimisation. Compiler edits stay
inside src/check/.

**What I learned**

Bidirectional checking can report a list element mismatch before the helper’s
argument mismatch; the hint must recover the enclosing call and distinguish
the list parameter from its element receiver. The macOS budgeted gate refuses
this host; the documented unbudgeted suite and GitHub Linux checks provide
the available validation, with the two known macOS case-folding failures
excepted. The instruction-budgeted Linux gate remains owed.
