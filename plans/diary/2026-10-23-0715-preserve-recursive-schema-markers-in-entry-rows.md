## 2026-10-23 07:15 CEST — Preserve recursive schema markers in entry rows

Rebased the entry-row removal over #820 after it landed during CI. The
recursive-schema analysis and its fixtures are preserved. The only conflict
was the ownership-summary version: schema endpoint markers keep version 35,
and invalidating template-row reports becomes version 36. The entry protocol
and sharing checks need no change.
