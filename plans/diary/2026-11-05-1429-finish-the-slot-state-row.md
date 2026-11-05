## 2026-11-05 14:29 CET — Finish the slot-state row

**What I did.** Closed S8-ref's row in slot terms (#1991). A store that may hold one object at two slots of a cell now
makes the contents escape (`Contents.zig`), which closes #1984 and #1986. A store that hangs on a helper's parameters is a
new contract column, `stores`, judged at the call and carried by block version 21. A loan has its own cause, `loan`,
with its cell and a fix as deep as the write. `Ref.modify`'s `.0` and `.1` are read at the call, and a take of several
objects is owned. P-sync is listed and pinned per platform, with a gate on new listeners. Appendix B's rows are fixtures.

**What I learned.** The versioned relation was not needed. One name per slot with weak updates is sound once a store
keeps slots apart or escapes them; a strong update would only be precision. A callback's `res_cond` is enough for its
answer, because its selections are of contents the same rule keeps apart, or of captures `Stored` has escaped. A numeric
literal's type variable was read as able to hold objects, so `[ 0 ]` cost eight spurious `disjoint` refusals of fold
accumulators, and hid `ModifyResultPaths`' green: `Kind.scalar` already had the answer. Pinning P-sync found a real gap:
a DOM handler's extractor runs inside a synchronous `focus()` (#2006). And `List.map` over a map's result is refused
even with #1981, which holds back `LoanCopyDepth`'s green (#2007). Source files at their size targets forced two splits,
`Within.zig` and `BlockNames.zig`.
