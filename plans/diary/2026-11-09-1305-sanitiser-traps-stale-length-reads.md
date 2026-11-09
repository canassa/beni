## 2026-11-09 13:05 CET — The list sanitiser traps a stale length read

**What I did.** #2347: a list a write left stale was read through `List.length`
without a trap, because a plain array's `length` cannot throw, so the oracle's
"no TRAP" missed it (only a plain-vs-v2 DIFF caught it). The cell was not the
cause; `Ref.update`'s `old` was just where the length read happened. Every
length read the lowering emits under `--sanitize-lists` (`List.length`, a list
pattern's length test, a loop's offset) now goes through `_sanitize.len`, which
traps on a poisoned plain array. Fixture `run/SanitiserCellStaleLength` is the
issue's program, which v2 now refuses; the compiler at 8301d0fee4 accepted it
and printed `4;0,1,2,3` with no trap, and with the patch applied it traps.

**What I learned.** Over the 47 835 probe programs the oracle had marked SAME,
none newly traps: the length blind spot hides nothing in that corpus. No
checker rule is a one-line mutation of the issue's program (`word_cell*`,
`stored_off`, `contents_check_off`, the fold mutants all still refuse it), so
the fixture pins the refusal, and the sanitiser change is proved against the
old compiler instead.
