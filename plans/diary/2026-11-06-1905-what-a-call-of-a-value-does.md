## 2026-11-06 19:05 CET — What a call of a value does

**What I did.** Review of #2153 reopened it. `(x.m) a` no longer reads the method as the call, the alias chain is one reading used by calls, function references and evidence, and a value's lambda or constructor is published as a called contract at `ε`. Any other value called answers `host`. The callee code moved to `src/own2/Callees.zig`, so `Groups.zig` fell from 1 898 to about 1 740 lines.

**What I learned.** `⊤` was too strong for a top-level value: its closure holds no frame's object, so §2.10's `host` argument applies as it stands, and that one change frees an unrelated list. My first try at the false "x holds it" message marked every `⊤` hold approximate, and it broke six fixtures: a `lent` answer is `⊤` too, and there the sharing is real. Reverted, #2152's remainder and a new issue hold the rest. The sweep's remaining refusals are not caution: a value that spawns a fiber can keep its argument (`W1keeper`).
