## 2026-10-30 01:32 CET — View chain images and delta composition

**What I did**

- #1279's re-review:
  - **Read-off.** `Shape.map` now gives every view of a forced chain the
    answer's image, so κ stored under a middle view survives read-off.
    `Summary.Table.add` also checks the nodes κ is stored under.
  - **Deltas.** A view's delta over a parameter whose actual is a delta
    composes over that delta's base, as `put` does. `map` does the same at a
    view base.
  - **Tests.** I added tests for the middle-view κ, a recast's inner view (at
    a place with nothing below, so the stored entry decides), a union's view
    side with a fold certificate, and the delta composition. Each test fails
    when its fix is reverted. I checked each revert in turn by editing a
    scratch copy.
  - **Rebase.** The branch is rebased onto #1261's tip.

**What I learned**

- A test of a κ read must make the stored entry decide the answer. The first
  recast test passed even with the fix reverted. Its place held lists, and
  then the read is `lost` whatever is stored.
- A debug check that makes a fresh `stamped.Column` per call breaks
  `build_test`'s slots-per-record bound, because safety builds run the check.
  `Ids.FixedDict` keeps such checks out of that count.
