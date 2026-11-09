## 2026-11-09 02:12 CET — linear effect records for erased classes

**What I did.** Master's `tests` job hit the 120 s hang guard on the build_test
read-off DAG test. Alone on dagon the test took 49 s: `dump --stage=ownership`
at depth 12 took 45 s, at depth 10 under 1 s. A bisect at 5 s put the jump at
70664db0e3 (erased types). gdb samples sat in `Erasure.applyRecord` →
`Solved.classIndex`: for each erased class it scanned every pair of the record
and looked each one's class up by a scan, classes × pairs × classes.
`Realms.applyCopy` (2026-11-06) did the same per realm dependency.
`Effects.applyRecord` now looks a pair's class up in a map once and buckets the
pairs by class; both callees get their class's pairs in the same order. Depth
12 dumps in 233 ms with the same output; the test takes about a second (#2329).

**What I learned.** A gates test that asserts a ratio of records can still hide
a time blow-up: the records stayed at 69 while the time grew 50 times per two
levels. Past depth 13 the chain still costs about 3.6 times per level, from
older code (`schemeNodes`' dedupe scan, `dependencies`, `Types.build`): #2332.
