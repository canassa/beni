## 2026-11-02 03:17 CET — Fix typed Task review findings

**What I did**

Kept suspendable recursive calls direct, confined hidden completion forwarding
to the suspension body's result call, and made a malformed suspension marker
an internal compiler error. Added recursion and emission regressions, retained
capability-pruning assertions as pending scenarios for #1670, and shared the
private runtime name fence across resolution, diagnostics and API generation.

**What I learned**

A work thunk multiplied native stack depth even before the first suspension.
The 5000-level regression now reaches its bottom yield and resumes iteratively.
In-place suspension primitives can also return a direct value; their marker
producer must preserve a call boundary before the sink invariant is checked.
