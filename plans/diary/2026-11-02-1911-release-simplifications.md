## 2026-11-02 19:11 CET — Release simplifications priced after brotli

### What I did

Priced wd-size2 slice 6 candidates independently on both plain/timed page pairs,
the full bench/corpus library and four emit/release programs. Kept equal atom
arms with inert tests, and immutable name copies used across branches and loops.
Rename now visits the printer's actual substitutions so a copy's replacement
remains captured in a loop. No core or platform runtime changes.

The retained combination saves 9 / 52 / 27 / 39 brotli bytes on the four pages;
bench/corpus is unchanged and the four selected library emit programs grow by
9 bytes in total. The PR records the independent candidates and exact flags.

Added a release golden, a dev/release behavior fixture and a loop-capture codegen
regression. Stashing the optimizer changes made both shape checks fail. Refreshed
and reviewed release goldens and runtime hashes; the existing development hashes
and run outputs did not change. The full hash recorder used an 8 GiB Node heap
because the workers branch's existing #1702 stress condition remains open.

### What I learned

More compact JavaScript is not always smaller after brotli. Local/global frequency
assignment, dead-name compaction and short-circuit statement printing lost on the
requested set; literal aliases and a native return rewrite did nothing. None ship.
Alias folding across a lexical scope needs Rename to observe substituted reads;
counting unique source bindings alone does not prevent a short-name capture.
