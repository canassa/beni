## 2026-10-09 13:27 CEST — Tag reads in the write-set pass

**What I did**
- Specified the owner's refinement as a dated amendment to `docs/design/write-sets.md`. A `case`
  reads `tag p`, which constructor a path holds, where a constructor pattern tests it; it reads
  the value whole where a literal or list pattern tests more. A tag fact's path is also a tag
  read. A tag read conflicts only with a `value` write at or above `p`. The amendment has the
  write-by-write table, the soundness argument (`diff` writes `node p` at a custom type only
  under `Γ ⊢ tag(p) = C`, and a path made undefined is covered at the prefix that changed), and
  how the rule meets A6, A1/A2/N1, the k-limit and the caps.
- Built it in `src/writes/Writes.zig`. A `tag` pseudo-step marks a tag read and is exempt from k.
  An `Alt` now carries its pattern reads. Summaries substitute tag reads. The dump prints
  `tag ρ.x`.
- Added seven fixtures, all red on master: `writes/TagHeader/` (Conduit's header: typing leaves
  it static, a helper's page switch and sign-in make it dynamic), `TagSwitchHelper`,
  `TagNested`, `TagRefutable`, `TagAbove`, `TagListElement` and `TagCut`. No existing hole
  changed class.
- Re-ran the S0 gate. Conduit has 829 → 650 pairs, 9.21 → 7.22 per key, against a bar of 0.67,
  so the pairs criterion still fires. Wrote this up as research 64's addendum.

**What I learned**
- Research 64 §4's third "header" group was the frame's `{page.content}` slot. That group reads
  every page's view, so tag reads cannot shrink it (73 → 69 keys). The two real header groups
  fell from 88 keys to 3.
- A `case` on a value that is itself a control-flow choice (`Session.viewer (toSession
  model)`) must keep A6's whole read of the scrutinee. `List.head`'s `Maybe` has no tag path
  that records the list's emptiness, so only the whole read covers it.
- A refutable pattern's literal is the trap: if the scrutiny were all tags, `Loaded (Named "")`
  would go static and a rename would show a stale page.
