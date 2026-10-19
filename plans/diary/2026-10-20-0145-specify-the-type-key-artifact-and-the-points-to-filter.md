## 2026-10-20 01:45 CEST — Specify the type-key artifact and the points-to filter

**What I did.** Turned `plans/type-directed-points-to.md` (§1 claim 2, §2, §3, slices 2–4; on the
`pts-field-summaries` branch) into normative text for issue #488, under the owner's 2026-10-20
decisions: D1 taken, D2 in its safe form, no cap (#442 stands), no inliner shortcut, D4 not taken.
`backend.md` §3 gains an *Amended 2026-10-20* paragraph on the type-key artifact; §9 gains
*Declared-type filtering of fact 3* after *The combined solver*'s slices; `boundary.md` §4.2 gains
a dated note that the release optimiser relies on nothing of `Js.to`'s contract. Docs only.

**What I learned.**
- Unboxing's boundary set, which the plan offered as D2's safe form, treats a type variable at a
  `Js.from` as opaque, so it still trusts `Js.to`'s contract. The safe form needs a `crosses` bit
  per quantifier in the interface, followed through callers. Only the `Js.from` side needs it: a
  `Js.to` yields a host value (`top`, no site) or an object that went in at a `Js.from`. Following
  `Js.to` through quantifiers instead would make every model `Json.decodeValue` produces wild and
  undo the #464 fix.
- Two erasures inside well-typed code that the plan did not list: `?` returns its subject unchanged
  at another type (`Result E A` as `Result E B`), and a nullary constructor of a parameterised type
  is one object at every instantiation. Both are wild in the spec.
- Linking a summary past a stricter filter is sound but imprecise; folding is exact and costs
  work. The plan had it the other way round ("costs precision").
- Keys must be computed in every build, not only `--release`, or a cache entry a development build
  wrote would give a release build different output.
- In a `browser-tea` page the model is already `top` at every `update`, because the hosted runtime keeps it
  in a `Js.ref` read back with `Js.to`. So the filter changes nothing there, and it reaches the
  dashboard only because `browser-inline` keeps the model in a JavaScript binding.
