## 2026-10-19 23:52 CEST — points-to copy edges, field summaries and load cells (#464)

**What I did**

Took issue #464 from the top on dagon: the release build of the research dashboard at
N=64 allocated tens of GiB and never finished, and the owner's bar is milliseconds. Profiled
the frozen master compiler first (`perf` from a nix shell, `--self-profile`): at N=16 the
whole compiler outside `specialise` takes about 10 ms and `specialise` 523 ms, all of it in
`Pts` (fact 3). Three structural causes, all in how `Pts` evaluated a constraint: a spread
re-walked every source site and every property on every change, with a linear property scan
and a union it then discarded; a member read re-unioned the property var of every site
whenever one changed and registered a dependency on each (9.7M dependency records per
fixpoint at N=64); and the `browser-inline` lowering emits one handler per widget message,
each with its own `const $before = $model` copy of the whole model and one spread of it,
so the work grows as sites × properties × spreads.

Built the `backend.md` §9 *combined solver*'s `copy`, `spread` and `load` as difference
propagation inside the existing `Pts` (`src/js/Spec.zig`): copy edges for bindings, call
arguments and returns that are unnarrowed names; a worklist of batched joins, no recursion,
one new slice per batch in the fixpoint's arena; field summaries per var that compose along
copy edges (one edge per property for a copy of a var); load cells per (var, property),
read by the reference sweep too; sorted properties. Every output in the corpus is
byte-identical (gates green on dagon, 519 release builds, every run hash). N=16 went
0.55 → 0.12 s, the N=64 spread reduction 1.35 → 0.09 s, the full N=64 dashboard from never
to 6.5 s at 1.1 GiB. Added `emit/release/inline/SpreadWide` (32 070M instructions before,
2 051M after, golden blessed with master's compiler) and two `Pts` unit tests. Recorded the
as-built note in `backend.md` §9 after the combined solver's slices.

Tried and reverted: composing load cells along copy edges, which made N=64 worse (8.9 s,
4.1 GiB) because the binding chain gave each handler's cell its own summary.

**What I learned**

- The residual cost at N=64 is a degenerate program, not the machinery: `Result.withDefault`
  is called with every widget's model and the inliner does not inline it (its first argument
  is a call, not an atom), so all 64 models merge into one var; the host JSON value then
  escapes them all, but before that 448 arm parameters each hold the merged 270 sites with 78
  property names. With the design's cap of 48 sites (`max_sites`, today the interim 1 000)
  the same build is 0.49 s at 219 MiB with identical output, and the structural passes
  (`pushChildren`, `srList`, `placeExpr`, `inlineScan`) become the profile. That is the
  owner's decision; so are context sensitivity for small helpers and letting the inliner
  bind a non-atom argument to a local.
- Under an edge model a node value is order-dependent in its escaped part: a cell keeps
  sites it linked through an object that later escaped, a fresh walk never sees them. The
  safety build's shuffled-order check now compares a `top` value on its live sites, which
  states the invariant (every extra site is escaped) instead of hiding it.
- A load's var must never go `top` through `makeTop`: that clears and escapes its sites,
  where the value a read gives keeps them beside `top`; the `uncapped` flag on `VSet` is that
  rule.
- The local machine cannot build beni (zig is killed for memory); every build, test and
  measurement runs on dagon, and the two clones of the branch must not both commit, or the
  pushes cross.
