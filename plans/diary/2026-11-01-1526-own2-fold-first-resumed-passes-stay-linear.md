## 2026-11-01 15:26 CET — own2: fold first, resumed passes stay linear

**What I did**

- Closed the approved #1535's last LOW finding: `k` resumed hits over one shared sub-DAG cost
  `O(k·|D|)` in pass 2. A resumed pass 2 now numbers only the newly read states. Earlier states are
  sinks whose components, cycle bits and bit sets are kept. The bits have one node numbering for the
  whole call, so a pass that merges node-graph components leaves the kept sets valid. §2.9 and §4.1
  updated.

**What I learned**

- Keeping earlier results as sinks is exact only when nothing old can reach anything new except
  through the boundary. Here the boundary is the hit, and the rank argument gives exactly that.
