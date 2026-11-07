## 2026-11-06 20:15 CET — Compile runtime schema builders

**What I did**

Ported interpreter removal to master's raw worker ABI. Runtime record, tagged and
recursive builders capture child workers; inspection metadata remains separate.
Removed the forced-library flag and its cache/test dimensions. Preserved the
unknown outcome facts of runtime mapping callbacks and added a refusal probe.

**What I learned**

The typed-storage branch's constructor-pruning change does not fit master's raw
ABI. Keeping master's private Schema constructor rule avoids unrelated page
growth. Keeping backward reporting as its existing Boolean also preserves all
Schema emit snapshots while depth-scoped claims handle tagged payloads.
