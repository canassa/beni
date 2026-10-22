## 2026-10-22 03:44 CEST — S1's decisions, and the work in flight

**What I did**

- Reviewed and merged, or checked before merging: #654 (`⊤` arguments across modules), #656 (enum
  cycles as conditional chains), #661 (fact 3's order check compared storage, not facts), #665
  (#456), and #659 (short field names in validator shapes, merged by the owner).
- Recorded the owner's decisions of the day in #668, `browser-inline.md` §8.4 and S1's tracking
  table (`plans/s1-gap-and-latency-report-2026-10-22.md`, Part 3):
  - §8.4's program-site handlers and D-c are reversed for S1's fix 7: one closure per root,
    writes in place, readers registered once at mount, built after #315 R4–R7.
  - The #286 chain is built without measurement gates; `DictFocus.grow`'s false refusal is
    accepted and returns with #294 (#663).
  - #294: `Dict.empty ⊤` in place of a name-keyed lowering, the Int/String key constraint as its
    own slice, and Tea's key tables as a private sorted array, which keeps W47 as amended on
    2026-10-02 (keys equal by their type's own `compare`).
  - #653: shape-read records get release names (it supersedes 2026-10-19's pinning).
- Wrote the agents' prompts: #447, F2, the `let` that stops `Opt` from inlining an arrow used once,
  release field names coloured by co-occurrence (#662), #294 and #658.
- Told #631 that an emit cache must key a caller's output on its callees' trailing unit parameters.
- Freed dagon's disk (91 % to 28 % used) with a cleanup agent; agent prompts now end with removing
  their worktree, cache and /tmp files.

**What I learned**

- A guarantee needs its source named before a restriction is weighed against it: W47's guarantees
  come from type identity and `Cmd.map`'s segment, and "any key type" is a convenience, so a sorted
  table keeps it at no cost.
- Short names are not free under brotli. A renamer's namespace size decides how short the names are:
  153 fields in one namespace gave most of them two letters.
