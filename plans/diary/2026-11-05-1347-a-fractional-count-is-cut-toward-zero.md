## 2026-11-05 13:47 CET — a fractional count is cut toward zero

**What I did**
- #990: `List.repeat`, `range` and `initialize` passed a fractional `Int` count (`2 ^ (0 - 1)` is `0.5`)
  to `new Array(n)` in `List.builder`, which throws `RangeError`. `String.repeat`, `padLeft` and
  `padRight` reached the same builder. A private `count` (`n ≥ 1 ? Math.trunc(n) : 0`) now cuts the
  count once, before the builder and the loop. `String.pad` cuts its length first; it padded one too
  many (`pad "1" 5.5 '.'` had 6 characters).
- No document said what a fractional index or count means. `language.md` §6.8 now has the table:
  a position is out of range (#988), a slice bound is cut toward zero (#988), a count is cut toward
  zero (#990), and a count too large for memory stops the program (Jayson's decision, 2026-11-05).
- `builder` lost its `n > 0 ? n : 0`: after `count`, every caller gives a whole number from 0 up.
  That paid for most of the bytes `count` added: release brotli of the 55 `run/` programs that
  use these functions moves −16 to +33 bytes (median +9), against +56 at most with the test kept.
- Sweep of the other count-taking functions: `Queue.takeN q 1.5` moves the queue's start to a
  fraction and `poll` then gives `Just undefined` (#1973); `Task.forEach` with a bound of 1.5 runs
  2 calls at once (#1974). `Random.list` and `Schedule.recurs` already cut.
- Fixture `tests/corpus/run/CoreListFractionalCount`, red on master's `core/` (`RangeError`).
- The owner's answer also opened #1985: `^` returns `Float`, and a new `^^ : Int, Int → Int`.

**What I learned**
- `--core-root=<dir>` gives one binary two cores: a red run and a before/after size run on master's
  `core/` need no second Zig build. `bench/size.mjs --corpus=<a copy of some fixtures>` takes a
  minute, where the whole corpus takes half an hour; it must run from the repo root.
- A guard only in `builder` is not enough: the loop's `i < 1.5` puts two elements. Cut the count
  before both.
- Three files are keyed by line or by body text, and a `core/` edit moves them:
  `tests/blackbox/ownership-v2-known.txt` (`core List <line:col>` entries, moved by hand),
  `tests/corpus/ownership/core.v2.unchecked` (blessed) and
  `tests/corpus/ownership/word-bodies.txt` (a worded body's hash: re-read the words in
  `ownership-checker.md` §24.8 and set the new pin).
- The core doc examples `--|     expr == value` are compiled and run by `docs_test`: a literal
  `2.5` is a `Float`, so a fractional `Int` example is `2 + 2 ^ (0 - 1)`.
