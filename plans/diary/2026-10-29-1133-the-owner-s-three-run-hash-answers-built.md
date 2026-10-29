## 2026-10-29 11:33 CET — The owner's three run-hash answers, built

**What I did**

- q1: every `browser/tea/` page is a value-fuzz case; the 213 markers are
  gone; `tests/corpus/browser/tea/no-value-fuzz.txt` is the one way out,
  a reason per line, failing closed on a stale or reasonless line. The 45
  pages master never fuzzed all pass in one walk, so the file names none.
- q2: Chrome keeps running every page; the docs say so.
- q3: the CI run-hash key hashes the harness, restore and save alike.
- Measured `gates -j4` through the queue: warm 1 000 s CPU before, 1 058 s
  after (160 s and 193 s wall, the second under twice the load); cold for
  the 45 cases 249 s wall with the harness compile.

**What I learned**

- The 45 pages had no value fuzz for a dull reason: the opt-in was the
  record file, made once for the former direct pages. An opt-in that a
  record carries decays as soon as pages are added; a default with a
  written exclusion does not.
- A value-fuzz case costs its two `--fuzz` builds and a dump on every
  gate run, cached or not: about 1.3 s CPU each. Measure CPU, not wall:
  the queue's neighbours move the wall clock more than the change does.
- The walker names failing cases only. A test that wants proof a case ran
  counts digests and the stale counter, not the report.
