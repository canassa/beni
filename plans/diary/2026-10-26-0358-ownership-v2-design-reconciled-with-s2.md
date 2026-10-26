## 2026-10-26 03:58 CET — Ownership v2: design reconciled with S2 as built

**What I did.** Edited `docs/design/ownership-v2.md` in place to match
S2's code (#1036, #1037) and the reviewer's rulings on #1036. §2.3: `leq`
is γ-inclusion and kind-blind, multiplicity compared only through κ
(`Cond.kappaLeq`), with the reason the structural rule fails `F(x) ⊑ x`
under `widen`; `widen` never expands a union's or positions node's sides,
a member rides beside the class image as a union side, there is no
`folded` bit, and no stored κ reaches a widened image at a summary
position; `cellsAt` of a positions node is a set and the multiset is
`dagKappa`'s, through `Radix.intersection`. §2.9/§3.4: S2's κ root is a
holder-owned persistent map keyed `(node, position class)` per value,
with S3a's per-value roots and `(NodeId, PathId)` trie kept as the later
step. §3.3 drops the folded bit, §3.5 states the supply key as built,
§5 lists the real exports, Appendix B's FoldedPositionsLost describes the
real fold. §2.5 needed no change: `▷` lowers to the same BIR call.

**What I learned.** When the code is right and the text is wrong, the
fix is to say why the text's rule cannot work — here, that a structural
`leq` cannot match a collection kept as a side beside a widened image —
or the next reader will rebuild the rule that was dropped.
