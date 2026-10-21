## 2026-10-21 05:32 CEST — a var that copies one var has that var's summary

**What I did.** Issue #568, part of #464, on top of #567. In `Pts`, a var with
one copy edge in that links summaries, holding nothing its source lacks, gets
no field summary of its own: `summaryOf` answers its source's, up a chain of
such copies (`aliasSummary`, `resolve`). It splits into its own (`split`) at a
second source, a site of its own, or `top`, and a var whose summary dies splits
the vars sharing it first. What read the shared summary through the var — load
cells, summary links, spreads — is listed on it and applied to the new summary
at the split; the spreads are woken. A mark's load cell is now a list. Five unit
tests (aliasing along a chain, a second source with the facts of a run that
never aliased, a fold, a filter mismatch, a source going `top`), the corpus case
`emit/release/inline/SpreadCopiesWide` (46 children: 4 750M → 3 852M, blessed
with the base compiler), and an *As built* note in `backend.md` §9.

**What I learned.**
- The issue's condition, one source and nothing folded, is not enough. The
  source must also be at the same summary depth (#562's regress guard reads the
  summary's vars' depth), its summary must not be dead, and a summary that dies
  must first split the vars sharing it: an uncapped copy of a capped var keeps a
  live summary when the source goes `top`.
- Redirecting readers would have meant a forwarding lookup on every summary
  access. Recording each reader on the aliased var and replaying it at the split
  is sound because whatever a reader took from the old summary is a subset of
  the new one.
- Pre-allocating summaries at discovery, as `summaryOf` did, is what keeps a
  cycle of copies from recursing. Deferring only the vars that could alias, and
  allocating an undecided source just before a feed, keeps that property.
- dashboard N=64 without `withDefault`: edges 269k → 152k, `specialise` 289 →
  229 ms, 0.37 → 0.31 s, 181 → 159 MB, output identical.
