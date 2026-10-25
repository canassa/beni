## 2026-10-25 22:58 CET — Ownership v2 S1: the L0–L4 foundations

**What I did**

Built slice S1 of `docs/design/ownership-v2.md` (#1012) in two pull requests
on `src/own2/`, behind nothing yet (the hidden `--ownership=v2` is S0's):

- #1027, L0–L1: `Ids.zig` (sixteen id newtypes, the per-declaration
  `Account` with growth allowance and baseline lanes, `Chunks`, a hash-free
  `FixedDict`, the one-shot `Tasks` queue), `Place.zig` (the place graph
  over an explicit type-graph `Source`, canonical paths with `⟲`, holds,
  structural encode/decode and graph-pair equality), the first piece of
  `Cell.zig` (the persistent patricia set), and `own2/rules_test.zig`, the
  layering gate.
- The second PR, L2–L4: the rest of `Cell.zig` (origins, labels, the trie,
  interning, splits, `alias`), `Facts.zig`, `Shape.zig` (interned nodes,
  persistent override maps, `proj`, `reach`, n-ary `join`, `map`,
  coinductive `leq`, `widen` as a congruence closure, the §7.5
  cross-checks behind `-Downership-full-cross-check`), `Prepass.zig` and
  `Regions.zig`, plus a `Bir.operands` walker every reader of a
  declaration's tree can share.

Every table reserves its records before allocating them; the unit tests
check the exhaustion and the invariant paths, `w5`'s 17-node DAG, a cyclic
type as one place, `widen` on `go`'s grafted levels, a chain of 64 deltas,
and `alias` returning a split.

**What I learned**

- Interning shape nodes by their set id only works if equal sets have equal
  ids: a canonical structure is not enough, the set nodes themselves must
  be hash-consed. Without it, projecting a widened cyclic value minted a new
  leaf per step and ran the account dry — a good sign the account works.
- A union must absorb a member it already has, or projecting a cyclic union
  nests `union(union(w, l), l)` forever; the coinductive `leq` then reaches
  its fixpoint.
- `Walk.structural` yields an `app`'s type arguments, not a constructor's
  payloads, so §2.1's "one walk over the solved type graph" cannot produce
  the `C#i` children by itself; `Place` reads the type graph through a
  source interface and the adapter is the next slice's. The `dict` place
  kind also has no identifying type word, and `Bir.Spread` does not exist
  before S2b. All three are reported as design gaps in the PRs.
- A `let_def`'s instruction precedes its body (its header is a forward
  reference), so a frame's range is computed from subtree starts, not
  assumed from post-order.
