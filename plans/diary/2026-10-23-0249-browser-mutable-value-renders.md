## 2026-10-23 02:49 CEST — Browser mutable value renders

**What I did**

Built the runtime half of #319, Part of #317, on dagon. The browser no longer
uses a List or record's identity to skip rendering. Checked instruction and
local-path facts reach the DOM lowering through a versioned dispatch sidecar
and markup interface; nominal wrappers and tuples containing mutable cells do
not receive identity permission. Scalar/string guards remain. Source-list
snapshots are gone, mutable keyed items have their keys recomputed, and class
and style lists keep only the strings actually written. Controlled properties
receive an explicit immutable-value permission.

Added four browser regressions, each failing semantically against the saved
baseline and passing in development and release: outer list writes, List and
record item writes, record key changes, helper/component/captured/Show inputs,
erased wrappers, class/style removals and aggregate controls. Targeted cache,
inline emit and DOM emit checks passed. Audited the browser/Tea drivers and
remaining identity comparisons; no driver change was needed. Updated twelve
DOM emit goldens and regenerated the skill API reference.

The owner clarified that required List/record recomputation may add console
lines. Sixteen existing fixtures change only those lines; a separate assertion
compares every saved DOM transcript byte for byte after removing console.log
lines. LetInMarkup now logs sorted on ticks, while its label behavior remains.
O2 (#318) is still open: the template/platform ownership removal is deferred
to Part 2 as instructed. No src/own files or ownership verdicts were changed.

**What I learned**

Removing a record row's identity skip also revisits controlled inputs. Keeping
the prior scalar model value avoids overwriting an unmarked external edit;
aggregate controls must always assign. An immutable flag from the checker
preserves that distinction without guessing from JavaScript representations.
Mutable keys must be recomputed even when a row item is the same object.

An interactive shell's job control can make setsid fork and invalidate the
recorded watcher PID. Disabling job control and checking PID, PGID and SID made
one watcher's process group reliable; stale processes were removed by exact
worktree identity. A one-shot build confirmed the binary before proceeding.
All scratch files use zig-out/scratch; the shared Zig cache is untouched.
