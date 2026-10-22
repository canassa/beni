## 2026-10-22 03:41 CEST — Stop ordered Dict on ownership refusal

**What I did**

The Tea specification passed the full self-hosted gate on dagon and is in
#669. The earlier #664 specification merged with all checks green. Rebasing
the uncommitted runtime draft picked up #456 and its pending DictFocusGrow.
The runtime draft now compiles as Zig but embedded core checking refuses
Set.sortBy's scalar-key callback as a shared-list write. Stopped under rule
10 and filed #670; no checks were weakened and no budget was raised.

Preserved the incomplete source overlay, patch and diagnostics under
~/worktree-evidence/beni-ordered-dict-resumed on dagon, cited from #670 and
#294. The overlay is evidence, not a green implementation or a landed fix.
The platform table migration, remaining collection-use migrations, skill
API generation, checker cleanup and grow recovery remain unfinished.

**What I learned**

The refusal says Dict.sortBy changes what it hands its callback at π1[*],
even though Set's callback receives an Int/String key and sorting permutes
storage. The cause may be the draft ownership rows or propagation in the
checker; it has not been isolated. Investigation must preserve the intended
representation and sound negative alias checks before this work resumes.
