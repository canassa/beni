## 2026-11-01 15:30 CET — own2: fold first, a merge reopens kept sets

**What I did**

- Fixed the check of 90b9fb3d4. Bits propagate only within a node-graph component, so a resumed pass
  that merges components left kept bit sets without the merged component's other bits. A new state
  could then miss its own cycle: two rank-0 leaves at period 2, where only the new run links the step.
- A merge now propagates the merged component's bits again over the earlier states in it, before new
  states read them. The cost is `|E_K|·⌈|K|/64⌉` a merge, and a call has fewer merges than nodes. It is
  stated in §2.9 and §4.1, with a two-leaf test variant.

**What I learned**

- "Keep earlier results as sinks" needs two facts. Earlier answers must not change, which the rank
  argument gives. And the representation of what is kept must not depend on a partition that later
  work can coarsen. I had checked the first and not the second.
