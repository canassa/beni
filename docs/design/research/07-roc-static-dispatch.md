# How Roc does ad-hoc polymorphism (and what transfers)

Evidence for the §3.1 decision. Sources: the vendored Roc compiler at `references/roc`
(Zig, master) and roc.zulipchat.com via [`.claude/skills/roc-zulip`](../../../.claude/skills/roc-zulip/SKILL.md).

> **Superseded in part by [`18-static-dispatch-revisited.md`](18-static-dispatch-revisited.md)
> (2026-09-16).** This report was written while Roc's static dispatch was a proposal. Report 18
> re-tests it against the shipped feature and corrects three things here: the check-time mechanism
> is row polymorphism rather than dictionary infrastructure (18 §1.2), nominal typing is required
> far more narrowly than "copy the design taste, not the machinery" implies — structural shapes get
> `is_eq`/`to_hash`/`parser_for`/`encoder_for` derived automatically (18 §4.2) — and the cost that
> actually survives lands on type inference (18 §2). The conclusion below still stands; its
> reasoning does not.

---

## The answer: one mechanism, not two

Roc has **no** `number`/`comparable`-style closed-set type variable, and **no** typeclasses
either — it shipped real abilities in the Rust-era compiler and removed them in the Zig rewrite
(Luke Boswell, #compiler development › breaking changes, 2025-01-08, id 492467217: *"Then static
dispatch, remove abilities..."*; Anton, 2025-01-14, id 493552040, lists "static dispatch" and
"removing tracking of lambda sets" as the rewrite's core changes).

What replaced both is a single uniform mechanism: **structural `where` constraints saying a type
has a method of a given name**, resolved by the checker into an explicit compile-time dispatch
plan. `+`, `==`, `Dict` and sorting are the same feature with different well-known method names —
`plus`, `is_eq`, `to_hash`. There is no recursive membership question to answer, so nothing
analogous to Elm's `comparable` walk sits in the unifier.

## The three decisions that matter to us

- **No generic `sort`.** `List.sort_with : List(item), (item, item -> [Before, Same, After]) ->
  List(item)` takes an explicit comparator (`src/build/roc/Builtin.roc:3877`). `min`/`max` are
  their own methods, deliberately decoupled from the comparison operators
  (`Builtin.roc:3327-3345`).
- **Comparison operators are numbers-only, on purpose.** Richard Feldman, #ideas › "Sorting
  tuples?", 2026-06-19 (id 605017711, 605018068): comparison operators *"should be for numbers
  only... I think it's a footgun if `string1 < string2` compiles."* Sortability for other types
  goes through separately-named, auto-derivable methods so `<` does not silently work on them.
- **`Dict`/`Set` require `is_eq` + `to_hash` structurally** — Rust's `Eq + Hash`, spelled as a
  `where` clause (`Builtin.roc:5613-5922`). Both are compiler-derivable for structural shapes
  (records, tag unions, lists); nominal types opt in (`docs/langref/static-dispatch.md:70-105`).

## Numbers

No special numeric hierarchy in the checker. `Num` is a namespace; each concrete type implements
`plus`, `is_lt`, `from_numeral` and friends, and generic numeric code is written with ordinary
structural constraints — `sum : List(item) -> item where [item.plus : ..., item.default : ...]`
(`Builtin.roc:5107`), which is not "numeric" in any special way.

Literals are the one bounded exception: an unannotated `5` is checked against a fixed ordered list
of 13 builtin candidates (`Dec, I64, U64, I128, ...`) and commits to the first that satisfies
constraints (`docs/langref/static-dispatch.md:391-401`, `src/types/literal_defaulting.zig`). A
short linear probe over a closed list — structurally unlike Elm's `number`, which ranges over an
open set.

## What it cost them

- **Lambda sets were their worst bug source for years** — the closure-typing machinery that makes
  per-call-site specialisation work. Feldman: *"we implemented it during type-checking rather than
  as a separate pass... we think it has caused a subset of the lambda set bugs we've seen"*
  (id 449641251); *"the volume of bugs has been so high for so long that it definitely feels like
  intentionally sacrificing some performance for the sake of correctness is the right move"*
  (id 489317324). Tearing lambda sets out of the type checker was a goal of the rewrite.
- **The checker still builds dictionary-passing infrastructure at check time** regardless of
  backend: `src/check/static_dispatch_registry.zig` and `src/check/dispatch_evidence.zig`, ~3,600
  lines combined. Recursive dispatch needs a cycle-termination guard (`design.md:5593-5606`) — the
  functional analogue of Elm's occurs guard. The difference that matters: it runs at
  dispatch/generalisation boundaries when a constrained generic is instantiated, **not inline in
  the unifier's happy path**.

## What transfers to a non-monomorphising JS backend

- **Transfers:** the front-end design — structural `where` constraints as the single ad-hoc
  polymorphism mechanism, well-known method names, derivable `is_eq`/`to_hash` for structural
  shapes, bounded literal defaulting. None of it assumes monomorphisation.
- **Does not transfer:** what makes static dispatch cheap at *runtime* in Roc's shipped
  configuration is `.lss`, full whole-program specialisation, which depends on a native target.
  Roc's non-specialising path (`--specialize=no`, `.boxy`) boxes generic values and passes
  **explicit runtime dictionaries/vtables** — precisely what §3 rules out — and its own docs mark
  it experimental (`design.md:6985-7016`). Compiling to JS without monomorphising puts us in
  `.boxy`'s position by default: none of `.lss`'s runtime win, while still paying the check-time
  dispatch-plan cost.

**Conclusion for §3.1:** copy the design taste, not the machinery. No generic `sort`, comparison
operators numeric, explicit comparators, structurally derived equality.

## Could not determine

- No message where Roc discusses and rejects Elm's `comparable` **by name** — the adjacent,
  well-documented decision is the removal of abilities.
- No compile-time numbers isolating `.boxy` from `.lss`.
- No evidence of how battle-tested `.boxy` is beyond "experimental".
