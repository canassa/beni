## 2026-11-03 10:55 CET — Checked markup operand evidence

**What I did**

Recovered the DOM lane after dagon's reboot, preserved its 18 unfinished files,
and rebased hostfree-dom onto workers-hostfree. Completed the typed lowering
operand channel: checked structural paths, composed capture tuple evidence,
and direct runtime calls carrying the ordinary hidden identity/data arguments.
Added cache validation for operand roots and function-type paths. Exercised
cold dispatch roundtripping, warm cache, and release through an imported generic
view and an annotated local helper.

**What I learned**

A generated call can be the only evidence demand in a local function. The local
boundary must retain its quantified roots before the operand demand is collected;
waiting for a source Any or Data call drops that information. Function types must
keep their children in the cached operand tree, while data witnesses still treat
a function as a leaf that cannot be plain data.

The focused integration and corrupt-cache tests passed. A locked full hash
refresh failed with 34 scenarios and 56 corpus cases. The same locked run on
exact workers-hostfree f238c3d355 failed with the same 34 scenarios and 57
corpus cases: the channel adds none. Both trees crash on the widest accepted
written plus chain, in development and release. Reported the reduced source
immediately; the manager assigned its repair to a separate crash lane. The
manager authorized a separate channel commit after this attribution, without
waiting for those base failures to be repaired. Full gates have not passed.
