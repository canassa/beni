## 2026-10-25 13:27 CET — Ownership checker v2 design: the re-check

**What I did.** A second Opus re-check of PR #1010 confirmed the four soundness blockers and the widening closed
and found five more defects, each verified by hand before changing anything: the index-exchange rule accepted a
duplicated row through nested guards (`dup2`), so it is now a flat decision chain on the index — the principled
form, since position `eₖ` then receives exactly one take; a cell's singleton/summary class must come from the
assumed class of the round, and κ, `writes` and `once` are recomputed rather than joined, or `List.map` sticks
at `shared`; a group re-walked once per round while a `W` bit rotated through N parameters, so use bits now flow
along the recorded argument→parameter edges with the cells; the holder search scanned the live scope per demand, so
holders now come from an inverted index over the persistent-set nodes with expiry at last use (columns and
comparison-ordered trees, no map keyed by a dense id); and S3a–S5 needed core's classes that only S6 would carry,
so a minimal block moved into S2b and `Fix.propagate` into S3b (83 days). Lemma 1 (ii) now names the exception
under a materialisation in force and rests it on O9. One verifier of my own re-ran the five programs.

**What I learned.** (1) "Guard set equals take set" is not a permutation; the *structure* of the decision (a flat
chain) is what makes each position receive one take. (2) A non-monotone component (here κ through the
singleton/summary class) must be recomputed, not joined, or a pessimistic first round is permanent. (3) An
inverted index that is linear must be built on the sharing the persistent sets already have, with expiry, not on
per-holder enumeration.
