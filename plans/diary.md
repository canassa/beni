# Captain's log

Append-only. Newest entries at the bottom. Never edit or delete a prior entry —
correct a past statement in a new one.

## 2026-09-16 00:05 CEST — the no-currying spec pass, and the first slice of it

**What I did**

- Read `transparent-effects-proposal.md` (P2) end to end and assessed what it
  would take to start implementing. The answer was that nothing in it can start:
  the 2026-09-14 no-currying decision had never been written into the spec, and
  `language.md` still carried it as a "pending spec change" note. Two independent
  reasons it gates P2 — effect flags have nowhere to live on a curried
  `{param, result}` chain, and statically choosing the direct or suspendable body
  at a call site needs known arity, which currying denies.
- Wrote the spec pass. `language.md` gained n-ary function types `Int, Int -> Int`,
  a new §6.7 for saturated calls, `_`, pipe-first `|>` and the `<-` bind, plus
  token, grammar, operator-table, lowering, formatter and diagnostic updates.
  `checker.md` §6.1/§6.2 now describe a function type that unifies only at equal
  arity, and §8.3 was re-cut from the missing-argument suite into an arity suite.
  `backend.md` §6 lost the calling convention entirely — no adapter, no arity tag,
  no curry wrapper, no direct-call share to measure. Commit `92ee10b`.
- Commissioned and landed `research/17-platform-primitives.md`, which discharges
  P2 §10 item 0 — the enumeration P2 says twice must exist before any surface
  decision is frozen. Commit `20823e8`.
- Shipped the first implementation slice: `>>` and `<<` removed, the `_`
  placeholder, the `let x <- e` rest-of-block bind, and the formatter's
  trailing-`<|` lambda rule. 23 new corpus fixtures, 3 new diagnostic codes,
  ~820 lines of compiler change. Commit `5cf3ec6`.
- Corrected the README, which claimed beni "keeps Elm's semantics" (false since
  currying was dropped) and described the daemon in the present tense (unwritten).
  Commit `1241bea`.
- Ran three read-only reviews: one over the spec pass, one over the slice-A
  implementation, one over `language.md`'s structure.
- Restructured `language.md`: §3's 18-item flat notes dump became three grouped
  sets, four rules moved to the sections that own them (which killed the §3/§6
  duplication), and §6.7 now names its four parts instead of stapling them
  together. 962 → 958 lines with the §10 catalogue, the grammar block and the
  heading list all verified byte-identical. Fixed four defects it found and left
  alone: two diagnostic codes jammed into one span in §7, `nesting_too_deep`
  missing from the §10 catalogue, a reference to a `tests/corpus/bad/` directory
  that does not exist, and implementation status leaking into a normative rule.
- Started this log, and wrote the repo's first `CLAUDE.md`, both modelled on the
  Betrayal at Krondor repo's conventions.

**What I learned**

- **A green test suite proved almost nothing here.** Each of the three reviews
  found real defects while `zig build test`, `test-blackbox` and `fmt-check` were
  all passing. The spec review found a grammar rule that could not parse a record
  type with two fields; the code review found a formatter that lied to itself
  about `if`/`let`/`case` nested in a bind value, and a `?` that escaped the
  placeholder lambda when the call was reached through a pipe. The corpus is the
  asset, not the unit tests.
- **The proposal's own headline example miscompiles against the repo as it
  stands.** `List.map` is `foldr`, `foldr` is a `foreign` whose JavaScript does
  `f(at.a)(out)`, and under P2's CPS lowering a suspending callback returns a
  suspension object — so the loop would cons scheduler objects into the output
  list. Well-typed, no diagnostic, garbage out. This reorders the plan: the
  tail-call loop must land before effects, not after, because it is what lets
  `foldl`/`foldr` leave `foreign` at all.
- **P2 §10 item 0's conditional splits rather than resolving.** Of 68 foreign
  values, 66 are first-order and only `foldl`/`foldr` are not. So the `foreign`
  keyword survives and nothing needs `suspends` inside a signature. But six
  primitives and seven imposed signatures are functions the *host* calls back
  into synchronously, which `boundary.md` §5.4 already promises in writing to
  check — so `sync` cannot stay a declaration modifier and `sync_boundary` is not
  droppable. The price is small: one bool on `Structure.Func`, one spare
  `Term.Tag`, one obligation kind.
- **A reviewer's proposed fix can be confidently wrong.** For the trailing-lambda
  indentation the reviewer said to pass `indent` instead of `lineIndent()`. That
  changes nothing for a list element, because `collection` passes the bracket's
  own column as the element's indent, so the two are already equal. The quantity
  actually wanted is where the chain starts. Verified by reverting and diffing the
  golden.
- **`sync` will need a witness in the interface, and P2 does not say so.** Its §8
  chain diagnostic names call sites in other modules with source positions. An
  interface carries types, not a call graph with spans. Either the interface gains
  a witness or the checker reaches into another module's body — which is exactly
  what the JS backend already does for arity, with a comment saying M4's cache
  cannot.
- Removing `>>` and `<<` had a lexical side effect nobody would predict: `--` no
  longer always begins a comment, because `x <-- c` now lexes as `<-`, `-`, `c`.
- **"Make it shorter" and "make it organised" pull against each other, and the
  first pass will silently pick organised.** Restructuring `language.md` grew it
  from 962 to 996 lines, because relocations and group lead-ins cost lines. A
  second pass with structure frozen and words as the only target got it to 956,
  and stopped there with an argument rather than a number: 412 of those lines are
  structural floor (blanks, headings, fences, frozen grammar and catalogue
  blocks, tables) and the remaining 544 carry roughly 250 rules. A mechanical
  reflow to the 100-column guide, deleting nothing, recovered one line — proof
  the prose was already packed and the length is content. Ask for a target, but
  accept arithmetic over obedience.
