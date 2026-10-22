## 2026-10-22 03:06 CEST — Make empty collections ordinary unit functions

**What I did**

Answered the owner's review of #664: `Dict.empty` and `Set.empty` become
ordinary functions of `⊤`, called as `Dict.empty ⊤` and `Set.empty ⊤`, like
`Schema.defaultOptions` since 2026-10-19. Replaced the proposed compiler
lowering of constant-shaped empty references in all four affected design
sections. No name-based lowering or compiler special case is specified.
The previous diary describes the superseded draft; it is left intact.

Paused auto-merge while preparing the correction. The exact unfiltered gate
passed on dagon with the self-hosted compiler and the shared global cache;
`flock /tmp/beni-codex-gates.lock` serialized this run with other sessions.
Log: `zig-out/ordered-dict-unit-empty-gates.log`. No local Zig, LLVM option,
size/speed study, budget increase or weakened check.

**What I learned**

Explicit construction is the owner's preferred public API. Passing either
empty function as a value now follows the normal calling convention and
allocates at each call; reading a binding to a constructed value still aliases
that value. No special treatment of qualified names is needed.

The separate implementation draft has followed this correction. Before any
runtime change, the new DictInsertionOrder and SetInsertionOrder fixtures both
failed in development and release on the old compiler for their intended
reasons: sorted iteration and equality that ignores insertion order. The
baseline log is `zig-out/dict-insertion-before.log` on dagon. These red fixtures
are in the implementation worktree, not this specification PR.
