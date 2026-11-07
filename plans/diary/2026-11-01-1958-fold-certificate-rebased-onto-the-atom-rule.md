## 2026-11-01 19:58 CET — fold certificate rebased onto the atom rule

**What I did.** I rebased #1529 onto master `611bbc6b0` and built #1572's rule: rule 4 reads every class of one certificate that lands at one caller class as one multiset (`KappaRead.ruleFourAgg`, `certClassesAggs`), with one group id per `(environment, i, L, node)` and `Cond.assertClassesSum` as its check. I fixed #1570 in the block reader, added `o/FoldCertificateClasses` (rows 20–22) and `o/FoldCertificateImportedPair`, and ran a Node oracle over 50 programs.

**What I learned.**
- The rebase's hard part was #1554: `propagate` moved to `Propagate.zig` and became fold-first, so #1529's union sides at a fold had to be rebuilt there (`keySides` in `foldPos`, and the same in the reference walk).
- The block reader made class images through their constructors. Under the atom rule a class can be a plain leaf, so every producer with those cells shared one node and one `fold_cond`. The writer's images are raw nodes, and the reader now keeps them raw too.
- With the rule, every row of the spec's *With the rule* column holds line for line, the oracle finds 0 unsafe in 11 544 runs, and forcing every line in place finds 24 unsafe programs.
- `LevelFresh`'s C5 panic is master's: walking a group member twice against the same ports gives two read-offs from its third walk on (#1582). R-7.4's ring walks once less on the rebased head and reads more precisely (#1588). Both keep the gates red, so the PR branch was not force-pushed.
