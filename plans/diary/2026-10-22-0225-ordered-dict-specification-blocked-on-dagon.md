## 2026-10-22 02:25 CEST — Ordered Dict specification blocked on dagon

**What I did**

Read CLAUDE.md, #294 and all its comments, #522 and its comments, #580,
#579, #456's follow-ups and #663. Created the isolated local worktree
`../beni-ordered-dict`, branch `ordered-dict-spec`, from freshly fetched
origin/master `776a3930b`. Left the original workspace's untracked work alone.

Drafted dated amendments in language.md §0/§6.8, backend.md §4 and
ownership-checker.md §32. They specify private `[key, value]` entries plus a
Map of positions, Int/String keys, order-sensitive equality without compare,
stable sortBy, key-based swap, clamped insertAt, shallow copy, fresh empty
seeds, primitive ownership rows, Set's inferred wrapper contracts, and the
later removal of the tree exceptions. The draft preserves the sound
construction conditions, records #579's read-then-replace refusal, and names
#663's required recovery of DictFocus.grow. No implementation changed.

Tried to prepare an independent worktree on dagon. Disk checkout made very
slow progress. After cancelling its checkout, prepared a detached worktree at
`/dev/shm/beni-ordered-dict` on the same commit with its own local cache path,
using a source archive from the local clean commit plus the three doc edits.
Started the required command there:
`ZIG_GLOBAL_CACHE_DIR=$HOME/.cache/zig-beni nix develop . -c zig build gates`.
It remained in Nix before Zig started; no test result exists. Cancelled the
client rather than leaving a build queued while stopping. Local `git diff
--check` passes. No Zig ran on the Mac, no LLVM option was used, and no
compiler size or speed measurements were made.

**What I learned**

Dagon has severe Btrfs space pressure despite df reporting about 171 GiB
available: filesystem usage reports 1 MiB device space unallocated and
24.49 GiB of 25 GiB metadata used (97.96%). Our git process was in
`reserve_bytes`, and the Nix daemon was in uninterruptible I/O wait. Other
Nix clients were already waiting too; none was killed or modified. This is
an environment blocker, not a gate failure or evidence against the design.
No filesystem maintenance, budget increase, checker weakening, or permission
change was attempted.

Evidence: `/dev/shm/beni-ordered-dict/zig-out/ordered-dict-spec-gates.log`,
`dagon-filesystem.txt` and `dagon-blocked-processes.txt`; copies at local
`/tmp/beni-ordered-dict-evidence/`. The gate log contains only Nix's dirty-tree
warning. The draft and this entry stay uncommitted: no green-gate claim, PR,
merge, issue closure, API generation or implementation is claimed. Resume
with the specification PR after dagon can complete the required gate, then
continue the separate implementation, checker cleanup and recovery PRs.
