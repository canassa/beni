## 2026-10-25 22:15 CET — Ownership v2: worked derivation of the core loops

**What I did**

I derived on paper, with only §2 of `ownership-v2.md`, the inferred classes of `mapHelp`, `List.map`,
`foldlFrom`, `List.foldl` and `List.foldr`. I also derived the five functions that v1 asserts and v2
leaves to inference (`base`, `offset`, `unsafeGet`, `sliceOf`, `sortWith`), and eight caller cases. The
result is the new Appendix C, cited from §2.13.16, §8's S2b row and §8.1. A read-only adversarial verifier
found no unsoundness. Its corrections are folded in: the `use` bits, the κ of a fold's result, and two
refusal causes. This is part of #1014. Only the design document and this entry changed.

**What I learned**

The loops reach their required rows, but only if `base` and `offset` have v1's rows. §8's S2b list leaves
them out (with `unsafeGet` and `sliceOf`). Inferred through the wordless `Js.get`/`Js.call` and a `⊤call`,
they let π₁ escape, and then every `List.map xs f` makes `xs` escape. `sortWith` cannot keep the record
condition: `at` makes no split, and the domain has no index ranges. A fold's accumulator is accepted in
place, but its element condition is `lost`: `within` covers a fold of two different labels, not one folded
taken label met across feedback. Each gap has its options in C.9. The decisions are the owner's.
