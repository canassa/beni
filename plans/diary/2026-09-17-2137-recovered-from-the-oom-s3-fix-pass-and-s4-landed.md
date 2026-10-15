## 2026-09-17 21:37 CEST — recovered from the OOM; S3 fix pass and S4 landed

**What I did**

- **Reconstructed the killed session** from its transcript and the two agents'
  transcripts. The OOM hit at ~17:45 with the S3 fix agent and the S4 backend
  agent both mid-gate; neither had reported, and their work sat uncommitted in
  one tree. Both slices were audited and reviewed before anything was committed.
- **S3 fix pass** (`04fdd62`). A read-only review of the uncommitted pass found
  defects 1 and 3 verified, 2 and 4 partial, and three blocking findings: the
  per-instantiation obligation duplicated Rule U3's deferral so every failing
  `where`-clause diagnostic printed twice (and one success path passed the same
  evidence twice); `declaresCompare` ignored `pub` and was module-scoped, so an
  unrelated `pub compare : Tag, Tag -> Order` made `Wraps Handle`'s `<` compile
  to an unsound call. Two more surfaced mid-slice from the S4 side: a `number`
  literal against an *imported* constrained callee got no evidence site (the
  emitted call was one argument short and Node threw at load), and the A.55
  branch sent every `foreign type` — `List` included — to `Basics.eq`, turning
  a correct refusal of `[ Id 1 2 ] == [ Id 1 99 ]` into a silent `False`. All
  fixed at the obligation and the gate, not the output; `Dispatch.zig`'s dedup
  block went away entirely. Spec appendix A.54–A.60 records the decisions.
- **S4 backend** (`a7f8219`). The prior agent's work was complete on all eight
  scope items; the completion agent added the A.7 `pub foreign … where`
  scenario, an `emissionOrder` rescan fix and the `internal` report for
  evidence-shape mismatches. Review then found that wall did not check arity
  (too-long and too-short evidence lists both emitted wrong-arity calls that
  ran) and four silent `undefined` returns; fixed, with an in-source test over a
  synthetic table proven to fail first. `run/UserEqInsideRecord` is held for S5,
  its refusal pinned as a blackbox scenario.
- Gates run by me on the combined tree: all green, blackbox twice.

**What I learned**

- **Two concurrent implementers plus a long manager transcript is over the
  machine's memory.** Each agent runs its own `zig build` pipeline; three at
  once with ReleaseFast benches in the mix is what died. The recovery worked
  because every agent's transcript survived on disk, but it cost a session.
  Rule now: one implementer building at a time, reviewers read-only alongside,
  no ReleaseFast inside agents, and `git worktree` for every fail-first proof.
- **Concurrent slices find each other's bugs faster than reviews do.** The
  cross-module literal site and the `List` regression were both caught by the
  backend running the checker's table, not by anyone reading `Solve.zig`. The
  `emit/` goldens caught the double-evidence regression the same way. Wiring
  slices together early is worth the coordination cost.
- **"Fix at the obligation, not the output."** The dedup block in
  `Dispatch.finish` hid a real duplication for a whole slice; removing it made
  a third duplicate source (Rule U2 vs the instantiation) visible immediately.
- **Harness gap, not fixed:** `corpus_test.zig` collects `core/` subdirectories
  with `projects=false`, so a two-module `--core` fixture cannot exist; the
  `PrivateForeignCompare` fixture carries a `foreign_outside_platform`
  diagnostic instead. One-line change, owed to S5 or S6.
- Follow-ups owed: a `dispatch/` golden pinning that the only `err` part a
  clean program produces is a `number` one (`structuralEq` relies on it); the
  churn test in `build_test` flaked twice on a first run after a rebuild
  (`churn.sh` swallows a failed spawn with `|| true`).

Next: S5, well-known `eq` — the derived bodies the backend currently refuses.
