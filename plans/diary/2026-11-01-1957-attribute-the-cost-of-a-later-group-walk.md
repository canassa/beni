## 2026-11-01 19:57 CET — Attribute the cost of a later group walk

**What I did.** Measured, with scratch instrumentation on master, where a later walk of a recursive group
spends its records for GroupFieldShift at n = 4/8/16, a copied `removeMin` and a copied `descend`
(#1372). Prototyped in scratch two parts of a rule (interned view environments, a cover test that
carries once) and wrote the attribution, the rule and the numbers into `ownership-v2.md` §8 slice 4,
§4.1 and Q8. Docs only.

**What I learned.**
- Since 4b a later walk is mostly deliveries, and each delivery reads the whole port: about c · K_r for K_r
  κ entries, c 140 → 244 at n = 16. `dropCovered` relabels the whole snapshot once per arm, and every
  view is new per call, so 90 % of κ memo lookups find no entry.
- The two prototyped parts take GroupFieldShift at n = 16 from 1 444 551 to 922 825 records with no
  verdict or summary change.
- `removeMin` is different: its walk is already linear in its class, but the class grows about four times
  in arms a round with every κ `lost`. That needs a design decision on a quotient of arms, not a reader rule.
  `descend` is `propagate`'s states per node.
