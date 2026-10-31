## 2026-10-31 07:11 CET — own2: the levels below a first return, kept apart

**What I did.** I built the rule from the diagnosis, with the go-ahead: causes 1 and 2 of #1253
together. The spec is its own commit, in `ownership-v2.md` §2.1 (*one position, one name*) and §2.11
item 3 (*the written position*).

- **One name.** At a path that is not a `⟲` and not a sealed first return, `Place.extend(p, ⟲)` is now
  `levelsOf(p)` when that is one path. When there are several (`B (List B) (List B)`), `p⟲` stays as
  the name of their join, and three readers take each level path:
  - `Shape.projectLeaf`, with `Cell.projectRefinedLevels` for parts;
  - `Walk.Graft.compose`, through `Place.expandLevels`;
  - a call's written positions.
- **By path.** In `Transfer.otherPaths`, each route carries its canonical path (`routePath`). The
  path is dropped below a place on no cycle. A route that arrives at a written position (`Written`:
  the write path's expansion and the actual's nodes there) is skipped. A value beside the write is
  read by position (`reachBeside`), and a symbolic value above the base holds the written object
  itself when its steps land on the write's path (`atWritten`). `Calls.Beside.keyed` is now keyed by
  the reach, since one node may now have two.
- **Fixtures.** `LevelsApart` (T: three and four fresh levels accepted; five shared actuals refused;
  the answered level-2 list refused, which v1 accepts) and `LevelsApartRoutes` (B: distinct accepted,
  two shared refused).

**What I learned.**

- **The six refusals from my probe.** Five were the walkers' own inner calls (`incTs` under `incT`).
  A part above the base by position was read as holding it; `atWritten` fixed that. RoseKidsHeld
  42:21 is v1's own refusal under new path text, so it is not a regression.
- **Three holes appeared while I built it.** The node-identity probe's three stay refused, and are
  existing fixtures. A walk that followed place steps alone missed what a `recast` holds
  (`CastRegion`'s `shared` and `deepShared` were accepted), so a recast or leaf is now read whole. A
  join's sides at the write path were not in the frontier, so `Written` now holds them too.
- **Expanding a use mark at a join is too coarse.** In the callee's own List-rooted graph, `⟲` merges
  the `#B.0` and `#B.1` lists, so a `W` expanded to both level paths writes lists that `incAll` never
  writes. That refused `incList`'s own call. The `W` marks stay at the join, and the written
  positions expand instead.
- **I was wrong about `LevelRecursiveUpdates` 64:5.** It is matched too. The answered right subtrees
  below `l` are other value nodes, and the written left lists are skipped by path. A tree that puts
  the answered list on the written spine is still refused (`h1`–`h3` probes).
- **Entries.** All 47 #1253 entries are gone from the known file: 44 at 12 positions now get v1's
  verdict and are path text where the text differs, and the 3 at CycleJoinRankWriter 56:5 moved to
  #1439, a `choice`'s arms read together. The LevelRecursiveUpdates 64:5 entry is gone as well.
- **Cost.**
  - K-wide `t == t`, K = 32: 1 814 records plain and 2 038 through a `Maybe` (master 1 812 / 2 036).
  - A `T (List T)` tower literal at heights 8 to 128: 2 411 → 65 656 records (master 3 023 → 324 921,
    refused before).
  - The 90 counted "checker v2" build tests pass.
- **Master's known file.** It has a stray `|||||||` merge-marker line, from 5f891bcbc (writing comparisons). I left it as I
  found it.
