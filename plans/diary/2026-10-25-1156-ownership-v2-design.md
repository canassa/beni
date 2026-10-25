## 2026-10-25 11:56 CET — Ownership checker v2: design and implementation plan

**What I did.** Wrote `docs/design/ownership-v2.md` (#1006): the HOW for `ownership-requirements.md`. Family: a
shape graph / abstract interpretation with materialisation, taking Morphic's type-shaped slots folded per type
SCC as the place set, Koka/Lean's loud contract and SCC driver, Clean's deep uniqueness as the sharing predicate.
Core: places from the solved type graph (a cyclic type is one place: #955), hash-consed shape nodes with a
`delta` node for record updates and joins over one base and a lazy `union` node where a join cannot merge
(#856, #716, #975), cells with `elem`/`others`/`level`/`below` refinements whose non-alias is a condition
(#970, #971, #977, #987), one `κ` per node with an `apart` group atom (#693), classes grafted at calls, one
worklist fixpoint driver, every asserted row as words (four new words and a worded `Send` alias). A soundness
lemma with twelve per-rule obligations, concrete table layouts, a layered module DAG with a gate test, ten slices
(~58 implementer-days), and a 260-row coverage appendix. One adversarial review agent found 34 items; 31 were
folded in (the rest were already fixed or cross-references).

**What I learned.** (1) A materialised `reach` set per node is quadratic on a chain of record updates; a
reverse index (cell → nodes, parent links, node → holders) with a dead-holder skip is linear. (2) The eager join
of two DAG-compressed values has the BDD `apply` bound; making the join lazy (a `union` node, projected on
demand) removes the multiplicative term instead of arguing it away. (3) A split's exclusivity must be a
*condition* carried as `xreq`, not a bit, or every split on a parameter is refused. (4) Constructor paths of
one value are alternatives, not products — without saying so, Conduit's `status` field is a false `disjoint`.
(5) `Ref`'s `◆` must be a holder/escape barrier or every captured `Ref` escapes its contents. (6) The
`writes` bit for `eq`/`compare` must mean a write of something that *arrived*, or every builder's `Builder`
makes `List.map` a comparison that changes a value.
