## 2026-11-04 23:59 CET — Recursive codec witnesses

**What I did**

Reduced #1793 to a generic recursive codec passed to Schema.parse. Synthetic
parameter nodes on recursive codec references had no endpoint terms. They now
forward the enclosing codec's endpoint seats so checked-data witnesses can be
built. Added JsonRecursiveCodecWitness; the saved base compiler refuses it,
and the fixed compiler prints decoded. Retained JsonDerivedDescribe unchanged.

**What I learned**

The recursive argument's slot mapping was correct, but the new checked-data
adapter also needs its resolved type information. Description-only reductions
did not exercise that path; parsing the recursive codec did.
