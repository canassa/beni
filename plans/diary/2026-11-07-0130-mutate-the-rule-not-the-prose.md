## 2026-11-07 01:30 CET — Mutate the rule, not the prose

**What I did.** Third pass on #2153: conflict markers out of the known list and refused by the gate, stale text in §2.11.3 and §2.14.5, `H2reader` and a lambda twin of `h1`, and each H row of §2.14.5 rewritten around what a mutation of its rule moved.

**What I learned.** My hand walk of H1–H6 overstated three rows. Turning each rule off took minutes and showed that H5 on this route rests on `Across.operands`, that `Eval.labelsOf` carries the lambda route, and that `deepAt`, `LaterFunctions` and `mayBeHeld` aren't reached by any fixture here. I also lost entries twice in the known list: a `sed` on a pattern that matched `ListSanitiserValues`, and a resolver that dropped a three-way base. Both showed only because the gate compares both ways.
