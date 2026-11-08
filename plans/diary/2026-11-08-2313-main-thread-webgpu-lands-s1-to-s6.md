## 2026-11-08 23:13 CET — Main-thread WebGPU lands, S1 to S6

**What I did**

- Managed #1277 as planner and validator, with one Opus agent per slice on dagon and an independent
  read-only review of every PR before merge.
- Merged, in order: S1 (#2254, #2255), S2 (#2262, #2265), S3 (#2266, #2269), S4 (#2289), S5 (#2296),
  S6 (#2306). #2240–#2244 are closed. #1277 stays open for the worker slice (#1299).
- Stacked each lane on the previous slice's branch so no lane waited for a merge.
- Moved CI to self-hosted runners on azathoth and tuned them (3 runners, CPUQuota 1000%, host caches
  written only by master runs). A warm run took 13.4 min against GitHub's 16–20. #2264 waits for the
  owner's code-owner review.

**What I learned**

- Merge the base of a stacked PR with `--merge`. A rebase merge of #2262 rewrote S2a's SHAs and
  #2265 conflicted in 15 files. Master's copies equalled S2a's head, so taking S2b's side was exact.
- Deleting a stacked PR's base branch closes the PR. Retarget it to master first.
- An agent's "N passed" can come from uncommitted files. S5's Chrome goldens were blessed from a
  racy run, and the corrected bless never reached a commit. Re-run Chrome fixtures at the pushed head
  before merging.
- Every independent review found a real blocker: S4 swallowed a defect on cancel and could hang a
  nested session; S5 committed racy goldens; S6's coverage gate passed rows that no fixture
  exercised. Green gates alone would have merged all three.
- Chrome on dagon needs a short `TMPDIR` symlink: with a long scratch path it fails to start
  (`ChromeDidNotStart`), most likely because socket paths must be at most 107 characters.
