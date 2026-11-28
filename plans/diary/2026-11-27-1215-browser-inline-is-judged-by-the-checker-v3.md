## 2026-11-27 12:15 CET — browser-inline is judged by the checker v3

**What I did**

- Merged the precision lanes into one branch: `own3-prec230` (prec227's field paths read where a
  closure is made, prec230's held functions and method calls), then `own3-prec229` (prec226's
  handlers read at the event, prec228's claims of calls whose arguments are not apart, prec229's
  same-place type variables), then `own3-prec231` (captured-record writes with `Fn.before`, holes
  evaluated once, markup interface 1.44 on top of 1.43). `origin/ownership-v2-design-review` and
  `origin/master` were in already. The conflicts were the kernel's history line, `Frame.applyAt`
  (prec230's answered closure beside prec228's duplicated-cells claims), `Contract.Fn`
  (`ans_own`, `receiver` beside `before`, in every copy and join), `Frame.finish` and the
  known-differences file, whose merge base held diff3 markers again.
- The auto-merged code did not compile: prec229's same-place reading had no case for prec230's
  `Src.held`. A held function's answer is code the body does not know, so it is never at the same
  place, and its call taints.
- Switched `browser-inline` to v3: `"ownership": "v3"` in its manifest (`boundary.md` §5.2), read by
  `Session.init` for `check` and `build` unless `--ownership=` names a checker; `dump` keeps its
  flags' checker. Such a build writes in place each record update v3 accepted, with v3's reads
  first (`Lower.Input.records_v3_plain`); lists are written as before. Tests of v1's machinery on
  this chain (cache, checked-core edge lists, limits, the `ownership/` corpus) pass `--ownership=v1`,
  and a fixture of v1's that v3 has no counterpart of carries an `.ownership-v1` file with its
  reason. A page pinned `.sanitize-lists-v3-refuses` on this chain is checked against its pin and
  runs no page. `run.mjs`'s plain leg names v3 on a platform of its own, so it keeps a copying
  build, and a program the plain build refuses is REFUSED, not PLAINFAIL.
- Fixed two soundness faults the switch exposed or the review found: a function held in a list,
  reached through a fold's callback, read its draft's answer with nothing of what the callback
  handed it (`run/HeldThroughCallbackLive`, and `check/bad/inline/FunctionElementBorrowed`, which only
  v1 had judged: TRAP, ip=DIFF); and an arm of a hole's `if` dropped the markup's hold while the
  other arm's pure, total read ran eagerly after the write (`browser/inline/HoleOnceSibling*Live`).
- Added the reviewers' fault pages as pinned refusals (`ConstantMarkup*Live`, `SentMessage*Live`).

**What I learned**

- The inline emit goldens grew 2.2% after brotli: v1's clean-module table unlocks lowering shapes
  (a model object written in place, no box) that v3's per-update channel does not give. v3 also
  reads no cache and no checked-core block, so a `browser-inline` build checks core from source,
  about 600 ms against 50 ms. Both are walls to report, not to work around.
- `--lists-in-place` is an oracle, not a lowering: it routes every write through a runtime that
  copies back into the old array. It must never be a production build's mode.
- A gate that only one checker ran hides the other's faults: `FunctionElementBorrowed` sat in the
  corpus as a v1 fixture while v3 accepted it.
- Evidence on the final tree: all 38 pages accepted and SAME under the four-leg oracle; the only
  `browser-inline` pages v3 refuses are pins; v3 dumps of 2 941 roots against e22c75218e: 0 accepted
  → refused, 341 refused → accepted. The ledger is 310 of 319: the soundness fix costs prec230's
  five `bench/corpus` `FormValidation` `andMap` lines (its validators are reached through a fold's
  callback that hands them a value of a type variable). v3 on the 33 real roots, ReleaseFast,
  alternating runs: 1 868 and 1 886 ms on e22c75218e, 1 939 ms on the merge.
