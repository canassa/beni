## 2026-10-15 19:16 CEST — Research 103: which platform runtime a page runs

**What I did**

- Built `bench/runtime-coverage/`. It runs every real app's corpus scripts
  (Conduit's three, TodoMVC, Sternhalma, Bike Wars) and the table app on both
  browser platforms' release builds in headless Chrome. V8 block coverage is
  mapped back to beni declarations through the release maps. Every transcript
  matched its golden except Sternhalma's, where Chrome rounds style pixels and
  the fixture has no `.chrome-expected`.
- Classified every never-executed piece of platform runtime into four kinds.
  (a) is code the compiler could know is unreachable. (b) is framework still
  shipped on direct. (c) is guarantees the scripts do not reach. (d) is code
  that can never run. Research 103 has the tables. Conduit tea ships 7.2 kB, of
  which 3.0 kB never ran and 1.0 kB is removable. Conduit direct ships 8.4 kB,
  of which 3.2 kB is the framework: TEA's row runtime inside helper templates,
  and the run-time template protocol.
- Landed one runtime-structure trim. `Rt.template` became `template(html)` and
  `templateOf(html, flags)`. On today's master that saves 122/63 B on Conduit
  and 49/30 B on Bike Wars. Pages with no flagged template are byte for byte unchanged.
- Prototyped field-value folding in `Spec`, saving 146/105 B on Conduit
  through request body kinds. The coordinator gave value-directed elimination
  to another agent, so I reverted it and kept the patch in
  `results/field-values-prototype.patch`.

**What I learned**

- On direct, "compile the framework away" is not done for markup that helpers
  return. Even TodoMVC ships 0.9 kB of template-selection protocol that
  interprets per-key masks the compiler wrote as strings.
- The command arms cannot be folded until fact 3 sees list elements.
  `List.base` reads a non-array list through `$plain()`, a method using
  `this`, so every element becomes ⊤.
- Beni's keyed rows (1.6–1.7 kB) are smaller than Solid 2's `mapArray` plus
  `reconcileArrays` (2.4 kB). Research 102 compared them against the wrong
  Solid file.
- Brotli prices shape. A tighter parse in the new `template` made TodoMVC
  16 B larger. Writing it as `templateOf`'s folded steps kept it identical.
