## 2026-10-15 02:08 CEST — Audit unchanged browser applications for ownership

**What I did**

Minimised all seven ownership errors in full TodoMVC, Bike Wars and Sternhalma.
Specified and implemented private single-read initialization transfer, listed
its absent Lean module semantics, and advanced ownership blocks to version 5.
Added accepted/unsafe class twins and a paired direct/tea page; stashing the
implementation makes both acceptance fixtures fail. Added Sternhalma's unchanged
external sources/script/golden to pending with its two remaining errors pinned.
All six browser-tea development/release script runs match the original goldens.
Direct builds still refuse all three applications; no application source changed.
Recorded run hashes for the new pages. Gates: 1,297 passed, 15 skipped, only the
two known macOS case-folding failures. Full pending also has an unrelated stale
ValueCommands signature (missing tracker field), documented in research 95.
Prepared a PR for review without merging.

**What I learned**

Six errors protect actual sharing: deferred persistence retains TodoMVC's model
list; Bike Wars reads the trail it concatenates and reuses initial bikes;
Sternhalma edits a board reused by selection and later games. The queued-list
witness prints 12 with value semantics and 22 when only a temporary emitted
small-list push mutates. Sternhalma's private centralHexagon has one strict
initializer read, so its fresh cells can transfer safely; the destination
Board.init must still remain shared. The thesis's idiomatic-error claim does
not establish that these unchanged applications can run with in-place lists.
