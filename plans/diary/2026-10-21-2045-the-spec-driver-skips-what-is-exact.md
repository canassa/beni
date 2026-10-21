## 2026-10-21 20:45 CEST — the spec driver skips what is exact

**What I did.** Issue #624: make `Spec.run` run an analysis or a structural pass only when
something it reads changed, stop `fuseCalls` building nodes it then discards, and move
`analyse`'s arrays into a reused arena. A throwaway trace of every step of `Spec.run` (sum of
`Mod.epoch`, nodes, names, modules with `fact3` set, each step's answer) on the dashboard N=16,
N=64 and `nowd` showed the loops already stop at the first step that changed nothing, and that
every analysis and pass at N=64 follows a change to something it reads (analysis 3 after #575's
three nodes, analysis 4 after the structural pass, pass 2 on analysis 4's facts). So only
`prune` gets an exact skip: a prune that dropped nothing records `Spec.stamp` (the epochs and
the globals) and each declaration's module and statement, and the next prune with both equal is
not run. `fuseAt` now sums the old size first, stops copying at the first copy that reaches it,
and on a decline truncates every module it wrote back to a mark (`Mod.takeBack`): 1 913 nodes and
~170 names a pass at N=64 no longer stay behind. Four `--self-profile` counters
(`spec_prunes`, `spec_prunes_skipped`, `spec_fuse_declined`, `spec_fuse_taken_back`), a
`build_test` on `run/Dictionaries`, an *As built* note in `backend.md` §9. Outputs byte for byte
the same; −3.5M instructions and −180 faults at N=64, wall within noise. The arena move was not
built: the later analyses take under 1 MB of the compilation arena; the inliners take ~16 MB,
mostly `Copy`'s per-copy arrays (#634).

**What I learned.** "Changes nothing in the output" and "nothing it reads changed" are different
claims, and the issue had merged them: the first is a property of these programs, the second
of the driver, and only the second licenses a skip. A rollback of appended IR has a long tail of
side tables keyed by node or name index (`Tables.keep`/`discards`/`unobserved`, `prop_more`,
`findName`'s index, `nameIn`'s answers): the first gates run caught `Tables.keep` through
`releaseKeeps` reading a node past the end. Never roll `epoch`/`version` back, since caches
compare by equality.
