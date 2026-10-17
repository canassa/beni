## 2026-10-17 09:28 CEST — Every ownership cap, loud or conservative

**What I did.** Issue #271, first half, as the owner decided (split #271). Two silent caps were holes. Past
`inst_depth` = 4 callbacks, `callbackLoanDemands` and `returnedParamDemands` dropped a demand and `instProv`
gave a `⊤` with no alias of the argument, so a fifth link let `List.push xs 1` through while the chain's
result was `xs`: now the `callbacks` limit, an error at the declaration, with `⊤limit` as the result
(`ownership/CallbackChain`). The evidence walk stopped eight terms deep and missed a writing `compare` in the
evidence of `List.sort` on lists nested ten deep: every term is now visited once, with an explicit stack and no
cap, because a limit would refuse harmless sorts (`ownership/EvidenceDeep`). An unresolved reference and an
unbound capture read as `⊤`, not as nothing, and a limit outside a declaration is an assertion. §16.7 has a
`callbacks` row and a table of every cap, each loud, conservative or removed. The path cut `k_limit` = 8 stays
silent: the hole is real (a caller cuts `r.a.b.c.d.e.f.g.h.x` that its callee reads as two places), but a loud
cut refuses core's `Schema` at 8 and at 16 steps, and a first conservative attempt refused `ApiItems`; issue
#286 owns its design. Gates green, `bench/ownership-everywhere.mjs` 0 of 850.

**What I learned.** core's `Schema` builds paths with no fixed depth — nested tuples for a record's fields,
chains of `parent` records — so the cut is what makes those summaries finite, and a cut is a cap no larger
value lifts. A cap that guards a walk over something the program bounds (the evidence terms) is better
removed than made loud: it refused nothing real, and the walk is linear with a seen-list.
