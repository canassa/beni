## 2026-10-19 09:58 CEST — slice 2 makes the emit rows, and nothing reads them

**What I did**

- Built slice 2 of #94's step two on `emit-cache-rows`: the funnel, the row kind and the maker
  (`backend.md` §9, *The embedded modules' printed text, in the pack*), with every build still
  lowering itself — the rows are made, word for word, and no build reads one.
- `src/js/Funnel.zig` is the funnel: every read `Lower` makes of the build whose answer can
  reach a printed byte now asks it — the six survivor sets, `arm_dead`, the `probe` of a
  `Js.maySuspend` body, `consumed`/`wanted`, `nullary`, the three comparator flags (`primitive`),
  `entry`, `development`, `core_private`, `schema_library`, `debug`, `markup`, `direct`, `steps`,
  every cross-module `needName` and the module-level runtime exports — and the answer is what it
  was: a build with no recorder pays a null check per ask. `Input.record` is set only by the
  maker, and each answer lands in the open unit's range; the prep-time asks enter no unit.
- `src/js/EmitPack.zig` is the row (`Kind.emit`, pack `version` 3, row format v1): keyed by
  SipHash-1-3 over `"BENIEMIT"`, the format version, the module key and one byte of
  `--schema-library`, holding the unit text as one blob and, per unit, the selector, facts, text
  range, marks' identities, `Needed` entries, runtime bits and replay edges. The head, tail and
  footer are not stored; the join rebuilds them.
- `src/core_pack_main.zig`'s maker lowers each cacheable embedded module once under canonical
  facts (development, `--schema-library` off, an all-live `Reach.Result`, no direct handle), adds
  the one payload under both option keys, then checks itself: decode → rebuild the pieces → join
  byte for byte.
- Two spec-vs-code catches before the PR: the merged spec says the pack stores two rows' identical
  bytes once, and that a refused module has **no row**. My first cut shared only edge lists and
  wrote zero-byte rows as refusal markers. Fixed both: `Pack.write` now shares `edges` and `emit`
  content (the map is content-keyed, so identical bytes share across kinds too); `refuses` moved
  out of `Maker` so the completeness check asks the same question of every module and requires no
  row for one the maker refuses; and the exact post-lowering markup net fails the maker with the
  module named, since the check cannot recompute a refusal the static scan missed.
- Evidence, one locked job: `diff -r` of master-today against the branch on `run/Dictionaries`,
  `browser/tea/ApiItems` and `bench/corpus` — 16, 43 and 62 files byte for byte, source maps
  included; the `emit/` goldens unchanged; no program ran under Node for want of a run hash;
  medians of 5 (`perf stat -e instructions:u`) against `acccea6a3`: dict 158.81M → 159.34M
  (+0.33%), apiitems 531.97M → 536.51M (+0.85%), corpus 421.97M → 425.21M (+0.77%).
- The pack: 4 182 851 → 6 672 561 bytes — 128 `emit` rows over 64 keys (57 modules plus seven
  extra chain instances: `Html` five times, `Dom`/`Hosted`/`Browser.Events` twice) resolving to
  53 distinct payloads of 2 486 126 bytes (pairs, instances and the five unit-less modules share),
  plus 3 584 of row table; the maker's run is 1 s, its compile 9 s. No embedded module is
  refused, and no row is empty.
- `zig build gates` green on the final tree (239/239 steps); the *As built* note is in
  `backend.md` §9, after slice 1's.

**What I learned**

- A pack's internal layout has no black-box witness: neither the payload sharing nor the refusal
  marker could be caught by a corpus fixture, a golden or a run hash. Reading the merged spec
  against the code line by line was the only instrument — twice in one slice, the document was
  right and my first cut was wrong.
- "A refused module has no row" is not the same as "a refused module has an empty row", and the
  difference decides where the refusal predicate must live: with no row, the completeness check
  has to re-ask `refuses` every run, and a refusal the static scan cannot see can only fail the
  maker — a cached marker would have hidden that defect.
- The payload map being content-keyed makes sharing cross-kind by construction: an `emit` row
  reuses an `edges` payload of identical bytes. The first test expectation (five payloads for
  seven rows) was wrong for exactly that reason, and the compiler caught it as `expected 237,
  found 232` — a good argument for asserting the blob's exact length, not just the offsets.
- The shared heavy lock serialized this session against a sibling's Lean runs, so the evidence
  job queued behind them and the last source edit had to precede the last gates run: a doc edit
  is free at any time, a `src/` edit costs a full gates cycle.
- `zig fmt` on this Zig rewrites `@intFromEnum` as `@backingInt`; new code has to be written with
  the latter or the gate's fmt step fails.
