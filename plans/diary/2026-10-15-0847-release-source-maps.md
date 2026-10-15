## 2026-10-15 08:47 CEST — release source maps

**What I did**

Specified and built `--release --source-maps` (issue #93, `backend.md`
§11.2). The multi-file layout gets one map per module. The scope-hoisted
file gets one map, with one source per module; the link step rebases each
module's marks into it. Hand-written pieces and the link step's glue start
with a one-field segment, so they stay unmapped. The printer moves a mark
past the adjacency guard's space and drops a mark that `closeBlock` leaves
past the end. Each declarator of a joined run marks its keyword, its name
and its function name. Under `--release` a local gets its beni name in
`names`. A body that `Spec` copies across modules now takes the position of
the call it replaces. Three black-box tests and four unit tests cover it;
each rule was checked red by a revert. The 414 `run/` programs build with
the same bytes as the base commit in development and in release, and with
the flag every file is the plain file plus its comment line.

**What I learned**

A map lookup finds the same segment when a mark sits on the space before
its token, so a position test does not see that defect. A test must check
that the segment starts at the token's own column. A cross-module copy
with no position was not harmless: the mark before it covered it, and a
crash in an inlined `Debug.todo` pointed at the `case` scrutinee.
