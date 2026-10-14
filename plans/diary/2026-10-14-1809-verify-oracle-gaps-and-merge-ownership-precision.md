## 2026-10-14 18:09 CEST — verify oracle gaps and merge ownership precision

**What I did**

Verified the reviewed PR head's ownership spec §26.7 already lists render/event
opaque slots including row/tagger propagation, carried constructor callbacks,
and unseen tagger capture requirements, each with its soundness risk. Under
the owner's conditional merge instruction, rebase-merged PR #99 and deleted
its branch. Master now ends at 796010989; the tested checker tree is unchanged.

**What I learned**

The oracle gaps cover the four Conduit error paths through grouped precision
rules, including message mapping. No extra spec amendment was needed before
merging. The separately pinned document-helper lowering gap remains open.
