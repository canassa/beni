## 2026-10-15 16:27 CEST — run the gates' refusal children on the running maker

**What I did**

Found why `gates_test.zig`'s three refusal tests timed out in a fresh
worktree on a loaded machine. Each child `zig build gates <option>` now runs
the build runner that spawned the test, `/proc/<ppid>/exe` with the four
leading arguments Zig gave it, instead of `zig build`. Off Linux the child is
still `zig build`. `BENI_GATES_REFUSAL_TEST` stays, and a refusal that is
lost still fails in about a second.

**What I learned**

`zig build` compiles two things. The configure script (`build.zig`) goes in
the local cache, and the child did reuse it through `--cache-dir`. The
build runner Zig calls the maker goes in the global cache, keyed by Zig's
version string and its library's files. Two Nix builds of Zig 0.17.0 are in
use on this machine (`v6azzhsc…`, ours, and `90x7n96l…`, whose
`std/zig/system.zig` differs). They share one manifest. Each one's maker
evicts the other's, and a waiting child blocks on the manifest lock while
the other build compiles. In a private global cache: ours cold 164 s, ours
again 0.4 s, the other zig 172 s, ours after it 153 s. An evicted maker can
also vanish from `o/` while the parent still runs, which is why the child
uses `/proc/<ppid>/exe` and not the path in the parent's argv. A `/proc`
file's stat says it is empty, so `readFileAlloc` reads nothing from it:
read it as a stream.

Before the fix, the gates test failed in a fresh worktree with the other zig
compiling on the same global cache and a cold `zig build test` alongside. All
three tests hit CompilerTimeout, and the run took 213 s. After it, the same
setup passed: `run gates_test` took 1 s and the run 24 s. Without eviction,
in fresh copies, the old test passed even at load 20. So load only made the
compile longer; eviction was the cause.
