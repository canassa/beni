## 2026-10-29 20:46 CET — Ownership v2: escape queries indexed and charged (#1226)

**What I did**

- `Demands.escapedAt` tested every escape point of its cell for every write, with no charge:
  e × w tests at growth 0 (Astra's review, 10⁶ at 1 000 × 1 000). A frame's escape points are now
  one sorted run per cell. Each point carries its run prefix's point of least `rank₂`. A query
  is one binary search, charged as growth of the run's size. The sort is charged once.
- The change stays inside `buildEscapes` and `escapedAt`. Demands stays under its 1 200-line
  target: the old two-pass count-and-fill became one sort of packed (cell, point) words.
- A counted black-box test sets escape and write counts independently (4 and 96). The mixed
  difference of the frame's inspections is 368, which is w · (log₂ e + 1); the product would be
  8 464. A lower bound makes the test red on master, where the term was 0 because nothing was
  charged. An escaped twin is refused `escaped` 16 times.
- Added Astra's §4.1 and §8 text, with an *As built* note.

**What I learned**

- Uncharged work cannot be seen in an account, so a test that bounds the product from above
  passes on the defect. What makes it red-first is a lower bound: the charged queries must show up.
- §2.5's second order turns "earlier and compatible" into a 2-D dominance query. A prefix
  minimum over a sorted run answers it, with no per-region index.
- Charging log-size work on a fixed demand lane would reach the lane's ceiling at about 2¹⁶
  escapes, so the probes go to a growth task.
