## 2026-10-12 08:24 CEST — ownership checker, slice 3a: destructive reads, exclusive contents, closures

**What I did.** Specified slice 3a in `ownership-checker.md` §17–§18 and built it in `src/own/`.
The destructive read is two asserted primitives in `core/List`: `traverseAt` (an element read that
hands its position out taken, lowered to `a[i]` like `at`) and `focus` (`update`'s old body); `map`,
`indexedMap`, `filterMap`, `foldl`, `foldr` and `update` are written over them and inferred, and
`kept` is the one exempt comparison. Exclusive contents are a condition per cell — holds on atoms
about arrivals, or fails exactly or approximately — published as `xres`/`xreq` and relied on where a
write needs it, with the split of `[ x, …rest ]`. Local-function groups are solved with a rollback
per round; once closures demand their captures at creation and themselves at each call; a function
parameter called inside a lambda is a call of it wherever the lambda runs; a function value handed
to JavaScript escapes its captures (`J`). Eight fixtures, the Lean comparison complete, research 77,
and the pass brought back to slice 2's cost after the new work had raised it by a third.

**What I learned.** A higher-order `traverse` would carry the traversal obligation in one body, but a
shared loop's callback call goes megamorphic: `foldl` over it is 65 % slower in Node, so the primitive
is the per-element read with its discipline stated. Accepting an element edit inside a library
function moves the write to every caller — `Cmd.map`'s key-path push now rejects 69 call sites,
most of Conduit; containment had been hiding a platform choice. Exclusivity cannot be a flag, since
most lists arrive from outside: it has to be a condition whose atoms the caller discharges, and a
pattern's element has to be a taken position or the split cannot be stated. The in-process
`bench/list` harness is bimodal at 100 000 elements; one process per build settles it. Two thirds of
Conduit's pass is re-summarising the library each dump — the summaries belong in the embedded core.
