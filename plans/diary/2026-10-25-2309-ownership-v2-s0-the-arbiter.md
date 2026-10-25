## 2026-10-25 23:09 CET — Ownership v2 S0: the arbiter

**What I did**

- Built slice S0 of `docs/design/ownership-v2.md` (#1011) with no edit to `src/own/`: the hidden
  `--sanitize-lists` (copy-and-poison at every core `List` writer of a clean module, runtime
  `src/js/sanitize_runtime.mjs` written as `_core/_sanitize.mjs` only when imported), `--records-in-place`,
  `--ownership=v1|v2` with v2 a stub that exits 2, `test-records-in-place` extended to `browser/inline/` and
  its twin `test-lists-in-place`, and `bench/ownership-everywhere.mjs --diff` over O1's audit roots
  (`bench/ownership-roots.mjs`, ported from #210's driver).
- Fixtures: `run/ListSanitiserValues` (every writer, every base form, a dot-call) and
  `run/ListSanitiserHiddenHolder` (a platform keeps a list out of the checker's sight; the sanitised pass
  must crash), with the `.sanitize-lists` and `.sanitize-lists-crash` goldens.
- Opened #1028 (browser-inline evaluates both arms of a branch and writes one list twice) and #1031 (a v1
  message cuts a base before its list literal's `]`).

**What I learned**

- A JavaScript array's `length` is non-configurable, so §7.3's "indices and `length` become throwing
  accessors" cannot hold for a plain array. Holes plus a throwing prototype trap every element read and
  every method in O(1); a stale read of `length` alone goes uncaught.
- v1 makes no `Dict` demand (the tree is persistent until #961), so a `Dict` sanitiser now would trap reads v1
  rightly accepts. It waits for S8.
- The record sanitiser was never run over `browser-inline` pages: 52 of them trapped at once, because the
  `inline` lowering drops an in-place update's value. Telling the write-set pass that nothing is in place under
  `--sanitize-records` fixed all 52; the in-place stores keep their own pass.
- `beni build` from inside `tests/corpus/run/` leaves a `.beni-cache` there that the corpus walker then reads
  as a fixture. Build scratch programs elsewhere.
- `HttpServerBadClients` failed once under `test-records-in-place` on master ("handlers ran: 7" against 6) and
  passed three times alone: a timing flake under load, not a stale read.
