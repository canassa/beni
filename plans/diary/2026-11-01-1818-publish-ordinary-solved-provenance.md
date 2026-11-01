## 2026-11-01 18:18 CET — Publish ordinary solved provenance

**What I did**

Part of #1296. Specified then implemented a diagnostic-only owned P9 ordinary Var inventory: selected entry schemes, final nominal parameters and exact originating alias scopes, private codec/common cache coverage, demand-aware loading and the existing hidden inspector consumer. No HostFree/Wire/ownership/transport permission is produced. Source default runs create no inventory; default loads of query-populated entries skip graph arrays but still read raw bytes and shared tables.

Focused validation: seven new named hermetic helpers plus structural/infrastructure controls passed (20/20 total); five new CLI cases and affected suites passed47/47, with additional four cursor and one legacy-consumer cases passing. Actual source error/restore/reset, OOM/fuzz, valid-index scope mutations, source0 warm caches, jobs/roundtrip/relocation and earlier-unrelated-module relinking are covered. A direct-writer review regression reproduced4,228 old-prefix bytes before MissingRepresentations; presence preflight now rejects with zero bytes. This is a narrow direct-API input guarantee, not broad OOM atomicity or a normal CLI reproduction.

Against accepted6bb compiler,34 module/mode pairs preserve public IFC and every other BEC section, all old dispatch payload bytes and original numeric refs/offsets; requested graph-only refs/strings append. Four dev/release builds have identical full JS trees. Matrix4/8/16 and sparse4/8 source checks all pass with actual D/T/E/F/R/Q inventories and exact old stdout prefixes. Failed preparation/test attempts were retained. Full gates, optimized budgets and combined integration remain parent work; no code commit/push was made by this agent.

**What I learned**

For Matrix16 the actual P9 store inventory is D2847/T2719/E11101/F804/R18/Q16, compared with595 compressed EntryRoots terms. This demonstrates why serialized DAG size cannot replace actual ordinary graph accounting; it proves no universal complexity bound. Store copy costs O(D+E), and original scope inputs R/Q are separately charged. Canonical HostFree construction and parametric Wire discharge remain separate unproved obligations. Template roots are not concrete payload specializations, and no v2 proof follows from this metadata.
