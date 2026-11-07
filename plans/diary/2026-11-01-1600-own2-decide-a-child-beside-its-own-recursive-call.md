## 2026-11-01 16:00 CET — own2: decide a child beside its own recursive call

**What I did**

- #1546. Rebuilt the program: `dup t = case t of N v l _ → N (List.push v 1) (dup l) l`, and a caller
  `drive t = dup (N [] t t)`. v2 refuses `dup l` in the body (`later-use`) and accepts the caller at
  `<N …>#N.0` (fresh) and `<N …>#N.1#N.0` (param). v1 gives the same verdicts on its folded paths.
- Decided it by execution. With copies, `drive (N [ 5 ] (N [ 6 ] L L) L)` is
  `N [1] (N [5,1] (N [6,1] L L) (N [6] L L)) (N [5] (N [6] L L) L)`. With every write in place where its
  verdict is accepted, and the refused sites copying, it is the same. With every write in place, `#N.2`
  becomes `N [5,1] (N [6,1] L L) L`: only the writes refused in `dup` change the result. Safe.
- Why (§2.11 item 3, rule (a), the #1367 amendment): the alias in the result is `dup`'s own and is
  refused there. The second `t` at `#N.2` is a path that `dup`'s class does not mark, so it is not beside
  the write. The twin `other` reads `π1#N.2` and its caller is refused `disjoint`.
- Added `bench/ownership-dup-oracle.mjs`: 9 callee bodies × pattern depths 1–3 × local or imported × 10
  callers, 7 inputs each, 3 780 runs. 0 differ on the real verdicts; 1 010 differ with every write in
  place (384 where only the callee is refused, 626 where the caller is).
- Fixture `ownership/ChildBesideOwnCall` with a v2 golden, six `absent` entries in
  `ownership-v2-known.txt` (v2 names `#N.1#N.0` apart from `#N.1⟨T⟩#N.0`), and a *Decided* note in
  `ownership-v2.md` §2.11 item 3. No compiler change.

**What I learned**

- With these verdicts the caller's accept at `#N.1#N.0` cannot be wrong in a run: the only way `dup`
  writes there is the refused inner call. The `other` twin is where the caller's check does work.
- A caller that destructures `dup`'s result and rebuilds it (`N a (N (List.push b 9) x y) z`) stops at
  the summary-size limit in v2 (#1548). That is a limit, not an accept.
