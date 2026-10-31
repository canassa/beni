## 2026-10-30 23:44 CET — Complete handler tail facts

### What I did

Removed the retrieved static UI and compatibility worktrees, branches, scratch,
and short browser TMPDIR after the manager verified their complete archive.
Started an isolated Dagon lane at 67f7e61a9 for Part of #894. Specified bounded
complete-handler tail facts in browser-inline §8.5 before implementing them.

Added independent optional write-set probing, source-qualified branch/call
occurrences, authoritative ordinary-write subset mapping, source-order bounded
exploration, and dump-visible facts/work counts. The probe owns separate caches
and interners, skips view analysis, and shares one additional W allowance across
its whole run. Published rows use flat SoA tables. Runtime lowering and the
reserved markup 1.24 interface remain unconnected pending manager fact/API review.

Six focused dump fixtures pass with the Debug compiler and fail against the
accepted baseline because that compiler lacks their new facts. Across 71 single
file write fixtures, ordinary output is unchanged. Complete ownership dumps for
all six new fixtures and eight complete development/release output trees match
the baseline byte for byte. Compiler source formatting and fixture formatting
pass. The manager retains responsibility for combined-tree full gates and commits.

### What I learned

Restoring counters after an in-place probe cannot isolate interned terms,
summary caches or id ordering. An independent analysis instance plus mapping to
existing ordinary write rows avoids changing ordinary ownership evidence. A
helper's local writes are insufficient: the caller continuation can add writes.
The existing writes dump uses ordinary alternative caps, while actual inline
lowering lifts them; its static-50 whole-model result cannot be presented as the
inline root plan. Exact root-plan inspection and runtime selection remain later
review steps, and no UI performance result is claimed for this facts foundation.
