## 2026-11-04 10:46 CET — rendererTruncate borrows its array; typed slots committed

**What I did**

Took the manager's correction to #1825: `Browser.Host.Array.rendererTruncate`
now takes a `borrowed Array a`, regenerated through `zig build native-bindings`
(only Array.beni changed), with the asserted ownership row removed and the
trusted-surface line restored. `ownership/core/ArrayTruncateCell` pins a
cell-held array that is truncated. Committed typed Slots. Picked the rows
lane's two commits onto a local wiring branch.

**What I learned**

Only `make` creates an Array; `fromList` and `slice` give read-only Views,
so no Array shares storage with a List. The browser platform now has no
rejected ownership line with both Slots and Rows in it. "Only List's eight
writers" still fails, now on `Js.Array.arraySet`, which came from upstream.
Rt.Rows has no CorePrivate fence yet, so the skill API lists it.
