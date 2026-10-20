## 2026-10-20 21:36 CEST — Fact 3's declared-type filter

**What I did.** Built slice 4 of the type-directed points-to plan (#491), stacked on #504: `Pts`
filters every batch that joins a local, a parameter or a function's return by the var's
representation key, and a copy edge links field summaries only where the target's filter is wild
or the source's. `emit/release/inline/TypedMerge` was blessed on the base and shrinks by the field
the filter lets go; nine `run/TypedFilter*` programs and an extended `run/UnboxedTypes` cover each
wild source the design lists. Rebased #504's commits onto master first (a conflict in
`check/Instantiate.zig`, both sides kept) and again when #504 rebased itself.

**What I learned.** The filter changes nothing on the dashboard it was designed for: `Main`'s
schemas make every key wild, and even without that, 12 of 16 widget models cross at `Schema`'s
`toHost`, `replace` has no result key because `Schema.Value` is a wild parameter, and the merge
travels through record properties, which the filter does not read. Two deliberately broken builds
are a cheap way to show what a soundness fixture guards. `/tmp` on dagon is an 8 GB tmpfs: never put
a worktree there. `check_test`'s "core's are catalogued" is at 4 301M of 4 300M on #504's head, a
failure that is #504's, not this slice's.
