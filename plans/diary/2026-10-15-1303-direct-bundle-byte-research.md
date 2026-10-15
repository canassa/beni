## 2026-10-15 13:03 CEST — Direct bundle byte research

**What I did**

Read CLAUDE.md, research 95/97, hand-minify and the Solid/dom-expressions
sources. Reproduced release sizes for Conduit, TodoMVC and table without
compiler changes. Recorded isolated and ordered brotli attribution, seven
prototype encodings, forty differential page transcripts, lookup kernels and
a fresh-page Conduit comparison. Wrote research 98 and prepared its PR for
Claude review; no merge is authorized.

**What I learned**

The 41 kB Conduit mask matrix costs only 1,598 B brotli in isolation; patch
entries cost 3,496 B. Short path IDs save 589 B with no established speed
change in the fresh-page batch. Complete group arrays save 233 B but need
layout timing. Packed u32 masks lose compressed bytes. TodoMVC is 566 B
larger under direct; table is 1,025 B smaller and emits no helper protocol.
Local checks have the two documented macOS case-folding failures; the
hardware-budget gate is owed on supported x86-64 Linux.
