## 2026-11-06 00:41 CET — send puts back the slots of a body with no context

**What I did**

- #1153: a throw out of an event handler does not reach the code that fired the event, so a
  body that calls `Dom.focus` goes on after the handler's `update` throws. A body with no log
  context of its own then went on with `update`'s context.
- I tested the issue's fix 1 first (`hasLogContext` reduced to `slotted`). It does not fix the
  issue's probe: there `update` sets the first slot of the page, so `slotted` is `False` when
  `send` runs, and no record holds the slots yet.
- `send` (`platforms/browser/Rt.beni`) now runs every `update` in a `Js.finally`, between
  `Task.beginUpdate` and `Task.endUpdate`. They replace `hasLogContext` and
  `withoutLogContext`. When no slot was set as `update` began, `endUpdate` puts the defaults
  back, under an entry on top of `update`'s finalisers that sets `update`'s slots again for the
  teardown.
- The specialiser (`src/js/Spec.zig`) writes a `try` with no `catch` and an empty `finally` as
  its guarded statements. Without it, every release page that sets no slot kept
  `try{…}finally{}` (+14 raw, +5 brotli on `CountersOneModule`). The fold also removes two
  latches that every hosted page had: the render's and the after-render phase's `finally` only
  clear `busy`, which such a page never reads, so they were already empty on `master`. Four
  `emit/release/tea` goldens lose 28 raw bytes each (3 to 11 brotli), and `build_test`'s count of
  `finally` in a hosted page goes from 5 to 3.
- Bytes, one compiler, `master`'s `core/` and `platforms/` against the branch's, 324 builds:
  in release, 310 are byte-identical (Conduit and the empty pages among them) and the 14 pages
  that set a slot grow by 166 to 168 raw bytes (−9 to +41 brotli).
- Four page fixtures, `browser/tea/LogBareBodyAfterReportedThrow` and three siblings (a body in
  a fiber, nested scopes, a slot set before), each red on `master` and green with the fix.
- Spec: `boundary.md` §9.8.16 (b) and `backend.md` §9, both amended 2026-11-06; a note in the
  effects proposal.

**What I learned**

- A runtime cell such as `slotted` cannot gate code that must run when the cell becomes true
  during the call. Only code after the call can see it, and a `Js.finally` is the one place for
  that. The cleanup folds, so the cost was only the empty `try`.
- `--platform=<dir>` loads only the named layer from the directory: `browser-tea`'s dependency
  `browser` still comes from the embedded copy. To test a change to `Rt.beni` without a rebuild,
  copy the three layers and point each manifest's `"platforms"` at `../<name>`.
- `nix develop` on a worktree with changes copies the tree to the store first, which takes
  minutes. Node and Zig are on `PATH` already through direnv.
- `beni build` writes a `.beni-cache` in the directory it runs in. A build run inside
  `tests/corpus/browser/tea` left one there, and the corpus walker took it for a fixture
  (`OwnershipV2Differs`, `BuildFailed`). Build probes in a copy.
- `core.v2.unchecked` is written only by the unfiltered ownership walk: a blessing run with
  `-Dcorpus=` does not write it. `BENI_WRITE_EXPECTED=1 BENI_BLESS_ONLY=ownership/core.v2 zig
  build test-blackbox-corpus` does.
