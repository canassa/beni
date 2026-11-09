## 2026-11-09 23:17 CET — a front the prepend computes is no element of the base (#2325)

**What I did.** Worker `ownership-v2-fable`, first slice of the epic #1006. `ownership/PrependFresh`
47:41 (`[ make x, …omitLast trail ] ++ other`, research 82's `Bike.update` line 56) was refused
`alias (approx)` under v2: `Relation.mayRecons` said "may re-cons" for every item made before the
base, and `make x` runs before `omitLast trail`. The test moved to a new file, `Recons.zig` (L6;
`Relation` was 10 lines below its target), and has a second rule. A front that the prepend's own
instruction computes is named nowhere else in the frame. A list, record or tuple literal there gets
no base storage in the walker. A call there is marked on the prepend's value (`Recons.frontFlag`,
in the spread kid's flag word), and the evaluation takes it when the item is that call's whole
result, a list or a record, and its own storage expands to that call's `fresh` atom alone.
`PrependFresh` 47:41 and `Bike` 56:62 are accepted, and `Game` 159:11 (the refused write's demand at
`Bike.update`'s caller) is gone. Fixtures `run/SanitiserPrependFront` (accepted, the same output
under the sanitiser) and `run/SanitiserPrependFrontHeld` (three refusals); mutants `recons_never`
and `recons_front_any`; §2.3.4 has the rule (*When a prepend may re-cons*).

**What I learned.** The fix the issue proposed, "ask `Distinct.overlap` whether the item meets the
base's elements", is not sound, and §2.13.2's old `reach(xs)` wording has the same hole in the slot
domain. The element that `cons` compares is the one stored *before* the base's view, and nothing
names it: `hide v s = case [ v, …s ] of [ _, …rest ] → rest` (second arm `[]`) publishes
`res ε π2ε fresh, [*] π2[*]`, and the walker's slice of a built list drops the kids it skips. So
`[ v, …hide v s ]` re-conses onto an array whose visible elements never held `v`. A sound test
must ask nothing of the base's elements. The rule built asks only who can hold the item.
A callee that keeps the list it answers publishes `res ε fresh host`, so "fresh alone" excludes it.
A constructor application is left out on purpose: a type of one constructor with one field is its
field in a release build, and `Js.same` compares a scalar by value. `Game` 232:9 was named on the
issue by mistake: it is `held-operand`, another cause, and stays in the known list.
