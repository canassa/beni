## 2026-11-06 02:29 CET — Sort #1971's CI failures into its own and the base's

**What I did**

- Rebased #1971 onto `workers-hostfree` `f6059fac92`, then onto `f631a01f02` (#2113) when the base moved during the runs. Both rebases were clean.
- Built the base in a second worktree under `zig-out/scratch/base-wt` and ran `zig build gates -j2` and `zig build test-playground -j2` on the base and on the head, each in its own heavy-run job.
- At `f6059fac92`: base and head fail the same 3 test groups and the same 77 corpus cases (4 `build/bad/inline`, 73 `emit`, plus `ownership/core.v2.unchecked`), with byte-identical actual output. Both fail `test-playground` on `run/WideArithmetic` only. So #1971 has no failure of its own.
- Traced each base failure: `74ccc0f694` (browser-inline's `Cmd.perform` calls the `sync` `Js.Dispatch.send`, so `sync_boundary` comes first, #1848 B); `b798a04357` (release goldens before typed Node writes, #1848 D, partly blessed by #2113); `698499ef80` from #1965 (new core declarations, golden not updated; I opened #2114); the wasm compiler's `check` overflows V8's stack on the 4095-term chain (evidence on #2090).
- Asked the owner (`schema-dual-path-q3`) whether the base failures get a separate PR before #1971.

**What I learned**

- A PR's CI runs on the merge with the base of that moment. A failure list from an older run can contain cases the base fixed since (`TypedAnyErasure`, `EtaReduceAlias`, `SpecInit`). Compare against a run of the current base.
- `test-playground` assigns programs to shards by index. A new `run/` fixture moves later programs to another shard, so the same failure shows as "part 3" instead of "part 2".
- Corpus failure sections come in a different order from run to run. Compare them per case, not as one diff.
- `node --stack-size=8000` lets the wasm compiler's `check` pass a chain that overflows the default stack: a quick way to show that a wasm-only failure is stack depth.
