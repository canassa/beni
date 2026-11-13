## 2026-11-13 03:21 CET — ownership v3 blind test, reader B

**What I did.** Read `ownership-v3-kernel.md` and `src/own3/`, then probed commit `ca2fc63410` blind:
a generator (`bench/ownership-sweeps/blind4b.mjs`, 6 596 programs in seven families), two random runs of
20 000 programs, the whole `tests/corpus/run/` corpus under v3, and about 100 programs by hand.
Research report 119 has the results.

**What I learned.** No soundness fault: about 47 800 programs, 6 182 accepted, every one printing what the
plain build prints. Two faults of termination: a chain of writes on one list doubles v3's time with each
write (`groundOf` and `markAtom` recurse into version runs that are closed already; 30 writes take 35 s),
and a type whose halves repeat has a location per path with no limit (the corpus program
`EvidenceDagBuildDepth32` never finishes). Beside the test, v1 accepts two shapes that read a stale list:
a `List.update` or `Dict.map` callback that answers a list the result holds already.
