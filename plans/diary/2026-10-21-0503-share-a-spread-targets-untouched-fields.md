## 2026-10-21 05:03 CEST — Share a spread target's untouched fields

**What I did.** Issue #564: in `Pts`, a property no one has written has no var, and one only a
spread of a name writes shares one var with every other such field, keyed by the root of the
chain of copies its summary var is (`shareField`, `VSet.shared`, `VSet.sharers`). A literal's key,
`write`, a non-name spread, a second spread or a broken chain gives the property its own var,
fed as before and feeding what the property fed (`ownField`, `unshare`, `Prop.outs`). Two unit
tests, the corpus case `emit/release/inline/SpreadCopies` (4 751M on the base compiler, 4 103M
after, golden blessed on the base), and an *As built* note in `backend.md` §9. Every golden and
run hash unchanged. `nowd`: edges 663k → 269k, 0.50 s → 0.37 s. N=64: 1.36M → 0.51M edges,
0.65 s → 0.45 s.

**What I learned.** The issue's premise was off by one level. The 349 record updates do not
spread one summary. Each handler spreads its own `$before`, whose summary is linked to the
model's. Keying the shared var by the spread's own summary var moved `spec_pts_edges` by 11% and
time by nothing. Keying it by the root of the single-source chain gave the half the profile
predicted. The self-hosted backend inlines nothing: an extra `lowerBound` per fold copy put
`MergedChildren` up 3% in the gates' build while the ReleaseFast build got 19% faster. Passing
the property's index fixed it. Next, by the same argument: a summary that is a copy of one other
summary could be that summary, which would remove the per-handler links (about 22k of the 49k
edges left per `nowd` run).
