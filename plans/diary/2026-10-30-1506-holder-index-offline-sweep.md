## 2026-10-30 15:06 CET — The holder index as one offline sweep (#1214)

**What I did.** Built `src/own2/Holders.zig`, the ownership checker v2's step 5 as
`ownership-v2.md` §2.8 *The holder index* specifies it: per frame, pairs from each holder's
cells, entries per covered use in a segment tree on rank₂ (two minima, top-2 split tags, a
pending tree), reliance as counters on `(start, end]`, a best-hold descent instead of listed
hold paths, light or heavy pairs, and a naive scan that cross-checks every frame of at most 8
holders under runtime safety. `Live` and the per-demand loop are gone; Demands keeps
conditions 1–4 and 6 and moved to L7. Liveness sorts a path's uses by kind and callee use
node, so a filter judges a group once. Fixtures: `HolderIndex` (Astra's counterexamples, the
canonical witness of a DAG), `core/TopHoldersMany`; build_test gates a depth-12 DAG and three
families from 25 to 100; the pick chain left `scenario/CK-1214` for the call-cost guard.

**What I learned.**
- The spec put Holders and Demands on one layer; the layering gate refuses a same-layer
  import, so Demands is L7 (Calls only took `Value` from it, now from Holders).
- Matching refinement chains by key, member by member, made `[ p1 … pn ]` n². The old
  `chain` read one member of the own split because all of them answer `under` it; the index
  keeps that rule as one counted reliance per (position, split), the target cell left out,
  and the naive scan keeps the member-by-member predicate to check it.
- The pick chain stayed quadratic until the same-path closure (a join's sides, a view's
  answer) was memoised per node with no route flags and kept only states that have a child
  reaching the candidate.
- The spec's "`element` when approximate" changes three refusals on several cells from
  `alias` to `element`; no accepted/refused verdict, summary or block changed in the corpus.
- Perl `s|…|…|` with pipes in Zig code silently mangled files twice: literal index/substr
  replacements or the Edit tool only.
