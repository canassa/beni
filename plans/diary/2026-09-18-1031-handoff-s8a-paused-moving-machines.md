## 2026-09-18 10:31 CEST — handoff: S8a paused, moving machines

**What I did**

- Committed the S8a rows the previous session had taken before it died
  (`3984d2d`): the S6b-header correction, M1a interleaved (check 1.20×, emit
  1.48× on a corpus with no dot-call), and M1b as one corpus through two
  compilers (1 683 errors on `master`'s checker, 0 on the branch).
- Stopped the relaunched S8a agent before it appended anything. The tree is
  clean and pushed. Two stale agents from the S3/S4 era were reported
  "stopped" on resume; their work is in `10f89b5`–`a7f8219`, nothing lost.

**Handoff — resuming on another machine**

- **Every number in `plans/static-dispatch-spike-results.md` is from one
  Intel N100.** The remaining S8a rows (M2, M3, M4, M5, M7, M8, M9 — brief
  §3) must not mix machines with the rows above. Either take them here later,
  or on the new machine re-take the C0 sides they compare against (M2, M5 R1–R6
  need the A binary; M3/M4/M8 cite S1's C0 rows at `:220/:293/:448` and would
  need re-taking too) under a new "machine 2" heading, and let report 19's §1
  method section say which rows are on which machine.
- **Binaries:** A is a ReleaseFast build of `c870e9a` (`git worktree add
  ../beni-s1 c870e9a`, then `zig build -Doptimize=ReleaseFast` — 13 317 664 B
  on the N100); B is HEAD built `--prefix /tmp/rf`. Neither worktree nor
  `/tmp/rf` travels; recreate both.
- **Still owed by S8a:** the `size.mjs` split fields (`eq_bytes` … `order_tables`)
  and `bench/runtime/c1/R5EvidenceForwarding.beni`, `c1/R6Megamorphic.beni`
  with the C0 checksums (5000000, 1352000). Then S8b writes report 19 per the
  brief's §5 outline.
- **Machine rules that came from the OOM:** one building agent at a time, no
  concurrent `zig build`, reviewers read-only. On a bigger machine relax as it
  allows, but keep the ABBA interleaving — it is what made M1a's 20 % trustworthy
  where S6b's 8 % was not.

**What I learned**

- A session can die with an agent mid-append and leave a valid, partial,
  uncommitted results file: append-only plus raw-lines-verbatim is what made
  it committable as-is instead of reconstructed.
