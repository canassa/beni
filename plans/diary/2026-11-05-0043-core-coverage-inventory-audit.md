## 2026-11-05 00:43 CET — Core coverage inventory audit

**What I did**

After the WordsBrowser expectations passed, the core parity check ran and
exposed the accepted List.removeLeaf size limit and stale core inventory.
Recorded that exact limit through the existing known-limit mechanism, tied
to ownership-checker.md §30, O0–O6, and #1854. No budget or publication rule
changed.

Audited 738→856 unchecked entries against master 006f4a9e75 and current
source declarations. The additions are 50 entries in new modules, 195 new
declarations, and 41 existing declarations. The manager accepted those 41
as explicit debt: String.reverse/repeat under the interim trie (#1854),
20 Task declarations under #1927 (re-audit after P6), 19 Schema declarations
under #1928. Every one is listed in the PR's declaration/cause/issue table.

The 168 disappearances are 132 removed declarations, six bodies replaced
by foreign primitives, and 30 newly checked declarations whose current
summaries were verified. The 383 moves/relabels comprise 133 unchanged
source declarations, 223 changed implementations, and 27 declarations new
since master but already named in the intermediate worker inventory.
The ledger leaves no unclassified entry. Evidence is saved under
~/worktree-evidence/wd-gates/cleanup-core-master-ledger.json.

**What I learned**

A fixture failure can mask the final core parity pass of its corpus walk.
The original inventory also mixes master and intermediate worker snapshots;
checking both declaration existence and current summary status avoids
mistaking removed or newly checked code for an unexplained coverage loss.
