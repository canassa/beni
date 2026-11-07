## 2026-11-05 22:42 CET — A traversal's supply, read answers, a fold's storage

**What I did.** S4's traversal precision, three stacked PRs (#2066, #2084 and a third for #2032), each spec first: a derived `each`
mark on a supply and `walk` for what only `taken` rows give; a write through it asks its own slot; `res_read`, a second result condition
with a label's answers read as what the run was handed; a fold's write judged by the slot it writes. Four pending fixtures left
`tests/pending/`. Sweeps: 546, then 798, then 866 master refusals accepted, 0 accepted refused, 0 TRAP/DIFF at each head.

**What I learned.** A selection is not simply better than `no`: inside a check a call that vouches is read differently from one that does
not, so turning a nested `no` into a condition refused programs master accepts. Keeping the first check exact and only retrying a
whole `no` makes the gain monotone by construction. An apart occurrence alone is compared with nothing: the written slot has to sit in one
selection with what the function holds, or a capture of an element goes unasked; the oracle caught that in the first build. The hand
reviews found five holes the sweeps missed (a deep write above a structural supply, reading the rest after a run, a family repeated in a
callee, a settled group, a capture's slot read from its root's type), and the sweeps found one the review could not have
(`below` read at a closing pass). Reading costs a full check where the strict one stops at the first conflict; `shapeOf` passed its limit until a
recursive group with no label stopped publishing one. A diff3 conflict in the known list keeps base rows: rebuild it from master
plus your rows. The local gates stop before the stale check while #2053's fixtures fail, so set them aside to see it.
