## 2026-11-08 19:16 CET — accept the n² cost of annotated alias chains

**What I did**

- Answered the four `@claude` findings on #2123 (#1475). One was a real defect: in `InterfaceTerms.Reader.expand`, a failing `getOrPut` after the exact `put` let an `errdefer` free a key that the memo held. Both memo entries now go in after one `ensureUnusedCapacity(2)`. `AliasShape.fits` makes a shape that names a missing argument unknown. Two `check/bad` fixtures pin that a hidden function key is refused after a clean application. #2123 is merged.
- The owner took option A for #2074 (2026-11-08): `checker-v2.md` §7.4, *Amended 2026-11-08*, accepts the n² cost of n annotations over a chain of n aliases, in words. No code changed. `perf_test.zig`'s doubling-record scenario keeps its claim, "not exponential".
- Corrected §7.4's 2026-11-06 amendment: the fixture is `check/good/AliasDiamondChain`, not `run/`.

**What I learned**

- A linear cost for #2074 is not one memo. The ground type is copied by the readings, generalisation, instantiation, the type keys and ownership v2, and the readings are only 19% of the cost at n = 128.
- The review found the out-of-memory defect only because it asked about a leak. Read every `errdefer` again after a `put` moves ownership into a map.
