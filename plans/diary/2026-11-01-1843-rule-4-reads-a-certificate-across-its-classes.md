## 2026-11-01 18:43 CET — rule 4 reads a certificate across its classes

**What I did.** I wrote the spec amendment for #1559: §2.9 rule 4, *Across the classes of one certificate*, with notes in §2.3, §2.11 item 3 (d) and §8 slice 4. I merged #1529's head with master `3460de8d3` locally, without pushing it. I traced `same`'s read-off at `hypAggs`. Then I prototyped the rule in scratch, with three unsound variants built as controls.

**What I learned.**
- The mechanism is the one #1559 guessed, and it is in the build, not in the spec. At `same l`, `same`'s three classes (`#Node.1`, `#Node.0#Node.1`, `#Node.2#Node.1`) all land in one caller class. `hypKeys` numbers groups for each class, and `certClassAgg` takes the maximum within one class. `classesMerge` then adds `X = π1#Node.0⟲#Node.1` from two classes. The spec's group `(call, i, L, node)` never had a class in it.
- The fix: one group across the landing classes, (a′) on the union of their keys, each key's multiplicity summed over the classes, and the maximum over distinct keys. Lemma R4′: the read is a function of the sum of the certificates that land at a caller class, so how widen splits a knot does not change it.
- The witnesses go green, row 7 is exact again, and #1538's lines stay accepted. The oracle finds 0 unsafe in 42 744 runs, and the control finds 14 unsafe programs.
- The corpus near-miss rows cannot isolate rule 4: each one is also refused by its frame's own κ. So the rule needs unit cases on certificates built directly, as row 19 has. Each unsound variant fails exactly its case there.
- The memo of (a′) needs the key set as its key now. A group's keys depend on which classes land at the caller class.
- I found two more problems. (1) #1570: the block reader joins `fold_cond` onto interned leaf nodes, so the imported `same` reads `unroll`'s failure. (2) On my merge, `LevelFresh` panics in C5 with or without the rule. It may come from my conflict resolution.
