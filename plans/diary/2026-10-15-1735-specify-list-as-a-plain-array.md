## 2026-10-15 17:35 CEST — Specify `List` as a plain array

**What I did.** I wrote the owner's decision of 2026-10-15 into the spec: "I want the trie gone
from the bundle. It might be included later as custom data structure (like Vector) if the
developer want. List is regular array." This change has no code.

- `backend.md` §4 gains *The representation: a plain array*, which covers:
  - the two forms that remain: plain, and a read-only view for `rest`/`tail`/`drop`;
  - in-place writes at accepted demands, and copies elsewhere;
  - writes to a view, which make it plain first;
  - the invariants and the reader protocol rewritten (`$b`/`$o` replace `$plain()`);
  - the runtime, identity and `--release` (a demand is an optimiser barrier);
  - a future `Vector`, only as a separate type the developer chooses;
  - the open platform question for the owner.

  The E1t/E1tp subsections are marked superseded and kept.
- `language.md` §6.8 gains *A list is a plain array*, with the cost table before and after,
  and what gets worse: versions kept beside each other, the queue idiom, and every write on a
  platform that is not in-place.
- `browser-direct.md` gains a closing amendment that rewrites S7 as "replace `core/List`'s
  representation". It folds in the independent oracle review's C1–C5 and amends the §13 rows
  and kill criterion 1. I also added pointers in §7.2, §7.4, §6.2, §14 and §15.
- I added pointers in `ownership-checker.md` §13.4 and §28.2, `boundary.md` §4, `schema.md`,
  `static-dispatch-spike.md`, `write-sets.md`, `fast-compiler.md`, the plans (`list-arrays`,
  `browser-decisions` W35, `compile-away`, `status-2026-10`) and research 87 and 102.

**What I learned.**

- **The review's C1 fallback no longer works once the trie is gone.** The fallback was to keep
  `++` copying and lower only the named writers. Under E1tp a copying `[ …acc, x ]` still
  pushed onto a trie. With plain arrays it makes every building loop quadratic, so the in-place
  lowering of constructions and the trie's removal have to land together.
- **The view must stay.** §8's scalar views only cover tail-recursive walks. Without a runtime
  view, non-tail recursion over `rest` copies a suffix at every step, which is O(n²).
- **Moving every platform to in-place has a cost.** `browser`'s markup runtime skips a `For` by
  list identity, and an in-place write would make that skip show a stale page.
- **W27's amendment (Q4, decided 2026-10-09) is still not written** in `language.md` §11.12.
- **CLAUDE.md's `List` paragraph still describes the trie.** I left it for the owner.
