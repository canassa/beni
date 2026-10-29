## 2026-10-29 13:50 CET — Prerender: an embedded engine, decided

**What I did.** Took the owner's decision on `prerender.md` §10 question 1: the prerender tree
runs in a JavaScript engine compiled into `beni` (QuickJS or its class), not in an installed
Node and not in a Zig evaluator. §5.1 says what the engine owes (browser-equal output, rule 5
determinism, measured cost); P1–P3 still use the `node` on `PATH` so the lowering and hydration
work is not blocked; a new slice P5 swaps the engine in and withdraws `prerender_needs_node`,
with `prerender_unsupported` for the playground.

**What I learned.** "Why is Node needed?" had a short honest answer: nothing in prerendering
needs Node, only an engine that runs the emitted code. A Zig evaluator is the expensive option
because core's `foreign` siblings are JavaScript, so it would be a second semantics of core that
must match the first digit for digit.
