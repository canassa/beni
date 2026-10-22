## 2026-10-22 22:05 CEST — Copy the remaining borrowed Ref lists

### What I did

Applied the owner's #219 decision at four genuine sharing sites:
RefUpdateImpure, the chat server, the websocket benchmark server and
LogSetMinimum. Each append copies the borrowed Ref list before changing it.
The Ref API keeps its existing ownership contract.

Recorded O1's LIST-only acceptance and the completed cause-by-cause work in
ownership-checker.md §30.7. The complete audit on scalar-key master plus the
ownership fixes and these copies covers 1,505 roots/module sets and 1,295
LIST lines: zero rejected, zero pending, no check/dump errors. The driver is
published on #210. Its 326 record reports are identical to the separate
site-and-cause inventory on #315; those remain report-only R4 input after
#286.

Integrated actual master c6fb3c022, including the emitter's const-alias
change after the scalar-key change. The Workers transcripts/hashes remain
current; LogSetMinimum's development/release hashes are refreshed. The
locked self-hosted full gate passes. The checker precision and all earlier
ownership controls were validated before #794 merged; the final copies
retain the programs' existing behaviour.

### What I learned

Ref.update lends its old value to its callback. A list append there must
make the version it owns explicitly, even when the program's purpose is an
unrelated effect or server operation. That is a fixture/application fix,
with no extra promise from Ref and no copying workaround in a platform.
