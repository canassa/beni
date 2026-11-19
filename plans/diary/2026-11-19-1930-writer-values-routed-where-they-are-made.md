## 2026-11-19 19:30 CET — Writer values routed where they are made

**What I did.** #2574 (blind round AM's borderline 1). Kernel §12 item 5 let a writer value
answered by a call, kept, or taking a callback be "the plain function, which copies" while v3
judged its calls as writes: a copying fallback and an oracle blind spot. Rewrote the item: a
writer of `List`, `Dict` or `Set` named as a value gets its own accepted v3 line
(`Enforce.valueWriter`, through a platform's alias too) and the lowering routes the value where
the reference is (`_sanitize$writer`, and the new `_sanitize$writerWait` that settles a parking
callback writer through `Task.andThen`). Calls through a `let` alias use the bare writer, so
nothing is routed twice. Kept forms stay refused and the message now names the fix. Fixtures
`run/WriterValuesRouted`, `…Live`, `WriterValuePlatformAlias`, `…Live`, `WriterValuesKept`; the
sweep `writer-values.mjs` (1 248). Research report 163.

**What I learned.** Routing at the call cannot work for a writer value: v3 judges a captured
writer at the closure's call (`flowCaptures`), and the call inside the lambda has no line at all,
so only the value itself can carry the routing. Under the `useReaches` mutant the base let 366 of
384 accepted live twins print SAME: they copied. On the lane all 384 trap. The ledger and every
real-root verdict are unchanged.
