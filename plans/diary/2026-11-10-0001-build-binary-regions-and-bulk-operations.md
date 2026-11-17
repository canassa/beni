## 2026-11-10 00:01 CET — Build Binary regions and bulk operations

**What I did**

- Recorded the owner's decision on cross-realm shared detection in binary.md §1 and the skill (90a154890f).
- Built option 4: `core/Binary/Region.beni`, a view checked once when made (9eebd2a9ea), then
  `Gpu.MappedRange.region`/`readRegion` and `Wgsl` on one region per call (bd4ab6c18c).
- Built option 5: bulk operations on `Binary` and `Region` (08f675f5a8). binary.md §6–§8 now say
  what was built. The skill reference has Regions and Bulk sections.
- Measured each slice with View and Region (or scalar and bulk) runs alternating in one process. The
  1024² texture took 335 ms with View and 220 ms with Region in Chrome, and 551 ms against 409 ms in
  Node.

**What I learned**

- Under `--release`, a record literal is evaluated in the order of its emitted keys, not in written
  order. A `Js.ref` read placed before a call that changes the ref sees the old value. Binding the
  call first does not help, because the single-use inliner moves it back. Master has the same
  defect; I reported it and did not fix it. A tuple keeps source order.
- `Array.from` over a million-element typed array is about 8× slower than filling an array that was
  made at its length. That made the first bulk read slower than the scalar loop.
- Bulk does not pay where the caller must build a large beni list only to hand it over. The
  texture's fastest path is a Region with per-access calls.
- A full disk shows up as `NoSpaceLeft` from zorg. After a `.zig-cache` is removed, a running build
  fails with `FileNotFound`. Rerun it.
