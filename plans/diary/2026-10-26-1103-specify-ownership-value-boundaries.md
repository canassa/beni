## 2026-10-26 11:03 CET — Specify ownership value boundaries

**What I did**

Read the implementation in src/own2 and every review/reply on #1060 and the preceding word/spread/core stack. Rewrote the ownership design and requirements in place: observable κ reads and shared owners, global canonical blocks, selected result/write-back words, trusted pin scope, and the remaining slice interfaces. Preserved the minimal-block As built account, including its actual complexity. Updated dependencies and scope estimates; documented the remaining v2-only metadata spelling choice.

Filed #1063 (projected κ lost by propagation/comparison), #1064 (propagation hash equality and invalidated slices), #1065 (block canonicalisation cost), and #1066 (reservation after work). Two temporary master probes reproduced #1063; their diff/log stays in ~/.cache/beni-agents/own2-plan-review and no probe source is committed. Requirement/pending mapping and the module DAG were checked mechanically. This is docs only; v1 and v2 code are unchanged.

**What I learned**

The same semantic position contract must govern inference, comparison, substitution and serialization. A successful byte round trip can hide a stronger decoded read. Shape sharing and snapshot ownership are separate identities. The architecture remains appropriate, but the current implementation has concrete integration blockers and unproved source-cost claims; a loud limit does not justify charging after work. The reference allocation is 164 days with a 145-day dependency path, not a calendar forecast.

Full `direnv exec . flock /tmp/beni-codex-gates.lock zig build gates` passed.
The compiler probes intentionally failed against master to demonstrate #1063;
they were removed before the green gate and are retained only in scratch.
