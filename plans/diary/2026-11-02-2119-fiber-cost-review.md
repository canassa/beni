## 2026-11-02 21:19 CET — fiber cost review

### What I did

Rebased workers-fiber-costs onto workers 753a1beed8 after #1725. A fresh controlled measurement still matches every retained/allocation delta and all six brotli caps exactly, so budgets.json stays unchanged.

Budget failures now list all offending cases and point to budgets.json, the measurement command and the verified-hash recording command. The CLI prints each ceiling's slack and the fast-path distance to its zero-allocation target. Positive slack requests tightening. Removed the architecture-only cache-key comment after the independent arm64 check confirmed identical results.

The gated benchmark check now calls all 18 Beni run* entries, validates every answer and checks that its entry list matches the exports. The reporting fixture fails with the implementation stashed: the old validator lists only the first breach. A wrong runTenHours answer also fails the expanded entry fixture. Restored code passes the targeted suite. Refreshed fiber and QueueGrowth run hashes; checked the existing S-program release goldens.

### What I learned

The #1725 metadata-folding change does not move this fiber baseline. The current fast-path distance remains 208.038112 bytes per point; the zero target is reported separately from today's ceiling. Collecting cost and size breaches together makes one measurement run sufficient to review every failing cap.
