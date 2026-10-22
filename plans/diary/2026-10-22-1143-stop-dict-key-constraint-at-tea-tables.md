## 2026-10-22 11:43 CEST — Stop Dict key constraint at Tea tables

**What I did**

Inspected current origin/master (9c9de7a66) in a fresh dagon worktree for
#294's separate Int/String key constraint slice requested after #664.
Stopped before implementation under the owner's explicit instruction:
Tea still requires non-Int/String Dict keys. `platforms/browser-tea/Tea.beni`
uses `Dict (List Key)` for jobs (line 164), `Dict Key` for live subscriptions
(line 174), and `Dict Key` for wanted subscriptions (line 496). `Key` is
`Hosted.Key`, a foreign type, not a scalar alias.

Reported the dependency on #294. No compiler, runtime, core, platform,
fixture or generated skill API was changed. No Zig ran locally; no LLVM
build, measurement, budget change or weakened check was used.

**What I learned**

#669 is merged as a specification, but Tea's private sorted table is not
implemented on master. Its boundary.md §9.8.3 contract explicitly replaces
both Hosted.Key and List Hosted.Key dictionaries without encoding keys.
That platform slice must land before enforcing the Int/String restriction
can leave Tea checking. The Dict tree can remain in place for the later
checker-only slice; the blocker is Tea's key types, not the representation.
