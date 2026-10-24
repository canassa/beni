## 2026-10-25 01:36 CEST — construction guards see what an operand holds below

**What I did.** Took over #474 (Dict.focus accepted one list in two tuple
payloads). It still reproduced on `7aa6b06c9`, and it was two defects, not one.

The general one: `spineValue` and `splitSpineValue` built a construction's
per-path separation guards and skipped every pair whose paths nest. So a list
stored at `[*].0` was never compared with what another operand holds there.
That operand was `π1[*]`, the old elements, in `List.push l ( xs, 0 )` inside a
helper, or `acc` for a spread `[ …acc, y ]`. The focus rule reads only the
written array's spine, so `List.update` edited one position in place while
another held the same list. The bare spread `snoc [ xs ] xs` was unsound too.
The new `besideCell` projects the other operand's cell to the stored path and
compares the two there. Fixtures: `BesideTupleHelper`, `BesideRecordHelper`,
`BesideLiteralHelper` and `BesideSpreadHelper`, each with a fresh control, red
on master by stash. `ownership-checker.md` has an amendment under *Construction
evidence*.

The Dict one: §20.8's `storedPair` lowers `Dict.insert`'s `π3` spine, and a
caller applies a parameter entry's spine condition only to the argument's root
cells, never to the list at `#Node.2.0`. Applying it to every list of the
argument refused the case but also refused DictFocus.groups, DictTupleFocus
(CK-266) and a FoldAccumulators case. The manager decided not to build the
precise fix in code that #294 deletes. Three red pending fixtures (CK-270:
`DictTupleAlias`, `DictRecordAlias`, `DictHelperAlias`) hold the refusal, each
with a fresh control that must stay accepted.

**What I learned.** The whole-corpus verdict diff is easiest with a wrapper as
`BENI_EXE` for `corpus_test`: on every `build` or `check`, it runs `check
--ownership-everywhere --diagnostics=json` with both compilers in the same
directory. That reaches projects and browser pages, which a per-file `dump`
cannot (2 of 3 files have no module context alone). The harness gives the
child a bare `PATH`, so the wrapper must export coreutils itself. `beni dump
--stage=ownership` overflows the stack on `parse/good/Lambdas.beni` on master
(#954).
