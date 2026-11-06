## 2026-11-06 14:23 CET — An arrival past a `var` says so (parked)

**What I did.** Redid #2112 on #2104's head as the callee's bit: a leaf read past a `var` is `past`, it arrives open and deep as `π1#1.0#0.0*↓`, keeps no suffix, and crosses every caller, block version 28. Five fixtures and a twin, a sweep family of arrivals past a fold (`~/.cache/beni-agents/s4k/gen/past.mjs`). Parked on `own2-open-past-fold-wip` when #2104 failed review: gates and the final bar were not run.

**What I learned.** The caller cannot tell a value at a fold from one below it, and the one bit replaces every test by place: the sweep's 3 360 TRAPs went to REFUSED with no SAME→REFUSED. The readers that concatenate an arrival's slot with a suffix (`FedWrite`, `PlainReach`, `LabelChain`) are the places a bit like this has to reach.
