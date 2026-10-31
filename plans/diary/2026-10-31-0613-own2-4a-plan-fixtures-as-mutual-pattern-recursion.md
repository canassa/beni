## 2026-10-31 06:13 CET — own2 4a's plan fixtures as mutual pattern recursion

**What I did**

- Wrote #1394's fixtures as mutual pattern recursion, as the manager decided on #1421 (Q3). A writer of every kids list (`incAll`/`incT`/`incRose`) and a list walker over `[ x, …rest ]` form one recursive group. That needs neither `List.get` nor a callback. The fixtures are `FoldedBCall` with `FoldedBCallImported`, `FoldedPreimageCall` (#1159's probes 0–5), `FoldSymbolicCall` (#1199's A and B, and #1196's decision-1 probe), `RecastActualSep` (#1219), `RoseKidsHeld`, `FoldedWriteCall`, and `CycleJoinRankWriter` (the writer half). Each one has v1's goldens.
- `RecastActualSep` matches v1 outright. `RoseKidsHeld` matches it at every call, and only the path text differs. The others need known entries:
  - 211 for canonical path text (#1253 option B). These have the same verdict at the call.
  - 47 owned by #1253. The levels below the first return fold into one `⟲` class, so distinct lists at the third level and below are refused. The smallest case is `incT (T [ T [ T [] ] ])`, refused where `incT (T [ T [] ])` is accepted.
  - 16 owned by 4c. Inside the group, `incList`'s `incAll b` at a `⟨B⟩` fold reads `repeated`, as in #1429.
  - 3 for R-4.3.5. v2 accepts `incTs kids` before `List.length kids`, which v1 refuses `later-use`. It's sound, and the callers still refuse the shared actual.
  - A known limit owned by #1372. The four-member group over the mutual `A`/`C` walks past the default allowance. With the allowance raised, it takes about 22 walks and 1.16 M growth for `incAs`.
- Filed #1435 with the red fixture `tests/pending/ownership/LocalEmptyInCtor.beni` (CK-315). A local `k = []` wrapped in a constructor and handed to an element writer is refused `disjoint` (approx), and the inline `[]` is accepted. No recursion is involved. It isn't unsound.

**What I learned**

- Using `k = []` as the shared list in these fixtures hits #1435 and hides what the fixture is about. Appendix B's `k = [ B [] [] ]` doesn't, so every fixture uses a non-empty `k`.
- The plan expected 4a to hold v1's verdicts on the distinct twins, because their actuals are acyclic literals. They don't: #1253's fold of the levels below the first return refuses them. The heights of CycleJoinRank, `opened` and `prefixDistinct` are all that case. These entries are owned by #1253 and not by 4c, as LevelRecursiveUpdates 64:5 is.
- No v2 acceptance where v1 refuses was found at any call, except R-4.3.5's sound one.
- `beni check` on a fixture writes `.beni-cache` beside it, and `dump` doesn't. Use `--no-cache`, or run projects from a copy.
- `test-pending` on master already reports a stale RED line (`WriteOneLevel`) and a green `scenario/CK-314`. Neither is from this change.
