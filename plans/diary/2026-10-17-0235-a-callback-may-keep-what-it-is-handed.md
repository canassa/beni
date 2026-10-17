## 2026-10-17 02:35 CEST — A callback may keep what it is handed

**What I did.** Issue #281, found by the review of PR #280. §16.4's supply edge checked a callback that
writes what its callee supplies, not one that keeps it in its result: `kParam f xs = t = f xs; ( t, List.push
xs 9 )` with `f = λys → ( ys, 1 )` was accepted, and in place `t.0` saw the push. A callee that hands on a
list it made itself and writes it after had the same hole, and no caller could see it. Two rules (spec: the
keep edge, §16.4): at the call, a borrowed supply of a parameter the callee writes rejects an actual whose
class may keep its parameter (`callbackKeeps`, cause `supply`, approximate because the summary does not order
the write after the call; the caller's own function parameter gets `need`); in the callee, a callback's
result is a holder of a non-parameter cell the call handed it (`cb_args`), so the later write is refused
there. Fixture `ownership/CallbackKeeps`, red on master. Gates green, `bench/ownership-everywhere.mjs` 0 of
850, the apps clean on `browser-direct`.

**What I learned.** A rule at the caller keeps `apply`-style functions precise, because the caller knows what
the actual keeps; a rule in the callee is needed only for what no caller sees. Putting the alias into the
callback's result value would have leaked into the summary's uses and supplies; making it a holder only for
the demand check keeps it inside the walk. `sepCells` already said "a callback may return what it was
handed" for conditions; the holder rule is the same fact for writes.
