# Keep writer effect facts separate

The first merged gate run caught unused ordinary function slots in unrelated
ownership reports. Effect collection had reused the slot-registering lookup.
It now reads existing slots and stores other parameter/path projections only
inside its effect facts. A projection without an ordinary callback protocol
proves only a known leaf effect; unknown or higher-order effects still refuse.
The revised portable layout is summary 40, cache entry 16 and interface 25.

A ReleaseSafe pre-fix compiler was built over the same fiber-merged tree.
Both whole ownership captures pass while observing their actual reports.
Of 6,657 sites, only three rejected needs disappear: DelegateWordedProtocol
6:17, HigherOrderWriter 18:18, and imported Main 4:18. The retained-list writer
and unknown writer stay refused. No accepted site becomes pending or rejected.
The imported cache fixture now also passes its callback through a record.
It fails before the fix and passes after it for both acceptance and refusal.
All ten cache files and interface hashes match byte for byte at jobs 1 and 8.
The codec round-trips field projections and rejects corrupt flags and counts.

Evidence: `~/worktree-evidence/wd-dom-wire/ownership-turn/final/` on dagon.
Part of #1825. This supersedes the initial version-39 precision evidence.
