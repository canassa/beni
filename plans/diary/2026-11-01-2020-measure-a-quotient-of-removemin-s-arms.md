## 2026-11-01 20:20 CET — Measure a quotient of removeMin's arms

**What I did.** Dumped the class of a copy of core's `Dict.removeMin` after every walk, join and delivery
(scratch instrumentation on master, self-hosted Debug), for six rounds at an allowance of 10⁸. Measured five
forms of it with scratch analysers. Wrote the relation, the readers it must cover and the measurements into
`ownership-v2.md` §2.3 and Q8 (#1372). Docs only. No prototype, because no exact rule was found.

**What I learned.**
- The growth is not mostly choice arms. It is unions at the key and value places, and knot images of earlier
  rounds held under recasts: 1 / 2 / 5 / 13 / 32 / 83 knots in rounds 1 to 6.
- Every quotient that keeps which cells occur together in one arm still grows 1.5 to 2.5 times a round. Only
  the pointwise form stays near 22 nodes, and it drops co-occurrence, which the other-path check and
  `Holders` can read. So it is not exact without a lemma that no one has.
- The 10⁸ run takes 7 min 36 s in Debug. Use 4 194 304 (14 s, three rounds) unless later rounds are needed.
