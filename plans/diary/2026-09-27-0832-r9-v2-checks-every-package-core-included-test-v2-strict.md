## 2026-09-27 — R9: v2 checks every package, core included; test-v2 strict

**What I did**

- `--checker=v2` now checks `core`, the platforms and every package, so every record a v2 build
  reads is v2-written and the v1-ABI fallbacks are deleted. `test-v2` is strict (the ratchet is
  gone; only `v2-expected.md` entries skip), and the determinism, 600- and 5 000-module scenarios
  run under v2. `key_version` 4.
- Checking `core` under v2 found CK-130: the module rule answered `Basics`' own types from its
  own `eq`/`compare` before asking the well-known table, so `LT < GT` failed in other modules.
- The review confirmed `core`'s interfaces and types byte-identical under both checkers (only
  R8b's `no_function` bit differs) and `bench/corpus`'s JavaScript identical except one A.18
  `===` for an all-nullary field; a 56-line probe over every core comparison API matched v1 in
  dev and release.
- One exit criterion missed and deferred by my decision: `s_tup6000` checks at ~1.6× v1 against
  the 1.10× budget (CK-131; it was 1.89× before R9 and unmeasured since 2026-09-24). New slice
  R9b before R11. `bench/corpus/DictExtra.beni` rewritten: it compared a rigid `v`
  structurally, which v2 rightly refuses.

**What I learned**

- A benchmark nobody re-runs stops being a budget. The tuple scenario drifted to 1.89× over four
  slices because every slice measured the generated corpora instead.
