## 2026-10-17 09:31 CEST — Give the model's close the hand-over demand

**What I did**

- #284: the model's `close` demands the builder it closes, as the spec's `done b n` does. One operand: the builder's cells against the live cells after and its element cells. Two operands (map's identity form): the source's cells join the other operand paths. The owner decided it on the dashboard (q5).
- The stale-view program is refused now; its guard, its comment and `DESIGN.md` say so. The plan decides the view-contents clause: true on reachable states, scheduled with the proof of link validity after a linked write.
- Reported the counts that change in the campaigns, the enumerator and the fixtures.

**What I learned**

- A rule the spec has and the model lacks shapes the invariant around a program the spec forbids. The stale view was such a shape: a model gap, not a fact about links.
- A hand-over demand needs the result to carry the builder's cells, so the Dead test sees the builder's later uses but not the result's; the let case removes the bound variable's uses before the rhs is checked.
