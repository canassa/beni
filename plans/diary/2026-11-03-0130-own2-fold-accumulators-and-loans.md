## 2026-11-03 01:30 CET — own2: fold accumulators written in place; loans pinned

**What I did**
- Measured #1713 on `own2-fiber-rows` and again on `own2-integrated`. On the integrated head, 308 demands are accepted by v1 and refused by v2. 49 of them are intended (comparison, held operand). The largest group is `disjoint (approx)` (95), and half of those are folds whose callback writes its accumulator.
- Found the cause. A fold hands the callback's answer back as the next accumulator. The answer is unknown code's, so the supply condition read through the recursive call was `no`. Built the `fed` occurrence (spec §2.11.3, `Fed.zig`). At the pass, that answer is read as what the direct call was handed as the same argument. A caller with a known code holds `fed` only when the code answers that argument and fresh objects. 16 positions are accepted now, and `List.foldl`/`foldr` included.
- Found a hole while building it. The first version did not judge the answer where it is handed back, and a walker that also keeps the answer (`[ a, …keepFold rest a f ]`) trapped under the sanitiser. The part is now judged as the argument. That is pinned by `run/SanitiserFoldHeldAnswer`.
- #1739: on `own2-fiber-rows` I built a holder-side made-after rule. On the integrated head #1714's made-after rule already accepts those cases, so I kept only a fixture and dropped the code in the port.
- #1735: stopped at a wall. The `⊤` is `Js.construct`'s unworded result. Proposed a rule that a foreign's unknown result holds only host-made or escaped objects, for a decision.

**What I learned**
- The supply condition is one selection: all occurrences pairwise distinct. So reading an answer as "its supplies" must use the fed-back argument only. Including the element supply made index-based folds (`foldlFrom a i …`) ask the array's elements apart from themselves.
- File line targets are tight: Eval, Distinct, Resolve and ContractText sat at their limits. A feature that is a new rule goes in its own small file, at a layer below its callers.
- Measure on the head you will land on. Half of what I built for #1739 was already on the integrated head.
