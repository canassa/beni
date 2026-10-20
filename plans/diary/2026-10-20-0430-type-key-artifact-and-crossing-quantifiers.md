## 2026-10-20 04:30 CEST — the type-key artifact and crossing quantifiers

**What I did.** Built slice 2 of `plans/type-directed-points-to.md` (#489)
to the amended contract (`backend.md` §3, §9, merged as #493):
`check/TypeKeys.zig` keys every Bir local and allocating instruction by
canonical closed type, lists what a module adds to the wild set (`Js.from`
and `Js.to` types, closed types a crossing quantifier is instantiated at,
`?` subjects), and computes per-quantifier `crosses` bits to a fixpoint,
published in `Interface.Quantified` (iface format 13). The artifact is the
cache entry's sixth section (`cache/type_keys_bytes.zig`, entry format 12),
made on every build. `dump --stage=typekeys` (hidden), `check --type-keys`
(hidden), `tests/corpus/typekeys/`, and a warm/cold/reordered-interner pair
in `cache_test.zig`. Spec in `checker-v2.md` §36.

**What I learned.**
- Keying only under `--release` would make a release build depend on a
  warm cache: `--release` is not in the entry key. The plan said release
  only; the amendment says every build, and that is the only sound choice.
- Records must be ordered by field TEXT, not symbol id, both in the node
  and in the order a walk interns children, or a cached artifact differs
  from a fresh one. The reordered-interner test is red without the sort.
- Under D2's safe form, `core/List` alone has 57 crossing quantifiers (its
  beni-in-core arrays go through `Js.from`), so every element type of a
  list handed to a `List` function joins the wild set. Expect slice 4's
  precision on list-heavy models to be limited by this.
- Cost: about 1.6M instructions per `bench/corpus` check, 2.5% of the
  check phase's instructions; I could not get it under 2% (callgrind shows
  the cost spread over the walk, interning and the crossing pass). The
  `type_keys` sections add 26 KB to 107 KB of entries (+24%).
