## 2026-11-06 20:23 CET — number rows by entry, not depth

**What I did**

- The review of #2161 failed it: `Pairs` compared a row's low with its depth, where Tarjan compares
  an entry number. A closed member's low is a depth a later sibling can stand at, so a cross edge
  looked like a head and solved a value made under a cut. `Xc21`, `Xloop` and `Xfoldr` trapped.
- Rows are numbered by entry. `run/SanitiserPairCrossEdge*` pin it, with twins, and `Pairs.zig` has
  the shape and a random system test.
- Corrected what I had overclaimed in `ownership-v2.md`: the head rule, `kept`, G12. `kept` is
  accumulated, not solved; G12 stays open for #2166 and #2160. The owner decided `Pairs.solved`
  stays, an exception for this table only.

**What I learned**

- **The three in-source tests of the first version never ran.** `Pairs.zig` was not in
  `src/beni.zig`'s list, so a filter matched nothing and printed nothing, and I read that silence as
  a pass. A test is not evidence until it has been seen to fail.
- 27,120 generated programs missed what 15,000 random equation systems caught in a minute: the
  defect needs an exact edge order. Model the algorithm as well as the programs that reach it.
- My claim that the answer does not depend on the order was true of joins only. `kept` is not
  monotone. I checked what does hold: 1,807,980 equations, none asks more than its row.
- I called the retained table "not a cache" in the first PR. It is one.
