## 2026-10-22 08:50 CEST — Cut the repeated work in construction conditions

**What I did**

Took #684. Profiled the ownership walk with callgrind on frame-pointer
ReleaseFast builds of #665's parent, `master` and the candidate, on the
research dashboard at N = 16, 64 and 256, on `nowd`, on the two core
ownership tests and on Conduit. #665's extra cost on the dashboard was the
`pushed` record: 64 fields of one parameter make a construction condition of
2 016 pairwise `rsep` atoms. Each call instantiates every atom, and each atom
projected the entry model again along both of its paths. A model under
`wide_index` entries is scanned per projection, so the cost was cubic in the
record's width.

Removed the repeated work without changing a fact. `ProvMemo` instantiates
each parameter provenance once per condition, with the cells `sepValues` and
`rsepValues` read, unless the value holds a closure. `containingCondition`
reads each operand's cells once. `rbase` is kept per cell. A build no longer
renders summary text, which only the dump prints. Ownership-phase instructions
went from 31.2M, 305M and 1 914M to 25.2M, 121M and 1 140M at N = 16, 64 and
256 (#665's parent: 23.2M, 85.9M and 571M). Every dump and output hash is
unchanged. Added `ownership/WideFieldConditions`: 5 444M on `master`, over the
budget, and 2 764M now.

**What I learned**

What remains is quadratic, and it belongs to the representation (#693, the
owner's decision). A summary
states each pair of a construction's operands as an atom, so the summary's
size, its text and each call's instantiation grow with the square of the
width. Linear cost needs a "pairwise apart" atom, which changes the summary
vocabulary, the block format and the goldens. #665's parent was already
superlinear from N = 64 to 256 (×6.6), through the same pairwise `sep_spine`
atoms.

The perf sampler on dagon is capped at 10 000 samples a second. A 0.3 s build
gives about 2 000 samples, too few to compare two builds. Callgrind gives
exact inclusive counts per function, and the self-hosted safe build profiles
the same way.

`-Downership-full-cross-check` fails `RecordTree` (#427) and
`LevelPlacesKinds` (#694) on `master` as well as on this branch.
