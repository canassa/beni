## 2026-11-04 10:59 CET — inherited workers-hostfree gate failures

**What I did.** Ran full gates on workers-hostfree c30bd3a393 (26 failing
tests, 254 corpus cases, 24 unformatted files), blessed every golden into a
scratch copy to read the diffs, classified each failure in #1848, and fixed
the ones with a clear answer on branch hostfree-inherited: the prerender
tree's main is a Spec root again (28 prerender release builds), route shapes
keep their box in release (browser-inline applied a push its shape refused),
Schema.key copies instead of editing its parameter, UncheckedWorkers' test
platform type-checks, nine hand-written files are formatted, and the stale
test expectations follow typed Task storage and the typed Node runtime.

**What I learned.** A run with BENI_WRITE_EXPECTED into the worktree, saved
and reset, is the quickest way to review hundreds of goldens. Most of the
rest is not stale: release emit grows 10.8% brotli, ownership adds rejected
demands through typed Cmd/Task storage, and v2 leaves more declarations
unchecked; those need the owner's call, not a bless. A test that stops at
its first failure hides the next one (Schema.key sat behind Js.Array.arraySet).
