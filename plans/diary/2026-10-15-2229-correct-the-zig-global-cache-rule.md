## 2026-10-15 22:29 CEST — Correct the Zig global-cache rule

**What I did.** The owner merged #173 before its reviewer finished. The
review found one error: the rule "no build step may put a file of the
worktree into Zig's global cache" gave `b.graph.global_cache_root` as its
example, and Zig 0.17 has no such field. I opened #197 and fixed the text in
`CLAUDE.md` and `flake.nix`: the example is now `b.graph.path(.global_cache,
…)`, the way a 0.17 `build.zig` names a path there. The texts also list all
that the global cache holds, and say that the other Zig evicted compiler-rt
too. I removed the hook from the `ownership` shell and corrected
`docs/getting-started.md` from Zig 0.16 to 0.17.

**What I learned.** #173's comment in the `ownership` shell said that Zorg
reads `ZIG_GLOBAL_CACHE_DIR`. That is wrong. Zorg reads
`ZORG_GLOBAL_CACHE_DIR`, and its own test keeps it in `~/.cache/zorg` when
`ZIG_GLOBAL_CACHE_DIR` is set (Zorg `v0.17.1-zorg.1`,
`lib/zorg/std/zig.zig:1720`, test "zorg keeps its global cache apart from
upstream zig"). A probe `build.zig` showed that `b.graph.path(.global_cache,
…)` is public: `zig build --list-steps` compiled it, and `addCopyFile` took
the path. So the hook did nothing in `ownership`. I
wrote the claim without a run of `zorg env`. A review that only checks
the code against itself does not find an API name that is wrong. Run the
command, or grep the pinned library, before a comment names an API.
