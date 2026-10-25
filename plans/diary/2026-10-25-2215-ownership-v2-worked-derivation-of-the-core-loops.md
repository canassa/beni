## 2026-10-25 22:15 CET — Ownership v2: worked derivation of the core loops

**What I did**

I derived on paper, with only §2 of `ownership-v2.md`, the inferred classes of `mapHelp`, `List.map`,
`foldlFrom`, `List.foldl` and `List.foldr`. I also derived the five functions that v1 asserts and v2 left to
inference (`base`, `offset`, `unsafeGet`, `sliceOf`, `sortWith`), and eight caller cases. The result is the
new Appendix C, cited from §2.13.16, §8's S2b row and §8.1.

A read-only adversarial verifier found no unsoundness. It corrected the κ of a fold's result and two refusal
causes, and changed `A` to `R` on `π₁[*]`.

The PR review then corrected the rest of the `use` bits to §2.10's read-off:
- π₄ of `foldlFrom` and π₂ of `foldl` are `RA`.
- π₅ is `R`.
- `unsafeGet` and `sliceOf` are `RE`.

The review also:
- showed that the unrestricted fix for gap 3 is unsound;
- added option (c) for `sortWith`;
- fixed the five C.10 points in their own sections.

The manager decided gap 1 from R-5.10.8: the four representation readers are `List` array primitives with
existing words. Part of #1014. Only the design document and this entry changed.

**What I learned**

The loops reach their required rows once `base` and `offset` are asserted. Inferred through the wordless
`Js.get`/`Js.call` and a `⊤call`, they let π₁ escape, and every `List.map xs f` would make `xs` escape.

`sortWith` keeps no record condition under the current rules. Index ranges would fix that, and so would a
`copy` followed by a swap-only sort.

A fold's accumulator is accepted in place, but its element condition is `lost`. "Taken elements of one
folded split are apart" is sound only between this call's own element and the elements that came back
through the feedback. Two values that came back through the feedback may come from one earlier call.

Gaps 2 and 3 are the owner's.

**Second review round**

The re-review found a hole in §2.2 as merged (#1029). Two `taken` elements of one container from distinct
splits were apart under the container's κ, but the index obligation covers only one traversal. In
`List.push (List.map xs λl → l) (List.foldl xs [] λx _ → x)`, `xs`'s last list sits at two positions.

§2.2 now defines a traversal by the label's entry prefix into the pinned loop group, with recursive folds in
the prefix excluded. My verifier then broke the prefix-only rule with `each ws xs f = List.map ws (λ_ → List.map xs f)`, where an ordinary fold hides one traversal per callback activation. So splits now carry a `single` bit, which is cleared when an actual's own splits leave through a folded callback label. Two traversals give `lost`. Gap 3's (a) depends on that fix. Four red twins went into
Appendix B.

v1 refuses both counterexamples on `browser-inline` (no live miscompile; comment on #1029). A label already
carries a call chain, so the traversal identity costs no new representation, only a bit per fold saying
which trigger made it.

**Third round.** The re-review could not break *Traversals* within one module, but blocks did not carry it:
§3.6's label record had no `single` bit and no entry mark. An importer would have to guess, and both guesses
are wrong: one reopens #1029 through an imported `each`, the other costs `List.map` its exclusivity. Blocks
now carry `single`, `entry` and the fold kind, with a determinism rule and a decode-failure rule (never
default to `single`). `OWN2` is v2, and `NestedTraversalAcrossModules` is an S6 red twin. Any new per-cell fact
that §2 compares must enter the block format in the same change.
