## 2026-10-15 13:10 CEST — Direct byte review follow-up

**What I did**

Answered Claude's PR #134 review by softening causal framing, replaying the
stub account in reverse order, checking every protocol-shaped literal and
mask-read location, adding overlap and source-map guards, disambiguating both
timing artifacts, and recording paired-round bootstrap intervals. Rechecked
the null restatement sentinel and the pinned Solid/dom-expressions source
anchors. CI's no-budget job passed; no merge was performed.

**What I learned**

Changing stub order moves Conduit's descriptor charge by 286 B and patch-entry
charge by 176 B. All 642/22/0 rewritten literals occupy protocol positions;
there are exactly three protocol mask reads in each helper-bearing app.
Every descriptive latency interval includes zero; these samples prove no
statistical equivalence. TodoMVC's specialized builder writes null explicitly,
so padding the group-array record with null preserves its exact sentinel.
