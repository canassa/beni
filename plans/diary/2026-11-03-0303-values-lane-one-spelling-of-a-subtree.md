## 2026-11-03 03:03 CET — values lane: one spelling of a subtree, a many leaf's second route

**What I did**
- Found why `Dict.descend` took 5 rounds with F7. Round 0 spelled `right`'s slots one by one. Round 1 spelled them `#0.4*` (a deep instantiation over `Step key value right rest`), and the equality saw a change. Added `Canon.zig` (L5): at the read-off, a contract's selections spell a subtree of at most `below_min` slots written out. descend is now 3 rounds and 25 773 records, with F7 kept. Spec §2.9.1 and §5 amended.
- Found and fixed #1748: a `many` leaf read whole gave both copies one route, so `idd`'s `π1{ε*}` over `P t t` asked `t` once. A write of one side was accepted (sanitiser DIFF on the base). New build_test; spec §2.9.3.
- Measured `Schema.shapesOf`: the #1740 widen is 2 108 of its 5 622 growth. Posted the lead (`uniformAtoms` for a whole subtree) and a `Subtree.meetRun` proposal for `Descent.holdsAt`'s k² loop on #1714.

**What I learned**
- The other normal form (written-out slots collapsed to the deep occurrence) is equal at the callee but not at the caller. A deep occurrence instantiated under a folded `⟲` name projects more than the callee's slots did. The k-list family took 7 rounds, and `FoldSymbolicCall` got two deep spellings of one set that read as one object twice. Measure both directions before choosing a normal form.
- The cost table's rows do not cover every declaration with growth. List the growth of every core declaration (`awk` over the dump) for base and head: that is how the +399 on `Schema.described*` showed up.
- Filtering the profiler by an account's continuation cap gives one declaration's records out of a whole-core run.
