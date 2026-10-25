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
