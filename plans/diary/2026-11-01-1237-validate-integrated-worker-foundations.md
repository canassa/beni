## 2026-11-01 12:37 CET — Validate integrated worker foundations

### What I did

Resumed PR #1304 after Dagon filesystem recovery. Independently verified the
manager's staged be99 tree against all 17,665 regular/symlink Git blob contents;
all matched. Reviewed and replayed 33 checked-control blackboxes and two codec/fuzz
semantic tests for bound Int suspension inputs. All passed. Verified both native
and continuation evidence archives in full, including all payload hashes and
symlink targets, before author cleanup; independently confirmed both obsolete
lanes and Git worktree registrations were absent. Two cache-only historical
setup-failure ELFs were unavailable after recovery and are explicitly documented,
with no reconstructed executable presented as an original.

Materialized combined tree 7de8d098eefc918dd7e358edb54780576f1c9aa6 in a separate
manager integration checkout. The first unfiltered gate ran 2269 tests: 2248
passed, 17 skipped, four old inspection assertions failed, and the generated ZON
snapshot lacked its final newline. Kept the complete failed log. The test fixes
retain the exact old goldens/prefixes and check the new uniquely delimited source
section separately. Empty-selector prewarming requests source evidence before
changing selectors, preserving the one-module expansion and zero-module warm
assertions. The native generator now writes the same formatter-required terminal
newline as its snapshot; actual pinned generation byte-compared equal to it.

The second exact unfiltered gate is to run after this entry is staged. Its result
will be retained in the manager scratch receipt rather than editing this entry.
Part of #1295 and decided C #1315; existing foundations also fix #1509/#1515.

### What I learned

Intrinsic literal scaffolds and interpolation chunks deliberately have no ordinary
type variable; realm recording must observe their actual checker hooks without
inventing one or dropping child expression calls. Packed source capture now has
actual cold/warm/roundtrip evidence, while native execution consumption and
lowering remain unfinished. Owning storage, production Task migration, C,
EntryHost, HostFree, Wire and launch remain unproved. Independent optimized cost
acceptance has zero measured rows: external Dagon workloads have not supplied an
admissible quiet window. No limit, guard, source rule or representation was waived.
