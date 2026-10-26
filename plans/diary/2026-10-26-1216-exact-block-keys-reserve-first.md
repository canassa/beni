## 2026-10-26 12:16 CET — exact block keys, reserve-first writer

**What I did.** Fixed #1065 and #1066 in the ownership v2 block writer.
Places are refined once as one graph, so every key that names a place
shares its rank and no place graph is encoded per key (nested places went
from ×3.9 per doubling to linear). Keys are exact: `Refine.rank` interns
words and orders distinct keys by (hash, length, words). Records no
position reaches, and the owners/supplies/classes, are ranked a height at
a time; only positions (the records that make cycles) go through
Hopcroft. `Refine.blocks` is now unlabelled with counted edges (a port
state per labelled part, none for a state with one part), grouping the
touched predecessors by lists threaded through per-state and per-count
arrays, with sorts only of splitting blocks and of counts. A `Meter` pays
before each step and panics in safe builds if work passes what was paid.
The reader reserves its place steps, knot members and mark scans first.
Tests probe every prefix of the allowance (writer, reader, refinement),
tie every hash, permute build orders, and count cost on rings, paths and
nested places.

**What I learned.** Refining every record together was correct but paid
a log factor on plain DAG chains that the old Merkle keys did not: a
256-deep chain of taken elements went past the default allowance.
Ranking the acyclic tiers by height and refining positions alone fixed
that. Charging every lookup and sort honestly makes a 1 000-node marked
ring cost 62 948 records against the old 54 070, which the old writer
reached partly by not charging its knot sort; that test now has about
4% headroom under 65 536.
