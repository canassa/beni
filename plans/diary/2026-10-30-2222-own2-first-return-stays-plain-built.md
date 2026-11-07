## 2026-10-30 22:22 CET — own2: the first return stays plain, built (#1253 option B)

**What I did.** Built the owner's option B for #1253 item 1 on `own2-cycle-child`, rebased onto master after
#1359. `Place.extend` keeps the first return to a recursive place a plain step and folds the levels below it
into `⟲` (`ownership-v2.md` §2.1, as amended; notes in §2.2, §2.3, §2.7, §3.1, and Place's §5 target to
1 150). Widen opens and keys a first return like a `⟲`. A holder's text climbs back over one. Then made the
type-path walks linear: a first return is **sealed** when no place of its cycle above it has returned yet, and
below a sealed one every fold stays inside it and every return to its place lands on its one `⟲`. So `hits` of
it is empty, `levelsOf` of it is itself and its `⟲`, and the graft's levels now call `Place.levelsOf`.
Fixtures: `SiblingSubtrees` and its mutual and imported twins, each red on master. A counted build test,
*a K-wide recursive type grows linearly with K*. Gates green, 2 min 8 s.

**What I learned.**

- The counted program (a write of the root's list beside `t == t` over a K-wide `T`) cost 1 476 / 3 084 /
  8 988 records at K = 8 / 16 / 32 with the prototype, 2 164 / 5 740 / 19 420 through a `Maybe`; sealed,
  1 012 / 1 260 / 1 756 and 1 068 / 1 372 / 1 980, master's line (1 007 / 1 245 / 1 725).
- Sealing is exactly the condition under which nothing below a first return pops above it. It is read off
  the existing `ret` column, with no extra state.
- A value that is two levels deep no longer folds at all (`M k (Just (M k Nothing))`): the repeat is one node
  at two exact paths instead of a fold's `{lost}`. Groups settle one round later.
- On 4a + master, `incAll` 14 305 → 41 160 records (demands 638 → 1 174, walks 4 → 5), `incLeft` 9 565 →
  61 953, and `MarkerAcross.keepRight` stops at `ownership_summary_size`. That is 4a's demand multiplication
  (#1354, #1372), not the walks.
- `LevelRecursiveUpdates` is unchecked on master, so its 64:5 known entry cannot land here; 4a must carry it.
