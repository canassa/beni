## 2026-10-22 02:51 CEST — Specify ordered Dict and Set

**What I did**

Resumed #294 after the owner cleared space on dagon. Rechecked its decisions
and #663. The previous RAM-backed worktree's Git registration was gone;
created `/home/canassa/beni-ordered-dict-resumed` from freshly fetched
origin/master `776a3930b`, with its own local cache. Synced the dated
specification draft and ran exactly
`ZIG_GLOBAL_CACHE_DIR=$HOME/.cache/zig-beni nix develop . -c zig build gates`
there, with the self-hosted compiler. It passed (exit 0). The documentation
step printed its informational example summary with a warning marker and
misleading `failed command` text, but there was no test failure. No Zig ran
locally, no LLVM option was used, and no size or speed measurement was made.

Completed the specification in language.md §0/§6.8, backend.md §4 and
ownership-checker.md §32, with matching amendments in checker-v2.md §37,
fast-compiler.md §3.1 and static-dispatch-spike.md. Specified private key/value
entry pairs plus Map positions, scalar-key restrictions through generic and
cached types, insertion-order APIs and equality, no compare, stable sortBy,
key-based swap, clamped insertAt, explicit shallow copying and fresh empty
seeds. Catalogued every Dict/Set operation's ownership contract and the
required removal of the old tree exceptions. Kept the original decisions,
section numbers and previous diary entry intact. This is the specification
step; no public implementation or generated API surface changed yet.

**What I learned**

An insertion writes dictionary storage, independently of whether its values
hold mutable cells. A focus that returns a new value writes the entries even
when its callback only reads. The primitive summaries must distinguish that
root write from an exclusive loan of one selected value. Repeated payloads
and copies must retain their deep alias conditions. #579's read-then-replace
case must refuse once the representation lands; #663's grow must recover.

An empty mutable seed must be fresh per construction despite the existing
constant-shaped API. A shallow dictionary copy also needs fresh private entry
pairs, so replacing one pair's value cannot change the other dictionary.

Gate evidence is `zig-out/ordered-dict-spec-gates.log` in the dagon worktree.
The specification PR is Part of #294; implementation, generated skill API,
checker cleanup and fixture recovery follow separately. Final cleanup will
preserve worthwhile evidence under `~/worktree-evidence/` before removing
this session's dagon worktree and temporary files, as the owner instructed.
