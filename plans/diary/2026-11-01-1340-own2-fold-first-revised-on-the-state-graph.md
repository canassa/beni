## 2026-11-01 13:40 CET — own2: fold first, revised on the state graph

**What I did**

- Took over #1535 after its adversarial review, whose findings 1 to 5 blocked the spec. Rewrote §2.9
  *Fold first* in place, and updated §4.1 and §8 question 8.
  - The reference is now a walk whose frames carry their route and whether they are folded. A folded
    frame looks its children up too, and the deduplication key is the whole frame. That makes it
    order-independent by construction.
  - The rule reads each state `(node, bits, run)` once into a state graph and computes a cycle bit (does
    a state reach its own node again). Then it builds positions by their set of states: a set with a
    cyclic state is a fold whose content is its closure. No key holds a route or a component.
  - Proved that the rule gives the reference's snapshot, and that today's walk makes the reference's
    folds or fewer. Every choice of folds is sound, so today's order dependence costs precision only
    (finding 7, no issue needed).
- Prototyped it in scratch on master `169bab548` with #1526's fix: today's walk, the reference and the
  rule behind environment switches.
  - Corpus: no line changes, records +0.22 %. All 30 373 calls give one id seven ways: each walk with
    and without the memo, and in both frontier orders.
  - #1289's chain at 8 calls: 1 036 652 → 53 147 records.
  - `removeMin`'s walk-2 joins: 7.3 M → 391 k. It is still a limit: its later walks have up to 14 670
    distinct states.
  - The reviewer's counterexamples, built as tied knots: coprime knots form one component of the state
    graph. A two-level knot with a 2^12-path sibling costs today's walk 16 386 positions and the rule
    33 states.
- Filed #1537: by reading, the old walk's clean memo can record `.none` for a state below another
  state's fold. It is 0 times in the corpus.

**What I learned**

- With the routes taken out, a position's subtree is a function of its set of states. A fold can land
  only where a cyclic state stands. So F2's memo needs no fold signature, and the region memo has no
  upward marks to replay.
- The first version of the cycle bit used a bit set over every node and cost 29 M records on one call.
  Restricting the bits to the nodes on a cycle of the node graph made it small. Pass 1, one read for
  each distinct state, is now about 80 % of the large calls. That read is the floor.
- A run that is cheaper changes how far a group gets before a limit. So the two runs' call sequences
  part, although every call they share gives the same id.
