## 2026-10-24 16:21 CEST — identical functions are one

**What I did.** #934 item 3, in a general form. The release one-file build printed both
`Maybe.withDefault` and `Result.withDefault` as `(a,b)=>a.$===0?a.a:b`. A new `Spec` pass,
`mergeSame`, runs after the structural loop. It finds top-level arrows with the same code
(`sameCode`: the same tags, literals, operators, property names and whole-program names, with
locals matched one to one; it compares only tags it knows). When the later of two such functions
is only ever the callee of a call, its calls name the earlier, and `prune` drops it. A function
whose value is taken is never merged, because its identity can be seen. Spec first: `backend.md`
§9 *Identical functions are one*. `emit/release/app/SameFunctions` and `run/SameFunctions` pin
the rule. Six `emit/release` goldens are red with the pass taken out. `./rr check` 24/24.

**What I learned.** It pays on the corpus (−4 to −26 B per golden), but on S1 the result is
inside the noise: a mean of −6 B over six builds, from −30 to +17. Removing one top-level name
shifts every later short name by a letter, and that moves brotli by about ±20 B whichever way it
goes. My hand edit, which renamed nothing else, measured −12 to −68 B and overstated the gain.
For a change of a few bytes, an edit that keeps every other name is not a fair estimate.
