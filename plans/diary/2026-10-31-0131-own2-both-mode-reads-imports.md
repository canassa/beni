## 2026-10-31 01:31 CET — own2: --ownership-both reads imported modules' v2 blocks

**What I did**
- Found why `dump --stage=ownership --ownership-both` marked every declaration that calls another project module `unchecked (not built: call)` while `--ownership=v2` checked it (#1398). An interface carries one ownership block. Under both mode the session's check runs v1, so the block is v1's, and `Enforce2.dump`'s `ImportReader` could not parse it.
- `Enforce2.dump` now checks each module after the modules it imports and keeps the block it publishes in a table the reader uses in place of the interface's. v1 is untouched.
- Added a build test: both mode on `ElementsApartImported` prints v1's report, the marker, then exactly the `--ownership=v2` report.
- Re-blessed the `.v2.unchecked` goldens that the parity run (`--ownership-both`) reads. 95 lines went: 48 declarations are now checked, 47 stay unchecked for a later cause (lambda, ctor, markup, record_update, local). Core lost exactly Clock.virtual, Set.singleton and Set.isEmpty. No verdict flipped (parity passed).

**What I learned**
- Any golden written under both mode was weaker than v2's own report. Blessing under both mode hides import gaps; the new test pins the equality.
