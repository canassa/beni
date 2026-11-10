## 2026-11-10 17:55 CET — an update that keeps no field makes no event

**What I did**

- A step of #1018 (records in the ownership checker v2), on branch `own2-full-update-no-event`, stacked on
  #2447 (the fix of #2443).
- `browser/tea/RecordUpdateCompare`: an update, a read of the written field of the old record, and then an
  update that replaces every field. The first update was refused, because the second one made an event as
  every update does. An update that keeps no field reads nothing of its record. `Update.of` now makes the
  event only where the update keeps a field or a row.
- This is the change that I made first, three hours ago, and took out again. Then it moved three lines of the
  corpus diff, and one of them was a wrong acceptance (#2443). Now, after the fix, it moves one line: the
  page's.
- Fixture `ownership/RecordFullUpdateLater`; mutant `full_update_reads`. A second fixture,
  `ownership/RecordFieldAfterWrite`, pins three more cases of the fix that I had only probed.

**What I learned**

- The order of two changes is part of their correctness. The same four lines of code were wrong before the
  fix and right after it.
- "No witness because the holder has no later use" was an accident that looked like a rule. The fixture for
  the full update (`RecordUpdateUse`, the probes) passed for that reason, and a read between the two updates
  was enough to break it.
- A probe that I ran after a fix and did not put into a fixture is a test that the next change does not run.
  I put the three into a fixture one pull request late, which is better than not at all.
