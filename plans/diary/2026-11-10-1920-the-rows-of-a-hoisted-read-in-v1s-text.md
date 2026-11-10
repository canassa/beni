## 2026-11-10 19:20 CET — the rows of a hoisted read, in v1's text

**What I did**

- The first part of S5b of #1018 (the record half of the lowering channel under checker v2), on branch
  `own2-record-hoist-rows`, stacked on #2450.
- Read v1 first: the emitter's side (`src/js/Lower.zig`, `placeHoists`) and the place where v1 makes its rows
  (`placement`, `publishRead`). v1 prints the rows in its dumps, and 12 fixtures pin them.
- v2 counted the reads that an accepted record write hoists. Now it keeps them: the read, its holder, where it
  is bound, and when. The report prints them in v1's text.
- Compared the two checkers' rows over the whole corpus with a copy of the diff tool that reads `hoist` lines:
  55 rows the same, 3 only in v2 with a reason each, none only in v1.

**What I learned**

- A dump line is the cheapest contract between two implementations. I did not touch the emitter, and I know
  that 55 rows agree.
- Three things were wrong in the first build, and the comparison found each in minutes:
  1. Garbage in the output. A line's rows were in the round's arena, and the lines outlive the round. A kept
     judgement copies its condition for the same reason; I had to do the same for the rows.
  2. A field capture's read was named by the closure. v1 names the access inside the lambda and places it by
     the closure.
  3. One row of a `run/` fixture was missing. I had kept one row for a read; v1 keeps one for a read and a
     depth (`m.form` and `m.form.name` are two rows of one source read).
- A need's accepted write had no line in v2, by a rule that is right for lists ("judged, with no line of its
  own"). For a record the line carries the rows. Without it the lowering would not bind `p.x` before a call
  that writes `p` through a callback's answer. The fixture for an unnamed field set (`RecordFieldSets`) had
  two lines fewer than v1 for that reason, and I had accepted that in #2426.
- The line targets of six files moved in one step. The facade was the one that I refused to raise twice: the
  rows' order went into the channel's file, where it belongs.
