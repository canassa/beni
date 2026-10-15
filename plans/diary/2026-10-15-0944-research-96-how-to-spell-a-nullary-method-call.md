## 2026-10-15 09:44 CEST — research 96: how to spell a nullary method call

**What I did**

Wrote `docs/design/research/96-nullary-method-calls.md`. The question was whether `xs.length` and
`current.trail.copy` could call a method that takes no arguments, where today `x.m` is always a field
read. I read the static-dispatch spec, `language.md` §6.3/§6.7/§12.5 and the checker's dot-call path
(`Resolve.method`, `Instances.onRecord`/`fieldCall`). I surveyed Roc's Zulip and `design.md`. I also
surveyed Lean 4's generalized field notation (in its elaborator source), Koka, Haskell `HasField`,
F#, OCaml, Scala 3, Swift/Kotlin, Rust, Nim, D and Gleam. The report recommends making `x.m` resolve
like `x.m a`: a record gives the field, a nominal type calls `M.m x`, and an unknown receiver waits.
When the receiver is still unknown at generalisation, the default is the field, not a `where` clause.
A post-check retag to a zero-argument `method_call` keeps the passes that walk field paths correct.
No spec or code changed.

**What I learned**

Every language with a type-directed bare `x.m` needs a "field beats method" rule, and that rule is
where its refactoring hazard comes from. beni needs none, because a record has no methods and a
nominal type has no fields. Roc decides in the parser because its nominal types can be record-backed
and expose both. Roc's zero-argument `()` followed from parens-and-commas and did not drive it. The
hidden cost on beni's side is that ownership, write sets and the markup tree all read `field_access`
chains as paths. If one of them read `current.trail.copy` as a path, the motivating line would be
refused as an alias.
||||||| parent of 36d780f0b (✅ bridge Lean ownership programs to the shipping compiler)
