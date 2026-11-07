## 2026-10-30 01:16 CET — a list of bound lists, projected once per place

**What I did**

- Profiled #1273. A list of n bound lists took 0.70 s at n = 100 and 2.54 s at n = 200 (Debug). `Cond.innersOf` and `Cond.side` grew with n². In `propagateFrom`, each of the n recast inners at the element's place was its own transition. Each transition projected every member through every member's own inners.
- First fix: one joined node per place in `frontier`. Verdicts and summaries did not move. But a probe's block did: a list of three spreads went from 1 756 to 1 624 bytes. I stopped and reported it.
- Second fix, as the coordinator ordered: a frame is one run of members plus a list of node records. The transitions are grouped by step, inner place and class, and the run is projected once per group. Each node keeps its own path, route, memo state and stored entry. The cursors are read once per frame.
- Results: 100 lists 0.71 → 0.23 s, 200 lists 2.57 → 0.28 s, 400 lists 10.86 → 0.49 s.
- Every corpus file's v2 dump is the same as master's, byte for byte, blocks included. Parity is unchanged.
- Added a counted test and a block pin. Resized three summary-size-limit tests, because the frontier now charges less. Opened PR #1285 and started one adversarial review.

**What I learned**

- A κ is stored under its node. Readers that go through `Shape.proj`, or through a union's sides in `dagKappa`, look up each inner's own child. So a dedupe that changes which node keys an entry is not sound, even when every verdict stays the same. The block bytes show it; the verdicts do not.
- The useful equivalence is in `side`. It depends on the inner's place, not on the inner. So the members' run can be shared while the nodes stay separate.
- The summary-size-limit tests sit a few hundred records under 65 536. Any change to charges moves them. Growth does not rise evenly with record width: one field more can add more than 1 400 records, so a "walk passes, print fails" window can disappear. I found a new one by scanning the width of the inner record.
- `pkill -f <pattern>` killed my own shell again, because the pattern was in my own command line.
