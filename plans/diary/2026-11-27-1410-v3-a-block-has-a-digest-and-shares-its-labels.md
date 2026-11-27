## 2026-11-27 14:10 CET — v3: a block has a digest and shares its labels

**What I did**

- Worker `own3-speed`, issue #2549, PR #2720, after its adversarial review. The reviewer worked for
  about two hours on a checkout of the first push and reported three findings.
- Finding 1: one changed bit of a cache file gave another verdict. Bit 0 of byte 73 of a block was the
  write flag of a parameter: the block still decoded, the importer was accepted and written in place
  (it printed 20 where 16 is right), and the importer's entry kept that verdict after the file was
  repaired. Fix: the block has a digest of its bytes (`iface_bytes.hash`), and the reader checks it
  before it reads any other byte.
- Finding 2: a chain of types nested 240 deep wrote an entry of 83 MB for 38 kB of source. The cache
  reads no entry above 64 MiB, so each build wrote the entry again and no build read it. The block
  wrote the whole path of each entry of each layout: about d³/6 labels. Fix: an entry is written as the
  count of labels that it shares with the entry before, and the labels after. A block is at most
  32 MiB, and `Dir.store` writes no entry that `Dir.load` refuses. The reviewer's inputs now: 3.8 MB
  and 2.2 MB, and the warm build installs 16 of 16 modules.
- Finding 3: the first import of a core module that is new to a build moves the key of each module
  outside core (the term `core_epoch` of the transitive recipe). It costs reuse and not correctness.
  I did not change it: the narrow term needs the closed list of what a walk reads of core, which is
  #2718. Kernel §7.1 rule 1 states the cost.
- A run with no cache made a transitive key for each module (+0.02 % to +0.5 % instructions). It makes
  none now.
- The review branch moved by 157 commits. I merged it (no force-push). Its contracts have new fields
  (`Fn.before`, `Contract.answers` with a module index, `Read.capture`, `Published.keeps_messages`),
  and the codec's compile-time guard stopped the build on each one, as designed. A module index is
  written as the module's package and name.
- Tests: the damage scenario has a fourth kind (one bit inside the body of each entry), and a new
  scenario builds a chain of 20 and of 40 nested record types (the warm build installs each module, and
  the larger entry is less than 3 times the smaller). Mutation checks: with the digest check removed
  the damage scenario and the unit test fail, and with no shared labels the new scenario and the unit
  test fail.
- Evidence on the merged tree against the new base (127cce0419): the gates are green. The dumps of
  2 943 roots are equal. The ledger is 310 of 319. The check sweep has 0 faults in 2 943 roots, and the
  build sweep has 0 faults in 2 885 roots under two sets of flags. `examples/conduit` under
  `--ownership=v3`, least of 25 rounds: 168.5 ms with no cache on the base, 34.9 ms warm, 82.6 ms after
  an edit of `Main`, 104.8 ms after an edit of a leaf, and 176.6 ms cold. Instructions: +0.005 % with
  no cache, +1.7 % cold, −88 % warm.
- Issues from the review that are not this PR's: #2726 (an unfinished `schema` gives an internal
  error in a safe build) and #2727 (the other sections of a cache entry have no digest).

**What I learned**

- The nine unit tests of `own3/Block.zig` had never run. `src/beni.zig` names each module group in its
  test block, and `own3` was not there, so the tests were not compiled. A filtered `zig build test`
  that matches no test exits 0 with no message. I found it only because a mutation that had to fail a
  unit test did not. A test that I did not see fail is not a test yet: run a new test once against a
  broken build, also a unit test.
- Structure checks are not a checksum. I had argued that a damaged block either fails a bounds check
  or is harmless. A flag is one bit and every value of it is valid. The reviewer changed 5 058 single
  bytes and 16 of them changed a result with no miss.
- A format that writes a path for each entry of a tree is cubic in the depth for a chain: entries ×
  path length × layouts. Sharing the first labels with the entry before makes it one label for each
  entry on a chain, with no table and no second pass.
- My size guard in the codec had the wrong neighbour: the block's cap must be below the cap of the
  entry that holds it, and the writer of the entry must refuse what its own reader refuses. Else a
  build pays for a write at each run and never gets a read.
- The compile-time list of fields in the codec did its work at the merge: four new fields, four
  compile errors, each at the type that changed.
