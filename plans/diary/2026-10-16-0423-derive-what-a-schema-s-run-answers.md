## 2026-10-16 04:23 CEST — derive what a schema's run answers

**What I did.** Issue #218, the owner's decision: no one ownership word for
every schema; the compiler derives each run's answer from the schema, per
direction. Specified as `ownership-checker.md` §30.10 (with amendments to §24.8
and §26.7) and `schema.md` §6, §11.3 and §12.10, then built in
`src/own/Ownership.zig`. A `Schema` value has two analysis slots, `⟨decoded⟩`
and `⟨encoded⟩`, as markup has `⟨render⟩`/`⟨events⟩`: what a run in that
direction may answer that it did not build from its input. Runs (`parse`,
`decode`, `read`, `encode`, `write` and their `With` forms) are asserted rows
that answer fresh plus their slot; makers fill slots (`box` — every
interpreting builder — `⊤`; `list`/`nullable`/`erased`/`converted` their
arguments'; `conversion` what its functions return that outlives the call;
`Schema.value` an input mark). A declaration's members (`S.schema`, `S.parse`,
…) get rows derived from its resolved plan (`via`s, `value` primitives,
referenced declarations and derived codecs). `Json.decode` & co. and
`Schema.derived` read the call's `codec` evidence. The input mark lets the
answer hold the program's own value only where a `Value` or a `backward`
hands it back. `browser/direct/ApiLogin` is promoted from
`tests/pending/`; `ApiItems`' twin is over the test budget as four builds in
one case (4 780M, like `HttpJson`, #184) and is deleted — the tea page runs
it. `ownership/SchemaAnswers` and
`check/bad/direct/SchemaConversionShared` pin the rule. `parse`/`parseWith`
lose their words (their trusted-surface and body pins go with them).

**What I learned.** A `⋆` entry of a record-typed cell is never taken for a
list inside it by a demand (the type filter drops it), so "may hold any part
of x" needs `x⋆` as well as `x`. `S.schema ⊤` takes `⊤`: a nongeneric
member's arity is one, not zero. On master `Item.parse` had no summary at all
and its answer was taken as fresh, so a conversion returning a top-level list
was accepted (`assumed`); it is now refused. §11.3's "a pure default may be
evaluated once" is observable once lists are written in place — noted for the
default slice.
