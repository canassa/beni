## 2026-10-15 20:01 CEST — give beni a Zig global cache of its own

**What I did**

Issue #161. Every dev shell in `flake.nix` now sets `ZIG_GLOBAL_CACHE_DIR`
to `${XDG_CACHE_HOME:-~/.cache}/zig-beni`, unless the caller set it. All
worktrees of beni share that cache, and each worktree keeps its own
`.zig-cache`. direnv's `use flake` runs the same hook. CI sets
`~/.cache/zig` itself, because `actions/cache` derives an entry's version
from its path list: a new path makes every saved entry miss. A CI step
fails if the shell stops keeping that value. CLAUDE.md *Building* and
`docs/getting-started.md` describe the two caches.

I reproduced the eviction on private caches. On one shared global cache:
beni cold 87.8 s, again 2.5 s, the other project's Nix Zig 0.17.0 83.7 s,
then beni 79.8 s. On the shell's default: beni 1.8 s, the other Zig 82.0 s
on its own cache, then beni 3.7 s. A second worktree with an empty
`.zig-cache` took 7.2 s and compiled no runner.

**What I learned**

The global cache is safe to share where the local one was not. Zig names
each input file of a manifest relative to a prefix: the working directory,
Zig's library, the local cache, the global cache or the build root. In the
global cache, every path was under Zig's library (`std/`, `compiler_rt/`,
`compiler/`) or the global cache (`b/`). In the local cache, 82 of the 200
newest manifests name `src/`, `tests/` or `build.zig`, which resolve to a
different file in each worktree. The objects in the global cache do hold
one absolute path: the global cache's own directory, as debug data.

`zig env` prints a cache directory under the working directory as a
relative path, and any other as an absolute path.
