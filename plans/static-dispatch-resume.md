# Resuming the static-dispatch spike on a new machine

**State at handoff (2026-09-18, `64a4b90` on `spike/static-dispatch`):** S0–S7 landed
and reviewed. S8a (measure) is partway: the S6b-header correction, M1a and M1b are
committed in `3984d2d`. Owed: the remaining S8a rows, then S8b (report 19).

Read in this order: `CLAUDE.md`, `plans/static-dispatch-s8-brief.md` (the procedure;
its "Manager decisions" block is binding), the last four entries of `plans/diary.md`,
the last three entries of `plans/static-dispatch-spike-results.md` (the format to
append in), `bench/README.md` (measurement discipline).

## 1. One-time setup on the new machine

```sh
git clone --recurse-submodules git@github.com:canassa/beni.git   # or fetch
cd beni && git checkout spike/static-dispatch && direnv allow
zig build && zig build test && zig build test-blackbox && zig build fmt-check   # must be green

# A = the C0 proxy: master's checker/backend plus the harness, ReleaseFast
git worktree add ../beni-s1 c870e9a
( cd ../beni-s1 && direnv exec ../beni zig build -Doptimize=ReleaseFast )
stat -c '%s' ../beni-s1/zig-out/bin/beni       # 13 317 664 on the N100; record whatever it is here

# B = the branch, ReleaseFast, never installed into the branch's zig-out
zig build -Doptimize=ReleaseFast --prefix /tmp/rf
stat -c '%s' /tmp/rf/bin/beni                   # 16 854 856 on the N100
```

## 2. The machine question — decide before taking a row

Every number in the results file is from one Intel N100 (4 cores, 16 GB). The
remaining rows compare against C0 sides taken there. Pick one:

- **(a) Same machine later.** Nothing changes; continue at §3.
- **(b) New machine.** Open the results file with a heading
  `## <date> — machine 2: <cpu, cores, RAM, OS, zig, node>` and re-take on it the C0
  sides the remaining rows cite: M2 (A binary, `constraint-chain` at n ∈ {10, 100,
  1000, 2000}), M5 R1–R6 with `--variant=c0` on A, M3 on A (`bench/churn.sh` on
  `bench/corpus` and `core --core`), M4 on A (`node bench/size.mjs`), M8 counts on
  `c870e9a`'s tree. Then take the B sides ABBA against them. Report 19's §1 method
  section must say which rows are on which machine; M1a/M1b stay N100-only.

## 3. S8a — remaining rows (brief §3, in this order)

M2 · M3 (B only unless (b)) · M4 with the split fields (`eq_bytes`/`eq_functions`/
`compare_bytes`/`compare_functions`/`order_bytes`/`order_tables` added to
`bench/size.mjs`, asserted by the existing `build_test` scenario) · M5 (write
`bench/runtime/c1/R5EvidenceForwarding.beni` and `c1/R6Megamorphic.beni` to their
C0 headers — same `-- ops:`, checksums 5000000 and 1352000 or the row is void; R4's C1
side is B against `--variant=c0`; one session C1→C0→C1→C0 `--runs=20`; `--cpu-prof`
on R4 and R6 both sides, top-10 self-time) · M8 · M9 · M7 (in a throwaway worktree
`../beni-s8`, removed after).

Rules: `uptime` before every instrument, verbatim; nothing recorded above load 2.0;
ABBA for every pair; results file append-only, `date` for headings; no `src/` change
(stop and report); bless nothing. Commit S8a when the rows are in and the gates are
green: `✅`-style is wrong — use `📝 S8a: <rows>`.

## 4. S8b — report 19

`docs/design/research/19-static-dispatch-spike-results.md`, outline in the brief §5,
model `research/12-js-output-and-chunking.md`. Every figure cites a results-file line.
§15 is trade-offs, not a verdict; §16 lists what could not be determined. Read-only
review of the report before committing (numbers traced, claims without a recorded
number flagged). Then the diary entry, and stop — the adoption decision is taken on
`master` after the report is read, never on the branch.

## 5. How to drive it

Manager pattern (`~/.claude/…/memory/manager-workflow.md`): one Opus implementer
for S8a, then one for S8b, each followed by a read-only reviewer; commit per
validated unit. Concurrency: on the N100 only one agent may build at a time (an
earlier session was OOM-killed by two); on a larger machine relax that, keep the
cap of 5 agents. Prompt to start a session with:

> Continue the static-dispatch spike from `plans/static-dispatch-resume.md`. Do the
> one-time setup, decide §2 (I am on <same machine | a new machine: …>), then run S8a
> and S8b as the brief says.
