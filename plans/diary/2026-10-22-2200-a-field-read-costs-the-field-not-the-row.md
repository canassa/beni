## 2026-10-22 22:00 CEST — a field read costs the field, not the row

**What I did**

- Profiled `check` on the research dashboard (N=64, nowd), the 100k corpus and a
  synthetic dashboard of W fields of records (W = 64…512), with callgrind and
  `perf stat -e instructions:u` on ReleaseFast builds on dagon (#464).
- Found that the synthetic dashboard's check grows as W² (116M at W=256, 404M at
  W=512), and that one cause is the field read: `Instances.fieldRead` took the
  direct path only for a leaf field of a record that is not an alias. Any other
  read built `{ ρ | f : result }`, bound `ρ` to a fresh copy of the rest of the
  row and merged a re-sorted third row back into the receiver.
- Widened the direct path to any field type and to an alias receiver, which then
  shows its expansion (`Unify.expand`), as the full path leaves it (#795).
- Added `check/bad/FieldReadThroughAliasExpands` (the message that prints the
  expansion) and a `test-perf` scenario that reads every field of a 1 000 and a
  2 000-field record of records.

**What I learned**

- Reading every field of a 2 000-field record of records cost 4 452M
  instructions to check; it now costs 57M. On the dashboard itself the gain is
  small (−0.27M), because its reads are few; the width cost there is in record
  updates and in re-sorting merged rows.
- The full path's leftover rows are subsets of the receiver's row with the same
  openness, so dropping them leaves the type-key record facts' field conflicts,
  and so the release field names, unchanged. A corpus-wide differential (every
  `.beni` under `tests/corpus` and `tests/pending`: four dumps and two checks
  each) was byte-identical.
- In a fish login shell, `ssh dagon 'bash -s' <<EOF` is the only reliable way to
  run a script; and zig's "failed command:" line after `docs_test` is printed on
  master too and does not mean the step failed — read the exit code.
