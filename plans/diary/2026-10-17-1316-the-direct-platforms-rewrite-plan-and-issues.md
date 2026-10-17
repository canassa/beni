## 2026-10-17 13:16 CEST — the direct platform's rewrite: plan and issues

**What I did**

Wrote `plans/direct-rewrite.md`: the owner's decision to throw `browser-direct` away and build
the platform again from the output. The spec is the research project's `tea-inline` emitter
(`../reactivity-research`), whose generated JavaScript becomes the goldens; seven slices
(S0 boundary without the kernel, S1 holes and handlers across modules, S2 keyed rows, S3 memo
nodes, S4 lifetime, S5 shared kinds, S6 a real application), each with a golden, a research
scenario and a bar (bytes and CPU ≤ 1.1 × tea-inline, locality flat, compile linear at 256); the
strict rule (errors, no coarse fallback); the guarantee ledger; seven decisions for the owner.
Opened #295 as the parent with #296–#302 (S0–S6) and #294 (`Dict` on `Map`) as sub-issues.
Nothing committed; no compiler change.

**What I learned**

The first platform's causes are all decisions, not limits: the host boundary (`Tea.element` →
`Task` 4.3 kB + `Dict` 3.9 kB raw on a one-widget page), messages surviving across module
boundaries (`switch(a.$)` and a 30-slot scope record per instance in the release output, where
§4.1 says "no message"), no sharing by kind, the derived block re-run (#282), the ownership width
cap, no lifetime. On the research scenarios tea-inline (strategy A) and tea-local (C) tie on bytes
and A is faster on every scenario (2.7× on derived-graph), which refines research 106's "C as the
start": the target is A's output with C's per-kind factory.
