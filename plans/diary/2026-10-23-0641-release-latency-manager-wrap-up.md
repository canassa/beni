## 2026-10-23 06:41 CEST — release latency (#464): manager wrap-up

**What I did.** Managed and validated the agents on #464 after #717/#727, then wound the
work down at the owner's "good for now".

- Release optimiser: #745, #757, #772, #791 (one solve instead of two: N=64 −19.9%,
  nowd −19.6%, 100k −14.3%), #797, #801, #803, #826. Parked: #788–#790 (349 B of growth
  from #791), #827 (per-statement parallel rewrite, lowering per declaration).
- Checker: #786, #802, #804, #805, #807, #810 (linear in record width), #836 (#812,
  exhaustiveness linear in arms). Open: #813, #831.
- Ownership: #762 (#716), #785/#778/#777 (the #720 regression: core −34%, cross-check
  restored), #822 (#814, lazy summary blocks), #835/#849 (#825, `main` and `step`).
  Open: #848.
- #823 (#816): the bench generator writes current beni again.

Where it stands: N=64 about 0.12 s at `--jobs=1`, 0.11 s at `--jobs=8`; 100k 0.37 / 0.18 s.

**What I learned.**
- Removing work beat parallelising it every time it was measured. Fact 3 per SCC
  (one SCC holds 70%), ownership per group (one call chain holds 85%) and the write-set
  pass per key (about 4 ms) were each measured and dropped before any code was written.
- The superlinear costs share one root: an update of a wide record is analysed as a
  whole new record by ownership, fact 3 and the write-set pass. A "base plus changed
  fields" domain across all three is the next structural lever, not yet studied.
- An agent's fit can mislead: "69% fixed cost per module" in `check` came from
  regressing on line counts; per-module instruction counts put it at about 12%.
