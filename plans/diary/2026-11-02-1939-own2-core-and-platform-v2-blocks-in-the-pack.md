## 2026-11-02 19:39 CET — own2: core and platform v2 blocks in the pack

**What I did**

- #1704: under `--ownership=v2` every core and platform module is installed from the embedded pack, whose
  entries carry v1's block, so every core call read the pessimistic contract. The pack now carries each such
  module's OWN2 block as its own row kind (`own2`, Pack version 4) under the entry's key. The maker runs v2
  after each chain's run, in dependency order (`Enforce.packBlocks`); a v2 run's `Incremental.install` of a
  pack hit hands the block to the importers (`Inputs.from_pack`). The interface keeps v1's block, so every key
  and hash is unchanged and the platform rows still hit. An import read as unknown is now named in the
  importer's report. Spec: `ownership-v2.md` §3.6, *The checked core*.
- Fixture `ownership/CoreContracts` (fails parity before, passes after). Removed
  `run/ListSanitiserV2Writes.sanitize-lists-v2-refuses`; its v2 run is now accepted and runs the same.
- Rebased onto the integrated tests head (`6c86f09e1`) and measured there: pack +257 588 bytes (8 516 664 →
  8 774 252), v1 output byte-identical on 884 corpus files, v1 start-up unchanged, v2 start-up +~1 ms.
  `--diff=v1,v2` without the known list: v2 refuses where v1 accepted 385 → 312.
- Filed #1721 (a recursive callee's callback label is `once`: `List.map ys λy → [ …xs, y ]` traps under the
  sanitiser) and #1723 (Distinct's instSel/instCondMixed recurse without end; most of the new limit lines).

**What I learned**

- Core's real contracts mostly swap one refusal for another: `unknown`/`escaped` fall from 229 to 68, and
  `disjoint`, `top-level` and `call` rise. What is left of the 312 is v2's own precision, not #1704.
- Swapping a block inside an interface would change its hash and miss every platform row. Keeping v1's
  block in the interface and the v2 block beside it, keyed the same, avoids a second set of keys.
- A limit can hide a loop: raising `@ownership_summary_size` turned 9 new limit lines into a segfault.
