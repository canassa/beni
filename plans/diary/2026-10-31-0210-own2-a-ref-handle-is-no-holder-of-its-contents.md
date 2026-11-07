## 2026-10-31 02:10 CET — own2: a Ref handle is no holder of its contents

**What I did.** Fixed #1366. Under `--ownership=v2`, `Ref.set cell x` was
refused `later-use` when anything later reached the cell through the
handle: a second `Ref.set`, a call that writes the cell (`poke cell`), or
`alias` through a second name for the handle. The cause is in the holder
index (`src/own2/Holders.zig`, `targetKeys`). The writer demand of
`cellwrite` is on `param π1·◆`, and the index took every trie ancestor of
the demanded cell as a candidate. That includes `param π1`, the handle, so
the handle's local was paired with the demand and its later use counted.
§2.13.7 already says that `◆` is a barrier: a holder of a `Ref` holds none
of its contents, and the only outside holders are loans. Candidate
discovery now stops at `◆` (`upCell`, `upPath`). That puts the current words
into effect. It does not need S8's slot state, so S8 needs no known entry
for it.

New fixture `tests/corpus/ownership/RefSetThenWrite.beni` contains the
issue's probe, set-set, call-call and a handle alias, all accepted. Its
twin, `storedReadAfter`, stays refused: the stored payload is the old
contents and is read after the cell is written again. The cause is
`Ref.set`'s `consumed`. v1 has no demand for any of them, so each v2
demand is a known `absent` entry. The fixture fails on master (five
`absent :: rejected`), which I checked with master's `src/` in a scratch
copy. The verdict diff over the ownership and run corpus (v2 on master
against v2 on the branch, and `bench/ownership-everywhere.mjs
--diff=v1,v2` over 1 997 roots) shows no verdict or summary change. Only
the `account` lines of five run programs change, because their index
reads fewer keys (`readTwice` and the four `Deferred.complete`
finishers, demands 35 → 17). With PR #1395 (4a) applied, `run/RefUpdateAcrossFibers`
31:9 and 32:9 are accepted. The Holders line target goes from 2 010 to 2 030.

**What I learned.** The demand on `◆` is now refused only by conditions
1–4 or by a loan. But a loan of the old contents read after `Ref.set`
(`xs = Ref.get cell; Ref.set cell [1]; List.length xs`) was already
accepted on master, and it still is. §2.13.7's "Dead requires every live
loan of an aliasing contents cell dead" is not enforced. Loan lifetimes
belong to S8. For `Ref.set` the old array is not edited, so the
acceptance is harmless today. `Ref.update` is still unbuilt in v2
(`not built: top`/`local`).
